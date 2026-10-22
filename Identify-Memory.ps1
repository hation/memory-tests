# ============================================================================
# Identify-Memory.ps1
# 用途：智能识别当前电脑所有内存槽位上的 DDR5 内存条，自动采集 SPD 信息并分类，
#       输出带时间戳的批次清单 CSV（memory_results\<批次>.csv），供批量验收使用。
#
# 用法：
#   .\Identify-Memory.ps1 -BatchName "batch01"
#   .\Identify-Memory.ps1 -ExpectedCsv "C:\path\expected.csv" -BatchName "batch01"
#
# 参数：
#   -ExpectedCsv  可选。预期清单 CSV 路径，需包含 SerialNumber 列；
#                 若包含 Capacity(GB) 列则额外校验容量是否一致。
#   -BatchName    可选。批次名称，用于生成文件名；缺省按时间戳自动生成。
# ============================================================================

param(
    [string]$ExpectedCsv = "",
    [string]$BatchName = ""
)

$ErrorActionPreference = 'Stop'

# ---------- 输出目录 ----------
$outDir = Join-Path $PSScriptRoot "memory_results"
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($BatchName -eq "") { $BatchName = "batch_$stamp" }

# ---------- 读取预期清单（若提供） ----------
$expected = @()
if ($ExpectedCsv -ne "" -and (Test-Path $ExpectedCsv)) {
    $expected = Import-Csv -Path $ExpectedCsv
    Write-Host "已加载预期清单: $ExpectedCsv（$($expected.Count) 条）"
}

# ---------- 采集所有内存槽信息 ----------
$memSticks = Get-CimInstance -ClassName Win32_PhysicalMemory
if (-not $memSticks) {
    Write-Host "未读取到任何内存信息，请确认内存条已安装且系统正常。"
    exit 1
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

    # SPD 序列号常有前导 0，清洗后判空
    $serial = ($m.SerialNumber -replace '^0+', '').Trim()
    if ($serial -eq "") { $serial = "UNKNOWN" }
    $pn = ($m.PartNumber -replace '\s', '').Trim()

    # ---------- 智能分类规则 ----------
    $issues = @()
    if ($memType -ne "DDR5") { $issues += "非DDR5($memType)" }
    if ($serial -eq "UNKNOWN") { $issues += "SPD无序列号" }
    if ($pn -eq "") { $issues += "SPD无型号" }
    if ($capGB -eq 0) { $issues += "容量读取异常" }

    # 与预期清单匹配
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

    $status = if ($issues.Count -eq 0) { "正常" } else { "待复核" }

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
        Status       = $status
        TestResult   = ""   # 由后续压测环节回填
        TestDate     = ""   # 由后续压测环节回填
    }
}

# ---------- 输出批次清单 ----------
$file = Join-Path $outDir "$BatchName.csv"
$rows | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "批次清单已生成: $file"
Write-Host "本批识别 $($rows.Count) 根，其中待复核 $(( $rows | Where-Object Status -eq '待复核' ).Count) 根"
Write-Host ""
$rows | Format-Table Slot, SerialNumber, PartNumber, CapacityGB, SpeedMTs, MemType, MatchState, Status -AutoSize

# ---------- 追加到累计总表（逐根可追溯） ----------
$master = Join-Path $outDir "master_manifest.csv"
$allRows = @()
if (Test-Path $master) {
    $allRows += Import-Csv -Path $master
}
$allRows += $rows
$allRows | Export-Csv -Path $master -NoTypeInformation -Encoding UTF8
Write-Host "累计总表已更新: $master（当前共 $($allRows.Count) 条记录）"
