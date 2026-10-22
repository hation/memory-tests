# memory-tests 工程基建优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 disk-tests 沉淀的工程基建（P0-P2 共 8 项），补齐 memory-tests 的测试框架、单源构建、版本单源、文档状态标记、JSON 事件流、SQLite 历史库与协作规则，并消除现有双目录/重复逻辑。

**Architecture:** PowerShell 脚本抽取共享库 `scripts/lib_common.ps1`（识别/解析/CSV/事件/版本函数），三个编排脚本 dot-source 共用；`scripts/build.ps1` 单源构建生成离线包；历史库用 Python 3 标准库 sqlite3 三段式（batches/entities/runs），幂等 upsert。

**Tech Stack:** PowerShell 5.1、Python 3（仅 sqlite3 标准库，测试用 unittest 免 pytest）、Memtest86+ v9。

**Spec:** [2026-10-22-通用测试工具基建搭建-design.md](../../2026-10-22-通用测试工具基建搭建-design.md)（通用规格）+ [29-disk-tests经验沉淀与新项目复用指南.md](../../29-disk-tests经验沉淀与新项目复用指南.md)（依据）。本计划把规格适配到 memory-tests：规格 §3.1-§3.9 全部落地；唯一调整 = §3.8 历史库经用户确认采用 **Python + sqlite3**（沿盘工具模式）。

## Global Constraints

- PowerShell 5.1 兼容（不用 PS7 专属语法）；脚本文件统一 UTF-8 **带 BOM**（PS5 中文兼容，历史上已踩坑）
- 离线包保持「免安装、零运行时依赖」（核心功能）；历史库为可选功能，需 Python 3
- 版本单一来源 = 根目录 `VERSION` 文件（当前 `v1`），任何地方不得再硬编码版本号
- 现有脚本行为**不得回归**：Run-MemtestSuite.ps1 三种解析器输出字段不变（08-报表结构说明 与之对齐）
- 源文件唯一：脚本源在 `scripts/`（git mv 从根迁入）；离线包 `SOL内存测试离线包/scripts` 由 build.ps1 生成，禁止手工同步
- 每任务独立可测、独立提交；提交用 `git -c user.name="ganxin" -c user.email="331596350@qq.com" commit`

## Review Focus

1. **MTLOG 行格式变体**：未知事件 / 缺字段的行不能崩解析器，必须落入 default 分支记录。→ Task 2 测试：fixture 含未知事件行，解析后 `Events` 含该行且无异常。
2. **USB 报告残缺**：写一半/截断的报告必须判 INCOMPLETE 而非误判 PASS。→ Task 2 测试：截断 fixture → `FinalStatus = "INCOMPLETE"`。
3. **批次清单 CSV 列错位**：`TestList="0,1,2,3"` 带引号逗号 + 行尾空字段不能错位（PS5 `Import-Csv` 丢行尾空字段的历史坑）。→ Task 2 测试：`Read-CsvManifest` 断言 17 列对齐。
4. **VERSION 缺失**：库或离线包缺 `VERSION` 时 `Get-AppVersion` 必须回退而非报错。→ Task 3 测试：临时删 VERSION → 返回 `v0-dev`。
5. **历史库重复导入**：同一报告导入两次必须幂等（UNIQUE + upsert），不得产生重复行。→ Task 6 测试：import 两次 → runs 行数不变。

---

### Task 1: 脚本入库 + 抽取 lib_common.ps1 公共库（P0-②）

**Files:**
- Create: `scripts/lib_common.ps1`
- Move: `Run-MemtestSuite.ps1`、`Run-BatchScheduler.ps1`、`Identify-Memory.ps1` → `scripts/`（git mv）
- Modify: `scripts/Run-MemtestSuite.ps1`、`scripts/Identify-Memory.ps1`、`scripts/Run-BatchScheduler.ps1`

