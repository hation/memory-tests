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
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -NoLogFile $true
Assert ($v.Status -eq 'FAIL' -and $v.Conclusion -match '未生成 results.txt') "FAIL 无日志(NoLogFile)"
$v = Get-Prime95Verdict -ActualMinutes 185 -TargetMinutes 180 -ErrorCount 0 -ExitedEarly $false -NoLogFile $false
Assert ($v.Status -eq 'PASS') "PASS NoLogFile=false 不破坏既有行为"
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
$m = @(Import-Csv (Join-Path $tmpDir 'master_manifest.csv'))  # @() 包裹：PS5.1 单行 CSV 返回标量，.Count 不可靠（同 test-ort.ps1）
Assert ($m.Count -eq 1 -and $m[0].Slot -eq 'ALL' -and $m[0].Result -eq 'Prime95 PASS') "master 合成行"
Remove-Item -LiteralPath $tmpDir -Recurse -Force
Write-Host "test-prime95: ALL PASS"
