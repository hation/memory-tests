import importlib.util
import os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'scripts', 'iso9660_build.py'))

def load_module():
    """Import scripts/iso9660_build.py directly (for _validate_name unit tests)."""
    spec = importlib.util.spec_from_file_location('iso9660_build', SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

def run_build(layout, out):
    return subprocess.run([sys.executable, SCRIPT, layout, out],
                          capture_output=True, text=True)

def parse_dir_records(data, lba, size):
    """Parse directory records at given LBA/size; return (name, flags, extent, dsize)."""
    recs = []
    off = lba * 2048
    end = off + size
    while off < end:
        ln = data[off]
        if ln == 0:
            break
        rec = data[off:off + ln]
        name_len = rec[32]
        recs.append((rec[33:33 + name_len], rec[25],
                     int.from_bytes(rec[2:6], 'little'),
                     int.from_bytes(rec[10:14], 'little')))
        off += ln
    return recs

def collect_names(data):
    """Walk the whole directory tree starting from PVD root record; return set of names."""
    pvd = data[16 * 2048:17 * 2048]
    root = pvd[156:190]
    names = set()
    seen = set()
    def walk(lba, size):
        if lba in seen:
            return
        seen.add(lba)
        for name, flags, ext, dsize in parse_dir_records(data, lba, size):
            if name in (b'\x00', b'\x01'):   # '.' and '..' entries (ECMA-119 9.1.10)
                continue
            names.add(name)
            if flags & 2:
                walk(ext, dsize)
    walk(int.from_bytes(root[2:6], 'little'), int.from_bytes(root[10:14], 'little'))
    return names

def parse_path_table(data, lba, size, endian):
    """Parse an ISO9660 path table (ECMA-119 9.4).

    Returns [(identifier, extent, parent_number), ...]. Record layout:
    1B id-len + 1B ext-attr-len + 4B extent + 2B parent number + id + pad
    (1 pad byte when id length is ODD, so record length = 8 + len + len%2).
    """
    recs = []
    off = lba * 2048
    end = off + size
    while off < end:
        ln = data[off]
        if ln == 0:
            break
        extent = int.from_bytes(data[off + 2:off + 6],
                                'little' if endian == 'little' else 'big')
        parent = int.from_bytes(data[off + 6:off + 8],
                                'little' if endian == 'little' else 'big')
        recs.append((data[off + 8:off + 8 + ln], extent, parent))
        off += 8 + ln + (ln % 2)
    return recs

def parse_fat16(data, lba):
    """Parse a FAT16 image embedded at ISO LBA (2048-byte sectors); BPB info."""
    off = lba * 2048
    bs = data[off:off + 512]
    bps = int.from_bytes(bs[11:13], 'little')
    reserved = int.from_bytes(bs[14:16], 'little')
    n_fats = bs[16]
    root_entries = int.from_bytes(bs[17:19], 'little')
    total = int.from_bytes(bs[19:21], 'little')
    fat_sectors = int.from_bytes(bs[22:24], 'little')
    root_sectors = root_entries * 32 // bps
    data_start = reserved + n_fats * fat_sectors + root_sectors
    return {'off': off, 'bps': bps, 'reserved': reserved, 'n_fats': n_fats,
            'root_entries': root_entries, 'total': total,
            'fat_sectors': fat_sectors, 'root_sectors': root_sectors,
            'data_start': data_start}

def fat_read_file(data, esp_lba, path):
    """Resolve an 8.3 path inside a FAT16 image at ISO LBA esp_lba; return bytes."""
    fat = parse_fat16(data, esp_lba)
    base = fat['off']
    def read_dir(cluster):
        if cluster == 0:
            off = base + (fat['reserved'] + fat['n_fats'] * fat['fat_sectors']) * fat['bps']
            count = fat['root_entries']
        else:
            off = base + (fat['data_start'] + cluster - 2) * fat['bps']
            count = fat['bps'] // 32
        entries = []
        for i in range(count):
            e = data[off + i * 32:off + i * 32 + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F:      # deleted / LFN
                continue
            name = e[0:8].decode('ascii').rstrip(' ')
            ext = e[8:11].decode('ascii').rstrip(' ')
            if ext:
                name += '.' + ext
            entries.append((name.upper(), e[11],
                            int.from_bytes(e[26:28], 'little'),   # cluster
                            int.from_bytes(e[28:32], 'little')))  # size
        return entries
    node = read_dir(0)
    for part in path:
        hit = [x for x in node if x[0] == part.upper()]
        if not hit:
            raise AssertionError('FAT path part not found: %r (dir has %r)'
                                 % (part, node))
        name, attr, cl, size = hit[0]
        if attr & 0x10:
            node = read_dir(cl)
            continue
        out = bytearray()
        cur = cl
        while 2 <= cur < 0xFFF7:
            sect = fat['data_start'] + cur - 2
            chunk = data[base + sect * fat['bps']:base + (sect + 1) * fat['bps']]
            out += chunk
            foff = base + fat['reserved'] * fat['bps'] + cur * 2
            cur = int.from_bytes(data[foff:foff + 2], 'little')
        return bytes(out[:size])
    raise AssertionError('FAT path not fully resolved: %r' % (path,))

class TestIso9660Build(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.layout = os.path.join(self.d.name, 'layout')
        self.out = os.path.join(self.d.name, 'out.iso')
        os.makedirs(self.layout)

    def tearDown(self):
        self.d.cleanup()

    def write(self, relpath, content=b'x'):
        p = os.path.join(self.layout, relpath)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(content)
        return p

    def test_build_and_structure(self):
        self.write('EFI/BOOT/BOOTX64.EFI', b'\x00\x01efi-boot-placeholder')
        self.write('GRUB/GRUB.CFG', b'set timeout=10\nsearch --file /BOOT/MT86PLUS.BIN\n')
        self.write('GRUB/X86_64-EFI/NORMAL.MOD', b'\x00\x02grub-mod')
        self.write('BOOT/MT86PLUS.BIN', b'\x00\x03memtest-kernel')
        r = run_build(self.layout, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.out))
        with open(self.out, 'rb') as f:
            data = f.read()
        # PVD at LBA 16: type 1 + magic CD001
        pvd = data[16 * 2048:17 * 2048]
        self.assertEqual(pvd[0], 1)
        self.assertEqual(pvd[1:6], b'CD001')
        # no Joliet SVD: scan the volume descriptor sequence up to the
        # terminator (255) -- no type-2 descriptor nor Joliet escape sequence
        vd_off = 16 * 2048
        while data[vd_off] != 255:
            self.assertNotEqual(data[vd_off], 2)          # no SVD (Joliet)
            self.assertNotIn(b'\x25\x2f\x40', data[vd_off:vd_off + 2048])
            vd_off += 2048
        # names in directory records (with ;1 version for files)
        names = collect_names(data)
        for expect in (b'EFI', b'BOOT', b'GRUB', b'X86_64-EFI',
                       b'BOOTX64.EFI;1', b'GRUB.CFG;1', b'MT86PLUS.BIN;1',
                       b'NORMAL.MOD;1'):
            self.assertIn(expect, names, 'missing %r in %r' % (expect, sorted(names)))
        # root records contain . and .. entries (single 0x00 / 0x01 bytes)
        root_recs = parse_dir_records(data, int.from_bytes(pvd[156:190][2:6], 'little'),
                                      int.from_bytes(pvd[156:190][10:14], 'little'))
        dot_names = {n for n, _, _, _ in root_recs}
        self.assertIn(b'\x00', dot_names)
        self.assertIn(b'\x01', dot_names)

    def test_uppercase_8_3(self):
        self.write('grub/grub.cfg', b'set timeout=10\n')
        self.write('boot/mt86plus.bin', b'kernel')
        r = run_build(self.layout, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.out, 'rb') as f:
            data = f.read()
        names = collect_names(data)
        self.assertIn(b'GRUB.CFG;1', names)
        self.assertIn(b'MT86PLUS.BIN;1', names)
        self.assertIn(b'BOOT', names)
        self.assertIn(b'GRUB', names)
        self.assertNotIn(b'grub.cfg;1', names)

    def test_non_8_3_errors(self):
        self.write('too_long_file_name_x.bin', b'x')
        r = run_build(self.layout, self.out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.out))

    def test_empty_layout(self):
        r = run_build(self.layout, self.out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.out))

    def _build_standard_layout(self):
        self.write('EFI/BOOT/BOOTX64.EFI', b'\x00\x01efi-boot-placeholder')
        self.write('GRUB/GRUB.CFG', b'set timeout=10\nsearch --file /BOOT/MT86PLUS.BIN\n')
        self.write('GRUB/X86_64-EFI/NORMAL.MOD', b'\x00\x02grub-mod')
        self.write('BOOT/MT86PLUS.BIN', b'\x00\x03memtest-kernel')
        r = run_build(self.layout, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(os.path.exists(self.out))
        with open(self.out, 'rb') as f:
            return f.read()

    def test_pvd_fields(self):
        """F2: PVD key fields beyond type/magic must be correct."""
        data = self._build_standard_layout()
        pvd = data[16 * 2048:17 * 2048]
        # descriptor: type 1, magic CD001, version 1
        self.assertEqual(pvd[0], 1)
        self.assertEqual(pvd[1:6], b'CD001')
        self.assertEqual(pvd[6], 1)
        # file structure version must be 1; the following byte unused = 0
        self.assertEqual(pvd[881], 1)
        self.assertEqual(pvd[882], 0)
        # logical block size: 2048, both endians (offsets 128-131)
        self.assertEqual(int.from_bytes(pvd[128:130], 'little'), 2048)
        self.assertEqual(int.from_bytes(pvd[130:132], 'big'), 2048)
        # volume space size: both endians equal and positive (offsets 80-87)
        vol_le = int.from_bytes(pvd[80:84], 'little')
        self.assertEqual(vol_le, int.from_bytes(pvd[84:88], 'big'))
        self.assertGreater(vol_le, 0)
        # path table size: both endians equal, positive (offsets 132-139)
        pt_size = int.from_bytes(pvd[132:136], 'little')
        self.assertEqual(pt_size, int.from_bytes(pvd[136:140], 'big'))
        self.assertGreater(pt_size, 0)
        # path table locations (offsets 140-151): L @ LBA19 (El Torito layout:
        # PVD16 + BootRecord17 + Terminator18), M right after; both non-zero
        l_lba = int.from_bytes(pvd[140:144], 'little')
        m_lba = int.from_bytes(pvd[148:152], 'big')
        self.assertEqual(l_lba, 19)
        self.assertGreater(m_lba, l_lba)
        self.assertEqual(int.from_bytes(pvd[144:148], 'little'), 0)  # no 2nd M table

    def test_path_table(self):
        """F1: little-endian path table must be complete and consistent."""
        data = self._build_standard_layout()
        pvd = data[16 * 2048:17 * 2048]
        pt_size = int.from_bytes(pvd[132:136], 'little')
        l_lba = int.from_bytes(pvd[140:144], 'little')
        m_lba = int.from_bytes(pvd[148:152], 'big')
        l = parse_path_table(data, l_lba, pt_size, 'little')
        m = parse_path_table(data, m_lba, pt_size, 'big')
        # record count: root + 5 non-root dirs (BOOT, EFI, GRUB,
        # EFI/BOOT, GRUB/X86_64-EFI)
        self.assertEqual(len(l), 6)
        self.assertEqual(len(m), 6)
        # first record is the root: identifier 0x00, parent dir number 1
        self.assertEqual(l[0][0], b'\x00')
        self.assertEqual(l[0][2], 1)
        # parent directory numbers are non-decreasing (ISO9660 ordering rule)
        parents = [p for _, _, p in l]
        self.assertEqual(parents, sorted(parents), 'parent numbers not ascending')
        # L and M tables carry identical records (names, extents, parents)
        self.assertEqual(l, m)

    def test_el_torito_boot_record(self):
        """El Torito: Boot Record VD at LBA 17 (type 0 + EL TORITO signature)."""
        data = self._build_standard_layout()
        br = data[17 * 2048:18 * 2048]
        self.assertEqual(br[0], 0)                       # type 0
        self.assertEqual(br[1:6], b'CD001')
        self.assertEqual(br[6], 1)                      # version
        self.assertIn(b'EL TORITO SPECIFICATION', br[7:39])
        cat_le = int.from_bytes(br[71:75], 'little')
        cat_be = int.from_bytes(br[75:79], 'big')
        self.assertEqual(cat_le, cat_be)
        self.assertGreater(cat_le, 0)
        # PVD @16, terminator right after boot record @18
        self.assertEqual(data[16 * 2048], 1)
        self.assertEqual(data[18 * 2048], 255)

    def test_el_torito_boot_catalog(self):
        """El Torito: catalog validation entry (0xEF / 55 AA / checksum) + default entry."""
        data = self._build_standard_layout()
        br = data[17 * 2048:18 * 2048]
        cat = int.from_bytes(br[71:75], 'little')
        c = data[cat * 2048:(cat + 1) * 2048]
        # validation entry: header 0x01, platform 0xEF (EFI), key 55 AA
        self.assertEqual(c[0], 1)
        self.assertEqual(c[1], 0xEF)
        self.assertEqual(c[30], 0x55)
        self.assertEqual(c[31], 0xAA)
        # checksum: sum of all sixteen 16-bit LE words == 0 mod 65536 (7.4.1)
        total = 0
        for i in range(0, 32, 2):
            total += c[i] | (c[i + 1] << 8)
        self.assertEqual(total & 0xFFFF, 0)
        # initial/default entry: no-emulation, boot indicator 0x88
        self.assertEqual(c[32], 0x88)
        self.assertEqual(c[33], 0x00)                   # media type no-emulation
        self.assertEqual(int.from_bytes(c[34:36], 'little'), 0)  # load segment
        self.assertEqual(c[36], 0)                      # system type
        cnt = int.from_bytes(c[38:40], 'little')        # sector count
        lba = int.from_bytes(c[40:44], 'little')        # boot image LBA
        self.assertGreater(cnt, 0)
        self.assertGreater(lba, 0)
        # boot image is a FAT16 volume (BS at 54-59 has "FAT16", 0x55AA sig)
        esp = data[lba * 2048:lba * 2048 + 512]
        self.assertEqual(esp[54:60], b'FAT16 ')
        self.assertEqual(esp[510:512], b'\x55\xAA')
        # sector count (2048-byte units) matches the ESP size from its BPB
        fat = parse_fat16(data, lba)
        self.assertEqual(fat['total'] * 512 // 2048, cnt)

    def test_esp_contains_bootx64(self):
        """ESP parses as FAT16 and yields EFI\\BOOT\\BOOTX64.EFI identical to source."""
        payload = b'\x00\x01EFI-BOOT-PLACEHOLDER-0123456789ABCDEF'
        self.write('EFI/BOOT/BOOTX64.EFI', payload)
        self.write('GRUB/GRUB.CFG', b'set timeout=10\n')
        self.write('GRUB/X86_64-EFI/NORMAL.MOD', b'\x00\x02grub-mod')
        self.write('BOOT/MT86PLUS.BIN', b'\x00\x03memtest-kernel')
        r = run_build(self.layout, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.out, 'rb') as f:
            data = f.read()
        br = data[17 * 2048:18 * 2048]
        cat = int.from_bytes(br[71:75], 'little')
        c = data[cat * 2048:(cat + 1) * 2048]
        esp_lba = int.from_bytes(c[40:44], 'little')
        got = fat_read_file(data, esp_lba, ['EFI', 'BOOT', 'BOOTX64.EFI'])
        self.assertEqual(got, payload)

    def test_no_el_torito_without_bootx64(self):
        """Without EFI/BOOT/BOOTX64.EFI the image stays pure ISO9660 (PVD+term)."""
        self.write('GRUB/GRUB.CFG', b'set timeout=10\n')
        self.write('BOOT/MT86PLUS.BIN', b'kernel')
        r = run_build(self.layout, self.out)
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(self.out, 'rb') as f:
            data = f.read()
        self.assertEqual(data[16 * 2048], 1)            # PVD
        self.assertEqual(data[17 * 2048], 255)          # terminator right after
        pvd = data[16 * 2048:17 * 2048]
        self.assertEqual(int.from_bytes(pvd[140:144], 'little'), 18)  # L path table
        names = collect_names(data)
        self.assertIn(b'GRUB.CFG;1', names)

    def test_space_semicolon_rejected(self):
        """F3: names with space or ';' must fail the build (non-8.3 promise)."""
        for bad in ('A B.C', 'FOO;1'):
            with self.subTest(name=bad):
                d = tempfile.TemporaryDirectory()
                try:
                    layout = os.path.join(d.name, 'layout')
                    os.makedirs(layout)
                    with open(os.path.join(layout, bad), 'wb') as f:
                        f.write(b'x')
                    out = os.path.join(d.name, 'out.iso')
                    r = run_build(layout, out)
                    self.assertNotEqual(r.returncode, 0,
                                        'should reject %r' % bad)
                    self.assertFalse(os.path.exists(out))
                finally:
                    d.cleanup()

    def test_validate_name_rejects_unsafe_chars(self):
        """F3: unit-level check that _validate_name is narrowed (no double ';1')."""
        mod = load_module()
        for bad in ('A B.C', 'FOO;1', 'A:B.C', 'GRUB.CFG;1',
                    'FOO*', 'FOO?', 'FOO/1', 'FOO\\1', 'FOO,1', 'FOO;1.BIN'):
            with self.subTest(file=bad):
                with self.assertRaises(ValueError):
                    mod._validate_name(bad, False)
        for ok in ('MT86PLUS.BIN', 'NORMAL.MOD', 'BOOTX64.EFI', 'GRUB.CFG',
                   'A-B.C', 'A_1.C', 'A^B.MOD', 'A~B', 'A#B.C', 'A@B.C'):
            with self.subTest(file=ok):
                self.assertEqual(mod._validate_name(ok, False), ok.upper())
        # directories are narrowed too: no space/';'/'.', no a-char separators
        for bad in ('MY DIR', 'DIR;1', 'DIR.X', 'A:B'):
            with self.subTest(dir=bad):
                with self.assertRaises(ValueError):
                    mod._validate_name(bad, True)
        for ok in ('X86_64-EFI', 'GRUB', 'BOOT', 'EFI', 'MY_DIR', 'A-B'):
            with self.subTest(dir=ok):
                self.assertEqual(mod._validate_name(ok, True), ok.upper())

if __name__ == '__main__':
    unittest.main(verbosity=2)
