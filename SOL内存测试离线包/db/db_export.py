# -*- coding: utf-8 -*-
# db/db_export.py — 导出历史库全量 CSV（utf-8-sig，Excel 可直接打开）
# 用法：python db_export.py --db history.db --out <path>
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db_common


def main():
    ap = argparse.ArgumentParser(description='导出历史库全量 CSV（utf-8-sig）')
    ap.add_argument('--db', default='history.db', help='历史库路径（缺省 history.db）')
    ap.add_argument('--out', required=True, help='导出 CSV 路径')
    args = ap.parse_args()

    conn = db_common.init_db(args.db)
    db_common.export_csv(conn, args.out)
    print('导出完成: %s' % args.out)


if __name__ == '__main__':
    main()
