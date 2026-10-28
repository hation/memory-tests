# ============================================================================
# Set-BmcStaticIp.ps1 — 被测服务器本机一键查询/恢复 BMC 静态 IP（ipmiutil raw 命令，绕过 BIOS 界面）
# 定位：BMC 管理口灯亮但无有效 IP（IP 源 = DHCP/Unspecified）、BIOS 设静态 IP 无提示失败时，
#       在服务器 Windows 系统内用本地 IPMI 接口恢复静态 IP。
# 依据：docs/21-BMC网络与IP恢复方案.md §5.2（raw 命令序列，2026-10-28 实机验证）。
# 用法（在离线包根目录运行，需管理员，如 C:\memtest\）：
#   .\scripts\Set-BmcStaticIp.ps1 -CheckOnly                       # 只读：查询现状并判定（静态=正常 / 非静态=需恢复）
#   .\scripts\Set-BmcStaticIp.ps1                                   # 恢复默认静态 IP 10.0.0.10 / 255.255.255.0（不自动冷复位）
#   .\scripts\Set-BmcStaticIp.ps1 -Ip 10.0.0.10 -Mask 255.255.255.0 -ColdReset   # 写入且回读通过后自动冷复位 BMC
#   .\scripts\Set-BmcStaticIp.ps1 -Help                             # 打印用法即退
# 依赖：lib_common.ps1（Write-CmdLog / Invoke-IpmiProbe）；内置 ipmiutil 自动发现
#       （<包根>\tools\ipmiutil-win64\ipmiutil.exe，整个目录拷贝含 DLL）。
# 判据：写后回读 `lan -c 1` 核对 IP/源/掩码 —— 回读兜底是最终成败判据（raw 命令输出形态
#       不同版本有差异，不作为判据）。恢复仅用 raw 命令（ipmiutil lan -s 报 Bus Error 不可用）。
# ============================================================================

param(
    [string]$Ip = "10.0.0.10",
    [string]$Mask = "255.255.255.0",
    [string]$Gateway = "",
    [string]$IpmiUtil = "",
    [switch]$CheckOnly,
    [switch]$ColdReset,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Set-BmcStaticIp.ps1 — 被测服务器本机查询/恢复 BMC 静态 IP（本地 IPMI 接口，ipmiutil raw 命令）

用法（在服务器上以管理员运行，如 C:\memtest\）：
  .\scripts\Set-BmcStaticIp.ps1 -CheckOnly                    只读查询现状（IP/源/MAC + 判定）
  .\scripts\Set-BmcStaticIp.ps1                               恢复静态 IP（默认 10.0.0.10/255.255.255.0）
  .\scripts\Set-BmcStaticIp.ps1 -Ip 10.0.0.10 -Mask 255.255.255.0 [-Gateway x.x.x.x] [-ColdReset]

参数：
  -Ip          目标静态 IP（默认 10.0.0.10）
  -Mask        子网掩码（默认 255.255.255.0）
  -Gateway     网关（默认跳过；填 0.0.0.0 也跳过——管理网直连无需网关，BMC 返回 d5 属正常）
  -IpmiUtil    ipmiutil.exe 路径（默认 <包根>\tools\ipmiutil-win64\ipmiutil.exe，需整个目录拷贝含 DLL）
  -CheckOnly   只读：仅查询现状并判定，不写任何 BMC 配置
  -ColdReset   写入成功且回读校验通过后自动执行 ipmiutil reset -c（服务器会短暂息屏 1~2 分钟，属正常）；
               不指定则仅提示，由人工确认时机后手动执行
  -Help        打印本帮助并退出

说明：
  - 只运行于被测服务器本机（本地 IPMI 接口），需管理员权限，不需要 BMC 有 IP；
  - 恢复仅用 raw 命令（ipmiutil lan -s 报 Bus Error 不可用）；
  - 写前读 + 写后回读校验（lan -c 1 核对 IP/源/掩码），回读兜底是最终成败判据。
"@
    exit 0
}

