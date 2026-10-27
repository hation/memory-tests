. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
# 清单表格解析辅助（黑盒读文件，UTF-8；供 PART5 校验 ORT 清单/总览更新）
function Get-OvRows([string]$Path) {
    $rows = @()
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match "^\| \d+ \|") {
            $cols = $line -split "\|"
            $rows += [PSCustomObject]@{ Item = $cols[1].Trim(); Status = $cols[3].Trim(); Result = $cols[4].Trim() }
        }
    }
    return $rows
}
function Get-FlowRows([string]$Path) {
    $rows = @()
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match "^\| " -and $line -notmatch "^\|-") {
            $cols = $line -split "\|"
            if ($cols.Count -ge 6 -and $cols[1].Trim() -ne '环节') {
                $rows += [PSCustomObject]@{ Key = $cols[1].Trim(); Status = $cols[3].Trim(); Result = $cols[4].Trim(); Product = $cols[5].Trim() }
            }
        }
    }
    return $rows
}
# PART1: Get-OrTVerdict 判定场景（按实施计划 Task 1 Step 1）
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
# GapLimitMin 参数（裁定②）：默认 30；45min 间隔在默认阈值下判中断，放宽到 60 后 PASS
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 45 -GapLimitMin 30 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '中断') "FAIL GapLimitMin=30"
$v = Get-OrTVerdict -ActualMinutes 4325 -TargetMinutes 4320 -Errors 0 -EccErrors 0 `
      -StartEventCount 1 -MaxEventGapMin 45 -GapLimitMin 60 -Stalled $false -MaxTempC 72 -TempSamples 72 -TempLimitC 85
Assert ($v.Status -eq 'PASS') "PASS GapLimitMin=60"
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

# PART2: Get-OrTLogMetrics（用 Invoke-MtlogParser 解析合成日志）
# 注意：计划原文 fixture 末条 ts=4320.0（秒）与断言 LogSpanMinutes -eq 4320 不一致
#（(4320-0)/60=72 min ≠ 4320；且 max gap=(4320-61)/60≈70.98 不在断言区间）。
# MTLOG ts 单位是秒，72h=259200s。此处将末条 ts 修正为 259200.0，使
# LogSpanMinutes=(259200-0)/60=4320 与原文断言一致；max gap=(259200-61)/60≈4318.98，
# 断言区间相应修正为 (4318,4320)。
$log = @'
MTLOG ts=0.0 ev=start version=9.0
MTLOG ts=60.0 ev=pass_end pass=0 errors=0 status=pass
MTLOG ts=61.0 ev=start version=9.0
MTLOG ts=259200.0 ev=pass_end pass=1 errors=0 status=pass
'@
$tmp = Join-Path $env:TEMP "ort-metrics-sample.mtlog.txt"
[System.IO.File]::WriteAllText($tmp, $log, (New-Object System.Text.UTF8Encoding($false)))
$sum = Invoke-MtlogParser -LogFile $tmp
$m = Get-OrTLogMetrics -Summary $sum
Assert ($m.StartEventCount -eq 2) "metrics start count"
Assert ($m.MaxEventGapMin -gt 4318 -and $m.MaxEventGapMin -lt 4320) "metrics max gap"
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
$master = @(Import-Csv (Join-Path $tmpDir 'master_manifest.csv'))  # @() 包裹：PS5.1 单行 CSV 返回标量，.Count 不可靠（同 Read-CsvManifest 注释）
Assert ($master.Count -eq 1 -and $master[0].Slot -eq 'ALL' -and $master[0].Result -eq 'ORT PASS') "master 合成行"
Remove-Item -LiteralPath $tmpDir -Recurse -Force

# PART4: Start/Stop-OrTTempSampling（假 LibPath 提供 Get-IPMITempSensors，MaxIterations 钩子快速跑完）
$fakeLib = Join-Path $env:TEMP ("ort-fakelib-" + [guid]::NewGuid().ToString("N") + ".ps1")
@'
function Get-IPMITempSensors {
    param([string]$BmcHost, [string]$BmcUser, [string]$BmcPass, [string]$IpmiTool)
    return @(
        [PSCustomObject]@{ Sensor = 'DIMM A'; TempC = 71.5 },
        [PSCustomObject]@{ Sensor = 'DIMM B'; TempC = 68.0 }
    )
}
'@ | Set-Content -LiteralPath $fakeLib -Encoding UTF8
$tempCsv = Join-Path $env:TEMP ("ort-temp-" + [guid]::NewGuid().ToString("N") + ".csv")
$tempJob = Start-OrTTempSampling -BmcHost '10.0.0.10' -BmcUser 'root' -BmcPass 'x' -IpmiTool 'fake-ipmi' `
    -IntervalMin 0 -CsvFile $tempCsv -LibPath $fakeLib -MaxIterations 2
