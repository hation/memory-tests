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
        # no Joliet SVD: scan the volume descriptor sequence, must not contain
        # a type-2 descriptor nor the Joliet escape sequence
        vd_off = 16 * 2048
        while data[vd_off] not in (255, 0):
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
        # path table locations (offsets 140-151): L @ LBA18 (brief contract),
        # M right after; both non-zero
        l_lba = int.from_bytes(pvd[140:144], 'little')
        m_lba = int.from_bytes(pvd[148:152], 'big')
        self.assertEqual(l_lba, 18)
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
