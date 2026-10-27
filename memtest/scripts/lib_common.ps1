# ============================================================================
# lib_common.ps1 — 共享库（脚本入库后公共逻辑抽取）
# 定位：DDR5 内存条 SOL 验收工具公共函数库（识别 / 解析 / 通用工具）。
#       本文件只提供可复用函数，禁止包含任何业务主流程逻辑。
# 依赖：PowerShell 5.1；由各脚本在 param 之后 dot-source 加载（. $PSScriptRoot\lib_common.ps1）。
#
# 函数清单：
#   Get-MemoryInventory      识别本机内存条并匹配预期清单
#   Parse-KvPairs            健壮 key=value 分词器
#   Invoke-MtlogParser       解析 MTLOG 串口日志
#   Invoke-TextReportParser  解析 USB 导出文本报告
#   Read-CsvManifest         健壮 CSV 读取（.NET TextFieldParser，保留行尾空字段）
#   Write-Event              向 stdout 输出一行 JSON 事件
#   Get-AppVersion           读取 VERSION（缺失回退 v0-dev）
#   Get-Config                读取 conf/app.conf 键值配置（非法键跳过）
#   Write-Log                时间戳日志输出 [HH:mm:ss] LEVEL msg
#   ConvertTo-CsvField       CSV 字段转义（含逗号/引号/换行加引号）
#   Confirm-Targets          打印目标清单并要求 y 确认（业务占位骨架）
#   Get-StageDone / Set-StageDone  .done 阶段标记读写
#   Wait-Slot                并发槽位信号量（骨架）
#   Get-SystemEvents         WHEA 内存相关系统事件（近 HoursBack 小时）
#   Get-PythonExe           定位内置 Python 解释器（tools\python 优先，其次 PATH）
#   Read-BmcPass            BMC 密码读取（已给直接用；空则管道/交互输入）
#   Invoke-IpmiProbe        调用 ipmitool 探针（stdout/stderr 分离 + 退出码）
#   Test-BmcRole            三态角色判定（Orchestrator/Server/AuthError，mc info 三套件探测）
#   Get-OrTVerdict           ORT 结论判定（口径 B 纯函数：时长/错误/中断/温度）
#   Get-OrTLogMetrics        ORT 日志指标（start 计数 / 最大事件间隔 / 跨度，分钟）
#   Start-OrTTempSampling    温度采样后台 Job（每 IntervalMin 分钟采样写长表 CSV）
#   Stop-OrTTempSampling     停采样 Job 并统计最高温 / 采样行数
#   Export-OrTReport         ORT 报告（<批次>-ort-report.csv + master_manifest 合成行）
#   Get-Prime95Verdict       Prime95 结论判定（时长不足/错误/提前退出 纯函数）
#   Get-Prime95LogStats      Prime95 日志错误统计（FATAL ERROR/Self-test failed/FAILED）
#   Export-Prime95Report     Prime95 报告（<批次>-prime95-report.csv + master 合成行）
# ============================================================================

# ----------------------------------------------------------------------------
# FR-1 智能识别与建档（复用 Identify-Memory.ps1 逻辑）
# ----------------------------------------------------------------------------
function Get-MemoryInventory {
    param([string]$ExpectedCsv, [string]$BatchName)

    $memSticks = Get-CimInstance -ClassName Win32_PhysicalMemory
    if (-not $memSticks) {
        Write-Warning "未读取到内存信息，请确认内存已安装。"
        return @()
    }

    $expected = @()
    if ($ExpectedCsv -ne "" -and (Test-Path $ExpectedCsv)) {
        $expected = Import-Csv -Path $ExpectedCsv
    }

    $rows = @()
    foreach ($m in $memSticks) {
        $capGB   = if ($m.Capacity) { [math]::Round($m.Capacity / 1GB, 0) } else { 0 }
        $memType = switch ($m.SMBIOSMemoryType) {
            24 { "DDR3" }
            26 { "DDR4" }
            34 { "DDR5" }
            35 { "LPDDR5" }
            36 { "LPDDR5X" }
            default { "Type$($m.SMBIOSMemoryType)" }
        }
        $serial = ($m.SerialNumber -replace '^0+', '').Trim()
        if ($serial -eq "") { $serial = "UNKNOWN" }
        $pn = ($m.PartNumber -replace '\s', '').Trim()

        $issues = @()
        if ($memType -ne "DDR5") { $issues += "非DDR5($memType)" }
        if ($serial -eq "UNKNOWN") { $issues += "SPD无序列号" }
        if ($pn -eq "") { $issues += "SPD无型号" }
        if ($capGB -eq 0) { $issues += "容量读取异常" }

        $matchState = "未提供预期清单"
        if ($expected.Count -gt 0 -and $serial -ne "UNKNOWN") {
            $found = $expected | Where-Object { $_.SerialNumber -eq $serial }
            if ($found) {
                $matchState = "匹配"
                if ($found.Capacity -and ([int]$found.Capacity -ne $capGB)) {
                    $issues += "容量与预期不符(预期$($found.Capacity)GB/实际${capGB}GB)"
                }
            } else {
                $matchState = "不在清单中"
                $issues += "不在预期清单"
            }
        }

        $rows += [PSCustomObject]@{
            Batch        = $BatchName
            Slot         = $m.DeviceLocator
            BankLabel    = $m.BankLabel
            SerialNumber = $serial
            PartNumber   = $pn
            Manufacturer = $m.Manufacturer
            CapacityGB   = $capGB
            SpeedMTs     = $m.Speed
            MemType      = $memType
            MatchState   = $matchState
            Issues       = ($issues -join "; ")
            Status       = if ($issues.Count -eq 0) { "正常" } else { "待复核" }
        }
    }
    return $rows
}

# ----------------------------------------------------------------------------
# FR-3/FR-4 日志捕获与解析
# ----------------------------------------------------------------------------

