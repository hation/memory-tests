# Memtest86+ 72h ORT 老化模式 + 可选 Prime95 整机满载 —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 Run-MemtestSuite.ps1 增加 72h ORT 模式（时长/错误/ECC/中断/温度五项留痕 + 口径 B 结论），新增「72h ORT 无限轮」ISO 预设并重制 memtest-sol.iso，预置可选 Prime95，同步文档并重新打包。

**Architecture:** ORT 判定逻辑抽成 lib_common.ps1 的纯函数（Get-OrTVerdict / Get-OrTLogMetrics / 温度采样 Job / Export-OrTReport）以便单元验收；Run-MemtestSuite.ps1 只负责参数、校验与分支接线；ISO 预设经 config\memtest-presets.conf 新增后由 New-MemtestSolIso.ps1 重制。

**Tech Stack:** PowerShell 5.1（PS5）、Memtest86+ v9 MTLOG、ipmitool SOL、GRUB ISO 构建（grub-mkimage + iso9660_build.py）、Prime95（官方 Windows 版）。

**Spec:** `docs/superpowers/specs/2026-10-26-memtest-72h-ort-mode-design.md`

## Global Constraints

- PowerShell 5.1（`#requires -Version 5.1`）；脚本风格沿用现有文件（cmdlog 指令记录、`Get-AppVersion` 读 VERSION、固定列投影写 CSV）。
- 参数优先级：命令行显式参数 > `config\memtest-suite.conf` > 脚本内置默认（Merge-SuiteConfig 机制）。
- MTLOG 事件格式 `MTLOG ts=<float> ev=<name> ...`；`pass_end.errors` 为累计语义（最后一条 pass_end 即全程总数）；`PassesCompleted = 最后一条 pass_end 的 pass+1`。
- 无限轮模式 Memtest86+ 不主动发 `ev=done`；ORT 终止靠"到达目标时长掐断 SOL"。
- ORT 结论口径 B：PASS = ActualMinutes≥MaxMinutes 且 Errors=0 且 EccErrors=0 且 日志无中断 且（TempSamples≥1 且 MaxTempC≤TempLimitC；TempLimitC≤0 时跳过温度判据）。
- 默认值（config 可覆盖）：MaxMinutes=0（不启用）、TempLimitC=85、TempIntervalMin=60、OrtBufferMin=10、OrtMaxGapMin=30。
- ORT 与 `-RestartLoop>0` 互斥（报错退出）；`-MaxMinutes>0` 与显式 `-MaxPasses` 并存时 MaxMinutes 优先并警告；USB/EFI 引导 + ORT → 报错退出。
- 打包纪律：所有代码/配置/文档改动后必须 `build.ps1 -Bump -Zip`（先删旧包再建，校验 hash）。
- 测试约定：`tests\test-*.ps1` 用 `Assert($cond,$msg)` 断言 + 结尾 `Write-Host "ALL PASS"`；运行命令 `powershell -NoProfile -ExecutionPolicy Bypass -File tests\<name>.ps1`。

## Review Focus

- `-MaxMinutes` 与 `-RestartLoop` 同给 → 必须报错退出且**不得触发 BMC 密码交互**（校验须在 Read-BmcPass 之前）。→ Task 3 校验测试。
- `-MaxMinutes` 配 USB/EFI → 报错退出，不静默降级。→ Task 3 校验测试。
- 72h 内 SOL 静默断线（日志停止增长）→ 判中断 FAIL，不许"假装跑完"。→ Task 1 Get-OrTVerdict（Stalled）+ Task 3 捕获扩展。
- 温度采样全失败（BMC 并发受限等）→ 结论 FAIL（TempSamples=0，注明"温度数据缺失"），不许漏判。→ Task 1 Get-OrTVerdict 用例。
- 解析回归：现有 sample-pass/sample-fail 解析不受 ORT 改动影响。→ Task 1 回归命令。

---

### Task 1: lib_common.ps1 ORT 纯函数与报告（含单元测试）

