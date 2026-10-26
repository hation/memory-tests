# ============================================================================
# Diag-Bmc.ps1 — BMC 一键诊断（四步：mc info / chassis status / sdr elist / sol activate）
# 定位：`mc info` 连不上 BMC（能力评估 5/10 显示「需 BMC」）时的一键排查。
# 依据：docs/15-BMC排查方案.md §2（诊断命令序列 + §2.3 三大原因对照表）。
# 用法（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser root -BmcPass <密码>   # 完整参数
#   .\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser root                    # 密码走管道/交互输入
#   .\scripts\Diag-Bmc.ps1 -Help                                              # 打印用法即退
# 依赖：lib_common.ps1（Invoke-IpmiProbe / Read-BmcPass）；内置 ipmitool 自动发现
#       （<包根>\tools\ipmitool\ipmitool.exe，同 Check-ServerCapabilities）。
# 输出：每步 [PASS]/[FAIL] + 末尾汇总表与三大原因提示；任一步失败以非 0 退出。
# ============================================================================

param(
    [string]$BmcHost = "",
    [string]$BmcUser = "",
    [string]$BmcPass = "",
    [string]$IpmiTool = "ipmitool",
    [switch]$Help
)

if ($Help) {
    Write-Host "Diag-Bmc.ps1 — BMC 一键诊断（在离线包根目录运行）"
    Write-Host "用法: .\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> [-BmcUser root] [-BmcPass <密码>] [-IpmiTool <ipmitool路径>]"
    Write-Host "四步: ① mc info(套件自动回退 -C 3/-C 17) ② chassis status ③ sdr elist(温度) ④ sol activate(短探测)"
    exit 0
}

if ($BmcHost -eq "") {
    Write-Error "-BmcHost 必填"
    exit 1
}

. $PSScriptRoot\lib_common.ps1
$ErrorActionPreference = 'Stop'

# 指令记录：本次调用入库（Help 已处理；BMC 密码等敏感参数由 Write-CmdLog 打码）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Diag-Bmc' -CmdArgs $MyInvocation.Line -State Start

# 内置 ipmitool 自动发现（同 Check-ServerCapabilities）
if ($IpmiTool -eq "ipmitool") {
    $bundled = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\ipmitool\ipmitool.exe"
    if (Test-Path -LiteralPath $bundled) { $IpmiTool = $bundled }
}

# 管道密码优先：脚本顶层 $input 可读外部管道（Read-BmcPass 的函数作用域内读不到，故在此先消费，
# 否则 -File 模式管道场景会落入 Read-Host 等待控制台而挂起）。
$pipeIn = @($input)
if ($BmcPass -eq "" -and $pipeIn.Count -gt 0) { $BmcPass = [string]$pipeIn[0] }
# 密码：未显式提供 → 管道/交互输入
$BmcPass = Read-BmcPass -Pass $BmcPass -Prompt "BMC 密码（$BmcHost）"

# 基础参数（后续步骤复用；mc info 确定生效套件后追加 -C N）
$a = @("-I", "lanplus", "-H", $BmcHost)
if ($BmcUser) { $a += @("-U", $BmcUser) }
if ($BmcPass) { $a += @("-P", $BmcPass) }

# 复用 Invoke-IpmiProbe 的安全包装：ipmitool 不存在 / 其他终止错误也转为 Code=1 结果，
# 保证任意失败都走 [FAIL] 流程而不抛未捕获异常（stdout/stderr 分离逻辑不在此重复）。
function Probe {
    param([string[]]$CmdArgs)
    try { return Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs $CmdArgs }
    catch { return [PSCustomObject]@{ Out = @(); Err = @($_.Exception.Message); Code = 1 } }
}

# 汇总表
$steps = @()   # [PSCustomObject]@{ Name; Pass; Detail }

Write-Host "===== BMC 一键诊断: $BmcHost ====="
Write-Host ("ipmitool: {0} | 用户: {1}" -f $IpmiTool, $(if ($BmcUser) { $BmcUser } else { "(未指定)" }))
Write-Host ""

# ---- ① mc info：默认套件 → 失败自动 -C 3 → 再失败 -C 17；记下生效套件供后续复用 ----
$cipherUsed = "默认套件"
$r = Probe @($a + @("mc", "info"))
if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
    Write-Host "[PASS] ① mc info（$cipherUsed）"
    $steps += [PSCustomObject]@{ Name = "① mc info"; Pass = $true;  Detail = "套件: $cipherUsed" }
} else {
    $errDefault = ($r.Err -join ' | ')
    $r = Probe @($a + @("-C", "3", "mc", "info"))
    if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
        $cipherUsed = "-C 3"; $a += @("-C", "3")
        Write-Host "[PASS] ① mc info（$cipherUsed 生效）"
        $steps += [PSCustomObject]@{ Name = "① mc info"; Pass = $true;  Detail = "套件: $cipherUsed" }
    } else {
        $errC3 = ($r.Err -join ' | ')
        $r = Probe @($a + @("-C", "17", "mc", "info"))
        if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
            $cipherUsed = "-C 17"; $a += @("-C", "17")
            Write-Host "[PASS] ① mc info（$cipherUsed 生效）"
            $steps += [PSCustomObject]@{ Name = "① mc info"; Pass = $true;  Detail = "套件: $cipherUsed" }
        } else {
            $errC17 = ($r.Err -join ' | ')
            Write-Host "[FAIL] ① mc info（默认/-C 3/-C 17 均失败）"
            $steps += [PSCustomObject]@{ Name = "① mc info"; Pass = $false; Detail = "默认[$errDefault] | -C 3[$errC3] | -C 17[$errC17]" }
        }
    }
}

