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
Assert (([regex]::Matches($r.Detail, 'Could not open socket!')).Count -eq 1) "unreachable → Detail 错误去重(三套件错误只留一条)"

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
Assert ($t.Out -match '若本机实为编排机且 BMC 应可达') "unreachable → 输出防护提示"

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

# ============================================================================
# Task 4 -VerifyPowerCycle 实测断电循环验证
# ============================================================================
# transition → 已验证
Remove-Item $env:TEMP\fake_ipmi_pwrcount -ErrorAction SilentlyContinue
$t = Run-Caps 'verify-transition' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '可测\(已验证') "transition → 已验证断电重启"

# flat → 未观察跳变
$t = Run-Caps 'verify-flat' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '未观察到掉电跳变') "flat → 未观察跳变文案"

# off → 关机中止（不发 power cycle）
$t = Run-Caps 'verify-off' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '服务器当前关机') "off → 关机中止文案"

# cycle 后恒 off：收尾确认未回 on → 不得报"已验证"，回落人工确认文案
Remove-Item $env:TEMP\fake_ipmi_pwrcount -ErrorAction SilentlyContinue
$t = Run-Caps 'verify-cycle-off' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -notmatch '已验证') "cycle-off → 不得报已验证"
Assert ((Get-CapStatus $t.Csv 10) -match '未观察到掉电跳变') "cycle-off → 回落人工确认文案"

# unreachable + -VerifyPowerCycle → 仍需编排机，不挂起
$t = Run-Caps 'unreachable' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '^需编排机') "unreachable+Verify → 第10项需编排机"
Remove-Item $t.Csv -Force -ErrorAction SilentlyContinue

Write-Host "  [caps] Check-ServerCapabilities 角色化端到端 OK"

# ============================================================================
# Task 5 Run-ServerAssessment 合并模式 + VerifyPowerCycle 透传
# ============================================================================
$assess = Join-Path $PSScriptRoot "..\scripts\Run-ServerAssessment.ps1"
$dir = Join-Path $env:TEMP ("assess-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $dir | Out-Null
# 服务器侧 CSV（含 Role 列）
$csvA = Join-Path $dir "srv-inband.csv"
@("Item,Name,Status,Role","4,ECC 纠错功能验证,可测(ECC 平台),被测服务器","10,反复上电掉电循环,需编排机(BMC 不可达: x),被测服务器","6,电压裕量,外包(可编程电源+示波器),被测服务器") | Set-Content $csvA -Encoding UTF8
# 编排机侧 CSV（含 Role 列）
$csvB = Join-Path $dir "srv-oob.csv"
@("Item,Name,Status,Role","4,ECC 纠错功能验证,需带内(服务器本机跑),编排机","10,反复上电掉电循环,可测(IPMI 断电循环),编排机","6,电压裕量,外包(可编程电源+示波器),编排机") | Set-Content $csvB -Encoding UTF8
$outDir = Join-Path $dir "out"
$o = & $ps -NoProfile -File $assess -MergeInband $csvA -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
$merged = Import-Csv (Join-Path $outDir "srv01-assessment.csv")
Assert ((($merged | Where-Object { $_.Item -eq '10' }).Status) -match '^可测') "合并 → 第10项取编排机(可测)"
Assert ((($merged | Where-Object { $_.Item -eq '4' }).Status) -match '^可测') "合并 → 第4项取服务器(可测 ECC)"
Assert ((($merged | Where-Object { $_.Item -eq '6' }).Status) -match '^外包') "合并 → 第6项外包"

# Role 传反 → 警告但结果正确
$csvA2 = Join-Path $dir "srv-inband-roleOob.csv"
@("Item,Name,Status,Role","10,反复上电掉电循环,需编排机(BMC 不可达: x),编排机") | Set-Content $csvA2 -Encoding UTF8
$o2 = & $ps -NoProfile -File $assess -MergeInband $csvA2 -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
Assert ($o2 -match '警告：-MergeInband') "Role 不符 → 输出警告"

# 旧版无 Role 列 → 照常合并
$csvA3 = Join-Path $dir "srv-inband-legacy.csv"
@("Item,Name,Status","10,反复上电掉电循环,需编排机(BMC 不可达: x)") | Set-Content $csvA3 -Encoding UTF8
$o3 = & $ps -NoProfile -File $assess -MergeInband $csvA3 -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
$merged3 = Import-Csv (Join-Path $outDir "srv01-assessment.csv")
Assert ((($merged3 | Where-Object { $_.Item -eq '10' }).Status) -match '^可测') "旧版无Role → 照常合并(第10项可测)"

# 只给一个合并参数 → 报错非0退出
$o4 = & $ps -NoProfile -File $assess -MergeInband $csvA -MachineName srv01 2>&1 | Out-String
Assert ($o4 -match 'MergeOob') "只给 MergeInband → 报错提示 MergeOob"
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  [assess] Run-ServerAssessment 合并模式 OK"

# ============================================================================
# 优化：Run-ServerAssessment 正常模式 cap CSV 按角色命名（避免两机同名覆盖）
# ============================================================================
$dirN = Join-Path $env:TEMP ("assessN-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $dirN | Out-Null
$env:FAKE_IPMI_MODE = 'ok'
"pw" | & $ps -NoProfile -File $assess -BmcHost 1.2.3.4 -BmcUser u -IpmiTool $fake -MachineName srv01 -OutDir $dirN 2>&1 | Out-Null
Assert (Test-Path (Join-Path $dirN "srv01-cap-编排机.csv")) "ok → cap CSV 命名为 srv01-cap-编排机.csv"
Assert (-not (Test-Path (Join-Path $dirN "srv01-cap.csv"))) "ok → 旧名 srv01-cap.csv 已不存在"

$env:FAKE_IPMI_MODE = 'unreachable'
"pw" | & $ps -NoProfile -File $assess -BmcHost 1.2.3.4 -BmcUser u -IpmiTool $fake -MachineName srv01 -OutDir $dirN 2>&1 | Out-Null
Assert (Test-Path (Join-Path $dirN "srv01-cap-被测服务器.csv")) "unreachable → cap CSV 命名为 srv01-cap-被测服务器.csv"
Remove-Item $dirN -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  [capname] Run-ServerAssessment cap CSV 角色命名 OK"
Write-Host ""
Write-Host "test-assessment-role: ALL PASS"
