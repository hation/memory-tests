#!/usr/bin/env python3
"""Minimal ISO9660 Level-1 assembler (pure stdlib, zero dependencies).

CLI:
    python scripts/iso9660_build.py <layout_dir> <out.iso>

Writes a mountable, UEFI-scanable ISO9660 Level-1 image:
- Logical sector 2048 bytes; PVD (type 1, magic "CD001") at LBA 16.
- Volume descriptor sequence = PVD + terminator only: NO Joliet SVD,
  NO Rock Ridge (no SP/ER system-use fields), NO El Torito boot record.
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
TERM_LBA = 17
L_PATH_LBA = 18

# ISO9660 d-characters and a-characters (ECMA-119 7.4.1)
D_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
A_CHARS = D_CHARS | set("!\"%&'()*+,-./:;<=>?_ ")


class _File:
    __slots__ = ('name', 'src', 'extent', 'size')

    def __init__(self, name, src):
        self.name = name          # upper-case ISO name (no version)
        self.src = src            # absolute source path on disk
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

    Raises ValueError for names that cannot be represented in ISO9660 Level 1.
    """
    up = name.upper()
    if is_dir:
        # Level 1 caps dir names at 8 chars, but the GRUB module dir
        # X86_64-EFI (9 chars) is a hard layout requirement; readers
        # (Windows cdfs, GRUB iso9660) consume the length field, so allow
        # up to the Level 2 limit (31). File names stay strict 8.3.
        if not (1 <= len(up) <= 31):
            raise ValueError("directory name must be 1-31 chars: %r" % name)
        if any(c not in A_CHARS for c in up) or '.' in up:
            raise ValueError("invalid directory name (ISO9660): %r" % name)
        return up
    base, dot, ext = up.partition('.')
    if dot and '.' in ext:
        raise ValueError("file name has multiple dots (not 8.3): %r" % name)
    if not (1 <= len(base) <= 8):
        raise ValueError("file base name must be 1-8 chars: %r" % name)
    if dot and not (1 <= len(ext) <= 3):
        raise ValueError("file extension must be 1-3 chars: %r" % name)
    if any(c not in A_CHARS for c in base + ext):
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


def build_iso(layout, out_iso):
    date7 = _iso_date()
    date17 = _pvd_date17()

    root, _ = _collect(layout)
    dir_list = _path_table_order(root)
    all_dirs = [root] + dir_list

    # --- path table size (root record + one record per non-root dir) ---
    pt_size = 8 + 1 + 1                       # root record: len_di=1 -> 8+1+pad
    for d in dir_list:
        nb_len = len(d.name.encode('ascii'))
        pt_size += 8 + nb_len + (nb_len % 2)  # pad when ODD
    pt_sectors = (pt_size + SECTOR - 1) // SECTOR
    m_pt_lba = L_PATH_LBA + pt_sectors        # M path table right after L table

    # --- allocate directory data extents ---
    cursor = m_pt_lba + pt_sectors            # M table has same size as L table
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

    pvd = _build_pvd(root_rec, vol_size, pt_size, L_PATH_LBA, m_pt_lba, date17)
    terminator = bytearray(SECTOR)
    terminator[0] = 255
    terminator[1:6] = b'CD001'
    terminator[6] = 1

    with open(out_iso, 'wb') as f:
        f.write(b'\x00' * (16 * SECTOR))      # system area (LBA 0-15)
        f.write(pvd)                          # LBA 16
        f.write(bytes(terminator))            # LBA 17
        f.write(bytes(l_pt).ljust(pt_sectors * SECTOR, b'\x00'))
        f.write(bytes(m_pt).ljust(pt_sectors * SECTOR, b'\x00'))
        for d in all_dirs:
            f.write(_dir_data_bytes(d, date7))
        for _, fl in files:
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
