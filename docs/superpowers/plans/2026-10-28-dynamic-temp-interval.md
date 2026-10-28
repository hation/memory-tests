# 动态温度采样间隔（ORT 模式）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** ORT 模式温度采样间隔按时长动态自适应（`-TempIntervalMin` 默认 0=动态，>0 显式固定），短测多轮、长测每小时 1 点。

**Spec:** `docs/superpowers/specs/2026-10-28-dynamic-temp-interval-design.md`（v2 修正版，builder-check 已过）

**Architecture:** lib_common 新增纯函数 `Get-DynamicTempIntervalMin`（≤60→4、否则→12；`clamp(ceil(MaxMinutes/TargetSamples),1,60)`）；Run-MemtestSuite `-TempIntervalMin` 默认 0（0=动态，ORT 分支计算实际间隔并打印）；config `TEMP_INTERVAL_MIN` 两处默认 60→0；docs/20 补参数说明 + 修订"默认每小时一次"。

## Global Constraints

- PowerShell 5.1；UTF-8 BOM 保留；cmdlog 不动。
- 动态只在 ORT 模式（`-MaxMinutes>0`）生效；普通压测（-MonitorTemp 单点读取）不受影响。
- 兼容：Start-OrTTempSampling `IntervalMin -gt 0` 判断保留（动态结果 ≥1 不 0 死循环）。
- 打包：逻辑代码调整 → `build.ps1 -Bump -Zip`（v17→v18）；先删旧包；hash 校验 + kit 同步。
- 基线 HEAD：b78e2f7。

## Review Focus

- 函数单测 12 档数字与 spec 表格一致（10→3,20→5,30→8,60→15,120→10,180→15,360→30,720→60,1440→60,2160→60,2880→60,4320→60）。
- `-TempIntervalMin 0` 默认 + 显式值覆盖；config 60→0 后标准配置下动态生效。
- ORT 打印含实际间隔（动态标注）；普通压测路径无回归。
- config 两处（repo + kit 副本经打包同步）都改 0。

---

### Task 1: lib_common 函数 + test-ort PART6 + Run-MemtestSuite 接线 + config

**Files:**
- Modify: `scripts/lib_common.ps1`（追加 Get-DynamicTempIntervalMin；Start-OrTTempSampling 参数默认 60→0 对齐）
- Modify: `scripts/Run-MemtestSuite.ps1`（`-TempIntervalMin` 默认 60→0；ORT 分支动态计算 + 打印"(动态)"；Help L125 同步）
- Modify: `config/memtest-suite.conf`（TEMP_INTERVAL_MIN=60→0）
- Modify: `tests/test-ort.ps1`（追加 PART6：Get-DynamicTempIntervalMin 12 档断言）

- [ ] **Step 1: 写失败测试**（test-ort.ps1 追加 PART6）——dot-source lib_common 后断言 12 档；结尾 `test-ort: PART6 ALL PASS`。
- [ ] **Step 2: 运行确认失败** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-ort.ps1` → Get-DynamicTempIntervalMin 不存在报错。
- [ ] **Step 3: 实现函数** — lib_common 追加（分档 ≤60→4 否则→12；`[Math]::Max(1,[Math]::Min(60,[Math]::Ceiling($MaxMinutes/$t)))`）。
- [ ] **Step 4: Run-MemtestSuite 接线** — 默认 0；ORT 分支（L557 打印前）`if ($TempIntervalMin -le 0) { $TempIntervalMin = Get-DynamicTempIntervalMin -MaxMinutes $MaxMinutes }`；打印加"(动态)"（当动态生效时）；Help L125 `-TempIntervalMin 温度/状态采样间隔（分钟，0=动态自适应，默认 0；>0 显式固定）`。
- [ ] **Step 5: config 两处** — repo `config/memtest-suite.conf` TEMP_INTERVAL_MIN 60→0（kit 副本 `memtest/config/memtest-suite.conf` 由 Task 2 打包同步，此处只改 repo；若 memtest/ 工作区已落后，Task 2 处理）。
- [ ] **Step 6: 运行确认通过** — `test-ort.ps1` → ALL PASS；`[scriptblock]::Create` 语法 OK。
- [ ] **Step 7: Commit**

```bash
git add scripts/lib_common.ps1 scripts/Run-MemtestSuite.ps1 config/memtest-suite.conf tests/test-ort.ps1
git commit -m "feat: dynamic temp sample interval in ORT mode (0=auto, explicit overrides)"
```

---

### Task 2: 文档 + 回归 + 打包 v18 + 提交

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（流程 6 补 `-TempIntervalMin 0=动态自适应...` 行；修订 L212"默认每小时一次"→"间隔按时长动态自适应"）
- Run: `scripts/build.ps1 -Bump -Zip`

- [ ] **Step 1: docs/20** — 流程 6 参数说明补行 + 修订测温文案；输出速查表无需改。
- [ ] **Step 2: 全量回归** — test-ort / test-lib / test-suite-config / test-task-checklist / test-results-import / test-prime95 / test-presets / test-args → 全部 ALL PASS。
- [ ] **Step 3: 打包** — `build.ps1 -Bump -Zip`（v17→v18）；zip 时间戳当前；hash 校验关键文件（lib_common/Run-MemtestSuite/config/docs20）repo↔kit↔zip 一致（含 config 60→0 同步进 kit）。
- [ ] **Step 4: Commit（范围按先例）** — repo scripts/docs/config + VERSION + kit 同步（scripts/config/docs/CHECKSUM/VERSION/README）；**不含** db/*、docs/superpowers/2026-10-27-prime95-mode-log-fix*。

```bash
git add docs/20-纯命令行压测手册.md VERSION memtest/...  # kit 同步按 git status 精确 add
git commit -m "chore: sync kit v18"
```

---

## 执行说明

- 执行方式：**Subagent-driven development**（用户固定默认）。每 Task 独立 subagent + reviewer；结尾整支复查。
- 基线 HEAD：b78e2f7（v17 打包提交）。
- 实机验证（ORT 冒烟 `-MaxMinutes 10` 打印动态间隔 3 分钟）为交付后人工步骤。
