. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$fake = Join-Path $PSScriptRoot 'fixtures\fake-ipmitool.cmd'
$env:FAKE_IPMI_MODE = 'unreachable'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert (-not $r.Reachable -and -not $r.LanPrintOk) "unreachable => Reachable=false"
$env:FAKE_IPMI_MODE = 'auth'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert (-not $r.Reachable) "auth => Reachable=false（凭据错误也判不可达）"
$env:FAKE_IPMI_MODE = 'preflight-static'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and $r.LanPrintOk -and $r.IpSourceStatic) "static => 全通过"
$env:FAKE_IPMI_MODE = 'preflight-dhcp'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and $r.LanPrintOk -and -not $r.IpSourceStatic) "dhcp => IpSourceStatic=false"
$env:FAKE_IPMI_MODE = 'preflight-lanfail'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and -not $r.LanPrintOk) "lanfail(重试后) => LanPrintOk=false"
Remove-Item Env:FAKE_IPMI_MODE -ErrorAction SilentlyContinue
Write-Host "test-bmc-net: ALL PASS"
