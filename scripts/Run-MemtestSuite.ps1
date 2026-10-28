# ============================================================================
# Run-MemtestSuite.ps1
# Memtest86+ 自动化编排与压测报告汇总工具（Windows PowerShell）
#
# 定位：PowerShell 作为编排器 —— 引导 Memtest86+ 执行真正的内存测试，
#       捕获其输出日志（MTLOG 串口日志 / USB 报告 / EFI），解析并汇总到
#       批量压测报告（与 Identify-Memory.ps1 的 master_manifest.csv 关联）。
#
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Run-MemtestSuite.ps1 -Help
#   .\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
#   .\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod Serial -SerialPort COM1 -BaudRate 115200 -MaxPasses 4
#   .\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod USB -UsbDrive E: -MaxPasses 4
#   .\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod USB -UsbDrive E: -UsbReportPrefix "MT86P_*" -MaxPasses 4
#   .\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod EFI -EfiImage D:\mt86plus.efi -MaxPasses 4 -ConfirmSwitch
#   .\scripts\Run-MemtestSuite.ps1 -ParseOnly -LogFile .\results\raw\mtlog.txt -BatchName batch01
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

    # 任务进度追踪（副作用，不影响压测行为）
    [string]$ChecklistBatch = "",        # 验收批次（缺省 = BatchName），用于任务清单归集
    [ValidateSet("标准", "混插")]
    [string]$Scenario = "标准",          # 标准压测 | 混插压力（仅影响清单更新，不影响压测）

    # ORT 老化模式（时长制）：-MaxMinutes>0 时启用，按时长而非轮数终止
    [int]$MaxMinutes = 0,        # 老化目标时长（分钟，0=关闭 ORT；72h 老化=4320）
    [int]$TempLimitC = 85,       # 老化温度上限（摄氏度，超过判异常）
    [int]$TempIntervalMin = 60,  # 温度/状态采样间隔（分钟）
    [int]$OrtBufferMin = 10,     # ORT 前缓冲（分钟，先跑完整一轮再开始计时）
    [int]$OrtMaxGapMin = 30,     # 最长无进度间隔（分钟，超时判定捕获停滞/日志中断）

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
  SOL 方式（BMC/IPMI，全自动；启动前自动 BMC 前置体检（BMC 可达 + IP 源须静态；异常中止并打印恢复指引））：
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
  -ChecklistBatch 验收批次（缺省=BatchName），用于任务清单归集
  -Scenario       标准 | 混插（默认标准；仅影响任务清单更新，不影响压测行为）
  ORT 老化模式（-MaxMinutes>0 启用，时长制终止；仅支持 SOL/Serial，与 -RestartLoop 互斥）：
  -MaxMinutes     老化目标时长（分钟，0=关闭；72h 老化=4320）
  -TempLimitC     老化温度上限（摄氏度，默认 85）
  -TempIntervalMin 温度/状态采样间隔（分钟，默认 60）
  -OrtBufferMin   ORT 前缓冲（分钟，默认 10，先跑完整一轮再计时）
  -OrtMaxGapMin   最长无进度间隔（分钟，默认 30，超时判定捕获停滞/日志中断）
  输出：
  -LogPath        输出目录（默认 <包根>\results\）
  -ParseOnly     仅解析模式：配合 -LogFile 解析已有日志/报告
  -ConfirmSwitch  确认允许执行引导/重启/断电操作
用法示例（在离线包根目录运行，如 C:\memtest\）：
  .\scripts\Run-MemtestSuite.ps1 -BootMethod SOL -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
  .\scripts\Run-MemtestSuite.ps1 -BootMethod Serial -SerialPort COM1 -BaudRate 115200 -MaxPasses 4
  .\scripts\Run-MemtestSuite.ps1 -BootMethod USB -UsbDrive E: -MaxPasses 4
  .\scripts\Run-MemtestSuite.ps1 -BootMethod EFI -EfiImage D:\mt86plus.efi -MaxPasses 4 -ConfirmSwitch
  .\scripts\Run-MemtestSuite.ps1 -ParseOnly -LogFile .\results\raw\mtlog.txt
  ORT 72h 老化（时长制，配温度采样；SOL/Serial）：
  .\scripts\Run-MemtestSuite.ps1 -BatchName srv01-a1-ort -BootMethod SOL -BmcHost 10.0.0.10 -BmcUser root -MaxMinutes 4320 -ConfirmSwitch