# 健壮的 key=value 分词器（支持带空格的引号值）
function Parse-KvPairs {
    param([string]$text)

    $map = @{}
    $len = $text.Length
    $i = 0
    while ($i -lt $len) {
        while ($i -lt $len -and [char]::IsWhiteSpace($text[$i])) { $i++ }
        if ($i -ge $len) { break }
        $start = $i
        while ($i -lt $len -and $text[$i] -ne '=' -and -not [char]::IsWhiteSpace($text[$i])) { $i++ }
        $key = $text.Substring($start, $i - $start)
        if ($i -lt $len -and $text[$i] -eq '=') {
            $i++
            if ($i -lt $len -and $text[$i] -eq '"') {
                $i++
                $vstart = $i
                while ($i -lt $len -and $text[$i] -ne '"') { $i++ }
                $val = $text.Substring($vstart, $i - $vstart)
                if ($i -lt $len) { $i++ }
            } else {
                $vstart = $i
                while ($i -lt $len -and -not [char]::IsWhiteSpace($text[$i])) { $i++ }
                $val = $text.Substring($vstart, $i - $vstart)
            }
            $map[$key] = $val
        }
    }
    return $map
}

# 解析 MTLOG 串口日志（格式：MTLOG ts=<sec>.<dsec> ev=<event> key=value ...）
function Invoke-MtlogParser {
    param([string]$LogFile)

    if (-not (Test-Path $LogFile)) {
        throw "日志文件不存在: $LogFile"
    }

    $summary = [PSCustomObject]@{
        PassesCompleted = 0
        Errors          = 0
        EccErrors       = 0
        FinalStatus     = "INCOMPLETE"
        Events          = @()
        ErrorDetails    = @()
        SpdInfo         = @()
        SystemInfo      = ""
    }

    foreach ($line in Get-Content -Path $LogFile -Encoding UTF8) {
        if ($line -notmatch '^MTLOG\s+ts=([\d.]+)\s+ev=(\S+)') { continue }

        $event  = $matches[2]
        $ts     = $matches[1]
        $rest   = ($line -split ' ev=', 2)[1]
        $fields = @{}
        if ($null -ne $rest) {
            $fields = Parse-KvPairs -text ($rest -replace '^[^ ]+\s*', '')  # 去掉行首事件名
        }
        $fields['ts'] = $ts   # 补上时间戳，供事件记录使用

        switch ($event) {
            "start" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "Memtest86+ 启动 (v$($fields.version))" }
            }
            "info" {
                $summary.SystemInfo = "CPU=$($fields.cpu); Board=$($fields.board); MemMB=$($fields.mem_mb); IMC=$($fields.imc)-$($fields.cas)"
            }
            "spd" {
                $summary.SpdInfo += [PSCustomObject]@{
                    Slot    = $fields.slot
                    SizeMB  = $fields.size_mb
                    Type    = $fields.type
                    Freq    = $fields.freq
                    Ecc     = $fields.ecc
                    Mfg     = $fields.mfg
                    Sku     = $fields.sku
                }
            }
            "pass_start" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "第 $($fields.pass) 轮开始" }
            }
            "pass_end" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "第 $($fields.pass) 轮结束，errors=$($fields.errors)" }
                $summary.Errors = [int64]$fields.errors
                if ($summary.PassesCompleted -lt ([int64]$fields.pass + 1)) {
                    $summary.PassesCompleted = [int64]$fields.pass + 1
                }
                if ($fields.status -eq "pass") { $summary.FinalStatus = "PASS" }
                elseif ($fields.status -eq "fail") { $summary.FinalStatus = "FAIL" }
            }
            "test_start" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "测试 $($fields.test) 开始: $($fields.name)" }
            }
            "test_end" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "测试 $($fields.test) 结束，errors=$($fields.errors)" }
            }
            "done" {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = "完成，passes=$($fields.passes)，status=$($fields.status)" }
                $summary.PassesCompleted = [int64]$fields.passes
                if ($fields.status -eq "pass") { $summary.FinalStatus = "PASS" }
                elseif ($fields.status -eq "fail") { $summary.FinalStatus = "FAIL" }
            }
            "addr" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields } }
            "data" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields } }
            "parity" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields } }
            "uecc" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields }; $summary.EccErrors++ }
            "ecc"  { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields }; $summary.EccErrors++ }
            default {
                $summary.Events += [PSCustomObject]@{ ts = $fields.ts; ev = $event; desc = ($fields | Out-String).Trim() }
            }
        }
    }
    return $summary
}

# 解析 USB 导出的文本报告（"Memtest86+ v... Report"，含 Final Result / Passes completed / Errors）
function Invoke-TextReportParser {
    param([string]$ReportFile)

    if (-not (Test-Path $ReportFile)) {
        throw "报告文件不存在: $ReportFile"
    }

    $content = Get-Content -Path $ReportFile -Encoding UTF8
    $summary = [PSCustomObject]@{
        PassesCompleted = 0
        Errors          = 0
        EccErrors       = 0
        FinalStatus     = "INCOMPLETE"
        PerTest         = @()
        SpdInfo         = @()
        SystemInfo      = ""
    }

    foreach ($line in $content) {
        if ($line -match '^  Test\s+(\d+):.*Errors:\s*(\d+)') {
            $summary.PerTest += [PSCustomObject]@{ Test = [int]$matches[1]; Errors = [int64]$matches[2] }
        }
        elseif ($line -match 'Passes completed:\s+(\d+)') {
            $summary.PassesCompleted = [int64]$matches[1]
        }
        elseif ($line -match 'Errors:\s+(\d+)') {
            $summary.Errors = [int64]$matches[1]
        }
        elseif ($line -match 'ECC Errors:\s+(\d+)') {
            $summary.EccErrors = [int64]$matches[1]
        }
        elseif ($line -match 'Final Result:\s*(PASS|FAIL|In progress)') {
            switch ($matches[1]) {
                "PASS" { $summary.FinalStatus = "PASS" }
                "FAIL" { $summary.FinalStatus = "FAIL" }
                default { $summary.FinalStatus = "INCOMPLETE" }
            }
        }
        elseif ($line -match '^  Slot\s+(\d+):\s+(\d+) MB (.+)$') {
            $summary.SpdInfo += [PSCustomObject]@{ Slot = [int]$matches[1]; SizeMB = [int64]$matches[2]; Detail = $matches[3] }
        }
        elseif ($line -match '^CPU:\s*(.+)$') {
            $summary.SystemInfo = "CPU=$($matches[1])"
        }
        elseif ($line -match '^Motherboard:\s*(.+)$') {
            $summary.SystemInfo += "; Board=$($matches[1])"
        }
    }
    return $summary
}

