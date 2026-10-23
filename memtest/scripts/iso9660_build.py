#!/usr/bin/env python3
"""Minimal ISO9660 assembler (pure stdlib, zero dependencies).

CLI:
    python scripts/iso9660_build.py <layout_dir> <out.iso>

File names are strict Level-1 8.3; directory identifiers are Level-2
(1-31 chars). This split is deliberate: the GRUB module dir X86_64-EFI
exceeds the Level-1 8-char cap (see _validate_name).

Writes a mountable, UEFI-bootable ISO9660 image:
- Logical sector 2048 bytes; PVD (type 1, magic "CD001") at LBA 16.
- Volume descriptor sequence = PVD + El Torito Boot Record + terminator
  when the layout contains EFI/BOOT/BOOTX64.EFI; NO Joliet SVD, NO Rock
  Ridge (no SP/ER system-use fields).
- El Torito (grub-mkrescue-compatible, for OVMF/UEFI firmware): Boot
  Record (type 0, "EL TORITO SPECIFICATION") at LBA 17, boot catalog
  (validation entry platform 0xEF + no-emulation default entry) pointing
  at a generated FAT16 ESP image which is stored on the ISO as the file
  EFI/BOOT/EFI.IMG and embeds EFI\\BOOT\\BOOTX64.EFI. Without
  BOOTX64.EFI the sequence stays PVD + terminator (pure ISO9660).
- File names: all upper-case 8.3 (e.g. BOOTX64.EFI); file directory
  records carry the ";1" version, directories do not; every directory
  record contains "." and ".." entries.
- Path table: little-endian (type L) required, big-endian (type M) also
  written; PVD points at both LBA and sizes. Path table and directory
  records match the data-area layout (file data 2048-aligned).

Layout contract (used by the memtest SOL ISO pipeline):
    EFI/BOOT/BOOTX64.EFI
    GRUB/GRUB.CFG
    GRUB/X86_64-EFI/*.MOD
    BOOT/MT86PLUS.BIN

Exit codes: 0 success; non-zero on empty layout or illegal (non-8.3) names.
"""

import os
import sys
import time

SECTOR = 2048
PVD_LBA = 16
BOOT_RECORD_LBA = 17
# Without El Torito: terminator at 17 and L path table at 18.
# With El Torito:    terminator at 18 and L path table at 19
# (PVD 16 + BootRecord 17 + Terminator 18), computed in build_iso.

# FAT16 ESP (no-emulation El Torito boot image) geometry.
ESP_MIN_SECTORS = 6144                 # 3 MiB minimum -> >= 4085 clusters (real FAT16)
ESP_FAT_COUNT = 2
ESP_ROOT_ENTRIES = 512                 # root dir = 32 sectors
ESP_SECTORS_PER_CLUSTER = 1

# ISO9660 d-characters (ECMA-119 7.4.1) plus a conservative set of DOS 8.3-safe
# specials. Separators that would corrupt the 8.3 form or clash with the ';1'
# version suffix (space, ';', ':', '/', '\\', '*', '?') are deliberately
# excluded so a non-conforming name always fails validation (review F3).
D_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
SAFE_SPECIAL = set("-^~!#%&@{}()'")
NAME_CHARS = D_CHARS | SAFE_SPECIAL


class _File:
    __slots__ = ('name', 'src', 'data', 'extent', 'size')

    def __init__(self, name, src, data=None):
        self.name = name          # upper-case ISO name (no version)
        self.src = src            # absolute source path on disk (None if generated)
        self.data = data          # generated content bytes (e.g. ESP image) or None
        self.extent = 0
        self.size = 0


class _Dir:
    __slots__ = ('name', 'parent', 'subdirs', 'files', 'extent', 'size', 'number')

    def __init__(self, name, parent):
        self.name = name          # upper-case ISO name (no version); '' for root
        self.parent = parent
        self.subdirs = []
        self.files = []
        self.extent = 0           # directory data LBA
        self.size = 0             # directory data size (sector-aligned)
        self.number = 0           # path table record number (root = 1)

    def get_or_add_subdir(self, name):
        for s in self.subdirs:
            if s.name == name:
                return s
        s = _Dir(name, self)
        self.subdirs.append(s)
        return s


