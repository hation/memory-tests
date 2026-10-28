. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$pass = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-pass.mtlog.txt"
Assert ($pass.PassesCompleted -eq 4) "pass passes"
Assert ($pass.Errors -eq 0) "pass errors"
Assert ($pass.FinalStatus -eq "PASS") "pass status"
Assert ($pass.SpdInfo.Count -eq 2) "pass spd count"
$fail = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-fail.mtlog.txt"
Assert ($fail.FinalStatus -eq "FAIL") "fail status"
Assert ($fail.ErrorDetails.Count -ge 1) "fail error detail"
$unk = Invoke-MtlogParser -LogFile "$PSScriptRoot\fixtures\sample-unknown.mtlog.txt"
Assert ($null -ne ($unk.Events | Where-Object { $_.ev -eq 'weird_key' })) "unknown event not crash"
$u = Invoke-TextReportParser -ReportFile "$PSScriptRoot\fixtures\sample-pass.usb.txt"
Assert ($u.FinalStatus -eq "PASS") "usb pass"
Assert ($u.PassesCompleted -eq 4) "usb passes"
Assert ($u.PerTest.Count -eq 2) "usb pertest"
$t = Invoke-TextReportParser -ReportFile "$PSScriptRoot\fixtures\sample-truncated.usb.txt"
Assert ($t.FinalStatus -eq "INCOMPLETE") "truncated not misjudged"
$tmpConf = Join-Path $env:TEMP "mt-test-app.conf"
@("# 业务占位", "PARALLEL_MAX=2", "MODE=quick", "ILLEGAL LINE WITHOUT EQUALS", "") | Set-Content -LiteralPath $tmpConf -Encoding UTF8
$cfg = Get-Config -Path $tmpConf
Assert ($cfg.PARALLEL_MAX -eq "2") "conf valid key PARALLEL_MAX"
Assert ($cfg.MODE -eq "quick") "conf valid key MODE"
Assert ($cfg.ContainsKey('ILLEGAL LINE WITHOUT EQUALS') -eq $false) "conf illegal key skipped"
Remove-Item -LiteralPath $tmpConf -Force
# --- 新增：Get-PythonExe / Read-BmcPass / Invoke-IpmiProbe ---
$py = Get-PythonExe
Assert (($null -eq $py) -or ($py -is [string])) "Get-PythonExe returns path or null"
$r1 = "testpass" | Read-BmcPass -Pass "" -Prompt "BMC 密码"
Assert ($r1 -eq "testpass") "Read-BmcPass reads piped input"
$r2 = Read-BmcPass -Pass "given" -Prompt "x"
Assert ($r2 -eq "given") "Read-BmcPass returns given pass without prompting"
$fake = Join-Path $env:TEMP ("fake-ipmitool-" + [guid]::NewGuid().ToString("N") + ".cmd")
@("echo probe-out", "exit /b 0") | Set-Content -LiteralPath $fake -Encoding ASCII
$p = Invoke-IpmiProbe -IpmiTool $fake -IpmiArgs @("mc", "info")
Assert ($p.Out -contains "probe-out") "Invoke-IpmiProbe captures stdout"
Assert ($p.Code -eq 0) "Invoke-IpmiProbe captures exit code"
Remove-Item $fake -Force
# --- SOL 捕获加固：空日志（SOL 会话头仅此而已）应解析为 INCOMPLETE，不抛异常 ---
$tmpSol = Join-Path $env:TEMP ("sol-empty-" + [guid]::NewGuid().ToString("N") + ".txt")
"[SOL Session operational.  Use ~? for help]" | Set-Content -LiteralPath $tmpSol -Encoding UTF8
$sol = Invoke-MtlogParser -LogFile $tmpSol
Assert ($sol.FinalStatus -eq "INCOMPLETE") "empty SOL log => INCOMPLETE"
Assert ($sol.PassesCompleted -eq 0) "empty SOL log => 0 passes"
Remove-Item $tmpSol -Force
Write-Host "test-lib: ALL PASS"
