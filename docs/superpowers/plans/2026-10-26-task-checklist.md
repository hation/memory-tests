# 任务进度追踪（批次总览 + 流程清单）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 参考 disk-tests 的"任务清单-结果.md"机制，为 memory-tests 增加批次级任务进度追踪：总览清单（17 项）+ 每流程明细清单，环境不支持自动标注，双机归集合并，自动化挂点更新。

**Architecture:** 清单函数进 lib_common（New-TaskChecklist/Update-TaskChecklist/Update-OverviewRow/Merge-TaskChecklists，UTF-8 Markdown 表格读写，disk-tests 移植）；薄壳脚本 New-TaskChecklist.ps1/Update-TaskChecklist.ps1；自动化挂点嵌入 Run-MemtestSuite/Run-Prime95Stress/Identify-Memory（加 -ChecklistBatch/-Scenario）；归集 Export/Import-ServerResults 打包并合并清单写回编排机。

**Tech Stack:** PowerShell 5.1、Markdown 表格（UTF-8）、`tests\test-*.ps1` Assert 约定。

**Spec:** `docs/superpowers/specs/2026-10-26-task-checklist-design.md`

## Global Constraints

- PowerShell 5.1；清单函数放 lib_common.ps1（双机可调）；UTF-8 读写（ReadAllText/WriteAllText UTF8 无 BOM，防中文乱码）；cmdlog `Write-CmdLog` 记录。
- 清单按**验收批次**组织：`results\<验收批次>\任务清单-总览.md` + `任务清单-<流程>.md`（10 张：建档/Memtest/混插/ECC/断电循环/ORT/Prime95/多平台/目检电性/L3外包）。
- 状态集：`✓ 做成 / ✗ 没做成 / ─ 本次没做 / ⏳ 进行中 / ⚠ 无法测试`；表列与 disk-tests 同款。
- 总览初始化读 `results\assessment\<机器>-assessment.csv`（或 srv01-assessment.csv）：`可测*`→`─`；`需编排机/需带内`→`─ 待执行`；`需 BMC/需条件*`→`⚠ 无法测试`+Action 原因；`外包*`→`⚠ 无法测试`+`外包送检（L3）`；评估缺失→提示+全 `─`。
- 环境依赖映射（总览测试项→评估项）：4→ECC、5→ORT、10→断电循环、16→混插、6-9/11-14→L3外包、15→多平台、1-3/17→无依赖。
- 归集合并：流程清单（建档/Prime95 等服务器独有）直接带入；共享清单（总览/混插）逐行取"有实际状态"一方（⚠ 算有状态；两边均 ─ 取服务器侧）；Import 合并后写回编排机 `results\<验收批次>\`（不存在则建）。
- 自动化挂点：Run-MemtestSuite 加 `-ChecklistBatch`（缺省=BatchName）与 `-Scenario`（`标准`/`混插`，缺省标准）；Run-Prime95Stress 加 `-ChecklistBatch`；Identify-Memory 建档完成更新（建立验收批次清单）。
- 版本：基线 v14（另一会话已提交）；完成后 `build.ps1 -Bump -Zip`（v15）。
- 打包纪律：逻辑代码调整 → 打包；先删旧包再建 + hash 校验。

## Review Focus

- 评估 CSV 缺失/损坏 → 提示且清单仍生成（全 ─），不崩溃。→ Task 1。
- 清单/总览不存在时 Update → 静默返回（幂等，不报错）。→ Task 1。
- 状态非法值 → 校验报错。→ Task 1/2。
- 合并共享清单逐行取有状态方（⚠ 算有状态；两边 ─ 取服务器侧），不丢编排机已更新行。→ Task 4。
- `-Scenario` 非 标准/混插 → ValidateSet 拒绝；`-ChecklistBatch` 缺省=BatchName。→ Task 3。

---

### Task 1: lib_common.ps1 清单函数区 + tests/test-task-checklist.ps1

**Files:**
- Modify: `scripts/lib_common.ps1`（尾部、Write-CmdLog 前追加"任务清单函数区"；紧接 Prime95 函数区后）
- Create: `tests/test-task-checklist.ps1`

**Interfaces:**
- Produces（Task 2-4 依赖的精确签名）：
  - `New-TaskChecklist [-ChecklistBatch<string>] [-MachineName<string>] [-ResultsDir<string>] [-AssessmentCsv<string>]` → 建 `results\<批次>\任务清单-总览.md` + 10 张流程清单（表结构见 spec）；读评估 CSV 标注（映射见 Global Constraints）；评估缺失提示；返回清单目录。
  - `Update-TaskChecklist [-ChecklistPath<string>] [-Key<string>] [-Status<string>] [-Result<string>] [-Product<string>]` → 按环节名定位更新状态/结果/产物（UTF-8）；文件不存在静默返回。
  - `Update-OverviewRow [-OverviewPath<string>] [-ItemNo<int>] [-Status<string>] [-Result<string>] [-Reason<string>]` → 按测试项编号定位更新总览行；文件不存在静默返回。
  - `Merge-TaskChecklists [-ServerChecklistDir<string>] [-OrchestratorChecklistDir<string>] [-MachineName<string>]` → 把服务器清单并入编排机：流程清单直接带入（不存在才复制）；总览/混插逐行取有状态方；返回编排机清单目录。

- [ ] **Step 1: 写失败测试 `tests/test-task-checklist.ps1`**（临时目录黑盒，dot-source lib_common 调函数）：
  - New：临时 ResultsDir 建 batch=testA1 → 断言总览存在 + 表含 17 行 + 10 张流程清单存在 + 初始状态 `─`；
  - New+评估标注：临时写 assessment CSV（含"需 BMC"、`需编排机`、`外包`、`可测` 行）→ 断言对应总览行 ⚠/─ 与原因；
  - New 评估缺失：不写 CSV → 断言全 `─` + 有提示（不抛异常）；
  - Update-TaskChecklist：更新一行 → 断言该行状态/结果/产物变化、其他行不变；文件不存在 → 不抛异常；
  - Update-OverviewRow：按编号更新 → 断言；文件不存在 → 不抛异常；
  - Merge：服务器目录含建档清单+总览（建档行 ✓）；编排机含总览（Memtest 行 ✓、建档行 ─）→ 合并后：建档清单带入、总览建档行取服务器 ✓、Memtest 行保留编排机 ✓；两边 ─ 取服务器侧。
- [ ] **Step 2: 运行确认失败** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-task-checklist.ps1` → 函数不存在报错。
- [ ] **Step 3: 实现四个函数**（lib_common.ps1 尾部追加；Markdown 表行定位正则 `^\| \d+ \|`、列 `-split "\|"`，UTF-8 ReadAllText/WriteAllText(UTF8 无 BOM, `\r\n`)）。
- [ ] **Step 4: 运行确认通过** — 同上 → `test-task-checklist: ALL PASS`。
- [ ] **Step 5: 回归** — `test-prime95.ps1`、`test-results-import.ps1` → ALL PASS（未动既有函数）。
- [ ] **Step 6: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-task-checklist.ps1
git commit -m "feat: task-checklist lib functions (new/update/overview/merge) + tests"
```

---

### Task 2: 薄壳脚本 New-TaskChecklist.ps1 + Update-TaskChecklist.ps1

**Files:**
- Create: `scripts/New-TaskChecklist.ps1`
- Create: `scripts/Update-TaskChecklist.ps1`
- Modify: `tests/test-task-checklist.ps1`（追加薄壳黑盒用例）

**Interfaces:**
- Consumes: Task 1 四个函数。
- Produces: 命令行入口——New：`-BatchName <建档批次> -ChecklistBatch <验收批次，缺省=BatchName> -MachineName [-ExpectedCsv]`；Update：`-BatchName -Flow <建档|Memtest|混插|ECC|断电循环|ORT|Prime95|多平台|目检电性|L3外包> -Key <环节> -Status <✓|✗|─|⏳|⚠> -Result -Product`；均 cmdlog + exit 0/1。

- [ ] **Step 1: 追加失败测试**（临时包根拷贝法，Invoke 薄壳黑盒）：New 生成清单；Update 人工更新一行；非法 `-Status` → 报错 exit 1。
- [ ] **Step 2: 运行确认失败** — 同上 → 脚本不存在报错。
- [ ] **Step 3: 实现两脚本**（param/默认值/校验/cmdlog/调用 lib_common；New 缺省 ResultsDir=`<包根>\results`；Update 组装 `results\<BatchName>\任务清单-<Flow>.md` 路径）。
- [ ] **Step 4: 运行确认通过** — 同上 → `test-task-checklist: ALL PASS`。
- [ ] **Step 5: Commit**

```bash
git add scripts/New-TaskChecklist.ps1 scripts/Update-TaskChecklist.ps1 tests/test-task-checklist.ps1
git commit -m "feat: task-checklist thin-shell scripts (manual init/update)"
```

---

### Task 3: 自动化挂点（Run-MemtestSuite / Run-Prime95Stress / Identify-Memory）

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`（param 块加 -ChecklistBatch/-Scenario；报告生成后更新）
- Modify: `scripts/Run-Prime95Stress.ps1`（param 加 -ChecklistBatch；完成更新）
- Modify: `scripts/Identify-Memory.ps1`（建档完成更新建档清单+总览 1/2 项；建立验收批次清单）