def _validate_name(name, is_dir):
    """Validate and upper-case an 8.3 file name or a directory name.

    Allowed characters are ISO9660 d-characters plus a conservative set of
    DOS 8.3-safe specials (NAME_CHARS); spaces and ';' (the ISO version
    separator) are rejected so every accepted file maps 1:1 to an 8.3 name
    without an accidental second ';1'. File names are strict Level-1 8.3;
    directory identifiers may be up to 31 chars (Level-2 limit, needed for
    the GRUB module dir X86_64-EFI). Raises ValueError for names that
    cannot be represented.
    """
    up = name.upper()
    if is_dir:
        # Level 1 caps dir names at 8 chars, but the GRUB module dir
        # X86_64-EFI (9 chars) is a hard layout requirement; readers
        # (Windows cdfs, GRUB iso9660) consume the length field, so allow
        # up to the Level 2 limit (31). File names stay strict 8.3.
        if not (1 <= len(up) <= 31):
            raise ValueError("directory name must be 1-31 chars: %r" % name)
        if any(c not in NAME_CHARS for c in up) or '.' in up:
            raise ValueError("invalid directory name (ISO9660): %r" % name)
        return up
    base, dot, ext = up.partition('.')
    if dot and '.' in ext:
        raise ValueError("file name has multiple dots (not 8.3): %r" % name)
    if not (1 <= len(base) <= 8):
        raise ValueError("file base name must be 1-8 chars: %r" % name)
    if dot and not (1 <= len(ext) <= 3):
        raise ValueError("file extension must be 1-3 chars: %r" % name)
    if any(c not in NAME_CHARS for c in base + ext):
        raise ValueError("invalid character in file name (ISO9660 Level 1): %r" % name)
    return base + ('.' + ext if dot else '')


def _collect(layout):
    """Walk layout dir; build the directory tree and return (root, file_count)."""
    root = _Dir('', None)
    file_count = 0
    for dirpath, dirnames, filenames in os.walk(layout):
        rel = os.path.relpath(dirpath, layout)
        parent = root
        if rel != '.':
            for part in rel.split(os.sep):
                parent = parent.get_or_add_subdir(_validate_name(part, True))
        for fn in sorted(filenames):
            iso = _validate_name(fn, False)
            if any(f.name == iso for f in parent.files):
                raise ValueError("duplicate ISO name %r under %r" % (iso, rel))
            parent.files.append(_File(iso, os.path.join(dirpath, fn)))
            file_count += 1
    if file_count == 0:
        raise ValueError("layout is empty: no files to pack: %r" % layout)
    return root, file_count


def _path_table_order(root):
    """Return non-root dirs ordered per ISO9660 path-table rule:
    grouped by ascending parent record number, sorted by name within group.
    BFS with per-level name sort satisfies this ordering."""
    result = []
    root.number = 1
    frontier = [root]
    number = 1
    while frontier:
        nxt = []
        for d in frontier:
            for s in sorted(d.subdirs, key=lambda x: x.name):
                number += 1
                s.number = number
                result.append(s)
                nxt.append(s)
        frontier = nxt
    return result


def _record_len(nameb):
    """Total byte length of a directory record for a name of len(nameb) bytes."""
    body = 33 + len(nameb)
    return body + (1 if body % 2 else 0)


def _make_dir_record(name, is_dir, extent, size, date7, name_is_bytes=False):
    """Build one ISO9660 directory record (ECMA-119 9.1)."""
    nameb = name if name_is_bytes else name.encode('ascii')
    if not is_dir and not name_is_bytes:
        nameb = nameb + b';1'
    body = 33 + len(nameb)
    pad = 1 if body % 2 else 0
    rec = bytearray()
    rec.append(body + pad)                    # length
    rec.append(0)                             # extended attribute record length
    rec += extent.to_bytes(4, 'little') + extent.to_bytes(4, 'big')
    rec += size.to_bytes(4, 'little') + size.to_bytes(4, 'big')
    rec += date7                              # recording date (7 bytes)
    rec.append(2 if is_dir else 0)            # file flags (dir bit)
    rec.append(0)                             # file unit size
    rec.append(0)                             # interleave gap size
    rec += (1).to_bytes(2, 'little') + (1).to_bytes(2, 'big')  # volume seq no
    rec.append(len(nameb))
    rec += nameb
    if pad:
        rec.append(0)
    return bytes(rec)


