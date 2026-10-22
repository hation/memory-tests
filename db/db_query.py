# -*- coding: utf-8 -*-
# db/db_query.py — 查询 SQLite 历史库（按 SN / 批次过滤；--trend 输出按 SN 的历史 runs 时序）
# 用法：python db_query.py [--db history.db] [--serial <sn>] [--batch <name>] [--trend]
import argparse
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db_common

COLS = ['Machine', 'Batch', 'SerialNumber', 'Result', 'Errors', 'EccErrors', 'Passes', 'TestDate']


def main():
    ap = argparse.ArgumentParser(description='查询 SQLite 历史库（跨批次按 SN 追踪）')
    ap.add_argument('--db', default='history.db', help='历史库路径（缺省 history.db）')
    ap.add_argument('--serial', default='', help='按序列号过滤')
    ap.add_argument('--batch', default='', help='按批次名过滤')
    ap.add_argument('--trend', action='store_true', help='按 SN 输出历史 runs 时序（同一 SN 跨批次追踪）')
    args = ap.parse_args()

    conn = db_common.init_db(args.db)
    sql = ('SELECT b.machine, b.batch, e.serial, r.result, r.errors, r.ecc_errors, r.passes, r.test_date '
           'FROM runs r JOIN batches b ON b.id=r.batch_id JOIN entities e ON e.id=r.entity_id '
           'WHERE 1=1')
    params = []
    if args.serial:
        sql += ' AND e.serial=?'
        params.append(args.serial)
    if args.batch:
        sql += ' AND b.batch=?'
        params.append(args.batch)
    if args.trend:
        sql += ' ORDER BY e.serial, r.test_date'   # 时序：按 SN 分组、按测试日期排序
    else:
        sql += ' ORDER BY r.test_date'
    rows = conn.execute(sql, params).fetchall()

    out = csv.writer(sys.stdout, lineterminator='\n')
    if not rows:
        print('（无匹配记录）')
        return
    if args.trend:
        out.writerow(['SN 历史时序（按序列号分组，按测试日期排序）'])
        out.writerow(COLS)
        for r in rows:
            out.writerow(r)
    else:
        out.writerow(COLS)
        for r in rows:
            out.writerow(r)


if __name__ == '__main__':
    main()