**Files:**
- Modify: `scripts/lib_common.ps1`（在文件尾部、`Write-CmdLog` 之前追加 ORT 函数区）
- Create: `tests/test-ort.ps1`

**Interfaces:**
- Produces（Task 3 依赖的精确签名）：
  - `Get-OrTVerdict [-ActualMinutes<double>] [-TargetMinutes<int>] [-Errors<int64>] [-EccErrors<int64>] [-StartEventCount<int>] [-MaxEventGapMin<double>] [-Stalled<bool>] [-MaxTempC<double>] [-TempSamples<int>] [-TempLimitC<double>]` → `[PSCustomObject]@{ Status; Conclusion }`
  - `Get-OrTLogMetrics [-Summary<object>]` → `[PSCustomObject]@{ StartEventCount; MaxEventGapMin; LogSpanMinutes }`（基于 parser Events 数组：ev='start' 计数；相邻事件 ts 最大间隔分钟；末条 ts − 首条 ts 分钟）
  - `Start-OrTTempSampling [-BmcHost] [-BmcUser] [-BmcPass] [-IpmiTool] [-IntervalMin<int>] [-CsvFile<string>] [-LibPath<string>] [-MaxIterations<int>]` → `[System.Management.Automation.Job]`（Start-Job 后台循环：dot-source LibPath 后每 IntervalMin 分钟调 Get-IPMITempSensors，长表 `Timestamp,Sensor,TempC` 追加写 CsvFile；MaxIterations=0 无限，>0 为测试钩子）
  - `Stop-OrTTempSampling [-Job<Job>] [-CsvFile<string>] [-WaitSec<int=30>]` → `[PSCustomObject]@{ MaxTempC; TempSamples }`（停 Job、收尾、读 CsvFile 统计最高温与采样行数）
  - `Export-OrTReport [-BatchName] [-ToolVersion] [-CaptureStart] [-CaptureEnd] [-TargetMinutes<int>] [-ActualMinutes<double>] [-Summary<object>] [-Metrics<object>] [-Verdict<object>] [-MaxTempC<double>] [-TempSamples<int>] [-Stalled<bool=$false>] [-ReportDir<string>] [-LogPath<string>]` → 写 `<Batch>-ort-report.csv` + master_manifest 追加一行（Slot=ALL，复用现有 14 列）

- [ ] **Step 1: 写失败测试 `tests/test-ort.ps1`（Get-OrTVerdict 五类场景）**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
# PASS：足时长(4325≥4320)+全零+单次start+无gap+未停滞+温度正常
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'PASS') "PASS 场景"
# 时长不足
$v = Get-OrTVerdict -ActualMinutes 3600 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '时长不足') "FAIL 时长不足"
# 有错误
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 2 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match 'Errors') "FAIL Errors"
# ECC 错误
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 1 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match 'ECC') "FAIL ECC"
# 多次 start（重启中断）
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 2 -MaxEventGapMin 5 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '中断') "FAIL 多次start"
# ts 大间隔
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 120 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '中断') "FAIL ts间隔"
# 捕获停滞（SOL 断线）
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $true -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '中断') "FAIL stalled"
# 超温
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC 88 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '温度') "FAIL 超温"
# 温度数据缺失
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC -1 -TempSamples 0 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '温度') "FAIL 温度缺失"
# TempLimitC<=0 时跳过温度判据（TempSamples=0 也 PASS）
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 5 -Stalled $false -MaxTempC -1 -TempSamples 0 -TempLimitC 0
Assert ($v.Status -eq 'PASS') "PASS 温度判据关闭"
Write-Host "test-ort: PART1 ALL PASS"
```

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-ort.ps1`
Expected: 报错 `Get-OrTVerdict` 不是函数（找不到）。

- [ ] **Step 3: 在 `scripts/lib_common.ps1` 实现 `Get-OrTVerdict`**

