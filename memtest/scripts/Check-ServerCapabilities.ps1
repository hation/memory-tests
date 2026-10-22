# ============================================================================
# Check-ServerCapabilities.ps1
# 服务器测试能力检查：探测一台被测服务器能跑 17 项验收里的哪些项目。
#
# 原理（带内 + 带外双重探测）：
#   带内（-Local，在服务器本机/已进 OS 时）：CIM 读内存槽数/ECC/类型/频率/
#     CPU 平台/Secure Boot → 决定项 1,2,3,4,15,16
#   带外（-BmcHost，编排机走 BMC/IPMI）：mc info / chassis status / sdr elist /
#     sol activate 短探测 → 决定项 5,10 与 SOL 通道可用性
#   固定外包项（6,7,8,9,11,12,13,14）：与服务器无关，恒为外包
#
# 用法：
#   .\Check-ServerCapabilities.ps1 -Local                    # 在服务器本机（Windows）跑
#   .\Check-ServerCapabilities.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>   # 编排机远程探测
#   .\Check-ServerCapabilities.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -OutCsv cap.csv
# ============================================================================

param(
    [switch]$Local,              # 带内：本机是/已进被测服务器（Windows），执行 CIM 探测
    [string]$BmcHost = "",       # 带外：BMC 管理 IP（走 ipmitool）
    [string]$BmcUser = "",
    [string]$BmcPass = "",
    [string]$IpmiTool = "ipmitool",
    [string]$OutCsv = ""         # 可选：输出能力报告 CSV
)

$ErrorActionPreference = 'Stop'