"@
    exit 0
}

# 配置化默认参数：命令行显式参数优先，其次 config/memtest-suite.conf，最后脚本内置默认
$suiteCfg = Get-Config -Path (Join-Path $PSScriptRoot '..\config\memtest-suite.conf')
$suiteDef = Merge-SuiteConfig -Cfg $suiteCfg -Bound $PSBoundParameters
foreach ($k in $suiteDef.Keys) { Set-Variable -Name $k -Value $suiteDef[$k] }

# ORT 模式校验（必须在 BMC 密码交互之前，避免无效组合卡在密码输入）
if ($MaxMinutes -gt 0) {
    if ($RestartLoop -gt 0) {
        Write-Error "ORT 模式与 -RestartLoop 互斥，请分开执行。"
        exit 1
    }
    if ($BootMethod -notin @('SOL', 'Serial')) {
        Write-Error "ORT 模式仅支持 SOL/Serial 引导方式（USB/EFI 不支持时长终止），当前 $BootMethod。"
        exit 1
    }
    if ($PSBoundParameters.ContainsKey('MaxPasses')) {
        Write-Warning "同时指定 -MaxPasses 与 -MaxMinutes，按 ORT 时长模式执行（MaxPasses 忽略）。"
    }
}

# 指令记录：本次调用入库（Help 已处理；BMC 密码等敏感参数由 Write-CmdLog 打码）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Run-MemtestSuite' -CmdArgs $MyInvocation.Line -State Start

# 管道密码优先：脚本顶层 $input 可读外部管道（Read-BmcPass 的函数作用域内读不到，故在此先消费，
# 否则 -File 模式管道场景会落入 Read-Host 等待控制台而挂起）。
$pipeIn = @($input)
if ($BmcPass -eq "" -and $pipeIn.Count -gt 0) { $BmcPass = [string]$pipeIn[0] }
# 密码：仅 SOL 方式（指定 BMC、未显式提供、非 ParseOnly）→ 管道/交互提示一次（初始化段、任何 BMC 调用前）
if ($BootMethod -eq 'SOL' -and $BmcHost -and -not $BmcPass -and -not $ParseOnly) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }

