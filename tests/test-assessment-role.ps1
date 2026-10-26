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

# ============================================================================
# Task 3 角色化端到端（Check-ServerCapabilities 角色化入口 + 三态文案 + Role 列）
# ============================================================================
$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$caps = Join-Path $PSScriptRoot "..\scripts\Check-ServerCapabilities.ps1"
function Run-Caps([string]$mode, [string[]]$extra) {
    $env:FAKE_IPMI_MODE = $mode
    $csv = Join-Path $env:TEMP ("cap-" + [guid]::NewGuid().ToString("N") + ".csv")
    $out = "pw" | & $ps -NoProfile -File $caps -BmcHost 1.2.3.4 -BmcUser u -IpmiTool $fake @extra -OutCsv $csv 2>&1 | Out-String
    return @{ Out = $out; Csv = $csv }
}
function Get-CapStatus($csv, [int]$item) {
    (Import-Csv -LiteralPath $csv | Where-Object { [int]$_.Item -eq $item }).Status
}

# 编排机：ok
$t = Run-Caps 'ok' @()
Assert ($t.Out -match '角色: 编排机') "ok → 角色行=编排机"
Assert ((Import-Csv $t.Csv)[0].Role -eq '编排机') "ok → cap CSV Role=编排机"
Assert ((Get-CapStatus $t.Csv 10) -match '^可测') "ok → 第10项可测"

# 被测服务器：unreachable（自动跑带内）
$t = Run-Caps 'unreachable' @()
Assert ($t.Out -match '角色: 被测服务器') "unreachable → 角色行=被测服务器"
Assert ((Import-Csv $t.Csv)[0].Role -eq '被测服务器') "unreachable → cap CSV Role=被测服务器"
Assert ((Get-CapStatus $t.Csv 10) -match '^需编排机') "unreachable → 第10项需编排机"
Assert ((Get-CapStatus $t.Csv 1) -match '^可测') "unreachable → 自动跑带内(第1项可测)"

# 凭据失败：auth（不跑带内，如实报告）
$t = Run-Caps 'auth' @()
Assert ($t.Out -match '凭据/权限失败') "auth → 输出含凭据失败"
Assert ((Get-CapStatus $t.Csv 10) -match '^条件: BMC 可达但凭据/权限失败') "auth → 第10项条件文案"
Assert ((Get-CapStatus $t.Csv 1) -match '^需带内') "auth → 不跑带内(第1项需带内)"

# 不带 -BmcHost：不得弹密码、判被测服务器
$env:FAKE_IPMI_MODE = 'ok'
$csv2 = Join-Path $env:TEMP ("cap2-" + [guid]::NewGuid().ToString("N") + ".csv")
$o2 = & $ps -NoProfile -File $caps -OutCsv $csv2 2>&1 | Out-String
Assert ($o2 -notmatch 'BMC 密码') "无 -BmcHost 不弹密码提示"
Assert ($o2 -match '角色: 被测服务器') "无 -BmcHost → 被测服务器角色"
Assert ((Import-Csv $csv2)[0].Role -eq '被测服务器') "无 -BmcHost → Role=被测服务器"

# 双通道 -Local -BmcHost（ok）：Role=编排机 且 带内也执行
$t = Run-Caps 'ok' @('-Local')
Assert ((Import-Csv $t.Csv)[0].Role -eq '编排机') "-Local -BmcHost → Role=编排机"
Assert ((Get-CapStatus $t.Csv 1) -match '^可测') "-Local -BmcHost → 带内也执行(第1项可测)"
Remove-Item $t.Csv, $csv2 -Force -ErrorAction SilentlyContinue

Write-Host "  [caps] Check-ServerCapabilities 角色化端到端 OK"
Write-Host ""
Write-Host "test-assessment-role: ALL PASS"
