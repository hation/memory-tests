import os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'scripts', 'iso9660_build.py'))

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

if __name__ == '__main__':
    unittest.main(verbosity=2)