# ---- ② chassis status：断电循环能力 ----
$r = Probe @($a + @("chassis", "status"))
if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
    Write-Host "[PASS] ② chassis status"
    $steps += [PSCustomObject]@{ Name = "② chassis status"; Pass = $true; Detail = "断电循环命令可用" }
} else {
    Write-Host "[FAIL] ② chassis status"
    $steps += [PSCustomObject]@{ Name = "② chassis status"; Pass = $false; Detail = ($r.Err -join ' | ') }
}

# ---- ③ sdr elist：含 degrees C 条目计数（温度传感器前提） ----
$r = Probe @($a + @("sdr", "elist"))
if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
    $tmpCnt = ($r.Out | Where-Object { $_ -match 'degrees C' }).Count
    Write-Host "[PASS] ③ sdr elist（温度条目 $tmpCnt 个）"
    $steps += [PSCustomObject]@{ Name = "③ sdr elist"; Pass = $true; Detail = "温度(degrees C)条目: $tmpCnt" }
} else {
    Write-Host "[FAIL] ③ sdr elist"
    $steps += [PSCustomObject]@{ Name = "③ sdr elist"; Pass = $false; Detail = ($r.Err -join ' | ') }
}

# ---- ④ sol activate：短探测（~6s，Start-Process 重定向输出，同 Check-ServerCapabilities） ----
$solOut = Join-Path $env:TEMP ("sol_probe_" + [guid]::NewGuid().ToString("N") + ".txt")
$solErrFile = "$solOut.err"
$solErrText = ""
$hasOut = $false
try {
    $p = Start-Process -FilePath $IpmiTool -ArgumentList ($a + @("sol", "activate")) `
            -RedirectStandardOutput $solOut -RedirectStandardError $solErrFile -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 6
    $hasOut = (Test-Path $solOut) -and ((Get-Item $solOut).Length -gt 0)
} catch {
    $solErrText = $_.Exception.Message
} finally {
    if ($p) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
}
Start-Sleep -Milliseconds 500
# 释放 SOL 通道：探测强杀进程后 BMC 可能残留 payload（报 "already active"），主动 sol deactivate（失败忽略）
& $IpmiTool @($a + @("sol", "deactivate")) 2>$null | Out-Null
if (Test-Path $solErrFile) {
    $errRaw = Get-Content $solErrFile -Raw -ErrorAction SilentlyContinue
    if ($null -ne $errRaw) { $solErrText = $errRaw.Trim() }
}
Remove-Item $solOut, $solErrFile -Force -ErrorAction SilentlyContinue
if ($hasOut) {
    Write-Host "[PASS] ④ sol activate（~6s 内收到输出）"
    $steps += [PSCustomObject]@{ Name = "④ sol activate"; Pass = $true; Detail = "短探测有输出" }
} else {
    Write-Host "[FAIL] ④ sol activate"
    $steps += [PSCustomObject]@{ Name = "④ sol activate"; Pass = $false; Detail = $(if ($solErrText) { $solErrText } else { "6s 内无任何输出（SOL 未启用/会话占用/权限不足）" }) }
}

# ---- 末尾汇总 ----
Write-Host ""
Write-Host "===== 诊断汇总 ====="
foreach ($s in $steps) {
    Write-Host ("{0}  {1}" -f $(if ($s.Pass) { "[PASS]" } else { "[FAIL]" }), $s.Name)
    if (-not $s.Pass -and $s.Detail) { Write-Host ("        -> " + $s.Detail) }
}
$failSteps = @($steps | Where-Object { -not $_.Pass })
Write-Host ""
if ($failSteps.Count -eq 0) {
    Write-Host "全部通过：BMC 连通、断电循环、温度、SOL 均可用。"
} else {
    Write-Host "共 $($failSteps.Count) / $($steps.Count) 步失败。按失败步骤对照 docs/15-BMC排查方案.md §2.3："
    $mcPassed = @($steps | Where-Object { $_.Name -match 'mc info' -and $_.Pass }).Count -gt 0
    foreach ($s in $failSteps) {
        if ($s.Name -match 'mc info') {
            Write-Host ("  {0}: 连接级失败，三大原因逐一排查：" -f $s.Name)
            Write-Host "      ① 加密套件不匹配（报错 Unable to get.../Authentication type ... not supported）→ 已自动试过 -C 3/-C 17 仍失败，查 BMC 版本/换新 ipmitool"
            Write-Host "      ② 网络路径不对（报错 Unable to connect/卡住超时）→ 确认在编排机(管理网)跑、BMC IP 与网段、能 ping 通"
            Write-Host "      ③ 账号/密码错误（报错 Invalid password/Unauthorized name）→ BMC 界面核对账号密码"
        } elseif ($s.Name -match 'chassis status' -or $s.Name -match 'sdr elist') {
            if ($mcPassed) {
                Write-Host ("  {0}: BMC 已连通但该项失败 → 多为账号权限不足(需 Operator/Admin)或对应功能未启用，参考 docs/15 §2.4/§3" -f $s.Name)
            } else {
                Write-Host ("  {0}: ① mc info 未连通，该项为连接级连带失败 → 先按上面 ① 的三大原因排查" -f $s.Name)
            }
        } elseif ($s.Name -match 'sol activate') {
            Write-Host ("  {0}: SOL 探测失败 → ①BMC 未开 SOL ②会话被占用(session already active) ③账号权限不足，参考 docs/15 §3" -f $s.Name)
        }
    }
    Write-CmdLog -Script 'Diag-Bmc' -State End -Result ("FAIL: " + $failSteps.Count + "/" + $steps.Count + " 步失败") -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
Write-CmdLog -Script 'Diag-Bmc' -State End -Result 'OK' -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
exit 0