Wait-Job -Job $tempJob -Timeout 30 | Out-Null   # 有限迭代 Job 先自然跑完，避免 Stop-Job 掐断首轮写入的竞态
$tempInfo = Stop-OrTTempSampling -Job $tempJob -CsvFile $tempCsv -WaitSec 30
Assert ($tempInfo.TempSamples -eq 4) "temp sampling rows (2 iterations x 2 sensors)"
Assert ($tempInfo.MaxTempC -eq 71.5) "temp sampling max"
Remove-Item -LiteralPath $tempCsv -Force
Remove-Item -LiteralPath $fakeLib -Force

# PART5: ORT 分支清单挂点（Update-OrTChecklist）仿真——参考 Task 3 报告仿真法：
# New 清单 → 构造 ORT 报告（Export-OrTReport 假数据）→ 调挂点 → 断言 任务清单-ORT.md 三环节
# 与总览第 5 项更新（PASS 场景；清单缺失自动建用 FAIL 场景验证）
$tmpDir5 = Join-Path $env:TEMP ("ort-cl-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir5 -Force | Out-Null
try {
    # ---- PASS 场景：时长达标 + 无错误 + 温度正常 ----
    $clBatchP = "ort-cl-pass"
    $dirP = New-TaskChecklist -ChecklistBatch $clBatchP -MachineName "srv01" -ResultsDir $tmpDir5
    $sumP = [PSCustomObject]@{ PassesCompleted = 36; Errors = 0; EccErrors = 0; FinalStatus = 'PASS' }
    $verdictP = [PSCustomObject]@{ Status = 'PASS'; Conclusion = '老化通过：4320 分钟 ≥ 目标 4320 分钟，Errors=0，ECC=0，无中断，最高温 72°C ≤ 85°C' }
    $tempP = [PSCustomObject]@{ MaxTempC = 72.0; TempSamples = 72 }
    Update-OrTChecklist -ChecklistBatch $clBatchP -ResultsDir $tmpDir5 -BatchName 'ort-cl-pass' `
        -Summary $sumP -Verdict $verdictP -ActualMinutes 4320 -TargetMinutes 4320 -TempInfo $tempP -TempLimitC 85
    $ortP = @(Get-FlowRows (Join-Path $dirP "任务清单-ORT.md"))
    $p72 = $ortP | Where-Object { $_.Key -eq '72h 满载' }
    Assert ($p72.Status -eq '✓ 做成' -and $p72.Result -match '实际 4320 min' -and $p72.Result -match 'Errors=0') "72h 满载 ✓（PASS 场景）"
    $pT = $ortP | Where-Object { $_.Key -eq '全程测温' }
    Assert ($pT.Status -eq '✓ 做成' -and $pT.Result -match '72' -and $pT.Product -eq 'ort-cl-pass-temp.csv') "全程测温 ✓（温度达标）"
    $pB = $ortP | Where-Object { $_.Key -eq '口径B结论' }
    Assert ($pB.Status -eq '✓ 做成' -and $pB.Result -match '老化通过') "口径B结论 ✓"
    $ovP = @(Get-OvRows (Join-Path $dirP "任务清单-总览.md"))
    $r5P = $ovP | Where-Object { $_.Item -eq '5' }
    Assert ($r5P.Status -eq '✓ 做成' -and $r5P.Result -match '老化通过') "总览第 5 项同口径 B ✓"

    # ---- FAIL 场景（清单缺失自动建）：时长不足 + 超温 ----
    $clBatchF = "ort-cl-fail"
    $sumF = [PSCustomObject]@{ PassesCompleted = 30; Errors = 3; EccErrors = 1; FinalStatus = 'FAIL' }
    $verdictF = [PSCustomObject]@{ Status = 'FAIL'; Conclusion = '时长不足(实际 3600 min / 目标 4320 min)' }
    $tempF = [PSCustomObject]@{ MaxTempC = 88.0; TempSamples = 60 }
    Update-OrTChecklist -ChecklistBatch $clBatchF -ResultsDir $tmpDir5 -BatchName 'ort-cl-fail' `
        -Summary $sumF -Verdict $verdictF -ActualMinutes 3600 -TargetMinutes 4320 -TempInfo $tempF -TempLimitC 85
    $dirF = Join-Path $tmpDir5 $clBatchF
    Assert (Test-Path (Join-Path $dirF "任务清单-ORT.md")) "FAIL 场景清单缺失自动建"
    $ortF = @(Get-FlowRows (Join-Path $dirF "任务清单-ORT.md"))
    $f72 = $ortF | Where-Object { $_.Key -eq '72h 满载' }
    Assert ($f72.Status -eq '✗ 没做成' -and $f72.Result -match 'Errors=3 EccErrors=1') "72h 满载 ✗（FAIL 场景，含 Errors/EccErrors）"
    $fT = $ortF | Where-Object { $_.Key -eq '全程测温' }
    Assert ($fT.Status -eq '✗ 没做成' -and $fT.Result -match '超温') "全程测温 ✗（超温）"
    $fB = $ortF | Where-Object { $_.Key -eq '口径B结论' }
    Assert ($fB.Status -eq '✗ 没做成' -and $fB.Result -match '时长不足') "口径B结论 ✗"
    $ovF = @(Get-OvRows (Join-Path $dirF "任务清单-总览.md"))
    $r5F = $ovF | Where-Object { $_.Item -eq '5' }
    Assert ($r5F.Status -eq '✗ 没做成') "总览第 5 项同口径 B ✗"

    # ---- 温度判据未启用（-TempLimitC 0，Serial 无 BMC）→ 全程测温 ⚠ ----
    $clBatchN = "ort-cl-nolimit"
    $sumN = [PSCustomObject]@{ PassesCompleted = 36; Errors = 0; EccErrors = 0; FinalStatus = 'PASS' }
    $verdictN = [PSCustomObject]@{ Status = 'PASS'; Conclusion = '老化通过：4320 分钟 ≥ 目标 4320 分钟，Errors=0，ECC=0，无中断，温度判据未启用' }
    $tempN = [PSCustomObject]@{ MaxTempC = [double]-1; TempSamples = 0 }
    Update-OrTChecklist -ChecklistBatch $clBatchN -ResultsDir $tmpDir5 -BatchName 'ort-cl-nolimit' `
        -Summary $sumN -Verdict $verdictN -ActualMinutes 4320 -TargetMinutes 4320 -TempInfo $tempN -TempLimitC 0
    $dirN = Join-Path $tmpDir5 $clBatchN
    $ortN = @(Get-FlowRows (Join-Path $dirN "任务清单-ORT.md"))
    $nT = $ortN | Where-Object { $_.Key -eq '全程测温' }
    Assert ($nT.Status -eq '⚠ 无法测试' -and $nT.Result -match '未启用') "全程测温 ⚠（判据未启用）"
    $nB = $ortN | Where-Object { $_.Key -eq '口径B结论' }
    Assert ($nB.Status -eq '✓ 做成') "口径B结论 ✓（判据关闭仍按时长+错误判）"
} finally {
    Remove-Item -LiteralPath $tmpDir5 -Recurse -Force
}
Write-Host "test-ort: ALL PASS"
