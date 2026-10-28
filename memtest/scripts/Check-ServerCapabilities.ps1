# ============================================================================
# Check-ServerCapabilities.ps1
# 服务器测试能力检查：探测一台被测服务器能跑 17 项验收里的哪些项目。
# 角色自动识别：-BmcHost 给定时先按 BMC 可达性判定本机角色（编排机/被测服务器），
#   只跑对应探测块；未给 -BmcHost 时按被测服务器处理（只跑带内 CIM）。
#
# 角色判定（Test-BmcRole，mc info 默认→-C 3→-C 17 三套件探测）：
#   Orchestrator（BMC 可达）   → 编排机：跑带外（chassis status / sdr elist / sol）
#   Server（BMC 不可达）       → 被测服务器：跑带内 CIM（读本机硬件）
#   AuthError（凭据/权限失败） → 记编排机角色，但不逐个探测，如实报条件
#
# 执行规则：
#   带内跑 ⇔ -Local 显式给出，或角色=被测服务器（含未提供 -BmcHost 的默认场景）
#   带外跑 ⇔ -BmcHost 给出，且角色=编排机（AuthError/Server 不逐个探测）
#   密码：-BmcHost 给出且未提供 -BmcPass 时提示一次；亦可经管道提供（echo pw | ...）
#   Role 列取值 = 角色分类（编排机/被测服务器），与是否额外跑带内无关
#
# 用法（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Check-ServerCapabilities.ps1 -Local                    # 在服务器本机（Windows）跑
#   .\scripts\Check-ServerCapabilities.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>   # 编排机远程探测（自动判角色）
#   .\scripts\Check-ServerCapabilities.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -OutCsv cap.csv
#   ... -VerifyPowerCycle   # 实测断电循环验证（仅编排机执行；开关本身即同意，不二次确认）
# ============================================================================

param(
    [switch]$Local,              # 带内：本机是/已进被测服务器（Windows），执行 CIM 探测
    [string]$BmcHost = "",       # 带外：BMC 管理 IP（走 ipmitool）；给出时先自动判角色
    [string]$BmcUser = "",
    [string]$BmcPass = "",
    [string]$IpmiTool = "ipmitool",
    [string]$OutCsv = "",        # 可选：输出能力报告 CSV
    [switch]$VerifyPowerCycle    # 实测断电循环验证：下发 chassis power cycle 观察掉电跳变（仅编排机，开关即同意）
)

$ErrorActionPreference = 'Stop'

# 共享库（Read-BmcPass / Invoke-IpmiProbe / Test-BmcRole 等公共逻辑）
. $PSScriptRoot\lib_common.ps1

# 管道密码优先：脚本顶层 $input 可读外部管道（Read-BmcPass 的函数作用域内读不到，故在此先消费，
# 否则 -File 模式管道场景会落入 Read-Host 等待控制台而挂起）。
$pipeIn = @($input)
if ($BmcPass -eq "" -and $pipeIn.Count -gt 0) { $BmcPass = [string]$pipeIn[0] }

# ---- 内置 ipmitool 自动发现（与 Run-MemtestSuite 一致） ----
if ($IpmiTool -eq "ipmitool") {
    $bundled = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\ipmitool\ipmitool.exe"
    if (Test-Path -LiteralPath $bundled) { $IpmiTool = $bundled }
}

# ---------------------------------------------------------------------------
# 角色判定（Test-BmcRole）
# ---------------------------------------------------------------------------
$role = 'Server'
$roleDetail = "未提供 -BmcHost"
$cipherArgs = @()
$bmcVendor = ""
if ($BmcHost -ne "") {
    if (-not (Test-Path -LiteralPath $IpmiTool)) {
        $role = 'Server'
        $roleDetail = "ipmitool 不可用: $IpmiTool"
    } else {
        # 密码：带外判定需 BMC 密码而调用方未显式提供 → 管道/交互提示一次（置于参数拼装之前）
        if (-not $BmcPass) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }
        $base = @("-I", "lanplus", "-H", $BmcHost)
        if ($BmcUser) { $base += @("-U", $BmcUser) }
        if ($BmcPass) { $base += @("-P", $BmcPass) }
        # EAP=Stop 会把原生命令 stderr 升级为终止错误，破坏 Invoke-IpmiProbe 的 Err 捕获与
        # Test-BmcRole 三套件归因；此处临时切 Continue，判定完恢复。
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $rr = Test-BmcRole -IpmiTool $IpmiTool -IpmiArgsBase $base
            $role = $rr.Role
            $roleDetail = $rr.Detail
            $cipherArgs = $rr.CipherArgs
            $bmcVendor = $rr.BmcVendor
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }
}