签名见 Interfaces。判定顺序：先时长不足 → 再 Errors/ECC → 再中断（StartEventCount>1、MaxEventGapMin>OrtMaxGapMin(入参为阈值比较用传入值，函数内与 -MaxEventGapMin 比较)、Stalled）→ 再温度（TempLimitC≤0 跳过；TempSamples=0 → FAIL"温度数据缺失"；MaxTempC>TempLimitC → FAIL"超温"）。Conclusion 为中文结论文本（FAIL 时附原因）。

- [ ] **Step 4: 运行确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-ort.ps1`
Expected: 输出 `test-ort: PART1 ALL PASS`。

- [ ] **Step 5: 扩展 `tests/test-ort.ps1`：Get-OrTLogMetrics + Export-OrTReport**

```powershell
# PART2: Get-OrTLogMetrics（用 Invoke-MtlogParser 解析合成日志）
$log = @'
MTLOG ts=0.0 ev=start version=9.0
MTLOG ts=60.0 ev=pass_end pass=0 errors=0 status=pass
MTLOG ts=61.0 ev=start version=9.0
MTLOG ts=4320.0 ev=pass_end pass=1 errors=0 status=pass
'@
$tmp = Join-Path $env:TEMP "ort-metrics-sample.mtlog.txt"
[System.IO.File]::WriteAllText($tmp, $log, (New-Object System.Text.UTF8Encoding($false)))
$sum = Invoke-MtlogParser -LogFile $tmp
$m = Get-OrTLogMetrics -Summary $sum
Assert ($m.StartEventCount -eq 2) "metrics start count"
Assert ($m.MaxEventGapMin -gt 60 -and $m.MaxEventGapMin -lt 61) "metrics max gap"
Assert ($m.LogSpanMinutes -eq 4320) "metrics log span"
Remove-Item -LiteralPath $tmp -Force

