# ============================================================================
# Export-ServerResults.ps1
# 服务器侧结果一键打包（结果归集：服务器 → 编排机，经 U盘搬运）
#
# 定位：把被测服务器 <包根>\results\ 里应归集的结果（建档 *.csv、
#       master_manifest.csv、reports\、work\、assessment\、cmdlog\、
#       任务清单 results\<批次>\任务清单-*.md）打包成
#       <机器名>-results-YYYYMMDD.zip（zip 顶层另含 _export-meta.txt 元信息），
#       产物放 <包根>\results\export\，由编排机 Import-ServerResults.ps1 导入。
#       排除 export\（导出产物自身，防递归）、raw\、imported\（编排机侧产物）。
#
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Export-ServerResults.ps1
#   .\scripts\Export-ServerResults.ps1 -MachineName srv01
#   .\scripts\Export-ServerResults.ps1 -MachineName srv01 -ResultsDir D:\memtest\results -OutDir E:\backup
# ============================================================================

#requires -Version 5.1

param(
    [string]$MachineName = "srv01",   # 用于 zip 文件名与 staging 目录名
    [string]$ResultsDir = "",         # 默认 <包根>\results
    [string]$OutDir = ""              # 默认 <包根>\results\export
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（Write-CmdLog / Get-AppVersion）
. $PSScriptRoot\lib_common.ps1

# 默认值
if ($ResultsDir -eq "") { $ResultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results" }
if ($OutDir -eq "") { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results\export" }

# 指令记录：本次调用入库（本脚本无敏感参数）
$scriptStartTime = Get-Date

# 校验 0：ResultsDir 必须存在（须在 Write-CmdLog Start 之前检查——
#   Start 会自建 <包根>\results\cmdlog、连带建出 <包根>\results；
#   若默认 ResultsDir 缺失时先 Start 再检查，存在性检查将失效，
#   报错会变成"无结果可导出"而非"结果目录不存在"）
if (-not (Test-Path -LiteralPath $ResultsDir)) {
    Write-Host "错误: 结果目录不存在（$ResultsDir）"
    # Start 尚未写：先补写 Start 再写 End，保持 cmdlog 的 Start/End 对
    Write-CmdLog -Script 'Export-ServerResults' -CmdArgs $MyInvocation.Line -State Start
    Write-CmdLog -Script 'Export-ServerResults' -State End -Result 'FAIL: ResultsDir 不存在' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# 预检 6 项（cmdlog 源状态须在 Start 之前记录：Write-CmdLog Start 会自建
#   <包根>\results\cmdlog\commands-<今日>.csv，若以复制结果判定会把"无结果"
#   误判为有内容——cmdlog 用 Start 前的源状态，其余 5 项 Start 前后不受影响）
$hasCmdlogSrc = Test-Path -LiteralPath (Join-Path $ResultsDir 'cmdlog')

Write-CmdLog -Script 'Export-ServerResults' -CmdArgs $MyInvocation.Line -State Start

# 校验 1：OutDir 不存在则创建
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# 6 项全缺判定（依据 Start 前的源状态）
$hasMaster  = Test-Path -LiteralPath (Join-Path $ResultsDir 'master_manifest.csv')
$hasCsvs    = @(Get-ChildItem -LiteralPath $ResultsDir -File -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'master_manifest.csv' }).Count -gt 0
$hasReports = Test-Path -LiteralPath (Join-Path $ResultsDir 'reports')
$hasWork    = Test-Path -LiteralPath (Join-Path $ResultsDir 'work')
$hasAssess  = Test-Path -LiteralPath (Join-Path $ResultsDir 'assessment')
if (-not ($hasMaster -or $hasCsvs -or $hasReports -or $hasWork -or $hasAssess -or $hasCmdlogSrc)) {
    Write-Host "错误: 无结果可导出（$ResultsDir 中 master_manifest.csv / 建档 csv / reports\ / work\ / assessment\ / cmdlog\ 均不存在）"
    Write-CmdLog -Script 'Export-ServerResults' -State End -Result 'FAIL: 无结果可导出' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

$dateStr = Get-Date -Format "yyyyMMdd"
$staging = Join-Path $OutDir "staging\$MachineName-$dateStr"
$zipPath = Join-Path $OutDir "$MachineName-results-$dateStr.zip"

# 主流程：staging 复制 6 项 + 任务清单 → 写 meta → 压缩 → cmdlog End → exit 0
# 运行期异常由 catch 兜底补写 cmdlog End（FAIL）后 exit 1；staging 由 finally 保证失败也清理
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    # 1) master_manifest.csv
    $srcMaster = Join-Path $ResultsDir 'master_manifest.csv'
    if (Test-Path -LiteralPath $srcMaster) {
        Copy-Item -LiteralPath $srcMaster -Destination (Join-Path $staging 'master_manifest.csv') -ErrorAction SilentlyContinue
    }
    # 2) 建档 *.csv（ResultsDir 根下，排除 master_manifest.csv）
    foreach ($csv in @(Get-ChildItem -LiteralPath $ResultsDir -File -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'master_manifest.csv' })) {
        Copy-Item -LiteralPath $csv.FullName -Destination (Join-Path $staging $csv.Name) -ErrorAction SilentlyContinue
    }
    # 3) 目录项（reports\ work\ assessment\ cmdlog\；顶层结构保持，逐项 Test-Path）
    foreach ($d in @('reports', 'work', 'assessment', 'cmdlog')) {
        $srcDir = Join-Path $ResultsDir $d
        if (Test-Path -LiteralPath $srcDir) {
            Copy-Item -LiteralPath $srcDir -Destination $staging -Recurse -ErrorAction SilentlyContinue
        }
    }

    # 4) 任务清单（results\<批次>\任务清单-*.md）：所在批次目录整个复制进 staging，
    #    顶层保持 <批次>\ 结构（zip 顶层出现批次目录）。排除 export\ raw\ imported\
    #    子树——与既有排除逻辑一致，不误伤 results\<批次>\ 下的清单。
    $checklistDirs = @(
        Get-ChildItem -LiteralPath $ResultsDir -Recurse -Filter '任务清单-*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(export|raw|imported)(\\|$)' } |
        Select-Object -ExpandProperty Directory -Unique
    )
    foreach ($cd in $checklistDirs) {
        Copy-Item -LiteralPath $cd.FullName -Destination $staging -Recurse -ErrorAction SilentlyContinue
    }

    # _export-meta.txt（UTF8 无 BOM，随 zip 顶层带走）
    $meta = @(
        "MachineName=$MachineName",
        "ServerResultsDir=$ResultsDir",
        "ExportTime=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "ToolVersion=$(Get-AppVersion)"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $staging '_export-meta.txt'), $meta + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

    # 打包（staging 内容 → zip，顶层即 6 项 + meta；同日重导同名 zip 覆盖）
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $fileCount = @(Get-ChildItem -LiteralPath $staging -Recurse -File).Count
    Write-Host "导出完成: $zipPath（$fileCount 个文件）"
    Write-CmdLog -Script 'Export-ServerResults' -State End -Result "Exported $zipPath ($fileCount 文件)" -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Write-Host "错误: 导出失败: $($_.Exception.Message)"
    Write-CmdLog -Script 'Export-ServerResults' -State End -Result ("FAIL: " + $_.Exception.Message) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
} finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
