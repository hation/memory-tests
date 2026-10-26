. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
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
Write-Host "test-ort: ALL PASS"
