# -*- coding: utf-8 -*-
# db/db_merge.py — 把 db2 数据幂等合并进 db1 副本，写入 out（按唯一键去重）
# 用法：python db_merge.py --db1 <path> --db2 <path> --out <path>
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db_common


def _copy_into(src, dst):
    """把 src 全部数据按唯一键幂等合并进 dst（ON CONFLICT 去重），返回 (批次, 实体, 记录) 条数。

    关键：源库自增 id 与目标库未必一致，须按唯一键（machine+batch / serial）映射后
    再写入 runs，避免外键错位与重复。
    """
    batch_map = {}
    entity_map = {}
    nb = ne = nr = 0
    for machine, batch in src.execute('SELECT machine, batch FROM batches'):
        batch_map[(machine, batch)] = db_common.upsert_batch(dst, machine, batch)
        nb += 1
    for serial, capacity_gb, part_number, manufacturer in src.execute(
            'SELECT serial, capacity_gb, part_number, manufacturer FROM entities'):
        fields = {}
        if capacity_gb is not None:
            fields['capacity_gb'] = capacity_gb
        if part_number:
            fields['part_number'] = part_number
        if manufacturer:
            fields['manufacturer'] = manufacturer
        entity_map[serial] = db_common.upsert_entity(dst, serial, fields)
        ne += 1
    for machine, batch, serial, result, errors, ecc_errors, passes, test_date in src.execute('''
            SELECT b.machine, b.batch, e.serial, r.result, r.errors, r.ecc_errors, r.passes, r.test_date
            FROM runs r
            JOIN batches b ON b.id = r.batch_id
            JOIN entities e ON e.id = r.entity_id'''):
        fields = {}
        if result is not None:
            fields['result'] = result
        if errors is not None:
            fields['errors'] = errors
        if ecc_errors is not None:
            fields['ecc_errors'] = ecc_errors
        if passes is not None:
            fields['passes'] = passes
        if test_date is not None:
            fields['test_date'] = test_date
        db_common.insert_run(dst, batch_map[(machine, batch)], entity_map[serial], **fields)
        nr += 1
    return nb, ne, nr


def _open_ro(path):
    """只读打开源库（uri mode=ro）：不写 WAL、不产生 journal，避免对源库造成副作用。"""
    import sqlite3
    uri = 'file:%s?mode=ro' % path.replace('\\', '/')
    return db_common._AutoCloseConn(sqlite3.connect(uri, uri=True, isolation_level=None))


def main():
    ap = argparse.ArgumentParser(description='把 db2 数据幂等合并进 db1 副本，写入 out（按唯一键去重）')
    ap.add_argument('--db1', required=True, help='主库路径')
    ap.add_argument('--db2', required=True, help='并入库路径')
    ap.add_argument('--out', required=True, help='合并结果库路径')
    args = ap.parse_args()

    c1 = _open_ro(args.db1)          # 源库只读打开，无写入副作用
    c2 = _open_ro(args.db2)
    co = db_common.init_db(args.out)  # 目标库正常读写建表
    n1 = _copy_into(c1, co)
    n2 = _copy_into(c2, co)
    print('合并完成: db1(%d批次/%d实体/%d记录) + db2(%d批次/%d实体/%d记录) -> %s'
          % (n1[0], n1[1], n1[2], n2[0], n2[1], n2[2], args.out))


if __name__ == '__main__':
    main()