**Interfaces:**
- Consumes: Task 1 函数（New-TaskChecklist/Update-TaskChecklist/Update-OverviewRow）。
- Produces: 清单缺失自动建（幂等）；各脚本完成后更新对应行。

- [ ] **Step 1: 读三个脚本定位插入点** — 找 param 块、报告生成/完成处（Run-MemtestSuite 报告 `Export-TestReport` 后；RestartLoop 完成处；Run-Prime95Stress `Export-Prime95Report` 后；Identify-Memory 建档写盘后）。
- [ ] **Step 2: Run-MemtestSuite** — param 加 `[string]$ChecklistBatch = ""`、`[ValidateSet('标准','混插')][string]$Scenario = '标准'`；完成处：清单缺失 `New-TaskChecklist`（缺省 BatchName=ChecklistBatch）；标准 → Memtest 清单档位行（按 -MaxPasses 与预设 testlist 判定档位名：1 轮快筛/1 轮全项/2 轮快筛/2 轮全项/4 轮快筛/4 轮全项）+ 总览第 3 项（Result 注明档位与 Errors/Passes；PASS→✓ FAIL→✗）；混插 → 混插清单"Memtest 混插组合"+ 总览第 16 项；`-RestartLoop N` 完成 → 断电循环"200 次循环"（Result=实际 N 次）+ 总览第 10 项。
- [ ] **Step 3: Run-Prime95Stress** — param 加 `[string]$ChecklistBatch = ""`；`Export-Prime95Report` 后：清单缺失自动建（服务器侧）；Prime95 流程清单环节（`-Minutes -ge 4320`→正式长压，否则冒烟）+ 混插清单"Prime95 长压"环节；**不更新总览第 5 项**。
- [ ] **Step 4: Identify-Memory** — 建档写盘后：`New-TaskChecklist`（BatchName=建档批次，建立验收批次清单）+ 建档清单三环节（识别✓/生成清单✓/比对按 MatchState）+ 总览第 1/2 项。
- [ ] **Step 5: 语法验证** — `[scriptblock]::Create((Get-Content -Raw scripts\Run-MemtestSuite.ps1))` 等三脚本无语法错误。
- [ ] **Step 6: Commit**

