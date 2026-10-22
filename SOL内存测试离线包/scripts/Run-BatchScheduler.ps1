# ============================================================================
# Run-BatchScheduler.ps1
# 批量批次调度器：读批次清单 CSV，逐批调用 Run-MemtestSuite.ps1，汇总全部结果。
#
# 用法示例：
#   .\Run-BatchScheduler.ps1 -ManifestCsv .\batches.csv
#   .\Run-BatchScheduler.ps1 -ManifestCsv .\batches.csv -DryRun
#   .\Run-BatchScheduler.ps1 -ManifestCsv .\batches.csv -ContinueOnError
#
# 批次清单 CSV 列：
#   BatchName, BootMethod, BmcHost, BmcUser, BmcPass, UsbDrive, EfiImage,
#   SerialPort, BaudRate, MaxPasses, TestList, ExpectedCsv,
#   MonitorEcc(yes), MonitorTemp(yes), RestartLoop, ConfirmSwitch(yes), LogPath
# 注意：TestList 含逗号时必须在 CSV 里用引号包裹（如 "0,1,2,3"）。
# ============================================================================

#requires -Version 5.1

param(
    [string]$ManifestCsv = "",

    [string]$SuiteScript = "",
    [string]$LogPath = "",
    [switch]$DryRun,
    [switch]$ContinueOnError,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# 共享库（识别/解析等公共逻辑，入库后统一抽取到 lib_common.ps1）
. $PSScriptRoot\lib_common.ps1

if ($Help) {
    Write-Host @"
批量批次调度器
---------------
参数：
  -ManifestCsv      批次清单 CSV（必填）
  -SuiteScript      Run-MemtestSuite.ps1 路径（默认与本脚本同目录）
  -LogPath          输出目录（默认 .\memory_results\，清单行内 LogPath 可覆盖）
  -DryRun           只打印将执行的命令，不真正运行
  -ContinueOnError  某批失败继续下一批（默认遇错停止）
  -Help             打印本帮助

批次清单 CSV 列：
  BatchName, BootMethod, BmcHost, BmcUser, BmcPass, UsbDrive, EfiImage,
  SerialPort, BaudRate, MaxPasses, TestList, ExpectedCsv,
  MonitorEcc(yes), MonitorTemp(yes), RestartLoop, ConfirmSwitch(yes), LogPath
  注意：TestList 含逗号时必须在 CSV 里用引号包裹（如 "0,1,2,3"）。
"@
    exit 0
}

if ($ManifestCsv -eq "") { Write-Error "缺少必填参数 -ManifestCsv"; exit 1 }
if (-not (Test-Path $ManifestCsv)) { Write-Error "批次清单不存在: $ManifestCsv"; exit 1 }
if ($SuiteScript -eq "") { $SuiteScript = Join-Path $PSScriptRoot "Run-MemtestSuite.ps1" }
if (-not (Test-Path $SuiteScript)) { Write-Error "编排脚本不存在: $SuiteScript"; exit 1 }
if ($LogPath -eq "") { $LogPath = Join-Path $PSScriptRoot "memory_results" }
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

# 健壮 CSV 读取已上移共享库（Read-CsvManifest，.NET TextFieldParser，保留行尾空字段）

$batches = Read-CsvManifest -Path $ManifestCsv
if ($batches.Count -eq 0) { Write-Error "批次清单为空"; exit 1 }

$summary = @()
$allRows = @()
$failed = 0

for ($i = 0; $i -lt $batches.Count; $i++) {
    $b = $batches[$i]
    $name = if ($b.BatchName) { $b.BatchName } else { "batch_$($i + 1)" }

    $runArgs = @{}
    $runArgs['BatchName'] = $name
    $runArgs['BootMethod'] = $b.BootMethod
    foreach ($k in @('BmcHost', 'BmcUser', 'BmcPass', 'UsbDrive', 'EfiImage', 'SerialPort', 'ExpectedCsv', 'TestList')) {
        if ($b.$k) { $runArgs[$k] = $b.$k }
    }
    if ($b.BaudRate -match '^\d+$') { $runArgs['BaudRate'] = [int]$b.BaudRate }
    if ($b.MaxPasses -match '^\d+$') { $runArgs['MaxPasses'] = [int]$b.MaxPasses }
    if ($b.MonitorEcc -eq 'yes') { $runArgs['MonitorEcc'] = $true }
    if ($b.MonitorTemp -eq 'yes') { $runArgs['MonitorTemp'] = $true }
    if ($b.RestartLoop -match '^\d+$') { $runArgs['RestartLoop'] = [int]$b.RestartLoop }
    if ($b.ConfirmSwitch -eq 'yes') { $runArgs['ConfirmSwitch'] = $true }
    if ($b.LogPath) { $runArgs['LogPath'] = $b.LogPath }

    $cmd = "& '$SuiteScript' " + (($runArgs.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ')
    Write-Host ("[{0}/{1}] {2}" -f ($i + 1), $batches.Count, $cmd)

    if ($DryRun) { continue }

    $start = Get-Date
    $status = "OK"
    $errMsg = ""
    try {
        & $SuiteScript @runArgs
        if ($LASTEXITCODE -ne 0) { throw "编排脚本退出码 $LASTEXITCODE" }
    } catch {
        $status = "FAIL"
        $errMsg = $_.Exception.Message
        $failed++
        Write-Warning ("批次 {0} 失败: {1}" -f $name, $errMsg)
        if (-not $ContinueOnError) {
            Write-Warning "已停止（加 -ContinueOnError 可继续下一批）"
            break
        }
    }
    $end = Get-Date

    $summary += [PSCustomObject]@{
        Batch  = $name
        Start  = $start.ToString("yyyy-MM-dd HH:mm:ss")
        End    = $end.ToString("yyyy-MM-dd HH:mm:ss")
        Status = $status
        Error  = $errMsg
    }

    # 汇总该批次逐根报告（若已生成）
    $repDir = if ($b.LogPath) { Join-Path $b.LogPath "reports" } else { Join-Path $LogPath "reports" }
    $repFile = Join-Path $repDir "$name-report.csv"
    if (Test-Path $repFile) {
        $allRows += Import-Csv -Path $repFile
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "DryRun 完成：仅打印命令，未执行任何批次，未写入文件。"
    exit 0
}

# 输出批次汇总
$sumFile = Join-Path $LogPath ("batch-summary-{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$summary | Export-Csv -Path $sumFile -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "批次汇总 -> $sumFile"
$summary | Format-Table Batch, Start, End, Status, Error -AutoSize

# 输出逐根汇总
if ($allRows.Count -gt 0) {
    $aggFile = Join-Path $LogPath ("all-batches-report-{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $allRows | Export-Csv -Path $aggFile -NoTypeInformation -Encoding UTF8
    Write-Host "逐根汇总 -> $aggFile（$($allRows.Count) 条）"
} else {
    Write-Host "（未汇总到任何逐根报告——可能为 DryRun 或批次未产出报告）"
}

# 输出批次级汇总文本 all-batches-summary.txt（UTF-8 BOM；无逐根报告则跳过）
if ($allRows.Count -gt 0) {
    $sumTxt = Join-Path $LogPath ("all-batches-summary-{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    # 对 all-batches-report 的 Result 列做 PASS / FAIL / INCOMPLETE / 未测 计数
    $countPass = 0; $countFail = 0; $countIncomplete = 0; $countUntested = 0; $countOther = 0
    foreach ($g in ($allRows | Group-Object Result)) {
        switch ($g.Name) {
            'PASS'       { $countPass = $g.Count }
            'FAIL'       { $countFail = $g.Count }
            'INCOMPLETE' { $countIncomplete = $g.Count }
            '未测'        { $countUntested = $g.Count }
            default      { $countOther += $g.Count }
        }
    }

    # 起始/结束时间与总耗时（数据即上述 batch-summary.csv 的 $summary）
    $firstStart = [datetime]::ParseExact($summary[0].Start, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $lastEnd    = [datetime]::ParseExact($summary[$summary.Count - 1].End, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
    $elapsed    = $lastEnd - $firstStart

    $lines = @(
        "===== DDR5 内存条 SOL 验收 · 批次汇总 =====",
        ("生成时间: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
        ("批次总数: {0}" -f $summary.Count),
        ("逐根总数: {0}" -f $allRows.Count),
        "",
        "结果统计（all-batches-report Result 列）:",
        ("  PASS:        {0}" -f $countPass),
        ("  FAIL:        {0}" -f $countFail),
        ("  INCOMPLETE:  {0}" -f $countIncomplete),
        ("  未测:        {0}" -f $countUntested),
        ("  其他:        {0}" -f $countOther),
        "",
        ("时间区间: {0} ~ {1}" -f $summary[0].Start, $summary[$summary.Count - 1].End),
        ("总耗时: {0} 小时 {1} 分 {2} 秒" -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)
    )
    $lines | Out-File -FilePath $sumTxt -Encoding UTF8
    Write-Host "批次汇总文本 -> $sumTxt"
} else {
    Write-Host "（跳过 all-batches-summary.txt：无逐根报告）"
}

if ($failed -gt 0) { exit 1 }
