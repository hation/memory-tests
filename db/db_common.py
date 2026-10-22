# -*- coding: utf-8 -*-
# db/db_common.py — SQLite 历史库公共层（三段式：批次 / 实体 / 测试记录）
# 纯 Python 3 标准库（仅 sqlite3 等），可选功能（需 Python 3），不影响核心 PowerShell 流程。
# 全部函数幂等：同批次同实体重复导入不产生重复行（UNIQUE 约束 + ON CONFLICT DO UPDATE）。
# WAL 模式；导出 CSV 为 utf-8-sig（Excel 可直接打开）。

import sqlite3
import csv
import os
import datetime


class _AutoCloseConn:
    """sqlite3.Connection 的自动关闭代理。

    背景：Python 3.11+ 重写版 sqlite3 的 Connection 内部用 functools.lru_cache
    缓存已编译语句，形成「连接 ↔ lru_cache」引用环。仅靠引用计数归零不会立即
    关闭底层句柄，须等循环 GC 回收，时机不可控。Windows 上未关闭的连接会锁住
    .db 文件，导致文件/临时目录无法删除（unittest 的 tearDown 清理即会报
    PermissionError）。本代理在自身被丢弃（refcount=0）时立即 close() 底层连接，
    保证确定性关闭；对外行为与 sqlite3.Connection 一致（其余成员委托给底层）。
    """

    __slots__ = ('_raw',)

    def __init__(self, raw):
        object.__setattr__(self, '_raw', raw)

    def __del__(self):
        try:
            raw = object.__getattribute__(self, '_raw')
        except AttributeError:
            return
        try:
            raw.close()
        except Exception:
            pass

    def __getattr__(self, name):
        # 非本类属性一律委托给底层连接（execute/cursor/commit/executescript 等）
        return getattr(object.__getattribute__(self, '_raw'), name)

    def close(self):
        object.__getattribute__(self, '_raw').close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def _now() -> str:
    """当前时间戳（ISO 格式，本地时区），用于 created_at / test_date 缺省值。"""
    return datetime.datetime.now().isoformat(timespec='seconds')


def init_db(path: str) -> sqlite3.Connection:
    """幂等建表（已存在不重建），PRAGMA journal_mode=WAL。

    表结构（三段式）：
      batches  —— 批次（machine + batch 唯一）
      entities —— 实体（内存条，serial 唯一）
      runs     —— 测试记录（batch_id + entity_id 唯一，跨批次按 SN 追踪）

    返回自动关闭连接（_AutoCloseConn 代理）：丢弃即关闭底层连接，
    避免 Windows 上 .db 文件被未释放连接锁定。
    """
    conn = _AutoCloseConn(sqlite3.connect(path, isolation_level=None))
    conn.execute('PRAGMA journal_mode=WAL')
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS batches(
            id INTEGER PRIMARY KEY,
            machine TEXT,
            batch TEXT,
            created_at TEXT,
            UNIQUE(machine, batch)
        );
        CREATE TABLE IF NOT EXISTS entities(
            id INTEGER PRIMARY KEY,
            serial TEXT UNIQUE,
            capacity_gb INTEGER,
            part_number TEXT,
            manufacturer TEXT,
            created_at TEXT
        );
        CREATE TABLE IF NOT EXISTS runs(
            id INTEGER PRIMARY KEY,
            batch_id INTEGER REFERENCES batches(id),
            entity_id INTEGER REFERENCES entities(id),
            result TEXT,
            errors INTEGER,
            ecc_errors INTEGER,
            passes INTEGER,
            test_date TEXT,
            UNIQUE(batch_id, entity_id)
        );
    ''')
    conn.commit()
    return conn


def upsert_batch(conn: sqlite3.Connection, machine: str, batch: str) -> int:
    """幂等写入批次：已存在则保留原 created_at（DO UPDATE SET created_at=created_at），返回 id。"""
    conn.execute(
        'INSERT INTO batches(machine, batch, created_at) VALUES(?, ?, ?) '
        'ON CONFLICT(machine, batch) DO UPDATE SET created_at=batches.created_at',
        (machine, batch, _now()))
    return conn.execute(
        'SELECT id FROM batches WHERE machine=? AND batch=?',
        (machine, batch)).fetchone()[0]


def upsert_entity(conn: sqlite3.Connection, serial: str, fields: dict) -> int:
    """幂等写入实体：ON CONFLICT(serial) DO UPDATE（仅合并 fields 中非空值），返回 id。

    fields 可含 capacity_gb / part_number / manufacturer。
    """
    cols = {k: v for k, v in fields.items() if v not in (None, '')}
    if cols:
        sets = ', '.join('%s=excluded.%s' % (k, k) for k in cols)
        conn.execute(
            'INSERT INTO entities(serial, %s, created_at) VALUES(?%s, ?) '
            'ON CONFLICT(serial) DO UPDATE SET %s' % (
                ', '.join(cols), ', ?' * len(cols), sets),
            [serial] + list(cols.values()) + [_now()])
    else:
        # 无字段也确保 serial 存在（幂等，INSERT OR IGNORE）
        conn.execute(
            'INSERT OR IGNORE INTO entities(serial, created_at) VALUES(?, ?)',
            (serial, _now()))
    return conn.execute(
        'SELECT id FROM entities WHERE serial=?', (serial,)).fetchone()[0]


def insert_run(conn: sqlite3.Connection, batch_id: int, entity_id: int, **fields) -> int:
    """幂等写入测试记录：ON CONFLICT(batch_id, entity_id) DO UPDATE SET fields，返回 id。

    fields 可含 result / errors / ecc_errors / passes / test_date。
    """
    cols = list(fields)
    if not cols:
        # 无字段也确保记录存在（幂等，INSERT OR IGNORE）
        conn.execute(
            'INSERT OR IGNORE INTO runs(batch_id, entity_id) VALUES(?, ?)',
            (batch_id, entity_id))
    else:
        sets = ', '.join('%s=excluded.%s' % (k, k) for k in cols)
        placeholders = ', '.join('?' * len(cols))
        conn.execute(
            'INSERT INTO runs(batch_id, entity_id, %s) VALUES(?, ?, %s) '
            'ON CONFLICT(batch_id, entity_id) DO UPDATE SET %s' % (
                ', '.join(cols), placeholders, sets),
            [batch_id, entity_id] + list(fields.values()))
    return conn.execute(
        'SELECT id FROM runs WHERE batch_id=? AND entity_id=?',
        (batch_id, entity_id)).fetchone()[0]


def export_csv(conn: sqlite3.Connection, out_path: str) -> None:
    """runs JOIN batches/entities 导出全量 CSV，utf-8-sig，含表头。"""
    cols = [
        'Machine', 'Batch', 'SerialNumber', 'CapacityGB', 'PartNumber',
        'Manufacturer', 'Result', 'Errors', 'EccErrors', 'Passes', 'TestDate',
    ]
    rows = conn.execute('''
        SELECT b.machine, b.batch, e.serial, e.capacity_gb, e.part_number,
               e.manufacturer, r.result, r.errors, r.ecc_errors, r.passes, r.test_date
        FROM runs r
        JOIN batches b ON b.id = r.batch_id
        JOIN entities e ON e.id = r.entity_id
    ''').fetchall()
    with open(out_path, 'w', encoding='utf-8-sig', newline='') as f:
        w = csv.writer(f)
        w.writerow(cols)
        w.writerows(rows)