**Interfaces:**
- Produces（lib_common.ps1 导出函数，签名固定）:
  - `Get-MemoryInventory [-ExpectedCsv <string>] [-BatchName <string>]` → `PSCustomObject[]`，字段：`Batch, Slot, BankLabel, SerialNumber, PartNumber, Manufacturer, CapacityGB, SpeedMTs, MemType, MatchState, Issues, Status`
  - `Invoke-MtlogParser [-LogFile <string>]` → summary 对象：`PassesCompleted, Errors, EccErrors, FinalStatus, Events, ErrorDetails, SpdInfo, SystemInfo`（字段名与现脚本一致，禁止改名）
  - `Invoke-TextReportParser [-ReportFile <string>]` → summary 对象：`PassesCompleted, Errors, EccErrors, FinalStatus, PerTest, SpdInfo, SystemInfo`
  - `Read-CsvManifest [-Path <string>]` → 行对象数组（TextFieldParser，保留行尾空字段）
  - `Write-Event [-Type <string>] [-Data <hashtable>]` → 向 stdout 输出一行 `{"type":...,"data":{...}}`（ConvertTo-Json -Compress）
  - `Get-AppVersion` → 读 `$PSScriptRoot\..\VERSION`（trim），缺失回退 `v0-dev`
  - `Write-Log [-Msg <string>] [-Level <string>="INFO"]` → 带时间戳控制台行 `[HH:mm:ss] LEVEL msg`
  - `ConvertTo-CsvField [-Value <object>]` → 含逗号/引号/换行时加引号转义
  - `Confirm-Targets [-Targets <array>] [-SkipConfirm <switch>]` → 打印被测清单，默认要求输入 `y` 确认（业务占位，骨架）
  - `Get/Set-StageDone [-Dir <string>] [-Stage <string>]` → `.done` 阶段标记读写（断点续跑骨架）
  - `Wait-Slot [-MaxSlots <int>]` → 并发槽位信号量（骨架，串行批次场景暂不接线）
  - `Get-SystemEvents [-HoursBack <int>=24]` → 系统级证据采集（实现 = 现 `Get-WheaMemoryErrors` 逻辑搬入）
- Consumes：无（新库）

- [ ] **Step 1: git mv 三个脚本进 `scripts/`**

Run: `git mv Run-MemtestSuite.ps1 scripts/ ; git mv Run-BatchScheduler.ps1 scripts/ ; git mv Identify-Memory.ps1 scripts/`
Expected: `git status` 显示 3 条 rename 到 scripts/

- [ ] **Step 2: 创建 `scripts/lib_common.ps1`**

把 `Run-MemtestSuite.ps1` 的 `Get-MemoryInventory`(L131-196)、`Parse-KvPairs`(L203-232)、`Invoke-MtlogParser`(L235-318)、`Invoke-TextReportParser`(L321-370)、`Get-WheaMemoryErrors`(L532-553) **原样搬入**（函数体、字段名逐字保留），新增 `Read-CsvManifest`（从 Run-BatchScheduler 的 `Read-ManifestRows` 搬入并改名）、`Write-Event`、`Write-Log`、`ConvertTo-CsvField`、`Get-AppVersion`，并按 §3.6 补 `Confirm-Targets`、`Get/Set-StageDone`、`Wait-Slot`、`Get-SystemEvents`（= 搬入的 Get-WheaMemoryErrors，作为内存业务版实现）。文件头注释注明「共享库，禁止业务逻辑」。UTF-8 BOM。

- [ ] **Step 3: 改写三个脚本为 dot-source 共用**

`scripts/Run-MemtestSuite.ps1`：顶部（param 之后）加 `. $PSScriptRoot\lib_common.ps1`；删除已搬走的函数定义（含 Get-WheaMemoryErrors，主流程调用处改为 `Get-SystemEvents`）。
`scripts/Identify-Memory.ps1`：加 dot-source；把自身的 `Get-CimInstance` 识别段换成 `Get-MemoryInventory -ExpectedCsv $ExpectedCsv -BatchName $BatchName`（保留其 `Status`/`Issues` 输出与 CSV 写出逻辑不变）。
`scripts/Run-BatchScheduler.ps1`：加 dot-source；`Read-ManifestRows` 删除，改调 `Read-CsvManifest`。

- [ ] **Step 4: 语法与冒烟验证**

Run: 对 4 个 ps1 逐一 `[System.Management.Automation.Language.Parser]::ParseFile` 断言无 error；`powershell -File scripts\Run-MemtestSuite.ps1 -Help` 输出正常；`powershell -File scripts\Identify-Memory.ps1 -BatchName smoke` 正常出清单。
Expected: 全通过，输出与重构前一致。

- [ ] **Step 5: Commit**

```bash
git add scripts lib_common.ps1
git commit -m "refactor: move scripts to scripts/, extract shared lib_common.ps1 (P0-2)"
```

