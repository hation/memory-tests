import tempfile, os, unittest, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'db'))
import db_common
class TestDb(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.d.name, 'h.db')
        db_common.init_db(self.db)
    def tearDown(self): self.d.cleanup()
    def conn(self): return db_common.init_db(self.db)   # 幂等建表
    def test_import_idempotent(self):
        c = self.conn()
        b = db_common.upsert_batch(c, 'm1', 'b1'); e = db_common.upsert_entity(c, 'SN1', {'capacity_gb': 16})
        db_common.insert_run(c, b, e, result='PASS')
        db_common.insert_run(c, b, e, result='PASS')     # 第二次
        n = c.execute("SELECT COUNT(*) FROM runs WHERE batch_id=? AND entity_id=?", (b, e)).fetchone()[0]
        self.assertEqual(n, 1)                            # 幂等
    def test_export_utf8(self):
        c = self.conn()
        db_common.upsert_batch(c, 'm1', 'b1'); db_common.upsert_entity(c, 'SN1', {'capacity_gb': 16})
        out = os.path.join(self.d.name, 'e.csv'); db_common.export_csv(c, out)
        with open(out, 'rb') as f: head = f.read(3)
        self.assertEqual(head, b'\xef\xbb\xbf')          # utf-8-sig
if __name__ == '__main__':
    unittest.main(verbosity=2)
