. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$fake = Join-Path $PSScriptRoot "fixtures\fake-ipmitool.cmd"
$base = @('-I', 'lanplus', '-H', '1.2.3.4', '-U', 'u', '-P', 'pw')

$env:FAKE_IPMI_MODE = 'ok'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'Orchestrator') "ok → Orchestrator"
Assert ($r.BmcVendor -eq 'FakeCorp') "ok → BmcVendor=FakeCorp"
Assert ($r.CipherArgs.Count -ge $base.Count) "ok → CipherArgs 含基础参数"

$env:FAKE_IPMI_MODE = 'unreachable'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'Server') "unreachable → Server"
Assert ($r.Detail -match '^BMC 不可达') "unreachable → Detail 前缀"

$env:FAKE_IPMI_MODE = 'auth'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'AuthError') "auth → AuthError"
Assert ($r.Detail -match '^BMC 可达但凭据/权限失败') "auth → Detail 前缀"
Write-Host "  [role] Test-BmcRole 三态 OK"