# 共享库（Read-BmcPass / Invoke-IpmiProbe 等公共逻辑）
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
if ($Local) {
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
# 带外探测（BMC/IPMI）
# ---------------------------------------------------------------------------
$oob = [ordered]@{
    BmcPresent = $false
    BmcVendor = ""
    SolAvailable = $false
    PowerCycleCapable = $false
    HasTempSensors = $false
    Error = ""
}
# 统一执行 ipmitool 见共享库 Invoke-IpmiProbe（stdout/stderr 分离 + 退出码，供诊断与 -C 3 兜底复用）
if ($BmcHost -ne "" -and (Test-Path -LiteralPath $IpmiTool)) {
    # 密码：带外探测需 BMC 密码而调用方未显式提供 → 管道/交互提示一次（置于 $a 拼装之前）
    if (-not $BmcPass) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }
    try {
        $a = @("-I", "lanplus", "-H", $BmcHost)
        if ($BmcUser) { $a += @("-U", $BmcUser) }
        if ($BmcPass) { $a += @("-P", $BmcPass) }

        # mc info：先默认加密套件；失败自动回退 -C 3（部分 BMC 默认套件不匹配，最常见原因）
        $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($a + @("mc", "info"))
        if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
            $oob.BmcPresent = $true
            $oob.BmcVendor = (($r.Out | Where-Object { $_ -match 'Manufacturer\s*:\s*(.+)' }) | Select-Object -First 1) -replace '.*:\s*', ''
        } else {
            $errDefault = ($r.Err -join ' | ')
            $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($a + @("-C", "3", "mc", "info"))
            if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
                $oob.BmcPresent = $true
                $oob.BmcVendor = (($r.Out | Where-Object { $_ -match 'Manufacturer\s*:\s*(.+)' }) | Select-Object -First 1) -replace '.*:\s*', ''
                $a += @("-C", "3")   # -C 3 有效，后续 chassis/sdr/sol 复用
            } else {
                $oob.Error = "BMC 连接失败(mc info)：默认套件[$errDefault]；-C 3 套件[$($r.Err -join ' | ')]"
            }
        }

        # 仅 BMC 已连通才继续探测单项能力（连不上时 5/10 判「需 BMC」，把真实报错亮出来）
        if ($oob.BmcPresent) {
            # 断电循环能力：chassis status 能返回即具备 chassis 控制
            $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($a + @("chassis", "status"))
            if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
                $oob.PowerCycleCapable = $true
            } else {
                $oob.Error = [string]::Join(' | ', (@($oob.Error, "chassis status 失败[$($r.Err -join ' | ')]") | Where-Object { $_ }))
            }

            # 温度传感器：sdr elist 能列出即具备（含 DIMM 温度则更好）
            $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs @($a + @("sdr", "elist"))
            if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
                $oob.HasTempSensors = ($r.Out | Where-Object { $_ -match 'degrees C' }).Count -gt 0
            } else {
                $oob.Error = [string]::Join(' | ', (@($oob.Error, "sdr elist 失败[$($r.Err -join ' | ')]") | Where-Object { $_ }))
            }

            # SOL 可用性：短探测（启动会话 ~6 秒，有输出即可用；无输出/立刻失败=未启用）
            $solOut = Join-Path $env:TEMP ("sol_probe_" + [guid]::NewGuid().ToString("N") + ".txt")
            $p = Start-Process -FilePath $IpmiTool -ArgumentList ($a + @("sol", "activate")) `
                    -RedirectStandardOutput $solOut -RedirectStandardError "$solOut.err" -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 6
            $hasOut = (Test-Path $solOut) -and ((Get-Item $solOut).Length -gt 0)
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            Start-Sleep -Milliseconds 500
            if ($hasOut) { $oob.SolAvailable = $true }
            Remove-Item $solOut, "$solOut.err" -Force -ErrorAction SilentlyContinue
        }
    } catch { $oob.Error = [string]::Join(' | ', (@($oob.Error, $_.Exception.Message) | Where-Object { $_ })) }
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

$items = @(
    [PSCustomObject]@{ Item = 1;  Name = "SPD 信息校验";          Status = if ($canMem) { "可测" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 2;  Name = "基础识别/容量频率读取";  Status = if ($canMem) { "可测" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 3;  Name = "全地址读写覆盖(Memtest)"; Status = if ($canMem) { "可测(引导 Memtest86+)" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 4;  Name = "ECC 纠错功能验证";      Status = if ($canEcc) { "可测(ECC 平台)" } elseif ($canMem) { "条件：内存非 ECC" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 5;  Name = "72h ORT 老化烧机";      Status = if ($canOrt) { "可测(需满载72h)" } elseif ($oob.BmcPresent) { "条件：需测温传感器" } else { "需 BMC" } }
    [PSCustomObject]@{ Item = 6;  Name = "电压裕量";              Status = "外包(可编程电源+示波器)" }
    [PSCustomObject]@{ Item = 7;  Name = "时序/SI";               Status = "外包(≥20GHz 示波器)" }
    [PSCustomObject]@{ Item = 8;  Name = "高低温循环";            Status = "外包(高低温箱)" }
    [PSCustomObject]@{ Item = 9;  Name = "THB 湿热偏压";          Status = "外包(恒温恒湿箱)" }
    [PSCustomObject]@{ Item = 10; Name = "反复上电掉电循环";      Status = if ($canPower) { "可测(IPMI 断电循环)" } else { "需 BMC" } }
    [PSCustomObject]@{ Item = 11; Name = "静电 ESD";              Status = "外包(静电枪)" }
    [PSCustomObject]@{ Item = 12; Name = "机械振动";              Status = "外包(振动台)" }
    [PSCustomObject]@{ Item = 13; Name = "机械冲击";              Status = "外包(冲击台)" }
    [PSCustomObject]@{ Item = 14; Name = "弯曲扭曲";              Status = "外包(治具)" }
    [PSCustomObject]@{ Item = 15; Name = "多平台兼容";            Status = if ($in.CpuVendor) { "可测(本机=$($in.CpuVendor))；另一平台需再接入" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 16; Name = "多通道混插压力";        Status = if ($in.MemorySlotsUsed -ge 2) { "可测(已用 $($in.MemorySlotsUsed) 槽)" } elseif ($canMem) { "条件：插满≥2根" } else { "需带内(进OS)" } }
    [PSCustomObject]@{ Item = 17; Name = "外观/焊点/电性复检";    Status = "可测(人工目检+万用表)" }
)

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
Write-Host "===== 服务器测试能力检查 ====="
Write-Host ("带内: {0} | 带外BMC: {1}" -f $(if ($Local) { "本机已探测" } else { "未执行(加 -Local 在本机跑)" }), $(if ($BmcHost) { "$BmcHost ($($oob.BmcVendor))" } else { "未指定" }))
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