---

### Task 2: tests/ 自动化测试框架（P0-①）

**Files:**
- Create: `tests/fixtures/sample-pass.mtlog.txt`、`tests/fixtures/sample-fail.mtlog.txt`、`tests/fixtures/sample-unknown.mtlog.txt`、`tests/fixtures/sample-pass.usb.txt`、`tests/fixtures/sample-truncated.usb.txt`、`tests/fixtures/sample-batches.csv`
- Create: `tests/test-lib.ps1`、`tests/test-args.ps1`

**Interfaces:**
- Consumes: Task 1 的 `Invoke-MtlogParser`、`Invoke-TextReportParser`、`Read-CsvManifest`、`Get-AppVersion`
- Produces: fixtures 内容约定（供 Task 6 复用风格）

- [ ] **Step 1: 造 fixtures**

`sample-pass.mtlog.txt`：含 `ev=start`、2 条 `ev=spd`、4 个 `ev=pass_end ... status=pass`、末尾 `ev=done passes=4 status=pass`。
`sample-fail.mtlog.txt`：pass_end 后有 `ev=data addr=0x100000 expect=0x55 actual=0x5A`，`ev=done passes=1 status=fail`。
`sample-unknown.mtlog.txt`：中间插一行 `MTLOG ts=9.0 ev=weird_key k=v`（未知事件）。
`sample-pass.usb.txt`：`Passes completed: 4`、`Errors: 0`、`Final Result: PASS`、2 行 `Test N: ... Errors: 0`。
`sample-truncated.usb.txt`：只到 `Passes completed: 2`，无 Final Result。
`sample-batches.csv`：表头 17 列；第 1 行 `TestList` 为 `"0,1,2,3"`；第 2 行行尾留空字段（`...,yes,`）。

- [ ] **Step 2: 写 `tests/test-lib.ps1`（dot-source 库，断言解析/判定/清单）**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
$pass = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-pass.mtlog.txt"
Assert($pass.PassesCompleted -eq 4 -and $pass.Errors -eq 0 -and $pass.FinalStatus -eq "PASS")
$fail = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-fail.mtlog.txt"
Assert($fail.FinalStatus -eq "FAIL" -and $fail.ErrorDetails.Count -ge 1)
$unk = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-unknown.mtlog.txt"
Assert($unk.Events | Where-Object ev -eq 'weird_key')   # 未知事件不崩
$u = Invoke-TextReportParser -ReportFile "$PSScriptRoot\fixtures\sample-pass.usb.txt"
Assert($u.FinalStatus -eq "PASS")
$t = Invoke-TextReportParser -ReportFile "$PSScriptRoot\fixtures\sample-truncated.usb.txt"
Assert($t.FinalStatus -eq "INCOMPLETE")                  # 残缺报告不误判
Write-Host "test-lib: ALL PASS"
```

- [ ] **Step 3: 写 `tests/test-args.ps1`（断言清单→命令映射）**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
$rows = Read-CsvManifest -Path "$PSScriptRoot\fixtures\sample-batches.csv"
Assert($rows.Count -eq 2)
Assert($rows[0].TestList -eq "0,1,2,3")                  # 引号逗号正确
Assert($rows[1].LogPath -eq "")                          # 行尾空字段保留
Write-Host "test-args: ALL PASS"
```

- [ ] **Step 4: 运行并确认全绿**