# Role 列取值 = 角色分类结果（编排机/被测服务器），与是否额外跑带内无关
$roleLabel = if ($role -in @('Orchestrator', 'AuthError')) { "编排机" } else { "被测服务器" }
# 带内跑 ⇔ -Local 给出 或 角色=Server；带外逐项探测仅角色=Orchestrator 执行
$runInband = ($Local) -or ($role -eq 'Server')
$runOob = ($BmcHost -ne "") -and ($role -eq 'Orchestrator')

# 防护提示（spec §3.1）：-BmcHost 给出但本机被判为被测服务器（BMC 不可达）→
# 本机可能实为编排机，跑带内的同时输出提示提醒检查网络路径
if ($BmcHost -ne "" -and $role -eq 'Server') {
    Write-Warning "若本机实为编排机且 BMC 应可达，请检查网络路径"
}

# ---------------------------------------------------------------------------
# 带内探测（CIM）
# ---------------------------------------------------------------------------
$in = [ordered]@{
    MemorySlotsUsed = 0
    MemorySlotsTotal = 0
    MemoryType = ""
    CapacityGB = 0
    SpeedMTs = 0
    IsEcc = $false
    CpuVendor = ""
    SecureBoot = ""
    Error = ""
}
if ($runInband) {
    try {
        $mem = @(Get-CimInstance -ClassName Win32_PhysicalMemory)
        $in.MemorySlotsUsed = $mem.Count
        $totalSlots = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty MemoryDevices
        $in.MemorySlotsTotal = if ($totalSlots) { [int]$totalSlots } else { $mem.Count }
        if ($mem.Count -gt 0) {
            $cap = 0; $spd = 0; $ecc = $false
            foreach ($m in $mem) {
                $cap += [int64]$m.Capacity
                $spd = [math]::Max($spd, [int64]$m.Speed)
                if ([int64]$m.TotalWidth -gt [int64]$m.DataWidth) { $ecc = $true }   # 72 vs 64 = ECC
            }
            $in.CapacityGB = [math]::Round($cap / 1GB)
            $in.SpeedMTs = $spd
            $in.IsEcc = $ecc
            $in.MemoryType = switch ($mem[0].SMBIOSMemoryType) {
                26 { "DDR4" }; 34 { "DDR5" }; 35 { "LPDDR5" }; default { "Type$($mem[0].SMBIOSMemoryType)" }
            }
        }
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $in.CpuVendor = $cpu.Manufacturer
        try { $in.SecureBoot = if (Confirm-SecureBootUEFI) { "已启用" } else { "未启用" } } catch { $in.SecureBoot = "未知/不支持" }
    } catch { $in.Error = $_.Exception.Message }
}