# ----------------------------------------------------------------------------
# 通用工具函数
# ----------------------------------------------------------------------------

# 健壮 CSV 读取：用 .NET TextFieldParser，正确处理带引号的逗号、且保留行尾空字段
# （PS 5.1 的 Import-Csv 会丢弃行尾逗号的空字段，导致列错位）
function Read-CsvManifest {
    param([string]$Path)

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path)
    $parser.TextFieldType = 'Delimited'
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true

    try {
        $headers = $parser.ReadFields() | ForEach-Object { $_.Trim() }
        $rows = @()
        while (-not $parser.EndOfData) {
            $vals = $parser.ReadFields()
            $obj = [ordered]@{}
            for ($c = 0; $c -lt $headers.Count; $c++) {
                $obj[$headers[$c]] = if ($c -lt $vals.Count) { $vals[$c].Trim() } else { "" }
            }
            $rows += [PSCustomObject]$obj
        }
    } finally {
        $parser.Close()
    }
    # 用 @() 包裹保证单行清单也返回数组（PS5.1 标量语义下调用方 .Count 可靠）
    return @($rows)
}

# 向 stdout 输出一行 JSON 事件 {"type":...,"data":{...}}（供外部工具消费）
function Write-Event {
    param([string]$Type, [hashtable]$Data)
    [PSCustomObject]@{ type = $Type; data = $Data } | ConvertTo-Json -Compress
}

# 读取应用版本：$PSScriptRoot\..\VERSION（trim），缺失回退 v0-dev。
# 结果缓存到 script 级变量，避免逐行/逐对象重复读盘。
$script:AppVersion = $null
function Get-AppVersion {
    if ($null -ne $script:AppVersion) { return $script:AppVersion }
    $vFile = Join-Path $PSScriptRoot "..\VERSION"
    if (Test-Path $vFile) {
        $v = (Get-Content -Path $vFile -Raw).Trim()
        if ($v -ne "") { $script:AppVersion = $v; return $v }
    }
    return "v0-dev"
}

# 读取键值/注释格式配置文件，返回 hashtable（修改 conf 即生效）。
# 行为：跳过空行与 # 注释行；非法键（不含 = 的行）跳过不报错；
#       Path 缺省时读 $PSScriptRoot\..\conf\app.conf；文件不存在返回空 hashtable。
function Get-Config {
    param([string]$Path = '')

    $cfg = @{}
    if ($Path -eq '') {
        $Path = Join-Path $PSScriptRoot '..\conf\app.conf'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t.IndexOf('=') -lt 0) { continue }   # 非法键（无 =）跳过不报错
        $idx = $t.IndexOf('=')
        $key = $t.Substring(0, $idx).Trim()
        if ($key -eq '') { continue }
        $val = $t.Substring($idx + 1).Trim()
        $cfg[$key] = $val
    }
    return $cfg
}

# 合并 Run-MemtestSuite 配置默认值：命令行显式参数($Bound)优先，配置未覆盖的键不返回。
# Cfg 来自 Get-Config(config/memtest-suite.conf)；返回「需要覆盖的默认值」哈希表。
function Merge-SuiteConfig {
    param(
        [hashtable]$Cfg,    # Get-Config 结果
        [hashtable]$Bound   # $PSBoundParameters（区分是否显式传参）
    )
    $r = @{}
    $map = @{
        'BOOT_METHOD'    = 'BootMethod'
        'BMC_HOST'       = 'BmcHost'
        'BMC_USER'       = 'BmcUser'
        'IPMI_TOOL'      = 'IpmiTool'
        'MAX_PASSES'     = 'MaxPasses'
        'TEST_LIST'      = 'TestList'
        'SERIAL_PARAM'   = 'SerialParam'
        'MONITOR_ECC'    = 'MonitorEcc'
        'MONITOR_TEMP'   = 'MonitorTemp'
        'RESTART_LOOP'   = 'RestartLoop'
        'CONFIRM_SWITCH' = 'ConfirmSwitch'
        'EXPECTED_CSV'   = 'ExpectedCsv'
        'LOG_PATH'       = 'LogPath'
        'MAX_MINUTES'    = 'MaxMinutes'
        'TEMP_LIMIT_C'   = 'TempLimitC'
        'TEMP_INTERVAL_MIN' = 'TempIntervalMin'
        'ORT_BUFFER_MIN' = 'OrtBufferMin'
        'ORT_MAX_GAP_MIN' = 'OrtMaxGapMin'
    }
    foreach ($k in $map.Keys) {
        $param = $map[$k]
        if ($Bound.ContainsKey($param)) { continue }
        $val = $Cfg[$k]
        if ($null -eq $val -or $val.Trim() -eq '') { continue }
        switch ($param) {
            { $_ -in 'MonitorEcc', 'MonitorTemp', 'ConfirmSwitch' } {
                $r[$param] = ($val -match '^(1|true|yes)$')
            }
            { $_ -in 'MaxPasses', 'RestartLoop', 'MaxMinutes', 'TempLimitC', 'TempIntervalMin', 'OrtBufferMin', 'OrtMaxGapMin' } {
                $n = 0
                if ([int]::TryParse($val, [ref]$n)) { $r[$param] = $n }
            }
            'BootMethod' {
                if ($val -in @('SOL', 'USB', 'EFI', 'Serial')) { $r[$param] = $val }
            }
            default { $r[$param] = $val }
        }
    }
    return $r
}

# 时间戳日志输出：[HH:mm:ss] LEVEL msg
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    Write-Host ("[{0}] {1} {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Msg)
}

# CSV 字段转义：含逗号/引号/换行时加引号并把内部引号翻倍
function ConvertTo-CsvField {
    param([object]$Value)
    $s = if ($null -eq $Value) { "" } else { [string]$Value }
    if ($s -match '[",\r\n]') {
        $s = '"' + ($s -replace '"', '""') + '"'
    }
    return $s
}

