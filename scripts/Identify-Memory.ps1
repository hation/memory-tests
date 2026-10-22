# ============================================================================
# Identify-Memory.ps1
# 用途：智能识别当前电脑所有内存槽位上的 DDR5 内存条，自动采集 SPD 信息并分类，
#       输出带时间戳的批次清单 CSV（<包根>\results\<批次>.csv），供批量验收使用。
#
# 用法（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Identify-Memory.ps1 -BatchName "batch01"
#   .\scripts\Identify-Memory.ps1 -ExpectedCsv "C:\path\expected.csv" -BatchName "batch01"
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

# 共享库（识别/解析等公共逻辑，入库后统一抽取到 lib_common.ps1）
. $PSScriptRoot\lib_common.ps1

# ---------- 输出目录 ----------
$outDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results"
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($BatchName -eq "") { $BatchName = "batch_$stamp" }

# ---------- 采集所有内存槽信息（复用共享库 Get-MemoryInventory；预期清单由库内单次加载匹配） ----------
$inventory = @(Get-MemoryInventory -ExpectedCsv $ExpectedCsv -BatchName $BatchName)
if ($inventory.Count -eq 0) {
    Write-Host "未读取到任何内存信息，请确认内存条已安装且系统正常。"
    exit 1
}

# 保留原输出扩展列（TestResult/TestDate 由后续压测环节回填）
$rows = @()
foreach ($inv in $inventory) {
    $inv | Add-Member -NotePropertyName TestResult -NotePropertyValue "" -Force
    $inv | Add-Member -NotePropertyName TestDate -NotePropertyValue "" -Force
    $rows += $inv
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
