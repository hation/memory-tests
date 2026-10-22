# -*- coding: utf-8 -*-
# db/db_import.py — 把报告 CSV 导入 SQLite 历史库（幂等：重复导入不产生重复行）
# 用法：python db_import.py <report.csv> [--db history.db] [--machine <name>]
import argparse
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db_common


def _to_int(s):
    s = (s or '').strip()
    return int(s) if s else None


def main():
    ap = argparse.ArgumentParser(description='导入报告 CSV 到 SQLite 历史库（幂等）')
    ap.add_argument('report_csv', help='报告 CSV 路径（列含 Batch/SerialNumber/Result/Errors/EccErrors/Passes/TestDate，其余列忽略）')
    ap.add_argument('--db', default='history.db', help='历史库路径（缺省 history.db）')
    ap.add_argument('--machine', default='', help='机器名（缺省为空；同一 machine+batch 视为同一批次）')
    args = ap.parse_args()

    conn = db_common.init_db(args.db)
    n = 0
    skipped = 0
    with open(args.report_csv, 'r', encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            batch = (row.get('Batch') or '').strip()
            serial = (row.get('SerialNumber') or '').strip()
            if not batch or not serial:
                continue
            result = (row.get('Result') or '').strip() or None
            test_date = (row.get('TestDate') or '').strip() or None
            errors = _to_int(row.get('Errors'))
            ecc_errors = _to_int(row.get('EccErrors'))
            passes = _to_int(row.get('Passes'))
            b = db_common.upsert_batch(conn, args.machine, batch)
            e = db_common.upsert_entity(conn, serial, {})
            # 幂等重复检测：同批次同实体已存在且字段一致 → 计为跳过
            prev = conn.execute(
                'SELECT result, errors, ecc_errors, passes, test_date '
                'FROM runs WHERE batch_id=? AND entity_id=?',
                (b, e)).fetchone()
            db_common.insert_run(conn, b, e, result=result, errors=errors,
                                 ecc_errors=ecc_errors, passes=passes, test_date=test_date)
            n += 1
            if prev is not None and list(prev) == [result, errors, ecc_errors, passes, test_date]:
                skipped += 1
    print('导入 %d 行（幂等重复跳过 %d 行）' % (n, skipped))


if __name__ == '__main__':
    main()