# ---------------------------------------------------------------------------
# 带外探测（BMC/IPMI，仅角色=编排机；AuthError/Server 不逐个探测）
# ---------------------------------------------------------------------------
$oob = [ordered]@{
    BmcPresent = $false
    BmcVendor = ""
    SolAvailable = $false
    PowerCycleCapable = $false
    HasTempSensors = $false
    Error = ""
}
# 统一执行 ipmitool 见共享库 Invoke-IpmiProbe（stdout/stderr 分离 + 退出码）。
# 生效参数复用角色判定的 CipherArgs（含 -C N 兜底）。
if ($runOob) {
    $oob.BmcPresent = $true
    $oob.BmcVendor = $bmcVendor
    # EAP 守卫：顶层 EAP=Stop 会把原生命令 stderr 升级为终止错误，破坏 Invoke-IpmiProbe 的
    # {Out;Err;Code} 捕获并让单个探测失败塌缩整块（丢 SolAvailable/HasTempSensors 三态归因）；
    # 与验证块同款：临时切 Continue，finally 恢复。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 断电循环能力：chassis status 能返回即具备 chassis 控制
        $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @("chassis", "status"))
        if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
            $oob.PowerCycleCapable = $true
        } else {
            $oob.Error = [string]::Join(' | ', (@($oob.Error, "chassis status 失败[$($r.Err -join ' | ')]") | Where-Object { $_ }))
        }

        # 温度传感器：sdr elist 能列出即具备（含 DIMM 温度则更好）
        $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @("sdr", "elist"))
        if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
            $oob.HasTempSensors = ($r.Out | Where-Object { $_ -match 'degrees C' }).Count -gt 0
        } else {
            $oob.Error = [string]::Join(' | ', (@($oob.Error, "sdr elist 失败[$($r.Err -join ' | ')]") | Where-Object { $_ }))
        }

        # SOL 可用性：短探测（启动会话 ~6 秒，有输出即可用；无输出/立刻失败=未启用）
        $solOut = Join-Path $env:TEMP ("sol_probe_" + [guid]::NewGuid().ToString("N") + ".txt")
        $p = Start-Process -FilePath $IpmiTool -ArgumentList ($cipherArgs + @("sol", "activate")) `
                -RedirectStandardOutput $solOut -RedirectStandardError "$solOut.err" -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 6
        $hasOut = (Test-Path $solOut) -and ((Get-Item $solOut).Length -gt 0)
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 500
        # 释放 SOL 通道：探测强杀进程后 BMC 可能残留 payload（报 "already active"），主动 sol deactivate（失败忽略）
        & $IpmiTool @($cipherArgs + @("sol", "deactivate")) 2>$null | Out-Null
        if ($hasOut) { $oob.SolAvailable = $true }
        Remove-Item $solOut, "$solOut.err" -Force -ErrorAction SilentlyContinue
    } catch { $oob.Error = [string]::Join(' | ', (@($oob.Error, $_.Exception.Message) | Where-Object { $_ })) }
    finally { $ErrorActionPreference = $prevEap }
}

# ---------------------------------------------------------------------------
# 实测断电循环验证（仅编排机 + -VerifyPowerCycle；开关本身即同意，不再二次确认）
# 序列：baseline(chassis power status) → 下发 cycle → 轮询观察 off→on → 收尾确认
# ---------------------------------------------------------------------------
$verifyItem10 = $null
if ($runOob -and $VerifyPowerCycle) {
    # 共用电源风险警示（不阻断；-VerifyPowerCycle 开关本身即同意，见 spec §4.6）
    Write-PowerCycleWarning

    # EAP 守卫：顶层 EAP=Stop 会把原生命令 stderr 升级为终止错误，破坏逐调用 {Out;Err;Code}
    # 捕获；验证逻辑内所有 Invoke-IpmiProbe 调用统一临时切 Continue，finally 恢复。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # baseline：服务器必须当前开机，否则中止（绝不发 cycle）
        $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @('chassis', 'power', 'status'))
        if ($r.Code -ne 0 -or ($r.Out -join ' ') -notmatch '\bon\b') {
            $verifyItem10 = '条件: 服务器当前关机，无法验证断电循环（请先开机）'
        } else {
            # 下发断电循环
            $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @('chassis', 'power', 'cycle'))
            if ($r.Code -ne 0 -or ($r.Out -join ' ') -notmatch 'Cycle') {
                $verifyItem10 = "条件: BMC 通但断电循环命令不可用($($r.Err -join ' | '))"
            } else {
                # 轮询：每 1s，窗口 30s；任一次含 off 记 observedOff，先 off 再见 on 即完成，提前结束
                $observedOff = $false
                for ($i = 0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 1
                    $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @('chassis', 'power', 'status'))
                    $st = ($r.Out -join ' ')
                    if ($st -match 'off') { $observedOff = $true }
                    if ($observedOff -and $st -match '\bon\b') { break }
                }
                # 收尾：确认 BMC 仍响应且已回到开机（spec §3.2 第 5 步是验证的一部分）。
                # 仅当收尾 Code=0 且输出含 on 才判"已验证"，否则回落人工确认文案，
                # 避免 power cycle 后服务器持续 off 仍被谎报为已验证。
                $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($cipherArgs + @('chassis', 'power', 'status'))
                if ($observedOff -and $r.Code -eq 0 -and (($r.Out -join ' ') -match '\bon\b')) {
                    $verifyItem10 = '可测(已验证：实测断电重启成功)'
                } else {
                    $verifyItem10 = '可测(命令已接受，未观察到掉电跳变，断电窗口极短，建议人工确认一次)'
                }
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# ---------------------------------------------------------------------------
# 汇总为 17 项可行性
# ---------------------------------------------------------------------------
# 项 1-17 名称与判定（带内数据决定可测性；带外决定通道；6-9,11-14 固定外包）
$in.CapacityGB = if ($in.CapacityGB) { $in.CapacityGB } else { 0 }
$canMem = ($in.MemorySlotsUsed -gt 0)      # 已识别到内存
$canEcc = $canMem -and $in.IsEcc
$canPower = $oob.PowerCycleCapable         # BMC 可断电循环
$canSol = $oob.SolAvailable
$canOrt = $canPower -and $oob.HasTempSensors   # ORT 72h：能持续供电满载 + 测温

# 第 5/10 项三态文案（角色优先；其余 15 项状态文案保持现状）
$item5 = if ($role -eq 'Server') { "需编排机($roleDetail)" }
         elseif ($role -eq 'AuthError') { "条件: $roleDetail" }
         elseif ($canPower -and $oob.HasTempSensors) { "可测(需满载72h)" }
         elseif ($canPower) { "条件: 需测温传感器" }
         else { "条件: BMC 通但断电循环命令不可用($oob.Error)" }
$item10 = if ($null -ne $verifyItem10) { $verifyItem10 }
          elseif ($role -eq 'Server') { "需编排机($roleDetail)" }
          elseif ($role -eq 'AuthError') { "条件: $roleDetail" }
          elseif ($canPower) { "可测(IPMI 断电循环)" }
          else { "条件: BMC 通但断电循环命令不可用($oob.Error)" }

$items = @(
    [PSCustomObject]@{ Item = 1;  Name = "SPD 信息校验";          Status = if ($canMem) { "可测" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 2;  Name = "基础识别/容量频率读取";  Status = if ($canMem) { "可测" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 3;  Name = "全地址读写覆盖(Memtest)"; Status = if ($canMem) { "可测(引导 Memtest86+)" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 4;  Name = "ECC 纠错功能验证";      Status = if ($canEcc) { "可测(ECC 平台)" } elseif ($canMem) { "条件：内存非 ECC" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 5;  Name = "72h ORT 老化烧机";      Status = $item5; Role = $roleLabel }
    [PSCustomObject]@{ Item = 6;  Name = "电压裕量";              Status = "外包(可编程电源+示波器)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 7;  Name = "时序/SI";               Status = "外包(≥20GHz 示波器)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 8;  Name = "高低温循环";            Status = "外包(高低温箱)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 9;  Name = "THB 湿热偏压";          Status = "外包(恒温恒湿箱)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 10; Name = "反复上电掉电循环";      Status = $item10; Role = $roleLabel }
    [PSCustomObject]@{ Item = 11; Name = "静电 ESD";              Status = "外包(静电枪)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 12; Name = "机械振动";              Status = "外包(振动台)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 13; Name = "机械冲击";              Status = "外包(冲击台)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 14; Name = "弯曲扭曲";              Status = "外包(治具)"; Role = $roleLabel }
    [PSCustomObject]@{ Item = 15; Name = "多平台兼容";            Status = if ($in.CpuVendor) { "可测(本机=$($in.CpuVendor))；另一平台需再接入" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 16; Name = "多通道混插压力";        Status = if ($in.MemorySlotsUsed -ge 2) { "可测(已用 $($in.MemorySlotsUsed) 槽)" } elseif ($canMem) { "条件：插满≥2根" } else { "需带内(进OS)" }; Role = $roleLabel }
    [PSCustomObject]@{ Item = 17; Name = "外观/焊点/电性复检";    Status = "可测(人工目检+万用表)"; Role = $roleLabel }
)

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
# 控制台首行角色
$roleLine = switch ($role) {
    'Orchestrator' { "角色: 编排机(BMC $BmcHost 可达)" }
    'AuthError'    { "角色: 编排机(BMC $BmcHost 可达，凭据/权限失败)" }
    default        { "角色: 被测服务器($roleDetail)" }
}
Write-Host $roleLine
Write-Host "===== 服务器测试能力检查 ====="
Write-Host ("带内: {0} | 带外BMC: {1}" -f $(if ($runInband) { "本机已探测" } else { "未执行(加 -Local 在本机跑)" }), $(if (-not $BmcHost) { "未指定" } elseif ($role -eq 'Orchestrator') { "$BmcHost ($bmcVendor)" } elseif ($role -eq 'AuthError') { "$BmcHost (凭据/权限失败)" } else { "$BmcHost (BMC 不可达)" }))
Write-Host ("内存: {0} 槽/{1} 槽 · {2} · {3}GB · {4}MT/s · ECC={5}" -f $in.MemorySlotsUsed, $in.MemorySlotsTotal, $in.MemoryType, $in.CapacityGB, $in.SpeedMTs, $in.IsEcc)
Write-Host ("CPU: {0} · SecureBoot: {1}" -f $in.CpuVendor, $in.SecureBoot)
Write-Host ("BMC: SOL={0} · 断电循环={1} · 测温={2}" -f $oob.SolAvailable, $oob.PowerCycleCapable, $oob.HasTempSensors)
if ($in.Error) { Write-Warning "带内探测错误: $($in.Error)" }
if ($oob.Error) { Write-Warning "带外探测错误: $($oob.Error)" }
Write-Host ""
Write-Host "17 项测试可行性："
$items | Format-Table Item, Name, Status -AutoSize

if ($OutCsv) {
    $items | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Host "能力报告已保存: $OutCsv"
}