```bash
git add scripts/Run-MemtestSuite.ps1 scripts/Run-Prime95Stress.ps1 scripts/Identify-Memory.ps1
git commit -m "feat: hook task-checklist auto-updates into memtest/prime95/identify"
```

---

### Task 4: 归集扩展（Export/Import-ServerResults 打包 + 合并清单）

**Files:**
- Modify: `scripts/Export-ServerResults.ps1`（打包范围加 `results\<批次>\任务清单-*.md`）
- Modify: `scripts/Import-ServerResults.ps1`（导入后合并清单写回编排机）

**Interfaces:**
- Consumes: Task 1 的 `Merge-TaskChecklists`。
- Produces: 服务器清单随包带走；导入合并写回 `results\<验收批次>\`。

- [ ] **Step 1: 读两脚本定位打包/导入逻辑** — Export 的 staging 复制 6 项处；Import 的 Expand-Archive 后。
- [ ] **Step 2: Export** — staging 复制加第 7 项：`results` 根下所有 `任务清单-*.md` 所在子目录（`results\<批次>\任务清单-*.md`，用 `Get-ChildItem results -Recurse -Filter 任务清单-*.md` 收集所在目录复制）——或简化为复制 `results\*\任务清单-*.md`。
- [ ] **Step 3: Import** — 解压后：收集 zip 内 `任务清单-*.md` → 按批次目录调用 `Merge-TaskChecklists`（服务器清单目录=解压所得；编排机目录=`<ImportRoot>\<批次>\`，不存在则建）→ 合并结果写回编排机 `results\<批次>\`。
- [ ] **Step 4: 验证** — `test-results-import.ps1` 全绿（临时包根：构造服务器 results 含任务清单 → Export → Import → 断言合并结果）。
- [ ] **Step 5: Commit**

```bash
git add scripts/Export-ServerResults.ps1 scripts/Import-ServerResults.ps1 tests/test-results-import.ps1
git commit -m "feat: archive and merge task checklists on results import"
```

---

### Task 5: 文档 + 全量回归 + 打包 v15 + 提交

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（新增"流程 11 · 任务进度追踪"）
- Modify: `docs/19-测试项执行清单.md`（同步任务清单说明）
- Run: `scripts/build.ps1 -Bump -Zip`

- [ ] **Step 1: docs/20 加"流程 11 · 任务进度追踪"**（置于流程 10 之后、附录之前）：做什么（批次总览+流程清单，双机归集合并，环境不支持自动标）；命令（`New-TaskChecklist.ps1 -BatchName srv01-a1`；`Update-TaskChecklist.ps1 -BatchName srv01-a1 -Flow 目检电性 -Key 目检金手指焊点 -Status ✓`；自动更新说明）；得到什么（总览+流程清单文件、总结论）；日志在哪（cmdlog）。输出速查表加一行。
- [ ] **Step 2: docs/19 第 16 项/输出文件** 同步任务清单说明（总览/流程清单文件位置）。
- [ ] **Step 3: 全量回归** — `test-task-checklist.ps1`、`test-results-import.ps1`、`test-prime95.ps1`、`test-ort.ps1`、`test-suite-config.ps1`、`test-lib.ps1`、`test-presets.ps1`、`test-args.ps1` → 全部 ALL PASS。
- [ ] **Step 4: 打包** — `build.ps1 -Bump -Zip`（v14→v15）；hash 校验关键文件（lib_common/New-TaskChecklist/Update-TaskChecklist/Run-MemtestSuite/Run-Prime95Stress/Identify-Memory/Export/Import/docs20）。
- [ ] **Step 5: Commit（范围按先例）** — repo scripts/docs + VERSION + kit 同步（scripts/docs/CHECKSUM/VERSION/README）；**不含** db/*。

---

## 执行说明

- 执行方式：**Subagent-driven development**（用户固定默认）。每 Task 独立 subagent 实现 + 独立 reviewer 复查；结尾整支复查。
- 基线 HEAD：be73b82（spec 已提交；v14 已由另一会话提交打包）。
- 实机冒烟（服务器建档→清单建立→归集合并）为交付后人工步骤，按手册流程 11 执行。