# 打印目标清单，默认要求输入 y 确认（业务占位骨架）
function Confirm-Targets {
    param([array]$Targets, [switch]$SkipConfirm)

    if ($Targets -and $Targets.Count -gt 0) {
        Write-Host "目标清单："
        foreach ($t in $Targets) { Write-Host "  - $t" }
    }
    if ($SkipConfirm) { return $true }
    $ans = Read-Host "是否确认继续？输入 y 确认"
    return ($ans.Trim().ToLower() -eq "y")
}

# .done 阶段标记读取
function Get-StageDone {
    param([string]$Dir, [string]$Stage)
    return (Test-Path (Join-Path $Dir "$Stage.done"))
}

# .done 阶段标记写入
function Set-StageDone {
    param([string]$Dir, [string]$Stage)
    New-Item -ItemType File -Path (Join-Path $Dir "$Stage.done") -Force | Out-Null
}

# 并发槽位信号量（骨架）：进程内计数等待，配 Release-Slot 释放。
# 简化实现：并发占用数达到 MaxSlots 时轮询等待。跨进程/Job 并发需用 Runspace 信号量（后续任务完善）。
$script:SlotUsage = 0
function Wait-Slot {
    param([int]$MaxSlots = 1)

    if ($MaxSlots -lt 1) { $MaxSlots = 1 }
    while ($script:SlotUsage -ge $MaxSlots) {
        Start-Sleep -Milliseconds 500
    }
    $script:SlotUsage++
}

# 释放一个并发槽位（与 Wait-Slot 成对调用；未占用时调用不报错）
function Release-Slot {
    if ($script:SlotUsage -gt 0) { $script:SlotUsage-- }
}

# ----------------------------------------------------------------------------
# FR-7 WHEA/ECC 监控（原 Get-WheaMemoryErrors 逻辑搬入改名）
# ----------------------------------------------------------------------------
function Get-SystemEvents {
    param([int]$HoursBack = 24)

    $errs = @()
    try {
        $errs = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-WHEA-Logger/Operational'
            StartTime = (Get-Date).AddHours(-$HoursBack)
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in @(18, 19, 47, 155, 160, 0xBC) } |
            ForEach-Object {
                [PSCustomObject]@{
                    Time     = $_.TimeCreated
                    Id       = $_.Id
                    Level    = $_.LevelDisplayName
                    Provider = $_.ProviderName
                    Message  = ($_.Message -replace "`r`n", " ")
                }
            }
    } catch {}
    return $errs
}

# ----------------------------------------------------------------------------
# 一键化改造：内置 Python 与 BMC 双格式（Get-PythonExe / Read-BmcPass / Invoke-IpmiProbe）
# ----------------------------------------------------------------------------