def _path_table_record(name, extent, parent_num, endian):
    """Build one path-table record (ECMA-119 9.4).

    A 1-byte padding field is added when the identifier length is ODD,
    keeping the record length (8 + len + pad) even.
    """
    nb = name if isinstance(name, bytes) else name.encode('ascii')
    rec = bytearray()
    rec.append(len(nb))                       # directory identifier length
    rec.append(0)                             # extended attribute record length
    rec += extent.to_bytes(4, endian)
    rec += parent_num.to_bytes(2, endian)
    rec += nb
    if len(nb) % 2 == 1:
        rec.append(0)                         # padding (odd length)
    return bytes(rec)


def _iso_date(t=None):
    t = t or time.localtime()
    tz = int(-time.timezone // 900)           # GMT offset in 1/4 hours (UTC+8 -> 32)
    return bytes([(t.tm_year - 1900) & 0xFF, t.tm_mon, t.tm_mday,
                  t.tm_hour, t.tm_min, t.tm_sec, tz & 0xFF])


def _pvd_date17(t=None):
    """17-byte volume-descriptor date string: YYYYMMDDHHMMSScc + tz char."""
    t = t or time.localtime()
    tz = int(-time.timezone // 900)
    digits = "%04d%02d%02d%02d%02d%02d%02d" % (
        t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, 0)
    # encode tz (1/4-hour units, 0..61) as '0'-'9','A'-'Z','a'-'z'
    if tz < 10:
        tzch = chr(ord('0') + tz)
    elif tz < 36:
        tzch = chr(ord('A') + tz - 10)
    else:
        tzch = chr(ord('a') + tz - 36)
    return (digits + tzch).encode('ascii')


def _build_pvd(root_rec, vol_size, pt_size, l_pt_lba, m_pt_lba, date17):
    pvd = bytearray(SECTOR)
    pvd[0] = 1
    pvd[1:6] = b'CD001'
    pvd[6] = 1
    pvd[8:40] = b' '.ljust(32, b' ')          # system identifier
    pvd[40:72] = b'MEMTEST SOL'.ljust(32, b' ')  # volume identifier
    pvd[80:84] = vol_size.to_bytes(4, 'little')
    pvd[84:88] = vol_size.to_bytes(4, 'big')  # volume space size
    pvd[120:122] = (1).to_bytes(2, 'little')
    pvd[122:124] = (1).to_bytes(2, 'big')     # volume set size
    pvd[124:126] = (1).to_bytes(2, 'little')
    pvd[126:128] = (1).to_bytes(2, 'big')     # volume sequence number
    pvd[128:130] = SECTOR.to_bytes(2, 'little')
    pvd[130:132] = SECTOR.to_bytes(2, 'big')  # logical block size
    pvd[132:136] = pt_size.to_bytes(4, 'little')
    pvd[136:140] = pt_size.to_bytes(4, 'big') # path table size
    pvd[140:144] = l_pt_lba.to_bytes(4, 'little')  # L path table location
    pvd[148:152] = m_pt_lba.to_bytes(4, 'big')     # M path table location
    pvd[156:190] = root_rec                   # root directory record
    pvd[190:318] = b' '.ljust(128, b' ')      # volume set identifier
    pvd[318:446] = b' '.ljust(128, b' ')      # publisher identifier
    pvd[446:574] = b' '.ljust(128, b' ')      # data preparer identifier
    pvd[574:702] = b' '.ljust(128, b' ')      # application identifier
    pvd[702:739] = b' '.ljust(37, b' ')       # copyright file identifier
    pvd[739:776] = b' '.ljust(37, b' ')       # abstract file identifier
    pvd[776:813] = b' '.ljust(37, b' ')       # bibliographic file identifier
    pvd[813:830] = date17                     # volume creation date/time
    pvd[830:847] = date17                     # volume modification date/time
    pvd[847:864] = b'0' * 17                  # expiration (unknown)
    pvd[864:881] = b'0' * 17                  # effective date (unknown)
    pvd[881] = 1                              # file structure version
    pvd[882] = 0                              # unused (must be zero)
    # 883..1394 application use (512 bytes, zero-filled); 1395..2047 reserved
    return bytes(pvd)


def _dir_data_bytes(d, date7):
    """Serialise one directory's data: . .. subdirs files, sector-aligned.

    Per ECMA-119 9.1.10 the "." entry is a single 0x00 byte and the ".."
    entry a single 0x01 byte (not the '.'/'..' characters).
    """
    parent = d.parent or d
    parts = [_make_dir_record(b'\x00', True, d.extent, d.size, date7, name_is_bytes=True),
             _make_dir_record(b'\x01', True, parent.extent, parent.size, date7, name_is_bytes=True)]
    entries = ([(s.name, True, s) for s in d.subdirs] +
               [(f.name, False, f) for f in d.files])
    entries.sort(key=lambda e: e[0])          # ISO9660: mixed, byte order by name
    for name, is_dir, node in entries:
        parts.append(_make_dir_record(name, is_dir, node.extent, node.size, date7))
    blob = b''.join(parts)
    blob += b'\x00' * (-len(blob) % SECTOR)
    return blob


def _find_efi_boot(root):
    """Locate EFI/BOOT/BOOTX64.EFI in the collected tree.

    Returns (parent _Dir, _File) or (None, None) when absent. Directory
    identifiers were upper-cased by _validate_name, so names are EFI/BOOT.
    """
    for d in root.subdirs:
        if d.name == 'EFI':
            for s in d.subdirs:
                if s.name == 'BOOT':
                    for f in s.files:
                        if f.name == 'BOOTX64.EFI':
                            return s, f
    return None, None


# --------------------------------------------------------------------------
# FAT16 ESP (no-emulation El Torito boot image) -- hand-written, zero deps.
# --------------------------------------------------------------------------

def _fat_dirent(name83, attr, cluster, size):
    """Build one FAT directory entry (32 bytes, no LFN)."""
    assert len(name83) == 11, 'FAT 8.3 name must be exactly 11 bytes: %r' % name83
    e = bytearray(32)
    e[0:11] = name83                          # 8.3, space padded
    e[11] = attr
    e[12:14] = b'\x00\x00'                    # NT reserved, ctime tenths
    dos_time = (10 << 11) | (0 << 5) | 0      # 10:00:00
    dos_date = ((2026 - 1980) << 9) | (10 << 5) | 23  # 2026-10-23
    e[14:16] = dos_time.to_bytes(2, 'little')  # creation time
    e[16:18] = dos_date.to_bytes(2, 'little')  # creation date
    e[18:20] = dos_date.to_bytes(2, 'little')  # last access date
    e[20:22] = (0).to_bytes(2, 'little')       # high cluster (FAT16: 0)
    e[22:24] = dos_time.to_bytes(2, 'little')  # write time
    e[24:26] = dos_date.to_bytes(2, 'little')  # write date
    e[26:28] = cluster.to_bytes(2, 'little')   # low cluster
    e[28:32] = size.to_bytes(4, 'little')      # file size
    return bytes(e)


def _make_fat16_esp(efi_data):
    """Build a FAT16 ESP disk image (sector-aligned) embedding efi_data as
    EFI\\BOOT\\BOOTX64.EFI. Returns bytes of length total_sectors * 512.

    Layout: boot sector (1) + FAT1 + FAT2 + root dir (512 entries) + data.
    Cluster count is forced to >= 4085 so the volume is a true FAT16
    (EDK2 FatPei/FatDxe pick the FAT flavour from the cluster count).
    The image size grows (in 512-sector steps) until everything fits.
    """
    bps = 512
    spc = ESP_SECTORS_PER_CLUSTER
    n_fats = ESP_FAT_COUNT
    root_entries = ESP_ROOT_ENTRIES
    root_sectors = root_entries * 32 // bps
    reserved = 1

    file_clusters = (len(efi_data) + bps - 1) // bps
    need_clusters = 2 + file_clusters          # EFI dir + BOOT dir + file

    def solve(total):
        fat = 1
        while True:
            data_start = reserved + n_fats * fat + root_sectors
            clusters = total - data_start
            fat_need = ((clusters + 2) * 2 + bps - 1) // bps
            if clusters < need_clusters:
                return None
            if fat_need <= fat:
                return fat, clusters
            fat = fat_need

    total = ESP_MIN_SECTORS
    while True:
        r = solve(total)
        if r is not None and r[1] >= 4085:     # real FAT16
            fat_sectors, clusters = r
            break
        if total >= 65535:
            raise ValueError("BOOTX64.EFI too large for a FAT16 ESP")
        total += 512

    data_start = reserved + n_fats * fat_sectors + root_sectors
    img = bytearray(total * bps)

    # --- boot sector (built separately, then slice-assigned: bytearray
    #     slices are copies, so mutating a slice view would not reach img) ---
    bs = bytearray(512)
    bs[0:3] = b'\xEB\x3C\x90'
    bs[3:11] = b'MEMTEST '
    bs[11:13] = bps.to_bytes(2, 'little')
    bs[13] = spc
    bs[14:16] = reserved.to_bytes(2, 'little')
    bs[16] = n_fats
    bs[17:19] = root_entries.to_bytes(2, 'little')
    bs[19:21] = total.to_bytes(2, 'little')    # total < 65536 -> 16-bit form
    bs[21] = 0xF8
    bs[22:24] = fat_sectors.to_bytes(2, 'little')
    bs[24:26] = (32).to_bytes(2, 'little')     # sectors per track
    bs[26:28] = (64).to_bytes(2, 'little')     # heads
    bs[28:32] = (0).to_bytes(4, 'little')      # hidden sectors
    bs[32:36] = (0).to_bytes(4, 'little')      # total32 (16-bit form used)
    bs[36] = 0x80                              # drive number
    bs[37] = 0
    bs[38] = 0x29                              # extended boot signature
    bs[39:43] = b'\x2a\x4d\x53\x01'            # volume id (arbitrary)
    bs[43:54] = b'MEMTEST SOL'.ljust(11, b' ')
    bs[54:62] = b'FAT16   '
    bs[510:512] = b'\x55\xAA'
    img[0:512] = bs

    # --- FATs (FAT1 + clone FAT2) ---
    fat = bytearray(fat_sectors * bps)
    fat[0:2] = (0xFFF8).to_bytes(2, 'little')  # entry 0: media byte marker
    fat[2:4] = (0xFFFF).to_bytes(2, 'little')  # entry 1: end marker

    def set_chain(start, n):
        for i in range(n):
            val = start + i + 1 if i < n - 1 else 0xFFFF
            off = (start + i) * 2
            fat[off:off + 2] = val.to_bytes(2, 'little')

    set_chain(2, 1)                            # EFI dir cluster
    set_chain(3, 1)                            # BOOT dir cluster
    set_chain(4, file_clusters)                # BOOTX64.EFI chain
    img[reserved * bps:(reserved + fat_sectors) * bps] = fat
    img[(reserved + fat_sectors) * bps:(reserved + 2 * fat_sectors) * bps] = fat

    # --- root directory (1 entry: EFI) ---
    root_off = (reserved + n_fats * fat_sectors) * bps
    img[root_off:root_off + 32] = _fat_dirent(b'EFI'.ljust(11), 0x10, 2, 0)

    # --- EFI dir (cluster 2) ---
    def cluster_off(c):
        return (data_start + c - 2) * bps

    img[cluster_off(2):cluster_off(2) + 96] = b''.join([
        _fat_dirent(b'.'.ljust(11), 0x10, 2, 0),
        _fat_dirent(b'..'.ljust(11), 0x10, 0, 0),    # parent is root
        _fat_dirent(b'BOOT'.ljust(11), 0x10, 3, 0),
    ])

    # --- BOOT dir (cluster 3) ---
    img[cluster_off(3):cluster_off(3) + 96] = b''.join([
        _fat_dirent(b'.'.ljust(11), 0x10, 3, 0),
        _fat_dirent(b'..'.ljust(11), 0x10, 2, 0),    # parent is EFI
        _fat_dirent(b'BOOTX64 EFI', 0x20, 4, len(efi_data)),
    ])

    # --- BOOTX64.EFI data (cluster 4..) ---
    img[cluster_off(4):cluster_off(4) + len(efi_data)] = efi_data

    return bytes(img)


# --------------------------------------------------------------------------
# El Torito boot record + boot catalog.
# --------------------------------------------------------------------------

def _build_boot_record(cat_lba):
    """Boot Record volume descriptor (El Torito 2.x / ISO9660 type 0).

    System identifier "EL TORITO SPECIFICATION" (offset 7-38), boot catalog
    pointer both-endian at offset 71.
    """
    br = bytearray(SECTOR)
    br[0] = 0
    br[1:6] = b'CD001'
    br[6] = 1
    br[7:39] = b'EL TORITO SPECIFICATION'.ljust(32, b'\x00')
    br[39:71] = b'MEMTEST SOL UEFI'.ljust(32, b'\x00')   # boot identifier
    br[71:75] = cat_lba.to_bytes(4, 'little')
    br[75:79] = cat_lba.to_bytes(4, 'big')
    return bytes(br)


def _build_boot_catalog(esp_lba, esp_sectors):
    """Boot catalog: 32-byte validation entry (platform 0xEF EFI) + 32-byte
    initial/default entry (no-emulation, boot indicator 0x88).

    Validation-entry checksum (El Torito 7.4.1): the sum of all sixteen
    16-bit little-endian words of the entry must be 0 modulo 65536. The
    checksum word (offset 28) is set to 0x10000 - (sum of the other 15
    words). Verified against the official memtest.iso and edk2 CdExpressPei.
    """
    # validation + default entries are built into one 64-byte block, then
    # slice-assigned (a bytearray slice is a copy, so it must not be mutated
    # in place after being taken as a view)
    head = bytearray(64)

    # validation entry
    head[0] = 1                               # header id
    head[1] = 0xEF                            # platform id: EFI
    head[4:28] = b'MEMTEST SOL'.ljust(24, b'\x00')  # identifier
    head[30] = 0x55
    head[31] = 0xAA
    total = 0
    for i in range(0, 32, 2):
        if i == 28:
            continue                          # checksum word treated as zero
        total += head[i] | (head[i + 1] << 8)
    ck = (0x10000 - (total & 0xFFFF)) & 0xFFFF
    head[28] = ck & 0xFF
    head[29] = (ck >> 8) & 0xFF

    # initial/default entry
    head[32] = 0x88                           # boot indicator
    head[33] = 0x00                           # media type: no emulation
    head[34:36] = b'\x00\x00'                 # load segment (unused)
    head[36] = 0                              # system type
    head[37] = 0                              # unused
    head[38:40] = esp_sectors.to_bytes(2, 'little')
    head[40:44] = esp_lba.to_bytes(4, 'little')

    cat = bytearray(SECTOR)
    cat[0:64] = head
    return bytes(cat)


def build_iso(layout, out_iso):
    date7 = _iso_date()
    date17 = _pvd_date17()

    root, _ = _collect(layout)

    # --- El Torito EFI boot: auto-generate a FAT16 ESP from EFI/BOOT/BOOTX64.EFI ---
    boot_parent, efi_boot = _find_efi_boot(root)
    esp_data = None
    if efi_boot is not None:
        with open(efi_boot.src, 'rb') as fh:
            boot_bytes = fh.read()
        esp_data = _make_fat16_esp(boot_bytes)
        if any(f.name == 'EFI.IMG' for f in boot_parent.files):
            raise ValueError("layout already contains EFI/BOOT/EFI.IMG")
        boot_parent.files.append(_File('EFI.IMG', None, data=esp_data))

    # --- volume descriptor sequence ---
    #   no El Torito: PVD(16) + terminator(17), L path table @18
    #   with El Torito: PVD(16) + BootRecord(17) + terminator(18), L @19
    if esp_data is None:
        term_lba = 17
        br_lba = None
        l_pt_lba = 18
    else:
        term_lba = 18
        br_lba = BOOT_RECORD_LBA
        l_pt_lba = 19

    dir_list = _path_table_order(root)
    all_dirs = [root] + dir_list

    # --- path table size (root record + one record per non-root dir) ---
    pt_size = 8 + 1 + 1                       # root record: len_di=1 -> 8+1+pad
    for d in dir_list:
        nb_len = len(d.name.encode('ascii'))
        pt_size += 8 + nb_len + (nb_len % 2)  # pad when ODD
    pt_sectors = (pt_size + SECTOR - 1) // SECTOR
    m_pt_lba = l_pt_lba + pt_sectors          # M path table right after L table

    # --- allocate directory data extents (boot catalog right after M table) ---
    cursor = m_pt_lba + pt_sectors            # M table has same size as L table
    boot_cat_lba = None
    if br_lba is not None:
        boot_cat_lba = cursor
        cursor += 1
    for d in all_dirs:
        # directory record size is name-dependent only; use placeholder extents
        size = 0
        for name, is_dir in [(b'\x00', True), (b'\x01', True)] + \
                            [(s.name, True) for s in d.subdirs] + \
                            [(f.name, False) for f in d.files]:
            nb = name if isinstance(name, bytes) else name.encode('ascii')
            if not is_dir:
                nb = nb + b';1'
            size += _record_len(nb)
        d.extent = cursor
        d.size = (size + SECTOR - 1) // SECTOR * SECTOR
        cursor += d.size // SECTOR

    # --- allocate file data extents (sorted by full ISO path) ---
    files = []
    def gather(d, prefix):
        for f in sorted(d.files, key=lambda x: x.name):
            files.append((prefix + f.name, f))
        for s in d.subdirs:
            gather(s, prefix + s.name + '/')
    gather(root, '/')
    files.sort(key=lambda x: x[0])

    for _, f in files:
        if f.data is not None:
            f.size = len(f.data)
        else:
            with open(f.src, 'rb') as fh:
                fh.seek(0, 2)
                f.size = fh.tell()
        f.extent = cursor
        cursor += (f.size + SECTOR - 1) // SECTOR

    vol_size = cursor

    # --- path tables (root record first, then non-root dirs) ---
    l_pt = bytearray()
    m_pt = bytearray()
    def add_pt(dest, name, extent, parent_num, endian):
        dest += _path_table_record(name, extent, parent_num, endian)
        return dest
    l_pt = add_pt(l_pt, b'\x00', root.extent, root.number, 'little')
    m_pt = add_pt(m_pt, b'\x00', root.extent, root.number, 'big')
    for d in dir_list:
        l_pt = add_pt(l_pt, d.name, d.extent, d.parent.number, 'little')
        m_pt = add_pt(m_pt, d.name, d.extent, d.parent.number, 'big')

    # --- root directory record (embedded in PVD) ---
    root_rec = _make_dir_record(b'\x00', True, root.extent, root.size, date7, True)

    pvd = _build_pvd(root_rec, vol_size, pt_size, l_pt_lba, m_pt_lba, date17)
    terminator = bytearray(SECTOR)
    terminator[0] = 255
    terminator[1:6] = b'CD001'
    terminator[6] = 1

    with open(out_iso, 'wb') as f:
        f.write(b'\x00' * (16 * SECTOR))      # system area (LBA 0-15)
        f.write(pvd)                          # LBA 16
        if br_lba is not None:
            f.write(_build_boot_record(boot_cat_lba))   # LBA 17
        f.write(bytes(terminator))            # LBA term_lba
        f.write(bytes(l_pt).ljust(pt_sectors * SECTOR, b'\x00'))
        f.write(bytes(m_pt).ljust(pt_sectors * SECTOR, b'\x00'))
        if boot_cat_lba is not None:
            esp_file = next(x for x in boot_parent.files if x.name == 'EFI.IMG')
            esp_sectors = esp_file.size // SECTOR    # ESP size is 2048-multiple
            f.write(_build_boot_catalog(esp_file.extent, esp_sectors))
        for d in all_dirs:
            f.write(_dir_data_bytes(d, date7))
        for _, fl in files:
            if fl.data is not None:
                data = fl.data
            else:
                with open(fl.src, 'rb') as fh:
                    data = fh.read()
            f.write(data)
            if len(data) % SECTOR:
                f.write(b'\x00' * (SECTOR - len(data) % SECTOR))


def main(argv):
    if len(argv) != 3:
        print('usage: python scripts/iso9660_build.py <layout_dir> <out.iso>',
              file=sys.stderr)
        return 2
    layout, out_iso = argv[1], argv[2]
    if not os.path.isdir(layout):
        print('error: layout directory not found: %s' % layout, file=sys.stderr)
        return 1
    try:
        build_iso(layout, out_iso)
    except (ValueError, OSError) as e:
        print('error: %s' % e, file=sys.stderr)
        try:
            if os.path.exists(out_iso):
                os.remove(out_iso)
        except OSError:
            pass
        return 1
    print('wrote %s (%d sectors)' % (out_iso,
                                     os.path.getsize(out_iso) // SECTOR))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