if ($LogPath -eq "") { $LogPath = Join-Path (Split-Path -Parent $PSScriptRoot) "results" }
$rawDir   = Join-Path $LogPath "raw"
$reportDir = Join-Path $LogPath "reports"
foreach ($d in @($LogPath, $rawDir, $reportDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

if ($BatchName -eq "") { $BatchName = "batch_" + (Get-Date -Format "yyyyMMdd_HHmmss") }

# 自动发现内置 ipmitool：若离线包/项目内存在 tools\ipmitool\ipmitool.exe，则优先使用（免联网、免配置）
if ($IpmiTool -eq "ipmitool") {
    $bundled = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\ipmitool\ipmitool.exe"
    if (Test-Path -LiteralPath $bundled) { $IpmiTool = $bundled }
}

# SOL 前置体检（fail-closed：BMC 不可达 / IP 源非静态 / lan print 失败均中止并给恢复指引）
if ($BootMethod -eq 'SOL' -and $BmcHost -and -not $ParseOnly) {
    $pre = Invoke-BmcPreflight -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool
    if (-not $pre.Reachable) {
        Write-Host ""
        Write-Host "[FAIL] BMC 前置体检：BMC 不可达（$($pre.Detail)）"
        Write-Host "  指引：① 编排机有线网卡 Code 43 先修（docs/21 §3）；② BMC 无 IP 则去被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复静态 IP；③ 修复后重跑本命令。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检不可达' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    if (-not $pre.LanPrintOk) {
        Write-Host "[FAIL] BMC 前置体检：无法读取 LAN 配置（IP 源未知，fail-closed）"
        Write-Host "  指引：到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 -CheckOnly 人工核实 IP 源后重跑。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检 lan print 失败' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    if (-not $pre.IpSourceStatic) {
        Write-Host "[FAIL] BMC 前置体检：IP 源非静态（DHCP/未指定），断电循环后易丢 IP"
        Write-Host "  指引：到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复静态 IP（默认 10.0.0.10/255.255.255.0），确认后重跑本命令。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检 IP 源非静态' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    Write-Host "[OK] BMC 前置体检通过：IP 源静态"
}

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
        [string]$IpmiTool, [string]$OutFile, [int]$TimeoutMinutes,
        [int]$MaxStallMin = 0
    )

    if (-not $ConfirmSwitch) {
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: 需 -ConfirmSwitch 确认' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        throw "SOL 方式涉及引导/重启，需加 -ConfirmSwitch 确认。"
    }

    $args = @("-I", "lanplus", "-H", $BmcHost)
    if ($BmcUser) { $args += @("-U", $BmcUser) }
    if ($BmcPass) { $args += @("-P", $BmcPass) }

    $capStart = Get-Date
    Write-Host "启动 ipmitool SOL 会话，输出到 $OutFile ..."
    $p = Start-Process -FilePath $IpmiTool -ArgumentList ($args + @("sol", "activate")) `
            -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err" -PassThru -WindowStyle Hidden

    # 等待 ev=done 出现（或超时/停滞）
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $done = $false
    $stalled = $false
    $sessionLost = $false
    $failHint = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        # 先扫 ev=done 再判进程退出：避免 ev=done 写入与 ipmitool 退出落在同一轮询窗口时误判 SessionLost
        if (Test-Path $OutFile) {
            if (Select-String -Path $OutFile -Pattern 'ev=done' -Quiet) { $done = $true; break }
        }
        # 会话断开早期检测：ipmitool 已退出且未收到 ev=done → 立即结束（不等 deadline）
        if ($p.HasExited -and -not $done) {
            $sessionLost = $true
            $failHint = "SOL 会话断开（ipmitool 已退出）"
            break
        }
        # 停滞检测：SOL 输出超过 MaxStallMin 分钟无写入 → 疑似会话中断
        if ($MaxStallMin -gt 0) {
            $lastWrite = (Get-Item $OutFile -ErrorAction SilentlyContinue).LastWriteTime
            if ($lastWrite) {
                $stallMin = ((Get-Date) - $lastWrite).TotalMinutes
                if ($stallMin -gt $MaxStallMin) {
                    $stalled = $true
                    Write-Warning "SOL 输出停滞 $([math]::Round($stallMin, 1)) 分钟，疑似会话中断。"
                    break
                }
            }
        }
    }

    # 结束 SOL 会话
    try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    if (-not $done -and -not $stalled -and -not $sessionLost) {
        Write-Warning "SOL 捕获超时（$TimeoutMinutes 分钟），未收到 ev=done。"
    }
    # 携带底层错误（如 keepalive）到指引（会话断开场景同样读取 .err，追加真实错误）
    if (Test-Path "$OutFile.err") {
        $errRaw = Get-Content -LiteralPath "$OutFile.err" -Raw -ErrorAction SilentlyContinue
        if ($errRaw) { $failHint = if ($failHint) { $failHint + "；" + $errRaw.Trim() } else { $errRaw.Trim() } }
    }
    return [PSCustomObject]@{ Done = $done; Stalled = $stalled; SessionLost = $sessionLost; FailHint = $failHint; CaptureStart = $capStart; CaptureEnd = Get-Date }
}

# SOL 无输出/会话中断的四查行动指引（文案与 docs/15、docs/20 一致）
function Write-SolTroubleshootHint {
    param([string]$FailHint = "")
    Write-Host ""
    Write-Host "⚠️ SOL 未收到 Memtest86+ 输出（或会话中断），按序排查："
    Write-Host "  ① 引导方式：必须是 BMC 虚拟介质挂载 memtest-sol.iso（Ventoy U 盘引导时串口走物理 COM，SOL 收不到）；"
    Write-Host "  ② BIOS 串口重定向（Console Redirection → SOL）须开启，波特率 115200 三处一致；"
    Write-Host "  ③ 残留 SOL 会话：sol deactivate 清掉再跑（session already active）；"
    Write-Host "  ④ BMC 链路：编排机能 ping 通 10.0.0.10；被测服务器本机跑 Set-BmcStaticIp.ps1 -CheckOnly 确认 IP 源静态。"
    if ($FailHint) { Write-Host ("  底层错误: " + $FailHint) }
    Write-Host "  参考：docs/15-BMC排查方案.md §3、docs/20 流程 2。"
}

# Serial 直连串口方式：物理串口线直连服务器 COM 口抓取 MTLOG（完全离线）
function Invoke-SerialCapture {
    param(
        [string]$SerialPortName, [int]$BaudRate,
        [string]$OutFile, [int]$TimeoutMinutes,
        [int]$MaxStallMin = 0
    )

    Write-Host "打开串口 $SerialPortName @ $BaudRate，等待 Memtest86+ 输出 ..."
    Write-Host "提示：需先用 USB/EFI 方式把被测服务器引导进 Memtest86+，且其 log 打到物理串口 ttyS0"

    $capStart = Get-Date
    $port = New-Object System.IO.Ports.SerialPort($SerialPortName, $BaudRate, "None", 8, "One")
    $port.ReadTimeout = 3000
    $port.Open()

    $sw = New-Object System.IO.StreamWriter($OutFile, $true, [System.Text.Encoding]::UTF8)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $done = $false
    $stalled = $false
    $lastWrite = Get-Date   # 停滞检测基准：最近一次写入时间
    try {
        while ((Get-Date) -lt $deadline) {
            if (-not $port.IsOpen) { break }
            try {
                $line = $port.ReadLine()
            } catch {
                # 读超时（ReadTimeout 3000ms）：检查输出停滞（超过 MaxStallMin 分钟无写入）
                if ($MaxStallMin -gt 0) {
                    $stallMin = ((Get-Date) - $lastWrite).TotalMinutes
                    if ($stallMin -gt $MaxStallMin) {
                        $stalled = $true
                        Write-Warning "串口输出停滞 $([math]::Round($stallMin, 1)) 分钟，疑似会话中断。"
                        break
                    }
                }
                continue
            }
            $sw.WriteLine($line)
            $sw.Flush()
            $lastWrite = Get-Date
            if ($line -match 'ev=done') { $done = $true; break }
        }
    } finally {
        $sw.Close()
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
    if (-not $done -and -not $stalled) {
        Write-Warning "串口捕获超时（$TimeoutMinutes 分钟），未收到 ev=done。"
    }
    return [PSCustomObject]@{ Done = $done; Stalled = $stalled; CaptureStart = $capStart; CaptureEnd = Get-Date }
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
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: 需 -ConfirmSwitch 确认' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
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

    Write-PowerCycleWarning
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

    # 循环后 BMC 复核（只提示不阻断）
    $post = Invoke-BmcPreflight -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool
    if (-not $post.Reachable) {
        Write-Warning "断电循环后 BMC 不可达：请到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复（勿配系统网卡 10.0.0.10，那是 BMC 的 IP）。"
    } elseif (-not $post.IpSourceStatic) {
        Write-Warning "断电循环后 BMC IP 源非静态：建议 .\scripts\Set-BmcStaticIp.ps1 恢复为静态，防止下次丢 IP。"
    }
}

# FR-11 温度监控（可选）：SOL 方式下通过 IPMI 读取温度传感器（含 DIMM 温度），
# Get-IPMITempSensors 已迁入 lib_common.ps1（生产采样 Job 与主流程均经 dot-source 使用）

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

    # 报表列清单（单一来源：行对象字面量顺序须与此一致；master 合并投影复用此数组）
    $reportColumns = @(
        'Batch', 'ToolVersion', 'Slot', 'SerialNumber', 'PartNumber', 'CapacityGB',
        'SpeedMTs', 'MemType', 'MatchState', 'TestDate', 'Passes', 'Errors',
        'EccErrors', 'Result'
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

    # 合并到 master_manifest.csv（用 List 避免 $all += 的 O(n²) 拷贝）
    $master = Join-Path $LogPath "master_manifest.csv"
    $all = New-Object System.Collections.Generic.List[object]
    if (Test-Path $master) { $all.AddRange([object[]](Import-Csv -Path $master)) }
    $all.AddRange([object[]]$reportRows)
    # 固定列投影：PS5.1 的 Export-Csv 列头由首对象属性决定，遗留旧行（无 ToolVersion 列）在前时会整体丢列，故统一重建列集合与顺序
    $all | Select-Object $reportColumns | Export-Csv -Path $master -NoTypeInformation -Encoding UTF8
    Write-Host "累计总表已更新: $master（共 $($all.Count) 条）"
}

# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------

if ($ParseOnly) {
    # 仅解析已有日志/报告
    if (-not $LogFile -or -not (Test-Path $LogFile)) {
        Write-Error "ParseOnly 模式需提供有效的 -LogFile"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: ParseOnly 缺有效 -LogFile' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
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
    Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result $summary.FinalStatus -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
}

Write-Host "===== Memtest86+ 编排开始（批次: $BatchName，方式: $BootMethod）====="
Write-Event -Type stage -Data @{stage='orchestrator'; status='start'; batch=$BatchName; method=$BootMethod}

$ortMode = ($MaxMinutes -gt 0)
if ($ortMode) {
    Write-Host "===== ORT 模式：目标 $MaxMinutes 分钟，温度上限 $TempLimitC°C，采样间隔 $TempIntervalMin 分钟 ====="
    $captureStart = Get-Date
    $tempCsv = Join-Path $reportDir "$BatchName-temp.csv"
    if ($BootMethod -eq 'Serial' -and -not $BmcHost) {
        # Serial 直连无 BMC：温度采样不可用，跳过 Job；温度判据由 Get-OrTVerdict 在 TempLimitC<=0 时自动关闭
        $tempJob = $null
        $tempInfo = [PSCustomObject]@{ MaxTempC = [double]-1; TempSamples = 0 }
        Write-Warning "ORT Serial 方式无 BMC：温度判据不可用，PASS 需加 -TempLimitC 0（或改用 SOL 方式）"
    } else {
        $tempJob = Start-OrTTempSampling -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool `
            -IntervalMin $TempIntervalMin -CsvFile $tempCsv -LibPath (Join-Path $PSScriptRoot 'lib_common.ps1')
    }
    try {
        $rawLog = Join-Path $rawDir "$BatchName.mtlog.txt"
        if ($BootMethod -eq 'SOL') {
            $cap = Invoke-SolCapture -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool `
                -OutFile $rawLog -TimeoutMinutes ($MaxMinutes + $OrtBufferMin) -MaxStallMin $OrtMaxGapMin
            # ORT 为无限轮（log 参数不带 maxpasses），永不打印 ev=done → 不能以 -not $cap.Done 判定失败，仅按会话断开/停滞判定
            if ($cap.SessionLost -or $cap.Stalled) {
                Write-Warning ("SOL 捕获会话断开/停滞（Stalled=$($cap.Stalled) SessionLost=$($cap.SessionLost)）")
                Write-SolTroubleshootHint -FailHint $cap.FailHint
            }
        } else {
            $cap = Invoke-SerialCapture -SerialPortName $SerialPort -BaudRate $BaudRate `
                -OutFile $rawLog -TimeoutMinutes ($MaxMinutes + $OrtBufferMin) -MaxStallMin $OrtMaxGapMin
        }
        # 未启动温度采样时（Serial 无 BMC）不调用 Stop（$tempJob 为 $null，Stop-OrTTempSampling 对 $null Job 幂等）
        if ($null -ne $tempJob) { $tempInfo = Stop-OrTTempSampling -Job $tempJob -CsvFile $tempCsv }
    } catch {
        if ($null -ne $tempJob) { Stop-OrTTempSampling -Job $tempJob -CsvFile $tempCsv | Out-Null }
        throw
    }
    $captureEnd = Get-Date
    $summary = if (Test-Path $rawLog) { Invoke-MtlogParser -LogFile $rawLog } else { $null }
    if ($null -eq $summary) {
        Write-Error "ORT：未获取到 Memtest86+ 日志。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: ORT 未获取到日志' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    $metrics = Get-OrTLogMetrics -Summary $summary
    $captureMin = [math]::Round((($captureEnd - $captureStart).TotalMinutes), 2)
    $actualMin = [math]::Min($captureMin, $metrics.LogSpanMinutes)
    $verdict = Get-OrTVerdict -ActualMinutes $actualMin -TargetMinutes $MaxMinutes -Errors $summary.Errors `
        -EccErrors $summary.EccErrors -StartEventCount $metrics.StartEventCount -MaxEventGapMin $metrics.MaxEventGapMin `
        -Stalled $cap.Stalled -MaxTempC $tempInfo.MaxTempC -TempSamples $tempInfo.TempSamples -TempLimitC $TempLimitC `
        -GapLimitMin $OrtMaxGapMin
    Write-Host ("ORT 结果: 时长=$actualMin 轮次=$($summary.PassesCompleted) 错误=$($summary.Errors) ECC=$($summary.EccErrors) 状态=$($verdict.Status) 结论=$($verdict.Conclusion)")
    Export-OrTReport -BatchName $BatchName -ToolVersion (Get-AppVersion) -CaptureStart $captureStart -CaptureEnd $captureEnd `
        -TargetMinutes $MaxMinutes -ActualMinutes $actualMin -Summary $summary -Metrics $metrics -Verdict $verdict `
        -MaxTempC $tempInfo.MaxTempC -TempSamples $tempInfo.TempSamples -Stalled $cap.Stalled -GapLimitMin $OrtMaxGapMin `
        -ReportDir $reportDir -LogPath $LogPath
    $ortExitCode = if ($verdict.Status -eq 'FAIL') { 2 } else { 0 }
    # ---- 任务进度追踪（ORT 分支挂点：副作用；清单缺失自动建；失败不影响 ORT 主流程） ----
    try {
        $clBatch = if ($ChecklistBatch) { $ChecklistBatch } else { $BatchName }
        Update-OrTChecklist -ChecklistBatch $clBatch -ResultsDir $LogPath -BatchName $BatchName `
            -Summary $summary -Verdict $verdict -ActualMinutes $actualMin -TargetMinutes $MaxMinutes `
            -TempInfo $tempInfo -TempLimitC $TempLimitC
    } catch {
        Write-Warning "任务清单更新失败（不影响 ORT 结果）: $($_.Exception.Message)"
    }
    Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result ("ORT " + $verdict.Status) -ExitCode $ortExitCode -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit $ortExitCode   # ORT 分支到此结束（不进入常规 per-slot 报告与 RestartLoop）
}

# FR-1 识别建档
$inventory = Get-MemoryInventory -ExpectedCsv $ExpectedCsv -BatchName $BatchName
if ($inventory.Count -eq 0) {
    Write-Error "识别不到内存，中止。"
    Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: 识别不到内存' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
$invFile = Join-Path $LogPath "$BatchName-inventory.csv"
$inventory | Export-Csv -Path $invFile -NoTypeInformation -Encoding UTF8
Write-Host "识别完成: $($inventory.Count) 根，清单 -> $invFile"
Write-Event -Type entity -Data @{stage='inventory'; count=$inventory.Count; batch=$BatchName}
$inventory | Format-Table Slot, SerialNumber, PartNumber, CapacityGB, SpeedMTs, MemType, Status -AutoSize

# 按引导方式捕获 Memtest86+ 日志
$rawLog = Join-Path $rawDir "$BatchName.mtlog.txt"
$usbReport = Join-Path $rawDir "$BatchName.usb.txt"

switch ($BootMethod) {
    "SOL" {
        $cap = Invoke-SolCapture -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass `
            -IpmiTool $IpmiTool -OutFile $rawLog -TimeoutMinutes ($MaxPasses * 90 + 30)
        if (-not $cap.Done) {
            Write-Warning ("SOL 捕获未收到 ev=done（Done=$($cap.Done) Stalled=$($cap.Stalled) SessionLost=$($cap.SessionLost)）")
            Write-SolTroubleshootHint -FailHint $cap.FailHint
        }
    }
    "Serial" {
        $cap = Invoke-SerialCapture -SerialPortName $SerialPort -BaudRate $BaudRate `
            -OutFile $rawLog -TimeoutMinutes ($MaxPasses * 90 + 30)
        if (-not $cap.Done) { Write-Warning "串口捕获未收到 ev=done（Done=$($cap.Done) Stalled=$($cap.Stalled)）。" }
    }
    "USB" {
        $src = Invoke-UsbCapture -UsbDrive $UsbDrive -ReportDir $rawDir -ReportPrefix $UsbReportPrefix
        $usbReport = Join-Path $rawDir (Split-Path $src -Leaf)
    }
    "EFI" {
        Invoke-EfiBoot -EfiImage $EfiImage -EfiBootId $EfiBootId -SerialParam $SerialParam `
            -MaxPasses $MaxPasses -TestList $TestList
        # EFI 引导后机器重启，本进程结束；重启后的续测/采集由配套计划任务执行。
        # 本机将重启，capture/parse/done 事件不可达，故此处补一条引导事件供日志追踪。
        Write-Event -Type stage -Data @{stage='efi'; status='boot'; batch=$BatchName}
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'OK: EFI 引导已设置，本机将重启' -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 0
    }
}

# 捕获完成（switch 各方式执行后、解析前）
Write-Event -Type stage -Data @{stage='capture'; status='done'; method=$BootMethod; batch=$BatchName}

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
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: 未获取到日志/报告' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }

    Write-Host ""
    Write-Host ("Memtest86+ 结果: 轮次=$($summary.PassesCompleted) 错误=$($summary.Errors) ECC=$($summary.EccErrors) 状态=$($summary.FinalStatus)")
    Write-Event -Type stage -Data @{stage='parse'; status='done'; passes=$summary.PassesCompleted; errors=$summary.Errors; result=$summary.FinalStatus}
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
    Write-Event -Type done -Data @{stage='report'; file=(Join-Path $reportDir "$BatchName-report.csv"); batch=$BatchName}
} finally {
    Write-Host ""
    Write-Host "（已保留本批次已解析数据；可用 -ParseOnly -LogFile <raw log> 断点续解析）"
}

# ---- 任务进度追踪（副作用：清单缺失自动建；失败不影响主流程；-Scenario 仅影响清单更新） ----
try {
    $clBatch = if ($ChecklistBatch) { $ChecklistBatch } else { $BatchName }
    $clDir = Join-Path $LogPath $clBatch
    if (-not (Test-Path -LiteralPath $clDir)) { $clDir = New-TaskChecklist -ChecklistBatch $clBatch -ResultsDir $LogPath }
    $overview = Join-Path $clDir '任务清单-总览.md'
    $mtStatus = if ($summary.FinalStatus -eq 'PASS') { '✓ 做成' } else { '✗ 没做成' }
    # 档位名判定：-TestList 非空 → 快筛档位（1 轮快筛对应清单环节"快筛"），否则全项档位。
    # 注意 ${MaxPasses} 花括号：PowerShell 5.1 会把 "$MaxPasses轮全项" 解析为变量 $MaxPasses轮全项（中文属合法标识符字符）→ 空串。
    $gearKey = if ($TestList) { if ($MaxPasses -eq 1) { '快筛' } else { "${MaxPasses}轮快筛" } } else { "${MaxPasses}轮全项" }
    $gearName = if ($TestList) { if ($MaxPasses -eq 1) { '1轮快筛' } else { "${MaxPasses}轮快筛" } } else { "${MaxPasses}轮全项" }
    $mtResult = "档位=$gearName；Passes=$($summary.PassesCompleted) Errors=$($summary.Errors)"
    $mtProduct = "$BatchName-report.csv"
    if ($Scenario -eq '标准') {
        $mtFlowPath = Join-Path $clDir '任务清单-Memtest.md'
        Update-TaskChecklist -ChecklistPath $mtFlowPath -Key $gearKey -Status $mtStatus -Result $mtResult -Product $mtProduct
        # 档位键无对应清单行（如 -MaxPasses 0/3，帮助文本 0=不限 为合法取值）→ 提示，
        # 避免"总览 ✓ 而 Memtest 流程清单全 ─"的误导；总览第 3 项仍按实际档位更新。
        $gearRowHit = $false
        if (Test-Path -LiteralPath $mtFlowPath) {
            $gearRowHit = [System.IO.File]::ReadAllText($mtFlowPath, [System.Text.Encoding]::UTF8) -match ("(?m)^\| " + [regex]::Escape($gearKey) + " \|")
        }
        if (-not $gearRowHit) {
            Write-Warning "档位 $gearName 无对应清单行（档位集：1/2/4 轮快筛/全项），本次仅更新总览"
        }
        Update-OverviewRow -OverviewPath $overview -ItemNo 3 -Status $mtStatus -Result $mtResult
    } else {
        Update-TaskChecklist -ChecklistPath (Join-Path $clDir '任务清单-混插.md') -Key 'Memtest 混插组合' -Status $mtStatus -Result $mtResult -Product $mtProduct
        Update-OverviewRow -OverviewPath $overview -ItemNo 16 -Status $mtStatus -Result $mtResult
    }
} catch {
    Write-Warning "任务清单更新失败（不影响压测结果）: $($_.Exception.Message)"
}

# FR-8 断电/重启循环（批次切换；建议从控制机运行）
if ($RestartLoop -gt 0) {
    if (-not $ConfirmSwitch) {
        Write-Warning "设置了 -RestartLoop 但未加 -ConfirmSwitch，跳过断电循环。"
    } elseif ($BootMethod -eq "SOL") {
        Invoke-PowerCycleLoop -Cycles $RestartLoop -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass `
            -IpmiTool $IpmiTool -LogCsv (Join-Path $reportDir "$BatchName-powercycle.csv")
        # 任务进度追踪：断电循环完成（副作用；失败不影响主流程）
        try {
            $clBatch = if ($ChecklistBatch) { $ChecklistBatch } else { $BatchName }
            $clDir = Join-Path $LogPath $clBatch
            if (-not (Test-Path -LiteralPath $clDir)) { $clDir = New-TaskChecklist -ChecklistBatch $clBatch -ResultsDir $LogPath }
            Update-TaskChecklist -ChecklistPath (Join-Path $clDir '任务清单-断电循环.md') -Key '200 次循环' -Status '✓ 做成' `
                -Result "$RestartLoop 次循环完成" -Product "$BatchName-powercycle.csv"
            Update-OverviewRow -OverviewPath (Join-Path $clDir '任务清单-总览.md') -ItemNo 10 -Status '✓ 做成' -Result "$RestartLoop 次循环完成"
        } catch {
            Write-Warning "任务清单更新失败（不影响断电循环结果）: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "断电循环仅支持 SOL 方式（IPMI），当前方式跳过。"
    }
}

Write-Host ""
Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result $summary.FinalStatus -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
Write-Host "===== 编排完成 ====="