# 定位内置 Python 解释器：优先 <包根>\tools\python\python.exe，其次 PATH 中的 python，
# 都没有则返回 $null。
function Get-PythonExe {
    $localPy = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\python\python.exe"
    if (Test-Path -LiteralPath $localPy) { return $localPy }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# 读取 BMC 密码：$Pass 非空直接返回；为空时优先取管道输入，否则 Read-Host -AsSecureString
# 交互输入。明文转换用 SecureStringToBSTR/PtrToStringUni/ZeroFreeBSTR（finally 中释放 BSTR）。
function Read-BmcPass {
    param([string]$Pass = "", [string]$Prompt = "BMC 密码")

    if ($Pass -ne "") { return $Pass }
    $piped = @($input)
    if ($piped.Count -gt 0) { return [string]$piped[0] }
    $sec = Read-Host $Prompt -AsSecureString
    $ptr = [System.IntPtr]::Zero
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        if ($ptr -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

# 调用 ipmitool 探针并捕获输出：stdout 行取字符串、stderr 行取 ErrorRecord 文本，
# 返回 Code=$LASTEXITCODE。
function Invoke-IpmiProbe {
    param([string]$IpmiTool, [string[]]$IpmiArgs)

    $out = @()
    $err = @()
    & $IpmiTool @IpmiArgs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $err += $_.ToString()
        } else {
            $out += $_.ToString()
        }
    }
    return [PSCustomObject]@{ Out = $out; Err = $err; Code = $LASTEXITCODE }
}

# 服务器角色判定：依次用 base / base+-C 3 / base+-C 17 执行 mc info，
# 首个成功（Code=0 且有输出）判 Orchestrator（返回生效参数 CipherArgs 与 Manufacturer 解析值）；
# 全部失败则合并错误文本归因：命中连接级特征 → Server（BMC 不可达），
# 命中凭据/权限特征 → AuthError，均未命中 → Server 保守兜底（Detail 用原始错误）。
function Test-BmcRole {
    param([string]$IpmiTool, [string[]]$IpmiArgsBase)

    $connRe = 'Could not open socket|Unable to connect|Connection refused|Network is unreachable|No route|Timed out|timeout'
    $authRe = 'Invalid password|Unauthorized|Authentication type|not supported|Unable to establish|Insufficient privilege|RAKP'

    $attempts = @(
        @($IpmiArgsBase),
        @($IpmiArgsBase + @('-C', '3')),
        @($IpmiArgsBase + @('-C', '17'))
    )

    $errLines = @()
    $effective = $attempts[$attempts.Count - 1]   # 全失败时兜底为最后一次尝试参数
    foreach ($attempt in $attempts) {
        $r = Invoke-IpmiProbe -IpmiTool $IpmiTool -IpmiArgs ($attempt + @('mc', 'info'))
        $errLines += $r.Err
        if ($r.Code -eq 0 -and $r.Out.Count -gt 0) {
            $vendor = ''
            foreach ($line in $r.Out) {
                if ($line -match 'Manufacturer:\s*(.+)') { $vendor = $matches[1].Trim(); break }
            }
            return [PSCustomObject]@{ Role = 'Orchestrator'; Detail = ''; CipherArgs = $attempt; BmcVendor = $vendor }
        }
        $effective = $attempt
    }

    $errText = (($errLines | Select-Object -Unique) -join ' | ')
    if ($errText -match $connRe) {
        return [PSCustomObject]@{ Role = 'Server'; Detail = "BMC 不可达: $errText"; CipherArgs = $effective; BmcVendor = '' }
    }
    if ($errText -match $authRe) {
        return [PSCustomObject]@{ Role = 'AuthError'; Detail = "BMC 可达但凭据/权限失败: $errText"; CipherArgs = $effective; BmcVendor = '' }
    }
    return [PSCustomObject]@{ Role = 'Server'; Detail = "BMC 不可达: $errText"; CipherArgs = $effective; BmcVendor = '' }
}

# ----------------------------------------------------------------------------
# Memtest SOL 引导菜单预设解析与 grub.cfg 生成
# ----------------------------------------------------------------------------

# 解析 config/memtest-presets.conf（key=value，跳过空行/# 注释/非法键，风格同 Get-Config）。
# 返回 [PSCustomObject]@{ Timeout=[int]; Default=[string]; Presets=[array] }，
# Presets 元素为 [PSCustomObject]@{ Key; Title; Cmdline }，按 conf 出现顺序。
# 校验：timeout 必须为整数；default 必须存在且指向已收集的 preset key；
#       每个 preset 的 title 与 cmdline 必须成对存在，否则 throw。
function Get-MemtestPresets {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "预设配置文件不存在: $Path"
    }

    $timeout = -1
    $default = ""
    $presetKeys = New-Object System.Collections.Generic.List[string]
    $titles = @{}
    $cmdlines = @{}

    # 显式 UTF8 读取：预设 conf 为 UTF-8 无 BOM（PS5.1 Get-Content 默认 ANSI 会把中文解成乱码）
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 0) { continue }   # 非法键（无 =）跳过
        $key = $t.Substring(0, $idx).Trim()
        if ($key -eq '') { continue }
        $val = $t.Substring($idx + 1).Trim()

        if ($key -eq 'timeout') {
            if ($val -notmatch '^\d+$') { throw "timeout 必须为整数: '$val'" }
            $timeout = [int]$val
        }
        elseif ($key -eq 'default') {
            $default = $val
        }
        elseif ($key.StartsWith('preset.') -and $key.EndsWith('.title')) {
            $pkey = $key.Substring(7, $key.Length - 7 - 6)
            if (-not $presetKeys.Contains($pkey)) { $presetKeys.Add($pkey) }
            $titles[$pkey] = $val
        }
        elseif ($key.StartsWith('preset.') -and $key.EndsWith('.cmdline')) {
            $pkey = $key.Substring(7, $key.Length - 7 - 8)
            if (-not $presetKeys.Contains($pkey)) { $presetKeys.Add($pkey) }
            $cmdlines[$pkey] = $val
        }
    }

    if ($timeout -lt 0) { throw "配置缺少 timeout" }
    if ($default -eq '') { throw "配置缺少 default" }

    $presets = @()
    foreach ($pkey in $presetKeys) {
        if (-not $titles.ContainsKey($pkey)) { throw "预设 '$pkey' 缺少 title" }
        if (-not $cmdlines.ContainsKey($pkey)) { throw "预设 '$pkey' 缺少 cmdline" }
        $presets += [PSCustomObject]@{ Key = $pkey; Title = $titles[$pkey]; Cmdline = $cmdlines[$pkey] }
    }

    if ($presets.Count -eq 0) { throw "配置未包含任何 preset" }
    $defaultIdx = -1
    for ($i = 0; $i -lt $presets.Count; $i++) {
        if ($presets[$i].Key -eq $default) { $defaultIdx = $i; break }
    }
    if ($defaultIdx -lt 0) { throw "default 未匹配到预设: '$default'" }

    return [PSCustomObject]@{ Timeout = $timeout; Default = $default; Presets = $presets }
}