. $PSScriptRoot\lib_common.ps1
$ErrorActionPreference = 'Stop'

# 指令记录：本次调用入库（Help 已处理；敏感参数由 Write-CmdLog 打码）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Set-BmcStaticIp' -CmdArgs $MyInvocation.Line -State Start

# 报错并退出 1（EAP=Stop 下 Write-Error 会抛，故用 -ErrorAction Continue + exit）
function Fail([string]$Msg) {
    Write-Error $Msg -ErrorAction Continue
    Write-CmdLog -Script 'Set-BmcStaticIp' -State End -Result ("FAIL: " + $Msg) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# IPv4 合法性：正则 + 每段 ≤255
function Test-Ipv4Address([string]$Value) {
    if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($o in ($Value -split '\.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# 十六进制字节串（如 "ff ff ff 00" / "0a 00 00 0a"）→ 点分十进制；非 4 字节原样返回
function Convert-ToDottedIp([string]$Value) {
    $v = $Value.Trim()
    if ($v -match '^[0-9a-fA-F]{1,2}( [0-9a-fA-F]{1,2}){3}$') {
        $parts = $v -split '\s+'
        return [string]::Join('.', ($parts | ForEach-Object { [Convert]::ToInt32($_, 16).ToString() }))
    }
    return $v
}

# 复用 Invoke-IpmiProbe 的安全包装：EAP=Stop 下原生 stderr（如本机无 IPMI 驱动）会升级为终止错误，
# 统一转为 Code=1 结果（stdout/stderr 分离逻辑不在此重复），保证任何失败都走 Fail 流程而非抛未捕获异常。
function Probe([string[]]$CmdArgs) {
    try { return Invoke-IpmiProbe -IpmiTool $IpmiUtil -IpmiArgs $CmdArgs }
    catch { return [PSCustomObject]@{ Out = @(); Err = @($_.Exception.Message); Code = 1 } }
}

# 读现状：ipmiutil lan -c 1（本地接口），解析 Lan Param(3) IP / (4) 源 / (5) MAC / (6) 掩码
function Get-LanConfig {
    $r = Probe @('lan', '-c', '1')
    $ip = ''; $src = ''; $mac = ''; $mask = ''
    foreach ($l in $r.Out) {
        if ($l -match 'Lan Param\(3\) IP address:\s*(.+?)\s*$') { $ip = $matches[1].Trim() }
        elseif ($l -match 'Lan Param\(4\) IP addr src:\s*(.+?)\s*$') { $src = $matches[1].Trim() }
        elseif ($l -match 'Lan Param\(5\) MAC addr:\s*(.+?)\s*$') { $mac = $matches[1].Trim() }
        elseif ($l -match 'Lan Param\(6\) Subnet mask:\s*(.+?)\s*$') { $mask = $matches[1].Trim() }
    }
    return [PSCustomObject]@{ Code = $r.Code; Out = $r.Out; Err = $r.Err; Ip = $ip; Src = $src; Mac = $mac; Mask = $mask }
}

# 执行一条 ipmiutil 命令并打印输出（过程提示；输出形态不同版本有差异，不作为最终判据）
function Invoke-Raw([string[]]$CmdArgs, [string]$StepLabel) {
    Write-Host ("→ " + $StepLabel)
    $r = Probe $CmdArgs
    foreach ($l in $r.Out) { Write-Host ("   " + $l) }
    foreach ($l in $r.Err) { Write-Host ("   [stderr] " + $l) }
}

try {
    # ---- Step 2: 参数校验 + 工具发现 ----
    if (-not (Test-Ipv4Address $Ip)) { Fail ("参数非法: -Ip '$Ip' 不是合法 IPv4 地址（每段 0-255）") }
    if (-not (Test-Ipv4Address $Mask)) { Fail ("参数非法: -Mask '$Mask' 不是合法 IPv4 掩码（每段 0-255）") }
    $gatewaySet = $false
    $gatewayHex = @()
    if ($Gateway -ne "" -and $Gateway -ne "0.0.0.0") {
        if (-not (Test-Ipv4Address $Gateway)) { Fail ("参数非法: -Gateway '$Gateway' 不是合法 IPv4 地址（每段 0-255）") }
        $gatewaySet = $true
        $gatewayHex = @([System.Net.IPAddress]::Parse($Gateway).GetAddressBytes() | ForEach-Object { $_.ToString('x2') })
    }

    if ($IpmiUtil -eq "") {
        $IpmiUtil = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\ipmiutil-win64\ipmiutil.exe'
    }
    if (-not (Test-Path -LiteralPath $IpmiUtil)) {
        Fail ("工具缺失: 未找到 '$IpmiUtil'。tools\ipmiutil-win64 需整个目录拷贝（ipmiutil.exe + libcrypto-3-x64.dll + libssl-3-x64.dll），只拷 exe 会报 DLL 缺失")
    }

    # ---- Step 3: 读现状（写前读）----
    $cur = Get-LanConfig
    if ($cur.Ip -eq "") {
        $detail = ($cur.Err -join ' | ')
        if (-not $detail) { $detail = ($cur.Out -join ' | ') }
        Fail ("无法读取 BMC LAN 配置（ipmiutil lan -c 1 未解析到 IP，返回码 " + $cur.Code + "）: " + $detail)
    }
    $srcCode = ''
    if ($cur.Src -match '^(\d+)') { $srcCode = $matches[1] }
    if ($srcCode -eq '01') { $verdict = '正常（静态）' }
    else { $verdict = '需恢复（当前非静态: ' + $(if ($cur.Src) { $cur.Src } else { '未知' }) + '）' }
    $curIpDisp = $(if ($cur.Ip) { Convert-ToDottedIp $cur.Ip } else { '(未解析)' })

    Write-Host ""
    Write-Host "===== BMC 静态 IP 现状（本地接口 lan -c 1） ====="
    Write-Host ("IP 地址 : " + $curIpDisp)
    Write-Host ("IP 源   : " + $(if ($cur.Src) { $cur.Src } else { '(未解析)' }))
    Write-Host ("MAC     : " + $(if ($cur.Mac) { $cur.Mac } else { '(未解析)' }))
    Write-Host ("判定    : " + $verdict)

    if ($CheckOnly) {
        Write-CmdLog -Script 'Set-BmcStaticIp' -State End -Result ("OK(CheckOnly): IP=" + $curIpDisp + " 源=" + $(if ($cur.Src) { $cur.Src } else { '?' }) + " 判定=" + $verdict) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 0
    }

    # ---- Step 4: 写路径（docs/21 §5.2 raw 命令序列；输出不作为判据，回读兜底为准）----
    $ipHex = @([System.Net.IPAddress]::Parse($Ip).GetAddressBytes() | ForEach-Object { $_.ToString('x2') })
    $maskHex = @([System.Net.IPAddress]::Parse($Mask).GetAddressBytes() | ForEach-Object { $_.ToString('x2') })

    Write-Host ""
    Write-Host "===== 恢复 BMC 静态 IP ====="
    Write-Host ("目标: IP=" + $Ip + " 掩码=" + $Mask + $(if ($gatewaySet) { " 网关=" + $Gateway } else { " 网关=跳过" }))
    Write-Host "（每条 raw 命令输出仅作过程提示，成败以回读校验为准）"

    # ① 验证 raw 通道（Get LAN 参数；若报 c7 数据长度无效，可加 set selector 字节 00）
    Invoke-Raw @('cmd','00','20','30','02','01','03','00') "① 验证 raw 通道: cmd 00 20 30 02 01 03 00"
    # ② 设置 IP 源 = 静态 (01)   ← 成功标志：len=1
    Invoke-Raw @('cmd','00','20','30','01','01','04','01') "② 设置 IP 源=静态(01): cmd 00 20 30 01 01 04 01（期望 len=1）"
    # ③ 设置 IP（大端字节序）
    Invoke-Raw (@('cmd','00','20','30','01','01','03') + $ipHex) ("③ 设置 IP=" + $Ip + ": cmd 00 20 30 01 01 03 " + ($ipHex -join ' '))
    # ④ 设置掩码
    Invoke-Raw (@('cmd','00','20','30','01','01','06') + $maskHex) ("④ 设置掩码=" + $Mask + ": cmd 00 20 30 01 01 06 " + ($maskHex -join ' '))
    # ⑤ 网关（仅当设置；0.0.0.0/空跳过，BMC 返回 d5 属正常）
    if ($gatewaySet) {
        Invoke-Raw (@('cmd','00','20','30','01','01','0c') + $gatewayHex) ("⑤ 设置网关=" + $Gateway + ": cmd 00 20 30 01 01 0c ...（返回 d5 属正常，可忽略）")
    }

    # ⑥ 回读兜底判据：lan -c 1 核对 IP/源/掩码
    Write-Host "⑥ 回读校验: ipmiutil lan -c 1"
    $after = Get-LanConfig
    if ($after.Ip -eq "") {
        $detail = ($after.Err -join ' | ')
        if (-not $detail) { $detail = ($after.Out -join ' | ') }
        Fail ("回读失败: lan -c 1 未解析到 IP（返回码 " + $after.Code + "）: " + $detail)
    }
    $srcCodeAfter = ''
    if ($after.Src -match '^(\d+)') { $srcCodeAfter = $matches[1] }
    $readIp = Convert-ToDottedIp $after.Ip
    $readMask = ''
    if ($after.Mask) { $readMask = Convert-ToDottedIp $after.Mask }

    $issues = @()
    if ($readIp -ne $Ip) { $issues += ("IP 不符: 期望 " + $Ip + "，回读 " + $(if ($readIp) { $readIp } else { '(未解析)' })) }
    if ($srcCodeAfter -ne '01') { $issues += ("IP 源非静态: 期望 01，回读 " + $(if ($after.Src) { $after.Src } else { '(未解析)' })) }
    if ($readMask -ne $Mask) { $issues += ("掩码不符: 期望 " + $Mask + "，回读 " + $(if ($readMask) { $readMask } else { '(未解析)' })) }
    if ($issues.Count -gt 0) {
        Fail ("回读校验未通过: " + ($issues -join '；'))
    }
    Write-Host ("回读校验通过: IP=" + $readIp + " 源=" + $after.Src + " 掩码=" + $readMask)

    # ⑦ -ColdReset → 自动冷复位 BMC；否则提示人工确认时机后手动执行
    if ($ColdReset) {
        Write-Host ""
        Write-Host "⑦ 冷复位 BMC 让配置生效（服务器会短暂息屏 1~2 分钟，属正常）: ipmiutil reset -c"
        $rr = Probe @('reset', '-c')
        foreach ($l in $rr.Out) { Write-Host ("   " + $l) }
        foreach ($l in $rr.Err) { Write-Host ("   [stderr] " + $l) }
        $resetNote = " 已冷复位"
    } else {
        Write-Host ""
        Write-Host "提示: 配置已写入并通过回读校验。BMC 需冷复位才生效（服务器会短暂息屏 1~2 分钟）——确认时机后手动执行:"
        Write-Host ("  " + $IpmiUtil + " reset -c")
        $resetNote = " 未冷复位（待人工执行 reset -c）"
    }

    Write-CmdLog -Script 'Set-BmcStaticIp' -State End -Result ("OK: IP=" + $Ip + " 掩码=" + $Mask + " 回读通过" + $resetNote) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Fail ("未预期异常: " + $_.Exception.Message)
}
