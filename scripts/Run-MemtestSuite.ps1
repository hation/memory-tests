# ============================================================================
# Run-MemtestSuite.ps1
# Memtest86+ 自动化编排与压测报告汇总工具（Windows PowerShell）
#
# 定位：PowerShell 作为编排器 —— 引导 Memtest86+ 执行真正的内存测试，
#       捕获其输出日志（MTLOG 串口日志 / USB 报告 / EFI），解析并汇总到
#       批量压测报告（与 Identify-Memory.ps1 的 master_manifest.csv 关联）。
#
# 用法示例：
#   .\Run-MemtestSuite.ps1 -Help
#   .\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
#   .\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod Serial -SerialPort COM1 -BaudRate 115200 -MaxPasses 4
#   .\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod USB -UsbDrive E: -MaxPasses 4
#   .\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod USB -UsbDrive E: -UsbReportPrefix "MT86P_*" -MaxPasses 4
#   .\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod EFI -EfiImage D:\mt86plus.efi -MaxPasses 4 -ConfirmSwitch
#   .\Run-MemtestSuite.ps1 -ParseOnly -LogFile .\memory_results\raw\mtlog.txt -BatchName batch01
#
# 依赖（可选）：
#   - SOL 方式需 ipmitool.exe（Windows 版）或厂商 SOL 工具，位于 PATH 或 -IpmiTool 指定
#   - Serial 方式需物理串口线连接服务器 COM 口
#   - USB 方式需 Memtest86+ v9（支持报告导出到 U 盘）
#   - EFI 方式需 UEFI 固件支持 bcdedit bootsequence
# ============================================================================

#requires -Version 5.1