# 由预设生成 grub.cfg 全文（string）：set timeout / set default / search 兜底行 + 每个预设的
# menuentry 块（linux <KernelPath> [Cmdline]）。-TimeoutSeconds/-DefaultIndex 缺省(-1)时用 Presets 值。
function ConvertTo-GrubCfg {
    param($Presets, [int]$TimeoutSeconds = -1, [int]$DefaultIndex = -1, [string]$KernelPath = "/BOOT/MT86PLUS.BIN")

    $timeout = if ($TimeoutSeconds -ge 0) { $TimeoutSeconds } else { $Presets.Timeout }
    $defaultIdx = $DefaultIndex
    if ($defaultIdx -lt 0) {
        $defaultIdx = -1
        for ($i = 0; $i -lt $Presets.Presets.Count; $i++) {
            if ($Presets.Presets[$i].Key -eq $Presets.Default) { $defaultIdx = $i; break }
        }
        if ($defaultIdx -lt 0) { throw "default 未匹配到预设: '$($Presets.Default)'" }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("set timeout=$timeout")
    [void]$sb.AppendLine("set default=$defaultIdx")
    [void]$sb.AppendLine("search --no-floppy --set=root --file $KernelPath")
    foreach ($preset in $Presets.Presets) {
        [void]$sb.AppendLine("menuentry `"$($preset.Title)`" {")
        if ($preset.Cmdline -eq '') {
            [void]$sb.AppendLine("  linux $KernelPath")
        } else {
            [void]$sb.AppendLine("  linux $KernelPath $($preset.Cmdline)")
        }
        [void]$sb.AppendLine("  boot")
        [void]$sb.AppendLine("}")
    }
    return $sb.ToString()
}

# ----------------------------------------------------------------------------
# 72h ORT 老化模式：判定 / 日志指标 / 温度采样 Job / ORT 报告
# ----------------------------------------------------------------------------

# ORT 结论判定（口径 B 纯函数）：PASS = 足时长且无错误且无中断且温度达标
# （TempLimitC≤0 时跳过温度判据）。判定顺序：时长不足 → Errors/ECC →
# 中断（StartEventCount>1 / MaxEventGapMin>30min / Stalled）→ 温度。
function Get-OrTVerdict {
    param(
        [double]$ActualMinutes,
        [int]$TargetMinutes,
        [int64]$Errors,
        [int64]$EccErrors,
        [int]$StartEventCount,
        [double]$MaxEventGapMin,
        [bool]$Stalled,
        [double]$MaxTempC,
        [int]$TempSamples,
        [double]$TempLimitC,
        [int]$GapLimitMin = 30
    )

    $status = 'PASS'
    $reason = ''
    if ($ActualMinutes -lt $TargetMinutes) {
        $status = 'FAIL'
        $reason = "时长不足(实际 ${ActualMinutes} min / 目标 ${TargetMinutes} min)"
    }
    elseif ($Errors -gt 0) {
        $status = 'FAIL'
        $reason = "存在内存错误(Errors=$Errors)"
    }
    elseif ($EccErrors -gt 0) {
        $status = 'FAIL'
        $reason = "存在ECC错误(EccErrors=$EccErrors)"
    }
    elseif ($StartEventCount -gt 1 -or $MaxEventGapMin -gt $GapLimitMin -or $Stalled) {
        $status = 'FAIL'
        $reason = "测试中断(StartEventCount=$StartEventCount, MaxEventGapMin=${MaxEventGapMin} min, Stalled=$Stalled)"
    }
    elseif ($TempLimitC -gt 0) {
        if ($TempSamples -eq 0) {
            $status = 'FAIL'
            $reason = '温度数据缺失(TempSamples=0)'
        }
        elseif ($MaxTempC -gt $TempLimitC) {
            $status = 'FAIL'
            $reason = "温度超限(超温: MaxTempC=${MaxTempC} 超过上限 ${TempLimitC})"
        }
    }
    if ($status -eq 'PASS') {
        # 结论文案按输入动态生成（不硬编码"72h"）：时长 + 无错误/中断 + 温度判据状态
        $conclusion = "老化通过：{0} 分钟 ≥ 目标 {1} 分钟，Errors=0，ECC=0，无中断" -f $ActualMinutes, $TargetMinutes
        if ($TempLimitC -gt 0) {
            $conclusion += "，最高温 {0}°C ≤ {1}°C" -f $MaxTempC, $TempLimitC
        } else {
            $conclusion += "，温度判据未启用"
        }
    } else {
        $conclusion = $reason
    }
    return [PSCustomObject]@{ Status = $status; Conclusion = $conclusion }
}

# 从解析器 Events 数组提取 ORT 日志指标：start 事件计数、相邻事件最大间隔（分钟）、
# 日志跨度（分钟）。ts 为 MTLOG 秒值（string），差值/60 转分钟；仅 1 条事件时跨度=0。
function Get-OrTLogMetrics {
    param([object]$Summary)

    $events = @($Summary.Events)
    $startCount = @($events | Where-Object { $_.ev -eq 'start' }).Count
    $maxGapMin = 0.0
    $spanMin = 0.0
    $tsList = @()
    foreach ($ev in $events) {
        $ts = 0.0
        if ($null -ne $ev.ts -and [double]::TryParse([string]$ev.ts, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ts)) {
            $tsList += $ts
        }
    }
    if ($tsList.Count -gt 1) {
        $tsList = @($tsList | Sort-Object)
        $spanMin = ($tsList[$tsList.Count - 1] - $tsList[0]) / 60.0
        for ($i = 1; $i -lt $tsList.Count; $i++) {
            $gap = ($tsList[$i] - $tsList[$i - 1]) / 60.0
            if ($gap -gt $maxGapMin) { $maxGapMin = $gap }
        }
    }
    return [PSCustomObject]@{ StartEventCount = $startCount; MaxEventGapMin = $maxGapMin; LogSpanMinutes = $spanMin }
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

# 温度采样后台 Job：dot-source LibPath 后每 IntervalMin 分钟调一次 Get-IPMITempSensors，
# 长表 Timestamp,Sensor,TempC 追加写 CsvFile。MaxIterations=0 无限循环（生产），>0 为测试钩子。
function Start-OrTTempSampling {
    param(
        [string]$BmcHost,
        [string]$BmcUser,
        [string]$BmcPass,
        [string]$IpmiTool,
        [int]$IntervalMin = 60,
        [string]$CsvFile,
        [string]$LibPath,
        [int]$MaxIterations = 0
    )

    $scriptBlock = {
        param($BmcHost, $BmcUser, $BmcPass, $IpmiTool, $IntervalMin, $CsvFile, $LibPath, $MaxIterations)

        if ($LibPath -and (Test-Path -LiteralPath $LibPath)) { . $LibPath }
        if (-not (Get-Command Get-IPMITempSensors -ErrorAction SilentlyContinue)) {
            throw "未找到 Get-IPMITempSensors，请用 -LibPath 指定含该函数的脚本"
        }
        if (-not (Test-Path -LiteralPath $CsvFile)) {
            "Timestamp,Sensor,TempC" | Set-Content -LiteralPath $CsvFile -Encoding UTF8
        }
        $i = 0
        while ($MaxIterations -eq 0 -or $i -lt $MaxIterations) {
            try {
                $samples = @(Get-IPMITempSensors -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool)
                foreach ($s in $samples) {
                    "{0},{1},{2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $s.Sensor, $s.TempC |
                        Add-Content -LiteralPath $CsvFile -Encoding UTF8
                }
            } catch {
                Write-Warning "温度采样失败: $($_.Exception.Message)"
            }
            $i++
            if ($MaxIterations -gt 0 -and $i -ge $MaxIterations) { break }
            if ($IntervalMin -gt 0) { Start-Sleep -Seconds ($IntervalMin * 60) }
        }
    }

    return Start-Job -ScriptBlock $scriptBlock -ArgumentList $BmcHost, $BmcUser, $BmcPass, $IpmiTool, $IntervalMin, $CsvFile, $LibPath, $MaxIterations
}

# 停止温度采样 Job（停 Job → 收尾 → 读 CsvFile 统计最高温与采样行数）。
# 无采样数据时 MaxTempC=0、TempSamples=0（供判据"温度数据缺失"使用）。
function Stop-OrTTempSampling {
    param(
        [System.Management.Automation.Job]$Job,
        [string]$CsvFile,
        [int]$WaitSec = 30
    )

    if ($Job) {
        if ($Job.State -eq 'Running') { Stop-Job -Job $Job }
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ($Job.State -eq 'Running' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        Receive-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }

    $tempC = @()
    if ($CsvFile -and (Test-Path -LiteralPath $CsvFile)) {
        $tempC = @(Import-Csv -LiteralPath $CsvFile | ForEach-Object { [double]$_.TempC })
    }
    $maxTemp = 0.0
    if ($tempC.Count -gt 0) { $maxTemp = ($tempC | Measure-Object -Maximum).Maximum }
    return [PSCustomObject]@{ MaxTempC = $maxTemp; TempSamples = $tempC.Count }
}

# ORT 报告：写 <Batch>-ort-report.csv（16 列）+ master_manifest 追加一行（Slot=ALL，
# 复用现有 14 列投影合并，写法同 Export-TestReport）。ToolVersion 由调用方传入（函数内不读 VERSION）。
function Export-OrTReport {
    param(
        [string]$BatchName,
        [string]$ToolVersion,
        [object]$CaptureStart,
        [object]$CaptureEnd,
        [int]$TargetMinutes,
        [double]$ActualMinutes,
        [object]$Summary,
        [object]$Metrics,
        [object]$Verdict,
        [double]$MaxTempC,
        [int]$TempSamples,
        [bool]$Stalled = $false,
        [int]$GapLimitMin = 30,
        [string]$ReportDir,
        [string]$LogPath
    )

    $startTime = if ($CaptureStart -is [datetime]) { $CaptureStart.ToString("yyyy-MM-dd HH:mm:ss") } else { [string]$CaptureStart }
    $endTime   = if ($CaptureEnd -is [datetime])   { $CaptureEnd.ToString("yyyy-MM-dd HH:mm:ss") }   else { [string]$CaptureEnd }
    $totalPasses = if ($Summary) { $Summary.PassesCompleted } else { 0 }
    $interrupted = ($Metrics.StartEventCount -gt 1) -or ($Metrics.MaxEventGapMin -gt $GapLimitMin) -or $Stalled

    $row = [PSCustomObject]@{
        Batch           = $BatchName
        ToolVersion     = $ToolVersion
        Mode            = 'ORT'
        StartTime       = $startTime
        EndTime         = $endTime
        TargetMinutes   = $TargetMinutes
        ActualMinutes   = $ActualMinutes
        TotalPasses     = $totalPasses
        Errors          = if ($Summary) { $Summary.Errors } else { 0 }
        EccErrors       = if ($Summary) { $Summary.EccErrors } else { 0 }
        MaxTempC        = $MaxTempC
        TempSamples     = $TempSamples
        MaxEventGapMin  = if ($Metrics) { $Metrics.MaxEventGapMin } else { 0 }
        Interrupted     = $interrupted
        Status          = if ($Verdict) { $Verdict.Status } else { 'FAIL' }
        Conclusion      = if ($Verdict) { $Verdict.Conclusion } else { '' }
    }

    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    $file = Join-Path $ReportDir "$BatchName-ort-report.csv"
    $row | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    Write-Host "ORT 报告已生成: $file"

    # master_manifest 合成行（Slot=ALL；14 列清单与 Export-TestReport 一致，合并投影复用）
    $reportColumns = @(
        'Batch', 'ToolVersion', 'Slot', 'SerialNumber', 'PartNumber', 'CapacityGB',
        'SpeedMTs', 'MemType', 'MatchState', 'TestDate', 'Passes', 'Errors',
        'EccErrors', 'Result'
    )
    $masterRow = [PSCustomObject]@{
        Batch        = $BatchName
        ToolVersion  = $ToolVersion
        Slot         = 'ALL'
        SerialNumber = ''
        PartNumber   = ''
        CapacityGB   = 0
        SpeedMTs     = 0
        MemType      = ''
        MatchState   = ''
        TestDate     = $endTime
        Passes       = $totalPasses
        Errors       = if ($Summary) { $Summary.Errors } else { 0 }
        EccErrors    = if ($Summary) { $Summary.EccErrors } else { 0 }
        Result       = if ($Verdict -and $Verdict.Status -eq 'PASS') { 'ORT PASS' } else { 'ORT FAIL' }
    }
    $master = Join-Path $LogPath 'master_manifest.csv'
    $all = New-Object System.Collections.Generic.List[object]
    if (Test-Path $master) { $all.AddRange([object[]](Import-Csv -Path $master)) }
    $all.AddRange([object[]]@($masterRow))
    $all | Select-Object $reportColumns | Export-Csv -Path $master -NoTypeInformation -Encoding UTF8
    Write-Host "累计总表已更新: $master（共 $($all.Count) 条）"
}

# ----------------------------------------------------------------------------
# Prime95 混插长压：判定 / 日志统计 / 报告
# ----------------------------------------------------------------------------

# Prime95 结论判定（纯函数）：PASS = 足时长且无错误且未提前退出。
# 判定顺序：提前退出（根因，优先）→ 时长不足 → 错误。PASS 文案含实际/目标时长；
# FAIL 附原因（含关键词"时长不足/错误/提前退出"，供测试断言与结论文案使用）。
function Get-Prime95Verdict {
    param(
        [double]$ActualMinutes,
        [int]$TargetMinutes,
        [int]$ErrorCount = 0,
        [bool]$ExitedEarly = $false,
        [bool]$NoLogFile = $false
    )

    $status = 'PASS'
    $reason = ''
    if ($ExitedEarly) {
        $status = 'FAIL'
        $reason = 'Prime95 提前退出(ExitedEarly=true)'
    }
    elseif ($ActualMinutes -lt $TargetMinutes) {
        $status = 'FAIL'
        $reason = "时长不足(实际 ${ActualMinutes} 分钟 / 目标 ${TargetMinutes} 分钟)"
    }
    elseif ($ErrorCount -gt 0) {
        $status = 'FAIL'
        $reason = "检测到错误(ErrorCount=${ErrorCount})"
    }
    elseif ($NoLogFile) {
        $status = 'FAIL'
        $reason = '未生成 results.txt(Prime95 未实际运行或时长过短未完成首轮)'
    }
    if ($status -eq 'PASS') {
        $conclusion = "Prime95 长压通过：{0} 分钟 ≥ 目标 {1} 分钟，0 错误" -f $ActualMinutes, $TargetMinutes
    } else {
        $conclusion = $reason
    }
    return [PSCustomObject]@{ Status = $status; Conclusion = $conclusion }
}

# 统计 Prime95 日志错误：逐行匹配错误正则 FATAL ERROR / Self-test failed / FAILED，
# 返回 ErrorCount 与 HasErrors。文件不存在 → ErrorCount=0/HasErrors=$false；LastWriteTime 缺失→null。
function Get-Prime95LogStats {
    param([string]$LogFile)

    if (-not (Test-Path -LiteralPath $LogFile)) {
        return [PSCustomObject]@{ ErrorCount = 0; HasErrors = $false; LastWriteTime = $null }
    }

    $errRe = 'FATAL ERROR|Self-test failed|FAILED'
    $count = 0
    foreach ($line in Get-Content -LiteralPath $LogFile) {
        if ($line -match $errRe) { $count++ }
    }
    $lastWrite = (Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).LastWriteTime
    return [PSCustomObject]@{ ErrorCount = $count; HasErrors = ($count -gt 0); LastWriteTime = $lastWrite }
}

# Prime95 报告：写 <Batch>-prime95-report.csv（16 列）+ master_manifest 追加一行
# （Slot=ALL、Passes=0、Errors=ErrorCount、EccErrors=0、Result=`Prime95 $($Verdict.Status)`，
# 复用 ORT 的 14 列投影合并，写法同 Export-OrTReport）。ToolVersion 由调用方传入（函数内不读 VERSION）。
function Export-Prime95Report {
    param(
        [string]$BatchName,
        [string]$ToolVersion,
        [object]$StartTime,
        [object]$EndTime,
        [int]$TargetMinutes,
        [double]$ActualMinutes,
        [string]$Mode,
        [int]$ErrorCount = 0,
        [object]$Verdict,
        [string]$ReportDir,
        [string]$LogPath
    )

    $startTime = if ($StartTime -is [datetime]) { $StartTime.ToString("yyyy-MM-dd HH:mm:ss") } else { [string]$StartTime }
    $endTime   = if ($EndTime -is [datetime])   { $EndTime.ToString("yyyy-MM-dd HH:mm:ss") }   else { [string]$EndTime }

    $row = [PSCustomObject]@{
        Batch         = $BatchName
        ToolVersion   = $ToolVersion
        Mode          = $Mode
        StartTime     = $startTime
        EndTime       = $endTime
        TargetMinutes = $TargetMinutes
        ActualMinutes = $ActualMinutes
        ErrorCount    = $ErrorCount
        Status        = if ($Verdict) { $Verdict.Status } else { 'FAIL' }
        Conclusion    = if ($Verdict) { $Verdict.Conclusion } else { '' }
    }

    if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
    $file = Join-Path $ReportDir "$BatchName-prime95-report.csv"
    $row | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    Write-Host "Prime95 报告已生成: $file"

    # master_manifest 合成行（Slot=ALL；14 列清单与 Export-OrTReport 一致，合并投影复用）
    $reportColumns = @(
        'Batch', 'ToolVersion', 'Slot', 'SerialNumber', 'PartNumber', 'CapacityGB',
        'SpeedMTs', 'MemType', 'MatchState', 'TestDate', 'Passes', 'Errors',
        'EccErrors', 'Result'
    )
    $masterRow = [PSCustomObject]@{
        Batch        = $BatchName
        ToolVersion  = $ToolVersion
        Slot         = 'ALL'
        SerialNumber = ''
        PartNumber   = ''
        CapacityGB   = 0
        SpeedMTs     = 0
        MemType      = ''
        MatchState   = ''
        TestDate     = $endTime
        Passes       = 0
        Errors       = $ErrorCount
        EccErrors    = 0
        Result       = if ($Verdict -and $Verdict.Status) { "Prime95 $($Verdict.Status)" } else { "Prime95 FAIL" }
    }
    $master = Join-Path $LogPath 'master_manifest.csv'
    $all = New-Object System.Collections.Generic.List[object]
    if (Test-Path $master) { $all.AddRange([object[]](Import-Csv -Path $master)) }
    $all.AddRange([object[]]@($masterRow))
    $all | Select-Object $reportColumns | Export-Csv -Path $master -NoTypeInformation -Encoding UTF8
    Write-Host "累计总表已更新: $master（共 $($all.Count) 条）"
}

# 指令记录（cmdlog）：把本项目每次脚本调用记入 <包根>\results\cmdlog\commands-YYYY-MM-DD.csv。
# 常开、CSV、按日期滚动；敏感参数（-BmcPass/-P 密码）自动打码为 ***。
function Write-CmdLog {
    param(
        [string]$Script,
        [string]$CmdArgs = '',
        [string]$State = 'Start',
        [string]$Result = '',
        [int]$ExitCode = 0,
        [double]$DurationSec = 0
    )
    $masked = $CmdArgs
    foreach ($re in @(
        '(-BmcPass\s+)(\S+)',
        '(-BmcPass=)(\S+)',
        '(-P\s+)(\S+)',
        '(-P=)(\S+)'
    )) {
        $masked = $masked -replace $re, ('${1}' + '***')
    }
    $row = [PSCustomObject]@{
        Timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Machine      = $env:COMPUTERNAME
        Dir          = (Get-Location).Path
        Script       = $Script
        Args         = $masked
        State        = $State
        Result       = $Result
        ExitCode     = $ExitCode
        DurationSec  = $DurationSec
    }
    $logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'results\cmdlog'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $file = Join-Path $logDir ("commands-{0:yyyy-MM-dd}.csv" -f (Get-Date))
    if (-not (Test-Path -LiteralPath $file)) {
        $row | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8
    } else {
        $row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -LiteralPath $file -Encoding UTF8
    }
}