# PART3: Export-OrTReport（假数据写临时目录，校验 CSV 与 master 合成行）
$tmpDir = Join-Path $env:TEMP ("ort-report-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$fakeSummary = [PSCustomObject]@{ PassesCompleted = 36; Errors = 0; EccErrors = 0; FinalStatus = 'PASS' }
$fakeMetrics = [PSCustomObject]@{ StartEventCount = 1; MaxEventGapMin = 5; LogSpanMinutes = 4320 }
$fakeVerdict = [PSCustomObject]@{ Status = 'PASS'; Conclusion = '72h 老化通过' }
Export-OrTReport -BatchName 'ort-test' -ToolVersion 'v9' -CaptureStart (Get-Date).AddHours(-72) -CaptureEnd (Get-Date) `
  -TargetMinutes 4320 -ActualMinutes 4320 -Summary $fakeSummary -Metrics $fakeMetrics -Verdict $fakeVerdict `
  -MaxTempC 72 -TempSamples 72 -ReportDir $tmpDir -LogPath $tmpDir
$ort = Import-Csv (Join-Path $tmpDir 'ort-test-ort-report.csv')
Assert ($ort.Mode -eq 'ORT' -and $ort.Status -eq 'PASS' -and $ort.TargetMinutes -eq '4320' -and $ort.TotalPasses -eq '36') "ort-report 内容"
$master = Import-Csv (Join-Path $tmpDir 'master_manifest.csv')
Assert ($master.Count -eq 1 -and $master[0].Slot -eq 'ALL' -and $master[0].Result -eq 'ORT PASS') "master 合成行"
Remove-Item -LiteralPath $tmpDir -Recurse -Force
Write-Host "test-ort: ALL PASS"
```

- [ ] **Step 6: 实现 `Get-OrTLogMetrics` 与 `Export-OrTReport`（lib_common.ps1）**

`Get-OrTLogMetrics`：遍历 `$Summary.Events`（对象含 `ts`(string)/`ev`），ts 解析为 double；`StartEventCount=@(ev -eq 'start').Count`；相邻 ts 差值秒数/60 取最大；`LogSpanMinutes=(末ts-首ts)/60`（仅 1 条事件时=0）。
`Export-OrTReport`：列 `Batch, ToolVersion, Mode, StartTime, EndTime, TargetMinutes, ActualMinutes, TotalPasses, Errors, EccErrors, MaxTempC, TempSamples, MaxEventGapMin, Interrupted, Status, Conclusion`（Mode='ORT'，Interrupted=metrics.StartEventCount>1 或 MaxEventGapMin>阈值或停表——此处用 `$Metrics.MaxEventGapMin -gt $Global:...` 简化为 `StartEventCount -gt 1` 与 gap 用传入；实际取值：`Interrupted = ($Metrics.StartEventCount -gt 1) -or $StalledParam`——签名加 `-Stalled<bool>`）。写 `<Batch>-ort-report.csv`；master_manifest 追加一行 Slot=ALL、SerialNumber/PartNumber 空、CapacityGB=0、SpeedMTs=0、MemType 空、MatchState 空、TestDate=EndTime、Passes=TotalPasses、Errors、EccErrors、Result=`ORT PASS/FAIL`，用现有 14 列投影合并写回。

- [ ] **Step 7: 运行确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-ort.ps1`
Expected: `test-ort: ALL PASS`。

- [ ] **Step 8: 回归现有解析测试**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1`
Expected: `ALL PASS`（解析器未动，确认无回归）。

- [ ] **Step 9: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-ort.ps1
git commit -m "feat: add ORT verdict/log-metrics/report helpers to lib_common"
```

---

### Task 2: config 新键 + Merge-SuiteConfig 映射

**Files:**
- Modify: `config/memtest-suite.conf`
- Modify: `scripts/lib_common.ps1`（`Merge-SuiteConfig` 的 `$map` 与 int 分支）
- Modify: `tests/test-suite-config.ps1`

**Interfaces:**
- Produces: config 键 `MAX_MINUTES/TEMP_LIMIT_C/TEMP_INTERVAL_MIN/ORT_BUFFER_MIN/ORT_MAX_GAP_MIN` → 参数 `MaxMinutes/TempLimitC/TempIntervalMin/OrtBufferMin/OrtMaxGapMin`（int 解析，非法忽略，Bound 优先）。

- [ ] **Step 1: 写失败测试（扩展 test-suite-config.ps1 增加 5 键映射用例）**

```powershell
# 9 新增 5 键映射 + int 解析 + Bound 优先
$cfg9 = @{ MAX_MINUTES='4320'; TEMP_LIMIT_C='85'; TEMP_INTERVAL_MIN='60'; ORT_BUFFER_MIN='10'; ORT_MAX_GAP_MIN='30' }
$r9 = Merge-SuiteConfig -Cfg $cfg9 -Bound @{}
Assert ($r9.MaxMinutes -eq 4320 -and $r9.TempLimitC -eq 85 -and $r9.TempIntervalMin -eq 60 -and $r9.OrtBufferMin -eq 10 -and $r9.OrtMaxGapMin -eq 30) "9 新增5键映射"
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_MINUTES='abc'} -Bound @{}).ContainsKey('MaxMinutes')) "9b 非法int忽略"
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_MINUTES='4320'} -Bound @{MaxMinutes=1}).ContainsKey('MaxMinutes')) "9c Bound优先"
# 10 完整映射 18 键
$cfg10 = @{ BOOT_METHOD='SOL'; BMC_HOST='h'; BMC_USER='u'; IPMI_TOOL='i'; MAX_PASSES='4'; TEST_LIST='0,1';
            SERIAL_PARAM='ttyS0,115200'; MONITOR_ECC='1'; MONITOR_TEMP='1'; RESTART_LOOP='5'; CONFIRM_SWITCH='1';
            EXPECTED_CSV='e'; LOG_PATH='l'; MAX_MINUTES='4320'; TEMP_LIMIT_C='85'; TEMP_INTERVAL_MIN='60';
            ORT_BUFFER_MIN='10'; ORT_MAX_GAP_MIN='30' }
Assert ((Merge-SuiteConfig -Cfg $cfg10 -Bound @{}).Count -eq 18) "10 映射 18 键"
```

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-suite-config.ps1`
Expected: 用例 9 断言失败（映射缺失）。

- [ ] **Step 3: 实现（lib_common.ps1 `Merge-SuiteConfig` + config 文件）**

`$map` 增加 5 行；int 分支 `{ $_ -in 'MaxPasses','RestartLoop','MaxMinutes','TempLimitC','TempIntervalMin','OrtBufferMin','OrtMaxGapMin' }` 走 TryParse。config\memtest-suite.conf 在 `# ---- 监控 / 附加 ----` 区追加 5 键注释与默认值（`MAX_MINUTES=0` 等，见设计 §4.1）。

- [ ] **Step 4: 运行确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-suite-config.ps1`
Expected: `ALL PASS`（含用例 9/10）。

- [ ] **Step 5: Commit**

```bash
git add config/memtest-suite.conf scripts/lib_common.ps1 tests/test-suite-config.ps1
git commit -m "feat: add ORT config keys to suite config merge"
```

---

### Task 3: Run-MemtestSuite.ps1 ORT 参数、校验与分支接线

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`（param 块 L27-70、Help L80-120、配置合并后校验、Invoke-SolCapture L161-196、Invoke-SerialCapture L199-235、主流程 L439-560）

**Interfaces:**
- Consumes: Task 1 的 Get-OrTVerdict / Get-OrTLogMetrics / Start-OrTTempSampling / Stop-OrTTempSampling / Export-OrTReport；Task 2 的参数合并。
- Produces: 新命令行参数 `-MaxMinutes -TempLimitC -TempIntervalMin -OrtBufferMin -OrtMaxGapMin`；ORT 分支产出 `reports\<批次>-ort-report.csv`、`reports\<批次>-temp.csv`、master_manifest 合成行。

- [ ] **Step 1: 加参数 + Help 文案**

param 块（`-RestartLoop` 之后、`-LogPath` 之前）插入 5 个 int 参数（默认 0/85/60/10/30，见设计 §4.1）；Help 文本 `监控/附加` 区加 5 行说明与 ORT 用法示例（`-BatchName srv01-a1-ort -BootMethod SOL -BmcHost 10.0.0.10 -BmcUser root -MaxMinutes 4320 -ConfirmSwitch`）。

- [ ] **Step 2: 加 ORT 校验（配置合并之后、Write-CmdLog 之前，L125 后）**

```powershell
# ORT 模式校验（必须在 BMC 密码交互之前，避免无效组合卡在密码输入）
if ($MaxMinutes -gt 0) {
    if ($RestartLoop -gt 0) {
        Write-Error "ORT 模式与 -RestartLoop 互斥，请分开执行。"
        exit 1
    }
    if ($BootMethod -notin @('SOL', 'Serial')) {
        Write-Error "ORT 模式仅支持 SOL/Serial 引导方式（USB/EFI 不支持时长终止），当前 $BootMethod。"
        exit 1
    }
    if ($PSBoundParameters.ContainsKey('MaxPasses')) {
        Write-Warning "同时指定 -MaxPasses 与 -MaxMinutes，按 ORT 时长模式执行（MaxPasses 忽略）。"
    }
}
```

- [ ] **Step 3: 校验测试（无 BMC 交互即报错退出）**

Run:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -MaxMinutes 4320 -RestartLoop 5`
Expected: 报错"互斥"、退出码 1、**无密码提示**。
Run:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -MaxMinutes 4320 -BootMethod USB`
Expected: 报错"仅支持 SOL/Serial"、退出码 1、无密码提示。
Run:
`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -Help`
Expected: 正常打印帮助、退出码 0（语法无误）。

- [ ] **Step 4: 扩展 Invoke-SolCapture（+MaxStallMin，返回对象）**

签名增加 `[int]$MaxStallMin = 0`；返回改为 `[PSCustomObject]@{ Done=[bool]; Stalled=[bool]; CaptureStart=[datetime]; CaptureEnd=[datetime] }`；循环内除现有 ev=done 检测外：记录 `$lastWrite=(Get-Item $OutFile -ErrorAction SilentlyContinue).LastWriteTime`，当 `$MaxStallMin -gt 0` 且 `(Get-Date)-$lastWrite` 超过 `$MaxStallMin` 分钟 → `Stalled=$true` 并 break（写警告"SOL 输出停滞 X 分钟，疑似会话中断"）。Invoke-SerialCapture 同步扩展（返回同结构；停滞检测基于 `$sw` 写入时间）。更新两处调用点（L461/L465）解构 `.Done/.Stalled/.CaptureStart/.CaptureEnd`。

- [ ] **Step 5: ORT 主分支接线（主流程 L439 之前插入 ORT 分支）**

在 `Write-Event -Type stage ... orchestrator start`（L440）之后、`Get-MemoryInventory`（L443）之前：

```powershell
$ortMode = ($MaxMinutes -gt 0)
if ($ortMode) {
    Write-Host "===== ORT 模式：目标 $MaxMinutes 分钟，温度上限 $TempLimitC°C，采样间隔 $TempIntervalMin 分钟 ====="
    $captureStart = Get-Date
    $tempCsv = Join-Path $reportDir "$BatchName-temp.csv"
    $tempJob = Start-OrTTempSampling -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool `
        -IntervalMin $TempIntervalMin -CsvFile $tempCsv -LibPath (Join-Path $PSScriptRoot 'lib_common.ps1')
    try {
        $rawLog = Join-Path $rawDir "$BatchName.mtlog.txt"
        if ($BootMethod -eq 'SOL') {
            $cap = Invoke-SolCapture -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool `
                -OutFile $rawLog -TimeoutMinutes ($MaxMinutes + $OrtBufferMin) -MaxStallMin $OrtMaxGapMin
        } else {
            $cap = Invoke-SerialCapture -SerialPortName $SerialPort -BaudRate $BaudRate `
                -OutFile $rawLog -TimeoutMinutes ($MaxMinutes + $OrtBufferMin) -MaxStallMin $OrtMaxGapMin
        }
        $tempInfo = Stop-OrTTempSampling -Job $tempJob -CsvFile $tempCsv
    } catch {
        Stop-OrTTempSampling -Job $tempJob -CsvFile $tempCsv | Out-Null
        throw
    }
    $captureEnd = Get-Date
    $summary = if (Test-Path $rawLog) { Invoke-MtlogParser -LogFile $rawLog } else { $null }
    if ($null -eq $summary) { Write-Error "ORT：未获取到 Memtest86+ 日志。"; exit 1 }
    $metrics = Get-OrTLogMetrics -Summary $summary
    $captureMin = [math]::Round((($captureEnd - $captureStart).TotalMinutes), 2)
    $actualMin = [math]::Min($captureMin, $metrics.LogSpanMinutes)
    $verdict = Get-OrTVerdict -ActualMinutes $actualMin -TargetMinutes $MaxMinutes -Errors $summary.Errors `
        -EccErrors $summary.EccErrors -StartEventCount $metrics.StartEventCount -MaxEventGapMin $metrics.MaxEventGapMin `
        -Stalled $cap.Stalled -MaxTempC $tempInfo.MaxTempC -TempSamples $tempInfo.TempSamples -TempLimitC $TempLimitC
    Write-Host ("ORT 结果: 时长=$actualMin 轮次=$($summary.PassesCompleted) 错误=$($summary.Errors) ECC=$($summary.EccErrors) 状态=$($verdict.Status) 结论=$($verdict.Conclusion)")
    Export-OrTReport -BatchName $BatchName -ToolVersion (Get-AppVersion) -CaptureStart $captureStart -CaptureEnd $captureEnd `
        -TargetMinutes $MaxMinutes -ActualMinutes $actualMin -Summary $summary -Metrics $metrics -Verdict $verdict `
        -MaxTempC $tempInfo.MaxTempC -TempSamples $tempInfo.TempSamples -Stalled $cap.Stalled `
        -ReportDir $reportDir -LogPath $LogPath
    Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result ("ORT " + $verdict.Status) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0   # ORT 分支到此结束（不进入常规 per-slot 报告与 RestartLoop）
}
```

（`Export-OrTReport` 签名需含 `-Stalled<bool>`——Task 1 Step 6 已注明。）

- [ ] **Step 6: 语法 + 校验回归**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -Help`
Expected: 帮助含 ORT 参数与示例、退出 0。
Run: 重复 Step 3 两个校验命令 → 仍报错退出、无密码交互。

- [ ] **Step 7: Commit**

```bash
git add scripts/Run-MemtestSuite.ps1
git commit -m "feat: add 72h ORT mode to Run-MemtestSuite"
```

---

### Task 4: ISO「72h ORT 无限轮」预设 + 重制 memtest-sol.iso

**Files:**
- Modify: `config/memtest-presets.conf`
- Rebuild: `memtest\boot\memtest-sol.iso`（经 New-MemtestSolIso.ps1，非手工编辑）

**Interfaces:**
- Produces: GRUB 菜单新增「Memtest86+ 72h ORT 无限轮（SOL）」预设（cmdline `log=ttyS0,115200 ecc`，不带 maxpasses）。

- [ ] **Step 1: 加预设（config/memtest-presets.conf 末尾）**

```
preset.72hORT.title=Memtest86+ 72h ORT 无限轮（SOL）
preset.72hORT.cmdline=log=ttyS0,115200 ecc
```

- [ ] **Step 2: 验证预设可解析且含新项**

Run:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". C:\Users\ganxin01\Documents\trae-work\memory-tests\scripts\lib_common.ps1; (Get-MemtestPresets -Path C:\Users\ganxin01\Documents\trae-work\memory-tests\config\memtest-presets.conf).Presets | Select-Object Key,Cmdline"
```
Expected: 列表含 `72hORT`，Cmdline=`log=ttyS0,115200 ecc`。

- [ ] **Step 3: 重制 ISO**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\New-MemtestSolIso.ps1 -Smoke`
Expected: 构建成功、挂载自检通过、`memtest\boot\memtest-sol.iso` 时间戳为当前；-Smoke 冒烟通过（失败则报告"未验证"并退出 1——需人工判断）。

- [ ] **Step 4: Commit**

```bash
git add config/memtest-presets.conf memtest/boot/memtest-sol.iso
git commit -m "feat: add 72h ORT unlimited preset and rebuild SOL ISO"
```

---

### Task 5: 预置可选 Prime95（Windows 整机满载工具）

**Files:**
- Create: `tools/prime95/`（下载官方 Windows x64 包解压入此目录）

- [ ] **Step 1: 下载官方 Prime95 Windows 版并解压到 tools\prime95\**

从 https://www.mersenne.org/download/ 获取 Windows x64 版本链接（当前为 prime95 v30.x，zip 约 10-20MB），`Invoke-WebRequest` 下载 → `Expand-Archive` 到 `tools\prime95\`。校验：`prime95.exe` 存在、`-h` 可运行（`prime95.exe -h` 输出版本号）。

- [ ] **Step 2: 验证**

Run: `tools\prime95\prime95.exe -h`
Expected: 打印 Prime95 版本信息（非报错）。

- [ ] **Step 3: Commit**

```bash
git add tools/prime95/
git commit -m "chore: bundle Prime95 as optional Windows full-load stress tool"
```

---

### Task 6: 文档同步（20/18/19/02/03）

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（流程 6 改写、周期评估表、输出文件速查表）
- Modify: `docs/18-测试方案总览.md`、`docs/19-测试项执行清单.md`、`docs/02-批量压力测试方案.md`、`docs/03-PowerShell压测工具需求说明.md`（72h ORT 相关 stress-ng"需自备"描述替换为内置 ORT 模式 + 可选 Prime95）

- [ ] **Step 1: 改写 docs/20 流程 6**

替换"stress-ng 需自备"命令为：
```powershell
# 72h ORT（内置 ORT 模式，结论口径 B；引导菜单选「72h ORT 无限轮」）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -BatchName srv01-a1-ort -BootMethod SOL -BmcHost 10.0.0.10 -BmcUser root -MaxMinutes 4320 -ConfirmSwitch
```
判读：`reports\<批次>-ort-report.csv` 的 `Status=PASS` 且 `Conclusion` 含"≥4320 分钟 / Errors=0 / ECC=0 / 无中断 / 温度≤85°C"；FAIL 按原因排查。新增"可选：Prime95 整机满载"小节（`prime95.exe -t` → Blend/Large FFTs，72h，判读 results.txt 无错误 + 无死机重启；先 ORT 通过后再决定）。周期评估表 72h ORT 行改为 ≈72h+缓冲，不依赖 stress-ng。输出文件速查表补 `reports\<批次>-ort-report.csv`、`reports\<批次>-temp.csv`。

- [ ] **Step 2: 同步 18/19/02/03**

搜索 `stress-ng` 与 `需自备`，将"72h ORT 老化需自备 stress-ng"表述改为"内置 Memtest86+ ORT 模式（-MaxMinutes）承担，可选 Prime95 整机满载"。

- [ ] **Step 3: 验证 + Commit**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Select-String -Path docs\*.md -Pattern 'stress-ng' | Select-Object Path,LineNumber,Line"`
Expected: 剩余命中仅为"不打包 stress-ng（无 Windows 版）"或 Prime95 替代说明，无"需自备 stress-ng 跑 72h"旧表述。
```bash
git add docs/20-纯命令行压测手册.md docs/18-测试方案总览.md docs/19-测试项执行清单.md docs/02-批量压力测试方案.md docs/03-PowerShell压测工具需求说明.md
git commit -m "docs: rewrite 72h ORT to built-in mode, Prime95 optional"
```

---

### Task 7: 全量回归 + 打包（build.ps1 -Bump -Zip）

**Files:**
- Run: `scripts/build.ps1 -Bump -Zip`（VERSION 递增 + 先删旧包再建 + 校验 hash）

- [ ] **Step 1: 全量测试回归**

Run 依次：`tests\test-ort.ps1`、`tests\test-suite-config.ps1`、`tests\test-lib.ps1`、`tests\test-presets.ps1`、`tests\test-args.ps1`
Expected: 全部 `ALL PASS`。

- [ ] **Step 2: 打包**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Bump -Zip`
Expected: 成功生成 `memtest.zip`（版本递增 vN→vN+1），输出"交付包已生成"。

- [ ] **Step 3: 包完整性校验**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$z = Get-Item C:\Users\ganxin01\Documents\trae-work\memory-tests\memtest.zip; $z.LastWriteTime; $k = Get-FileHash C:\Users\ganxin01\Documents\trae-work\memory-tests\memtest\scripts\Run-MemtestSuite.ps1 -Algorithm SHA256; $k.Hash"`
Expected: zip 时间戳为当前；`memtest\scripts\Run-MemtestSuite.ps1` 的 SHA256 与包内一致（用 `Expand-Archive` 到临时目录对关键文件比对 hash：lib_common.ps1 / Run-MemtestSuite.ps1 / config / memtest-presets.conf / boot\memtest-sol.iso）。

- [ ] **Step 4: Commit**

```bash
git add VERSION memtest/ memtest.zip 2>/dev/null; git add VERSION memtest/
git commit -m "chore: bump version and repack memtest.zip"
```
（memtest.zip 若被 .gitignore 忽略则仅提交 VERSION 与 memtest/ 增量。）

---

## 执行说明

- 执行方式：**Subagent-driven development**（用户固定默认）。每个 Task 派独立 subagent 实现，主 agent 复核后进入下一个；全部完成后统一汇报。
- 实机冒烟（Task 3 的端到端 ORT 运行、Task 4 的服务器重新挂载新 ISO 并选「72h ORT 无限轮」）需用户在被测服务器侧执行，不在本计划自动验收范围内；本计划验收到"单测/语法/打包/文档"层。