Run: `powershell -NoProfile -File tests\test-lib.ps1` 与 `tests\test-args.ps1`
Expected: 各打印 `ALL PASS`；任一行断言失败则以非零退出码结束（用 `throw` 实现 Assert）。

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: add test framework with parser/judgement/manifest fixtures (P0-1)"
```

---

### Task 3: VERSION 单一来源 + 注入（P1-④）

**Files:**
- Create: `VERSION`（内容 `v1`）
- Modify: `scripts/lib_common.ps1`（Get-AppVersion 已在 Task 1，若未实现则本任务补全）、`scripts/Run-MemtestSuite.ps1`（Export-TestReport 加 ToolVersion 列）

**Interfaces:**
- Produces: 报表 CSV 新增列 `ToolVersion`（在 `Batch` 之后）；`master_manifest.csv` 同列

- [ ] **Step 1: 创建 `VERSION` 文件**（内容 `v1`，无换行）
- [ ] **Step 2: 在 `Export-TestReport` 的 report 行对象加 `ToolVersion = Get-AppVersion`**（位于 `Batch` 之后）
- [ ] **Step 3: 验证**

Run: `powershell -Command ". scripts\lib_common.ps1; Get-AppVersion"`
Expected: `v1`。删除 `VERSION` 再跑 → `v0-dev`（回退不崩，Review Focus 4），恢复文件。

- [ ] **Step 4: Commit**（`git commit -m "feat: single-source version VERSION + report column (P1-4)"`）

---

### Task 4: build.ps1 单源构建（P1-③）

**Files:**
- Create: `scripts/build.ps1`
- Modify: `SOL内存测试离线包/README.md`（版本行由构建注入）

**Interfaces:**
- Produces: 命令 `scripts\build.ps1 [-KitDir <path>]`，默认 `KitDir = <repo>\SOL内存测试离线包`；产物 `KitDir\CHECKSUM.txt`

- [ ] **Step 1: 写 `scripts/build.ps1` 核心逻辑**

```
param([string]$KitDir = "<repo>\SOL内存测试离线包")
$ver = Get-Content VERSION (trim)
① 同步：scripts(3+lib_common) → KitDir\scripts\；docs/* → KitDir\docs\；boot/config/tools 原样（存在则拷）
② 注入：KitDir\VERSION = $ver；KitDir\README.md 首部加一行 `> 工具版本：$ver`（幂等：先删旧行再加）
③ 校验：关键文件存在（scripts\lib_common.ps1、docs\01-验收测试方案.md、boot\memtest.iso、tools\README-tools.md）；写 KitDir\CHECKSUM.txt（SHA256，每行 `hash 相对路径`）
④ 幂等：重复构建结果一致
```

- [ ] **Step 2: 运行构建**

Run: `powershell -NoProfile -File scripts\build.ps1`
Expected: 离线包 scripts 出现 `lib_common.ps1`；`KitDir\VERSION` = v1；README 含版本行；CHECKSUM.txt 生成。

- [ ] **Step 3: 幂等复跑**：再跑一次，CHECKSUM 内容不变。
- [ ] **Step 4: Commit**（`git commit -m "feat: single-source build scripts/build.ps1 -> offline kit (P1-3)"`）

---

### Task 5: docs [当前有效] 状态标记 + 路径修正（P1-⑤）

**Files:**
- Modify: `docs/01..11`（各文档头部加状态块）、`SOL内存测试离线包/docs/01..11`（同步，由 build 覆盖亦可）、`README.md`

- [ ] **Step 1: 给 docs/01-11 每份文档在标题行之后插入状态块**

```markdown
> 状态：[当前有效]（2026-10-22）
> 变更记录：2026-10-22 文档体系编号化（对齐 disk-tests）；工程基建优化更新
```

用 PowerShell 循环插入（按行首 `# ` 标题后插两行），注意保留原文件 BOM/编码。

- [ ] **Step 2: 修正 README 与 docs 中脚本路径为 `scripts/`**（重构后脚本已入 scripts/；README 命令由 `.\scripts\...` 保持，检查 docs 引用 `Identify-Memory.ps1` 等路径加 `scripts/` 前缀）
- [ ] **Step 3: 验证**：每份 docs 文件第 1-3 行含 `[当前有效]`；README 路径可指向真实文件。
- [ ] **Step 4: Commit**（`git commit -m "docs: add [current] status markers and fix script paths (P1-5)"`）

---

### Task 6: SQLite 三段式历史库（P2-⑦，Python + sqlite3）

**Files:**
- Create: `db/db_common.py`、`db/db_import.py`、`db/db_query.py`、`db/db_export.py`、`db/db_merge.py`
- Create: `tests/test_db.py`（unittest，stdlib 免 pytest）
- Modify: `docs/08-报表结构说明.md`（历史库章节）、`SOL内存测试离线包/README.md`（db 可选功能说明）

**Interfaces:**
- `db_common.py`: `init_db(path) -> sqlite3.Connection`（建表+WAL）；`upsert_batch(conn, machine, batch)`；`upsert_entity(conn, serial, fields:dict)`；`insert_run(conn, batch_id, entity_id, **fields)`（幂等：`UNIQUE(batch_id, entity_id)` + `ON CONFLICT DO UPDATE`）；`export_csv(conn, out_path)`（utf-8-sig）
- `db_import.py`: `python db_import.py <report.csv> [--db history.db] [--machine <name>]`；识别 CSV 列（Batch/SerialNumber/Result/...），按 `Batch` 建批次、按 `SerialNumber` 建实体、逐行入 runs
- `db_query.py`: `--db`、`--serial <sn>`、`--batch <name>`、`--trend`（按 SN 输出历史 runs）
- `db_export.py`: `--db` `--out`
- `db_merge.py`: `--db1` `--db2` `--out`（幂等合并，按唯一键去重）

- [ ] **Step 1: 写 `db/db_common.py`**（三段式表：`batches(id, machine, batch, UNIQUE(machine,batch))`、`entities(id, serial, capacity_gb, part_number, manufacturer, created_at, UNIQUE(serial))`、`runs(id, batch_id FK, entity_id FK, result, errors, ecc_errors, passes, test_date, UNIQUE(batch_id, entity_id))`；PRAGMA WAL；upsert 幂等）
- [ ] **Step 2: 写 `tests/test_db.py`（unittest）**

```python
import tempfile, os, unittest, sys, sqlite3
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
```

- [ ] **Step 3: 写 import/query/export/merge 四个 CLI 脚本**（argparse；`--db` 缺省 `history.db`；import 逐行幂等）
- [ ] **Step 4: 运行测试**

Run: `python tests\test_db.py -v`
Expected: 全绿（用 `python` 或磁盘工具自带 `disk-tests\deploy\bin\python\python.exe`）。

- [ ] **Step 5: 端到端冒烟**：`db_import.py tests\fixtures 产出的一份 report.csv`（或用 `--batch` 造数据）→ `db_query.py --serial <sn>` 出历史 → `db_export.py` 出 utf-8-sig CSV → `db_merge.py` 两库合并幂等。
- [ ] **Step 6: 更新 docs/08 与离线包 README**（db 为可选功能，需 Python 3；核心功能仍纯 PS）
- [ ] **Step 7: Commit**（`git commit -m "feat: sqlite history db (three-segment, idempotent) + tests (P2-7)"`）

---

### Task 7: JSON 事件流 + AGENTS.md + 报表三件套（P2-⑥⑧）

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`（主流程里程碑处调 `Write-Event`）、`scripts/Run-BatchScheduler.ps1`（末尾写 `all-batches-summary.txt`）
- Create: `AGENTS.md`

- [ ] **Step 1: Run-MemtestSuite 主流程加事件输出**：在「编排开始 / 识别完成 / 捕获完成 / 解析完成 / 报告已生成」5 处调 `Write-Event -Type stage|entity|done -Data @{...}`（SOL/USB 捕获为 stage 事件）
- [ ] **Step 2: 调度器写 summary 三件套**：全部批次跑完后写 `all-batches-summary.txt`（批次数、总根数、PASS/FAIL/INCOMPLETE 计数、耗时）
- [ ] **Step 3: 创建 `AGENTS.md`**（仿 disk-tests：① 开发/修复任务强制 superpowers 流程（brainstorming→spec→plan）；② 计划完成后子代理驱动执行不询问；③ 简化：纯文档/一次性改动不受限）
- [ ] **Step 4: 验证**：`-ParseOnly` 跑一份 fixture 日志，控制台出现 JSON 事件行；调度器 DryRun 正常。
- [ ] **Step 5: Commit**（`git commit -m "feat: json event stream, AGENTS.md, report summary (P2-6/8)"`）

---

### Task 8: 全量验证 + 同步 + 提交推送

- [ ] **Step 1: 全量回归**：`powershell -File tests\test-lib.ps1`、`test-args.ps1`、`python tests\test_db.py` 全绿；4 个 ps1 语法全过
- [ ] **Step 2: 构建+冒烟**：`scripts\build.ps1` 后离线包齐（lib_common、VERSION、CHECKSUM）；`Run-MemtestSuite.ps1 -Help`、`Identify-Memory.ps1` 冒烟
- [ ] **Step 3: 同步离线包 docs**（build 已覆盖；确认 11 份含状态标记）
- [ ] **Step 4: 更新 docs/05 使用手册**（新增 lib_common/build/事件流/VERSION 说明）与根 README（目录结构加 scripts/db/tests/VERSION）
- [ ] **Step 5: 提交并推送**（`git add -A; git commit -m "chore: verify, sync kit, update docs" ; git push origin main`）

---
