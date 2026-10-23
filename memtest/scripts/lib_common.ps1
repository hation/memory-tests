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
            "uecc" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields } }
            "ecc" { $summary.ErrorDetails += [PSCustomObject]@{ Type = $event; Fields = $fields } }
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
