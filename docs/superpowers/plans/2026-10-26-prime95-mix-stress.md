# Prime95 混插长压自动化（第 16 项）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `Run-Prime95Stress.ps1`，用已内置的 Prime95 替代 TM5 做混插的 Windows 内长压（无人值守 + 到点自动停 + 判读 results.txt + 出报告），同步文档并重新打包 v13。

**Architecture:** Prime95 判定/日志统计/报告三块抽成 lib_common.ps1 纯函数（复用 ORT 的报告与 master_manifest 合并模式），脚本只做校验、并发防护、启动、轮询、收尾；文档同步覆盖 01/02/18/19/20 五份；build.ps1 加新脚本与 prime95.exe 的 hash 覆盖。

**Tech Stack:** PowerShell 5.1、Prime95 v30.19b20（内置 `tools\prime95\`）、`tests\test-*.ps1` Assert 测试约定。

**Spec:** `docs/superpowers/specs/2026-10-26-prime95-mix-stress-design.md`

## Global Constraints

- PowerShell 5.1（`#requires -Version 5.1`）；脚本风格沿用现有（cmdlog `Write-CmdLog`、`Get-AppVersion`、固定列投影写 CSV）。
- Prime95 已内置 `tools\prime95\prime95.exe`（v30.19b20）。**配置写 `prime.txt`（不写 local.txt，v30.19 已废弃）；首版 prime.txt 仅含 `OutputJSON=0`，Torture 模式键不假设格式（实机冒烟后回填）。**
- 存活判定**以进程 `HasExited` 为主**；`results.txt` LastWriteTime 仅作辅助提示（官方默认 300s 才写一次，阈值 10 分钟级）。
- 工作目录隔离：`prime95.exe -t -W<批次目录>`，results.txt 写进批次目录（防旧日志污染 + 防同目录并发官方 bug）。
- **同目录/同名并发防护**：启动前检测已有 prime95 进程 → 报错退出。
- 口径：PASS ⇔ `ActualMinutes ≥ Minutes` 且 `ErrorCount=0` 且 `ExitedEarly=$false`（到点主动 Stop=正常收尾；未到点进程退出=FAIL）。
- `ActualMinutes` 从进程启动起算（含 BootDelay 90s 误差，结论注明）。
- master_manifest 合成行**复用 Export-OrTReport 同一套 14 列投影与合并逻辑**（Slot=ALL，Result=`Prime95 PASS/FAIL`）。
- 打包纪律：`build.ps1 -Bump -Zip`；`$scriptFiles` 加 `Run-Prime95Stress.ps1`；`$keyFiles` 加 `tools\prime95\prime95.exe`；先删旧包再建 + hash 校验。
- 报告落盘机器 = 脚本运行机器（服务器 Windows）的 `results\`，与建档现状一致，不做跨机合并。
- 实机冒烟（前置验收）**本次不跑**（无服务器），文档标注"无人值守=待验证"。

## Review Focus

- 已存在的 prime95 进程（同目录并发官方 bug）→ 启动前检测报错退出。→ Task 2 脚本。
- 旧 `results.txt` 残留污染判定（上次 FATAL ERROR 被当本次）→ `-W` 批次目录隔离。→ Task 2 脚本。
- `-Minutes` 很小/非法（0 或负数）→ 校验报错，不启动。→ Task 2 脚本。
- 进程启动后立即退出（未到时长）→ FAIL"提前退出"，不是 PASS。→ Task 1 纯函数 + Task 2 脚本。
- `-Mode` 非法值 → 校验报错（只允许 Blend/Large）。→ Task 2 脚本。

---

### Task 1: lib_common.ps1 Prime95 纯函数与报告（含单元测试）

**Files:**
- Modify: `scripts/lib_common.ps1`（尾部、`Write-CmdLog` 前追加 Prime95 函数区；紧接 ORT 函数区后）
- Create: `tests/test-prime95.ps1`

**Interfaces:**
- Produces（Task 2 依赖的精确签名）：
  - `Get-Prime95Verdict [-ActualMinutes<double>] [-TargetMinutes<int>] [-ErrorCount<int>] [-ExitedEarly<bool>]` → `[PSCustomObject]@{ Status; Conclusion }`（PASS 结论文案含实际/目标时长；FAIL 附原因，含关键词"时长不足/错误/提前退出"）
  - `Get-Prime95LogStats [-LogFile<string>]` → `[PSCustomObject]@{ ErrorCount; HasErrors; LastWriteTime }`（扫描错误行 `FATAL ERROR`/`Self-test failed`/`FAILED`；文件不存在 → ErrorCount=0/HasErrors=$false）
  - `Export-Prime95Report [-BatchName] [-ToolVersion] [-StartTime<datetime>] [-EndTime<datetime>] [-TargetMinutes<int>] [-ActualMinutes<double>] [-Mode<string>] [-ErrorCount<int>] [-Verdict<object>] [-ReportDir<string>] [-LogPath<string>]` → 写 `<Batch>-prime95-report.csv` + master_manifest 合成行（**复用 ORT 的 14 列投影**：Batch/ToolVersion/Slot/SerialNumber/PartNumber/CapacityGB/SpeedMTs/MemType/MatchState/TestDate/Passes/Errors/EccErrors/Result；Slot=ALL、Passes=0、Errors=ErrorCount、EccErrors=0、Result=`Prime95 PASS/FAIL`）

- [ ] **Step 1: 写失败测试 `tests/test-prime95.ps1`**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
# Get-Prime95Verdict 五类
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false
Assert ($v.Status -eq 'PASS') "PASS 足时长无错"
$v = Get-Prime95Verdict -ActualMinutes 120 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '时长不足') "FAIL 时长不足"
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 2 -ExitedEarly $false
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '错误') "FAIL 有错误"
$v = Get-Prime95Verdict -ActualMinutes 90 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $true
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '提前退出') "FAIL 提前退出"
# Get-Prime95LogStats
$tmp = Join-Path $env:TEMP "p95-stats-sample.txt"
[System.IO.File]::WriteAllText($tmp, "line1`n[FATAL ERROR] x`nTest 1, run 2, FAILED`n", (New-Object System.Text.UTF8Encoding($false)))
$s = Get-Prime95LogStats -LogFile $tmp
Assert ($s.ErrorCount -eq 2 -and $s.HasErrors) "stats 错误行计数"
[System.IO.File]::WriteAllText($tmp, "ok line`nok2`n", (New-Object System.Text.UTF8Encoding($false)))
$s = Get-Prime95LogStats -LogFile $tmp
Assert ($s.ErrorCount -eq 0 -and -not $s.HasErrors) "stats 无错误"
$s = Get-Prime95LogStats -LogFile (Join-Path $env:TEMP "p95-missing.txt")
Assert ($s.ErrorCount -eq 0 -and -not $s.HasErrors) "stats 文件缺失"
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
# Export-Prime95Report
$tmpDir = Join-Path $env:TEMP ("p95-report-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$verdict = [PSCustomObject]@{ Status = 'PASS'; Conclusion = 'Prime95 长压通过' }
Export-Prime95Report -BatchName 'mix' -ToolVersion 'v13' -StartTime (Get-Date).AddMinutes(-185) -EndTime (Get-Date) `
  -TargetMinutes 180 -ActualMinutes 185 -Mode 'Blend' -ErrorCount 0 -Verdict $verdict -ReportDir $tmpDir -LogPath $tmpDir
$r = Import-Csv (Join-Path $tmpDir 'mix-prime95-report.csv')
Assert ($r.Mode -eq 'Blend' -and $r.Status -eq 'PASS' -and $r.TargetMinutes -eq '180') "report 内容"
$m = Import-Csv (Join-Path $tmpDir 'master_manifest.csv')
Assert ($m.Count -eq 1 -and $m[0].Slot -eq 'ALL' -and $m[0].Result -eq 'Prime95 PASS') "master 合成行"
Remove-Item -LiteralPath $tmpDir -Recurse -Force
Write-Host "test-prime95: ALL PASS"
```

- [ ] **Step 2: 运行确认失败** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-prime95.ps1` → 报错函数不存在。

- [ ] **Step 3: 实现三个函数（lib_common.ps1 尾部追加）**

`Get-Prime95Verdict`：判定顺序 时长不足 → 错误 → 提前退出；PASS 文案 `"Prime95 长压通过：{Actual} 分钟 ≥ 目标 {Target} 分钟，0 错误"`（含 BootDelay 误差说明可放 Conclusion 尾部或省略）。
`Get-Prime95LogStats`：`Select-String`/逐行匹配错误正则 `FATAL ERROR|Self-test failed|FAILED`；`LastWriteTime` 取 `(Get-Item -ErrorAction SilentlyContinue).LastWriteTime`（缺失→null）。
`Export-Prime95Report`：16 列（Batch/ToolVersion/Mode/StartTime/EndTime/TargetMinutes/ActualMinutes/ErrorCount/Status/Conclusion）写 `<Batch>-prime95-report.csv`；master_manifest 用 `Export-OrTReport` 同款合并（List + Import-Csv + 14 列 Select-Object 投影 + Export-Csv），Result=`Prime95 $($Verdict.Status)`。

- [ ] **Step 4: 运行确认通过** — 同上命令 → `test-prime95: ALL PASS`。

- [ ] **Step 5: 回归** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-ort.ps1` → ALL PASS（未动 ORT 函数）。

- [ ] **Step 6: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-prime95.ps1
git commit -m "feat: add Prime95 verdict/log-stats/report helpers to lib_common"
```

---

### Task 2: `scripts/Run-Prime95Stress.ps1` 主脚本

**Files:**
- Create: `scripts/Run-Prime95Stress.ps1`

**Interfaces:**
- Consumes: Task 1 的 Get-Prime95Verdict / Get-Prime95LogStats / Export-Prime95Report。
- Produces: 命令行参数 `-BatchName/-Prime95Exe/-Minutes/-Mode/-LogPath/-Help`；产出 `results\reports\<批次>-prime95-report.csv` + `results\master_manifest.csv` 合成行 + `results\work\<批次>\` 工作目录（含 results.txt）。

- [ ] **Step 1: 写脚本骨架（含全部校验与主流程）**

```powershell
#requires -Version 5.1
param(
    [string]$BatchName = "",
    [string]$Prime95Exe = "",
    [int]$Minutes = 180,
    [ValidateSet("Blend", "Large")]
    [string]$Mode = "Blend",
    [string]$LogPath = "",
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
. $PSScriptRoot\lib_common.ps1
if ($Help) { # 打印帮助（含用法示例与实机冒烟提示）; exit 0 }
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Run-Prime95Stress' -CmdArgs $MyInvocation.Line -State Start
# 默认值
if ($BatchName -eq "") { $BatchName = "p95_" + (Get-Date -Format "yyyyMMdd_HHmmss") }
if ($Prime95Exe -eq "") { $Prime95Exe = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\prime95\prime95.exe" }
if ($LogPath -eq "") { $LogPath = Join-Path (Split-Path -Parent $PSScriptRoot) "results" }
$reportDir = Join-Path $LogPath "reports"
$workDir   = Join-Path $LogPath "work\$BatchName"
foreach ($d in @($LogPath, $reportDir, $workDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
# 校验
if ($Minutes -le 0) { Write-CmdLog ... -Result 'FAIL: Minutes 非法'; exit 1 }
if (-not (Test-Path $Prime95Exe)) { Write-CmdLog ... -Result 'FAIL: Prime95 不存在'; exit 1 }
# 并发防护：检测已有 prime95 进程（同名进程，排除自身 PID）
$existing = @(Get-Process -Name 'prime95' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
if ($existing.Count -gt 0) { Write-CmdLog ... -Result 'FAIL: prime95 已在运行'; exit 1 }
# 预置 prime.txt（OutputJSON=0；模式键留待实机冒烟回填，首版不写）
[System.IO.File]::WriteAllText((Join-Path $workDir 'prime.txt'), "OutputJSON=0`n", (New-Object System.Text.UTF8Encoding($false)))
# 启动
$p = Start-Process -FilePath $Prime95Exe -ArgumentList @("-t", "-W$workDir") -PassThru -WindowStyle Minimized
$startTime = Get-Date
# 轮询循环（每 30s）：进程 HasExited 为主 + results.txt 错误扫描 + 时长判定
$errors = 0; $exitedEarly = $false
do {
    Start-Sleep -Seconds 30
    if ($p.HasExited) { if ((Get-Date) - $startTime -lt [TimeSpan]::FromMinutes($Minutes)) { $exitedEarly = $true; break } }
    $stats = Get-Prime95LogStats -LogFile (Join-Path $workDir 'results.txt')
    if ($stats.HasErrors) { $errors = $stats.ErrorCount; break }   # 提前停
    # 辅助：results.txt 长时间未写入仅提示（官方 300s 写入间隔，不判死）
    if ($stats.LastWriteTime -and ((Get-Date) - $stats.LastWriteTime).TotalMinutes -gt 10) {
        Write-Host "提示：results.txt 已 10+ 分钟未更新（Prime95 写入间隔约 300s，持续观察）"
    }
} while ((Get-Date) - $startTime -lt [TimeSpan]::FromMinutes($Minutes))
$endTime = Get-Date
if (-not $exitedEarly -and -not $stats.HasErrors) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
$actualMin = [math]::Round((($endTime - $startTime).TotalMinutes), 2)
$finalStats = if ($exitedEarly) { [PSCustomObject]@{ ErrorCount = 0 } } else { Get-Prime95LogStats -LogFile (Join-Path $workDir 'results.txt') }
$verdict = Get-Prime95Verdict -ActualMinutes $actualMin -TargetMinutes $Minutes -ErrorCount $finalStats.ErrorCount -ExitedEarly $exitedEarly
Write-Host ("Prime95 结果: 时长=$actualMin 错误=$($finalStats.ErrorCount) 状态=$($verdict.Status) 结论=$($verdict.Conclusion)")
Export-Prime95Report -BatchName $BatchName -ToolVersion (Get-AppVersion) -StartTime $startTime -EndTime $endTime `
    -TargetMinutes $Minutes -ActualMinutes $actualMin -Mode $Mode -ErrorCount $finalStats.ErrorCount `
    -Verdict $verdict -ReportDir $reportDir -LogPath $LogPath
Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result ("Prime95 " + $verdict.Status) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
exit 0
```

（失败路径如校验/并发防护参照现有脚本补 `Write-CmdLog ... -State End -Result 'FAIL: ...' -ExitCode 1` 再 exit 1；cmdlog 密码打码逻辑对非密码参数无影响。）

- [ ] **Step 2: 语法验证** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-Prime95Stress.ps1 -Help` → 打印帮助、exit 0。
- [ ] **Step 3: 校验路径验证（不启动真实 Prime95）** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-Prime95Stress.ps1 -Minutes 0` → 报错"Minutes 非法"、exit 1；`-Prime95Exe C:\nonexistent.exe` → 报错"Prime95 不存在"、exit 1。
- [ ] **Step 4: Commit**

```bash
git add scripts/Run-Prime95Stress.ps1
git commit -m "feat: add Run-Prime95Stress unattended torture wrapper"
```

---

### Task 3: build.ps1 纳入新脚本 + prime95.exe hash

**Files:**
- Modify: `scripts/build.ps1`（`$scriptFiles` 列表 L73-84、`$keyFiles` 追加 L207 附近）

**Interfaces:**
- Consumes: Task 2 的 `scripts/Run-Prime95Stress.ps1`。
- Produces: 包内含新脚本；CHECKSUM.txt 覆盖 `tools\prime95\prime95.exe`。

- [ ] **Step 1: `$scriptFiles` 加 `'Run-Prime95Stress.ps1'`**（在 `'Smoke-MemtestIso.ps1'` 之后）
- [ ] **Step 2: `$keyFiles` 追加 `(Join-Path $KitDir 'tools\prime95\prime95.exe')`**（在 ipmitool 行之后）
- [ ] **Step 3: 构建校验** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1`（不带 -Zip 先构建）→ 成功；`Select-String memtest\CHECKSUM.txt -Pattern 'prime95'` → 命中。
- [ ] **Step 4: Commit**

```bash
git add scripts/build.ps1
git commit -m "build: include Run-Prime95Stress and prime95.exe in kit checksum"
```

---

### Task 4: 文档同步（01/02/18/19/20）

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（流程 3 改写、流程 6 Prime95 部分、输出速查表）
- Modify: `docs/19-测试项执行清单.md`（第 16 项 + 第 5 项两处）
- Modify: `docs/18-测试方案总览.md`（第 16 项、工具映射、FAQ 等处 TM5→Prime95）
- Modify: `docs/01-验收测试方案.md`（TM5/OCCT 表述降级"可选人工"）
- Modify: `docs/02-批量压力测试方案.md`（TM5/OCCT 表述同步）

- [ ] **Step 1: docs/20 流程 3（L144-157）** — 改为：Memtest 部分不变 + Windows 内长压 Prime95 自动化命令：

```powershell
cd C:\memtest
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-Prime95Stress.ps1 -BatchName srv01-a1-mix -Minutes 180 -Mode Blend
```
判读 `reports\srv01-a1-mix-prime95-report.csv` 的 `Status=PASS`；TM5 降级附注（无 headless、仅人工）；日志位置更新。输出速查表流程 3 行加 `reports\<批次>-prime95-report.csv`。
- [ ] **Step 2: docs/20 流程 6 可选 Prime95（L205-208）** — 手工 `prime95.exe -t` 改接脚本：`Run-Prime95Stress.ps1 -BatchName srv01-a1-ort-p95 -Minutes 4320 -Mode Blend`。
- [ ] **Step 3: docs/19 第 16 项（L89/91/163）+ 第 5 项（L118-121）** — 怎么做/输出文件两行同步为 Prime95 脚本；TM5 附注。
- [ ] **Step 4: docs/18（L62/169/204/212/233/247/261 等）** — 第 16 项工具列、软件清单、FAQ 中"TM5/OCCT 需自备"改为"Prime95 已内置 + 脚本；TM5/OCCT 可选人工"。
- [ ] **Step 5: docs/01（L26/28/44/46/55/92/98/132/134/144/146）、docs/02（L21/76/93/148/163/174/182/209）** — TM5/OCCT 表述降级"可选人工"或并入 Prime95 脚本说明；保留 stress-ng 合理引用。
- [ ] **Step 6: 验证** — `powershell -NoProfile -ExecutionPolicy Bypass -Command "Select-String -Path docs\01*.md,docs\02*.md,docs\18*.md,docs\19*.md,docs\20*.md -Pattern 'TM5' | Select-Object Path,LineNumber,Line"` → 剩余命中均为"可选人工/降级"表述，无"TM5 为混插必测/需自备主导"旧表述。
- [ ] **Step 7: Commit**

```bash
git add docs/20-纯命令行压测手册.md docs/19-测试项执行清单.md docs/18-测试方案总览.md docs/01-验收测试方案.md docs/02-批量压力测试方案.md
git commit -m "docs: switch mix-stress Windows load to Prime95 script, TM5 optional"
```

---

### Task 5: 全量回归 + 打包（build.ps1 -Bump -Zip）

**Files:**
- Run: `scripts/build.ps1 -Bump -Zip`

- [ ] **Step 1: 全量测试回归** — 依次跑 `tests\test-prime95.ps1`、`tests\test-ort.ps1`、`tests\test-suite-config.ps1`、`tests\test-lib.ps1`、`tests\test-presets.ps1`、`tests\test-args.ps1` → 全部 ALL PASS。
- [ ] **Step 2: 打包** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Bump -Zip` → 成功（v12→v13），`memtest.zip` 时间戳当前。
- [ ] **Step 3: 包完整性** — `Expand-Archive` 临时解压，比对 `scripts\Run-Prime95Stress.ps1`、`scripts\lib_common.ps1`、`tools\prime95\prime95.exe`、`docs\20-纯命令行压测手册.md` 的 SHA256 与仓库 kit 一致；包内 VERSION=v13；清理临时目录。
- [ ] **Step 4: Commit（提交范围按 ORT 计划先例裁定）** — 只 add：`VERSION`、`memtest/scripts/Run-Prime95Stress.ps1`、`memtest/scripts/lib_common.ps1`、`memtest/scripts/build.ps1`、`memtest/docs/20/19/18/01/02`、`memtest/tools/prime95/`、`memtest/CHECKSUM.txt`、`memtest/VERSION`、`memtest/README.md`（build 注入产物若变化）；**不含** repo `db/*` 与 `memtest/db/*`（用户未提交改动）。`git commit -m "chore: bump version and repack with Prime95 mix-stress script"`。

---

## 执行说明

- 执行方式：**Subagent-driven development**（用户固定默认）。每个 Task 派独立 subagent 实现 + 独立 reviewer 复查后进入下一个；结尾整支复查。
- 实机冒烟（`Run-Prime95Stress.ps1 -Minutes 5`）为**前置验收但本次不跑**（用户暂无服务器），脚本按容错设计交付，文档标注"无人值守=待验证"；下次有服务器后跑冒烟、回填 prime.txt 模式键。