param(
    [string]$BatchName = "",

    [ValidateSet("SOL", "USB", "EFI", "Serial")]
    [string]$BootMethod = "SOL",

    # SOL 方式参数
    [string]$BmcHost = "",
    [string]$BmcUser = "",
    [string]$BmcPass = "",
    [string]$IpmiTool = "ipmitool",

    # Serial 直连串口方式参数（物理串口线直连，完全离线）
    [string]$SerialPort = "COM1",
    [int]$BaudRate = 115200,

    # USB 方式参数
    [string]$UsbDrive = "",
    [string]$UsbReportPrefix = "MT86P_*",   # 报告文件前缀（Memtest86+ 保存为 MT86P_NN.TXT）

    # EFI 方式参数
    [string]$EfiImage = "",
    [string]$EfiBootId = "memtest86plus",

    # Memtest86+ 引导参数
    [int]$MaxPasses = 4,
    [string]$TestList = "",            # 如 "0,1,2,3"；空 = 全部
    [string]$SerialParam = "ttyS0,115200",

    # 识别与监控
    [string]$ExpectedCsv = "",
    [switch]$MonitorEcc,
    [switch]$MonitorTemp,              # 可选：SOL 方式下通过 IPMI 读取温度传感器

    # 重启循环（批次切换）
    [int]$RestartLoop = 0,

    # 输出
    [string]$LogPath = "",
    [switch]$ParseOnly,
    [string]$LogFile = "",             # ParseOnly 模式：待解析的原始日志/报告文件
    [switch]$ConfirmSwitch,
    [switch]$Help
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（识别/解析等公共逻辑，入库后统一抽取到 lib_common.ps1）
. $PSScriptRoot\lib_common.ps1

if ($Help) {
    Write-Host @"
Memtest86+ 自动化编排与压测报告汇总工具
-----------------------------------------
参数：
  -BatchName      批次名（缺省按时间戳），用于文件名与归集
  -BootMethod     SOL | Serial | USB | EFI（默认 SOL）
  SOL 方式（BMC/IPMI，全自动）：
  -BmcHost/-BmcUser/-BmcPass   BMC 连接参数
  -IpmiTool       ipmitool 路径（默认 PATH 中 ipmitool）
  Serial 方式（物理串口线直连，完全离线）：
  -SerialPort     串口端口（默认 COM1）
  -BaudRate       波特率（默认 115200，须与服务器端一致）
  USB 方式（半自动，需人工插拔 U 盘；测完按 F1→6 保存报告）：
  -UsbDrive       U 盘盘符（报告导出目录，如 E:）
  -UsbReportPrefix 报告文件前缀（默认 MT86P_*）
  EFI 方式（一次性引导，需配合 Serial/USB 取日志）：
  -EfiImage       mt86plus.efi 路径
  -EfiBootId      临时引导项描述（默认 memtest86plus）
  Memtest86+ 参数：
  -MaxPasses      轮数（默认 4，0=不限）
  -TestList       测试列表（如 0,1,2,3；空=全部）
  -SerialParam    串口参数（默认 ttyS0,115200）
  识别/监控：
  -ExpectedCsv    预期清单（复用 Identify-Memory.ps1 匹配）
  -MonitorEcc     同时监控 WHEA/ECC 事件
  -MonitorTemp    读取 IPMI 温度传感器（仅 SOL 方式）
  -RestartLoop    断电-上电循环次数（仅 SOL 方式，建议从控制机运行）
  输出：
  -LogPath        输出目录（默认 .\memory_results\）
  -ParseOnly     仅解析模式：配合 -LogFile 解析已有日志/报告
  -ConfirmSwitch  确认允许执行引导/重启/断电操作
用法示例：
  .\Run-MemtestSuite.ps1 -BootMethod SOL -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
  .\Run-MemtestSuite.ps1 -BootMethod Serial -SerialPort COM1 -BaudRate 115200 -MaxPasses 4
  .\Run-MemtestSuite.ps1 -BootMethod USB -UsbDrive E: -MaxPasses 4
  .\Run-MemtestSuite.ps1 -BootMethod EFI -EfiImage D:\mt86plus.efi -MaxPasses 4 -ConfirmSwitch
  .\Run-MemtestSuite.ps1 -ParseOnly -LogFile .\memory_results\raw\mtlog.txt
"@
    exit 0
}

if ($LogPath -eq "") { $LogPath = Join-Path $PSScriptRoot "memory_results" }
$rawDir   = Join-Path $LogPath "raw"
$reportDir = Join-Path $LogPath "reports"
foreach ($d in @($LogPath, $rawDir, $reportDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

if ($BatchName -eq "") { $BatchName = "batch_" + (Get-Date -Format "yyyyMMdd_HHmmss") }

# ----------------------------------------------------------------------------
# FR-3/FR-4 日志捕获与解析（解析器见共享库 lib_common.ps1）
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# FR-2/FR-3 三种引导与捕获
# ----------------------------------------------------------------------------

# SOL 方式：通过 BMC/IPMI SOL 抓取串口日志（全自动）
function Invoke-SolCapture {
    param(
        [string]$BmcHost, [string]$BmcUser, [string]$BmcPass,
        [string]$IpmiTool, [string]$OutFile, [int]$TimeoutMinutes
    )

    if (-not $ConfirmSwitch) {
        throw "SOL 方式涉及引导/重启，需加 -ConfirmSwitch 确认。"
    }

    $args = @("-I", "lanplus", "-H", $BmcHost)
    if ($BmcUser) { $args += @("-U", $BmcUser) }
    if ($BmcPass) { $args += @("-P", $BmcPass) }

    Write-Host "启动 ipmitool SOL 会话，输出到 $OutFile ..."
    $p = Start-Process -FilePath $IpmiTool -ArgumentList ($args + @("sol", "activate")) `
            -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err" -PassThru -WindowStyle Hidden

    # 等待 ev=done 出现（或超时）
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $done = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        if (Test-Path $OutFile) {
            if (Select-String -Path $OutFile -Pattern 'ev=done' -Quiet) { $done = $true; break }
        }
    }

    # 结束 SOL 会话
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    if (-not $done) {
        Write-Warning "SOL 捕获超时（$TimeoutMinutes 分钟），未收到 ev=done。"
    }
    return $done
}

# Serial 直连串口方式：物理串口线直连服务器 COM 口抓取 MTLOG（完全离线）
function Invoke-SerialCapture {
    param(
        [string]$SerialPortName, [int]$BaudRate,
        [string]$OutFile, [int]$TimeoutMinutes
    )

    Write-Host "打开串口 $SerialPortName @ $BaudRate，等待 Memtest86+ 输出 ..."
    Write-Host "提示：需先用 USB/EFI 方式把被测服务器引导进 Memtest86+，且其 log 打到物理串口 ttyS0"

    $port = New-Object System.IO.Ports.SerialPort($SerialPortName, $BaudRate, "None", 8, "One")
    $port.ReadTimeout = 3000
    $port.Open()

    $sw = New-Object System.IO.StreamWriter($OutFile, $true, [System.Text.Encoding]::UTF8)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $done = $false
    try {
        while ((Get-Date) -lt $deadline) {
            if (-not $port.IsOpen) { break }
            try {
                $line = $port.ReadLine()
            } catch {
                continue   # 读超时（ReadTimeout 3000ms），继续等
            }
            $sw.WriteLine($line)
            $sw.Flush()
            if ($line -match 'ev=done') { $done = $true; break }
        }
    } finally {
        $sw.Close()
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
    if (-not $done) {
        Write-Warning "串口捕获超时（$TimeoutMinutes 分钟），未收到 ev=done。"
    }
    return $done
}

# USB 方式：提示人工引导 U 盘，测试完成后按 1 次键保存报告，编排器自动读取（半自动）
function Invoke-UsbCapture {
    param([string]$UsbDrive, [string]$ReportDir, [string]$ReportPrefix)

    Write-Host "USB 方式（半自动，只需按 1 次键）："
    Write-Host "  1. 将 Memtest86+ 引导 U 盘插入被测服务器并引导"
    Write-Host "  2. 测试跑完（按 MaxPasses 轮）后，在 Memtest86+ 界面按 F1 进配置"
    Write-Host "  3. 按数字键 6（保存报告到 USB）—— 报告将以 MT86P_NN.TXT 写入 U 盘"
    Write-Host "  4. 按 Esc 重启回系统（可选，编辑脚本会继续等报告）"
    Write-Host "  等待 U 盘出现新报告文件（Ctrl+C 可中止）..."

    # 记录 U 盘上已有的报告，只认"新出现"的文件
    $seen = @{}
    if (Test-Path $UsbDrive) {
        Get-ChildItem -Path $UsbDrive -Filter $ReportPrefix -ErrorAction SilentlyContinue |
            ForEach-Object { $seen[$_.FullName] = $true }
    }

    $found = $null
    while ($null -eq $found) {
        Start-Sleep -Seconds 5
        if (-not (Test-Path $UsbDrive)) { continue }
        $candidate = Get-ChildItem -Path $UsbDrive -Filter $ReportPrefix -ErrorAction SilentlyContinue |
            Where-Object { -not $seen.ContainsKey($_.FullName) } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $candidate) {
            # 等待文件写完整（连续 3 次轮询大小不变）
            $size1 = $candidate.Length
            Start-Sleep -Seconds 2
            $size2 = $candidate.Length
            Start-Sleep -Seconds 2
            $size3 = $candidate.Length
            if ($size1 -eq $size2 -and $size2 -eq $size3 -and $size3 -gt 0) {
                $found = $candidate
            }
        }
    }
    Write-Host "发现报告: $($found.FullName)（$($found.Length) 字节）"
    Copy-Item -Path $found.FullName -Destination $ReportDir
    return $found.FullName
}

# EFI 方式：bcdedit 一次性引导 mt86plus.efi（同一台被测机器）
function Invoke-EfiBoot {
    param(
        [string]$EfiImage, [string]$EfiBootId, [string]$SerialParam,
        [int]$MaxPasses, [string]$TestList
    )

    if (-not $ConfirmSwitch) {
        throw "EFI 方式涉及引导/重启，需加 -ConfirmSwitch 确认。"
    }
    if (-not (Test-Path $EfiImage)) {
        throw "EFI 镜像不存在: $EfiImage"
    }

    $cmdline = "console=$SerialParam log=$SerialParam"
    if ($MaxPasses -gt 0) { $cmdline += " maxpasses=$MaxPasses" }
    if ($TestList) { $cmdline += " testlist=$TestList" }

    # 创建一次性引导项
    $guid = [Guid]::NewGuid().ToString()
    & bcdedit /create "$EfiBootId" /application OSLOADER /d "Memtest86+ One-time"
    & bcdedit /set "$EfiBootId" path "\path\to\mt86plus.efi"
    & bcdedit /set "$EfiBootId" device partition="$(Split-Path $EfiImage)"
    & bcdedit /set "$EfiBootId" osdevice partition="$(Split-Path $EfiImage)"
    & bcdedit /set "$EfiBootId" options "$cmdline"
    & bcdedit /set "{fwbootmgr}" bootsequence "$EfiBootId"

    Write-Host "已设置一次性引导项，即将重启进入 Memtest86+（完成后自动重启回系统）。"
    Write-Host "注意：EFI 方式日志需配合串口/SOL 捕获，或用 USB 报告导出。"
    if ($ConfirmSwitch) {
        & Restart-Computer -Force
    }
}

# ----------------------------------------------------------------------------
# FR-8 断电/重启循环 + FR-11 温度监控
# ----------------------------------------------------------------------------

# FR-8 断电-上电循环（IPMI chassis power cycle；建议从控制机运行，勿在被测机上跑）
function Invoke-PowerCycleLoop {
    param(
        [int]$Cycles, [string]$BmcHost, [string]$BmcUser, [string]$BmcPass,
        [string]$IpmiTool, [string]$LogCsv
    )

    $rows = @()
    for ($i = 1; $i -le $Cycles; $i++) {
        $t = Get-Date
        Write-Host ("循环 {0}/{1}：断电-上电 ..." -f $i, $Cycles)
        try {
            $a = @("-I", "lanplus", "-H", $BmcHost)
            if ($BmcUser) { $a += @("-U", $BmcUser) }
            if ($BmcPass) { $a += @("-P", $BmcPass) }
            & $IpmiTool @($a + @("chassis", "power", "cycle")) | Out-Null
            Start-Sleep -Seconds 90   # 等待重新上电并初始化
            $rows += [PSCustomObject]@{ Cycle = $i; Time = $t.ToString("yyyy-MM-dd HH:mm:ss"); Result = "PowerCycled" }
        } catch {
            $rows += [PSCustomObject]@{ Cycle = $i; Time = $t.ToString("yyyy-MM-dd HH:mm:ss"); Result = "FAIL: $($_.Exception.Message)" }
        }
    }
    $rows | Export-Csv -Path $LogCsv -NoTypeInformation -Encoding UTF8
    Write-Host "断电循环记录 -> $LogCsv"
}

# FR-11 温度监控（可选）：SOL 方式下通过 IPMI 读取温度传感器（含 DIMM 温度）
function Get-IPMITempSensors {
    param([string]$BmcHost, [string]$BmcUser, [string]$BmcPass, [string]$IpmiTool)

    $a = @("-I", "lanplus", "-H", $BmcHost)
    if ($BmcUser) { $a += @("-U", $BmcUser) }
    if ($BmcPass) { $a += @("-P", $BmcPass) }
    $out = & $IpmiTool @($a + @("sdr", "elist")) 2>$null
    $temps = @()
    foreach ($line in $out) {
        if ($line -match '^\s*([^|]+?)\s*\|\s*([\d.]+)\s+degrees C') {
            $temps += [PSCustomObject]@{ Sensor = $matches[1].Trim(); TempC = [double]$matches[2] }
        }
    }
    return $temps
}

# ----------------------------------------------------------------------------
# FR-6 报告汇总（合并 master_manifest.csv）
# ----------------------------------------------------------------------------
function Export-TestReport {
    param(
        [string]$BatchName,
        [array]$Inventory,
        [object]$MemtestSummary,
        [string]$ReportDir,
        [string]$LogPath
    )

    $reportRows = @()
    foreach ($inv in $Inventory) {
        $reportRows += [PSCustomObject]@{
            Batch        = $BatchName
            ToolVersion  = Get-AppVersion
            Slot         = $inv.Slot
            SerialNumber = $inv.SerialNumber
            PartNumber   = $inv.PartNumber
            CapacityGB   = $inv.CapacityGB
            SpeedMTs     = $inv.SpeedMTs
            MemType      = $inv.MemType
            MatchState   = $inv.MatchState
            TestDate     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Passes       = if ($MemtestSummary) { $MemtestSummary.PassesCompleted } else { 0 }
            Errors       = if ($MemtestSummary) { $MemtestSummary.Errors } else { 0 }
            EccErrors    = if ($MemtestSummary) { $MemtestSummary.EccErrors } else { 0 }
            Result       = if ($MemtestSummary) { $MemtestSummary.FinalStatus } else { "未测" }
        }
    }

    $file = Join-Path $ReportDir "$BatchName-report.csv"
    $reportRows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Write-Host "批次报告已生成: $file"

    # 合并到 master_manifest.csv
    $master = Join-Path $LogPath "master_manifest.csv"
    $all = @()
    if (Test-Path $master) { $all += Import-Csv -Path $master }
    $all += $reportRows
    # 固定列投影：PS5.1 的 Export-Csv 列头由首对象属性决定，遗留旧行（无 ToolVersion 列）在前时会整体丢列，故统一重建列集合与顺序
    $all | Select-Object Batch, ToolVersion, Slot, SerialNumber, PartNumber, CapacityGB, SpeedMTs, MemType, MatchState, TestDate, Passes, Errors, EccErrors, Result |
        Export-Csv -Path $master -NoTypeInformation -Encoding UTF8
    Write-Host "累计总表已更新: $master（共 $($all.Count) 条）"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

if ($ParseOnly) {
    # 仅解析已有日志/报告
    if (-not $LogFile -or -not (Test-Path $LogFile)) {
        Write-Error "ParseOnly 模式需提供有效的 -LogFile"
        exit 1
    }
    # 按内容路由：首行是 MTLOG 走串口解析器，否则走文本报告解析器
    $firstLine = Get-Content -Path $LogFile -TotalCount 1
    if ($firstLine -match '^MTLOG') {
        $summary = Invoke-MtlogParser -LogFile $LogFile
    } else {
        $summary = Invoke-TextReportParser -ReportFile $LogFile
    }
    $summary | ConvertTo-Json -Depth 4
    exit 0
}

Write-Host "===== Memtest86+ 编排开始（批次: $BatchName，方式: $BootMethod）====="

# FR-1 识别建档
$inventory = Get-MemoryInventory -ExpectedCsv $ExpectedCsv -BatchName $BatchName
if ($inventory.Count -eq 0) {
    Write-Error "识别不到内存，中止。"
    exit 1
}
$invFile = Join-Path $LogPath "$BatchName-inventory.csv"
$inventory | Export-Csv -Path $invFile -NoTypeInformation -Encoding UTF8
Write-Host "识别完成: $($inventory.Count) 根，清单 -> $invFile"
$inventory | Format-Table Slot, SerialNumber, PartNumber, CapacityGB, SpeedMTs, MemType, Status -AutoSize

# 按引导方式捕获 Memtest86+ 日志
$rawLog = Join-Path $rawDir "$BatchName.mtlog.txt"
$usbReport = Join-Path $rawDir "$BatchName.usb.txt"

switch ($BootMethod) {
    "SOL" {
        Invoke-SolCapture -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass `
            -IpmiTool $IpmiTool -OutFile $rawLog -TimeoutMinutes ($MaxPasses * 90 + 30)
    }
    "Serial" {
        Invoke-SerialCapture -SerialPortName $SerialPort -BaudRate $BaudRate `
            -OutFile $rawLog -TimeoutMinutes ($MaxPasses * 90 + 30)
    }
    "USB" {
        $src = Invoke-UsbCapture -UsbDrive $UsbDrive -ReportDir $rawDir -ReportPrefix $UsbReportPrefix
        $usbReport = Join-Path $rawDir (Split-Path $src -Leaf)
    }
    "EFI" {
        Invoke-EfiBoot -EfiImage $EfiImage -EfiBootId $EfiBootId -SerialParam $SerialParam `
            -MaxPasses $MaxPasses -TestList $TestList
        # EFI 引导后机器重启，本进程结束；重启后的续测/采集由配套计划任务执行
        exit 0
    }
}

# 解析 + 汇总（FR-10：Ctrl+C/异常时 finally 保护已解析结果）
try {
    # 解析
    $summary = $null
    if ($BootMethod -in @("SOL", "Serial") -and (Test-Path $rawLog)) {
        $summary = Invoke-MtlogParser -LogFile $rawLog
    } elseif ($BootMethod -eq "USB" -and (Test-Path $usbReport)) {
        $summary = Invoke-TextReportParser -ReportFile $usbReport
    }
    if ($null -eq $summary) {
        Write-Error "未获取到 Memtest86+ 日志/报告。"
        exit 1
    }

    Write-Host ""
    Write-Host ("Memtest86+ 结果: 轮次=$($summary.PassesCompleted) 错误=$($summary.Errors) ECC=$($summary.EccErrors) 状态=$($summary.FinalStatus)")
    if ($summary.ErrorDetails.Count -gt 0) {
        Write-Host "错误明细:"
        $summary.ErrorDetails | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.Type, (($_.Fields | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " ")) }
    }

    # FR-7 WHEA/ECC 监控
    $whea = @()
    if ($MonitorEcc) {
        $whea = Get-SystemEvents
        Write-Host "WHEA 内存相关事件（近24h）: $($whea.Count) 条"
        if ($whea.Count -gt 0) {
            $whea | Format-Table Time, Id, Level -AutoSize
            $whea | Export-Csv -Path (Join-Path $reportDir "$BatchName-whea.csv") -NoTypeInformation -Encoding UTF8
        } else {
            Write-Host "未检测到 WHEA 内存错误事件。"
        }
    }

    # FR-11 温度监控（可选）
    if ($MonitorTemp) {
        if ($BootMethod -eq "SOL") {
            $temps = Get-IPMITempSensors -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool
            if ($temps.Count -gt 0) {
                Write-Host "IPMI 温度传感器:"
                $temps | Format-Table Sensor, TempC -AutoSize
                $temps | Export-Csv -Path (Join-Path $reportDir "$BatchName-temp.csv") -NoTypeInformation -Encoding UTF8
            } else {
                Write-Host "未读取到 IPMI 温度传感器（检查 BMC 权限）。"
            }
        } else {
            Write-Host "温度监控仅支持 SOL 方式（IPMI 传感器），当前方式跳过。"
        }
    }

    # FR-6 汇总报告
    Export-TestReport -BatchName $BatchName -Inventory $inventory -MemtestSummary $summary `
        -ReportDir $reportDir -LogPath $LogPath
} finally {
    Write-Host ""
    Write-Host "（已保留本批次已解析数据；可用 -ParseOnly -LogFile <raw log> 断点续解析）"
}

# FR-8 断电/重启循环（批次切换；建议从控制机运行）
if ($RestartLoop -gt 0) {
    if (-not $ConfirmSwitch) {
        Write-Warning "设置了 -RestartLoop 但未加 -ConfirmSwitch，跳过断电循环。"
    } elseif ($BootMethod -eq "SOL") {
        Invoke-PowerCycleLoop -Cycles $RestartLoop -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass `
            -IpmiTool $IpmiTool -LogCsv (Join-Path $reportDir "$BatchName-powercycle.csv")
    } else {
        Write-Warning "断电循环仅支持 SOL 方式（IPMI），当前方式跳过。"
    }
}

Write-Host ""
Write-Host "===== 编排完成 ====="
