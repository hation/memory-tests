# ============================================================================
# Import-ServerResults.ps1
# 编排机侧结果导入（结果归集：服务器 → 编排机，经 U盘搬运）
#
# 定位：把服务器导出的 <机器名>-results-YYYYMMDD.zip（经 U盘拷到编排机）导入到
#       <ImportRoot>\imported\<机器名>\。累积式：直接并入、不清理旧内容——
#       同名文件被新导入覆盖，旧批次独有文件保留。zip 内任务清单
#       （<批次>\任务清单-*.md）解压后并入编排机 results\<批次>\（调
#       Merge-TaskChecklists 逐行取有状态方；失败仅警告，不影响导入主流程）。
#       防重复：imported\import-log.csv
#       已含相同 ZipName 时默认跳过（不追加 log、exit 0）；-Force 允许重导（重新
#       解压覆盖同名；Note 按是否已导入过判定：已导入记"重导"，首次导入记"首次导入"）。
#       import-log.csv 字段：
#       ImportTime,MachineName,ZipName,FileCount（本次导入的 zip 条目数）,SourceDir,Note；
#       SourceDir 读 zip 内 _export-meta.txt 的 ServerResultsDir（meta 缺失留空）。
#       机器名：显式 -MachineName 优先，否则从 zip 文件名正则
#       ^(.+)-results-\d{8}\.zip$ 解析，解析失败报错 exit 1。
#
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Import-ServerResults.ps1 -ZipPath E:\srv01-results-20261026.zip
#   .\scripts\Import-ServerResults.ps1 -ZipPath E:\srv01-results-20261026.zip -Force
#   .\scripts\Import-ServerResults.ps1 -ZipPath E:\srv01-results-20261026.zip -MachineName srv01 -ImportRoot D:\memtest\results
# ============================================================================

#requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$ZipPath,            # U盘里的导出 zip（必填）
    [string]$MachineName = "",   # 缺省从 zip 文件名正则解析，显式优先
    [string]$ImportRoot = "",    # 默认 <包根>\results
    [switch]$Force               # 重导（import-log 已含同 ZipName 时覆盖重导）
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（Write-CmdLog）
. $PSScriptRoot\lib_common.ps1

# 默认值
if ($ImportRoot -eq "") { $ImportRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "results" }

# 指令记录：本次调用入库（本脚本无敏感参数）
$scriptStartTime = Get-Date
$scriptName = 'Import-ServerResults'

Write-CmdLog -Script $scriptName -CmdArgs $MyInvocation.Line -State Start

# 校验 1：ZipPath 必须存在且以 .zip 结尾
if (-not (Test-Path -LiteralPath $ZipPath)) {
    Write-Host "错误: zip 不存在（$ZipPath）"
    Write-CmdLog -Script $scriptName -State End -Result 'FAIL: ZipPath 不存在' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
if ($ZipPath -notmatch '\.zip$') {
    Write-Host "错误: 非 zip 文件（$ZipPath），仅支持 .zip 结尾的导出包"
    Write-CmdLog -Script $scriptName -State End -Result 'FAIL: 非 zip 文件' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# 机器名解析：显式 -MachineName 优先；否则从 zip 文件名正则解析
$zipName = Split-Path -Leaf $ZipPath
if ($MachineName -eq "") {
    if ($zipName -match '^(.+)-results-\d{8}\.zip$') {
        $MachineName = $matches[1]
    } else {
        Write-Host "错误: 无法从文件名解析机器名（$zipName），请显式指定 -MachineName"
        Write-CmdLog -Script $scriptName -State End -Result 'FAIL: 机器名解析失败' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
}

# 机器名白名单校验：只允许字母/数字开头，后续字符限 [A-Za-z0-9._-]，
# 拒绝 `..`、路径分隔符等值逃出 <ImportRoot>\imported\ 隔离目录（防路径穿越）
if ($MachineName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    Write-Host "错误: 机器名非法（$MachineName）"
    Write-CmdLog -Script $scriptName -State End -Result 'FAIL: 机器名非法' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# 主流程：判重 → Skip 或 解压 → 读 meta 填 SourceDir → 合并任务清单 → 统计文件数 → 追加 import-log → End exit 0
# 运行期异常由 catch 兜底补写 cmdlog End（FAIL）后 exit 1
try {
    $importedRoot = Join-Path $ImportRoot 'imported'
    $targetDir = Join-Path $importedRoot $MachineName
    $logFile = Join-Path $importedRoot 'import-log.csv'

    # 防重复：import-log 已含相同 ZipName → 无 -Force 跳过（不追加 log）；有 -Force 重导
    $already = $false
    if (Test-Path -LiteralPath $logFile) {
        $already = @(Import-Csv -LiteralPath $logFile | Where-Object { $_.ZipName -eq $zipName }).Count -gt 0
    }
    if ($already -and -not $Force) {
        Write-Host "跳过: 已导入过 $zipName（如需重导请加 -Force）"
        Write-CmdLog -Script $scriptName -State End -Result "Skip: 已导入过 $zipName" -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 0
    }

    # 累积式解压：并入 <ImportRoot>\imported\<机器名>\，不清理旧内容；同名文件覆盖
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    # FileCount：本次导入的文件数 = zip 内条目数（解压前统计，避免累积目录计数失真）
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fc = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $fileCount = $fc.Entries.Count
    $fc.Dispose()

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $targetDir -Force

    # SourceDir：读 zip 内 _export-meta.txt 的 ServerResultsDir（meta 缺失留空）
    $sourceDir = ""
    $metaFile = Join-Path $targetDir '_export-meta.txt'
    if (Test-Path -LiteralPath $metaFile) {
        foreach ($line in Get-Content -LiteralPath $metaFile -Encoding UTF8) {
            if ($line -match '^ServerResultsDir=(.*)$') { $sourceDir = $matches[1].Trim(); break }
        }
    }

    # 任务清单归集合并（副作用：失败仅 Warning，不影响导入主流程；cmdlog 由既有逻辑负责）。
    # 清单位于解压目标 <批次>\ 子目录（服务器 results 导出包形态），或直接位于解压目标根
    # （清单裸打包形态，批次回退为机器名）。调 Merge-TaskChecklists 把服务器清单并入
    # 编排机 <ImportRoot>\<批次>\（不存在则建），写回编排机 results\<批次>\。
    try {
        $checklistFiles = @(Get-ChildItem -LiteralPath $targetDir -Recurse -Filter '任务清单-*.md' -File -ErrorAction SilentlyContinue)
        if ($checklistFiles.Count -gt 0) {
            $targetFull = (Get-Item -LiteralPath $targetDir).FullName.TrimEnd('\')
            foreach ($bd in @($checklistFiles | ForEach-Object { $_.Directory.FullName } | Select-Object -Unique)) {
                $rel = if ($bd.StartsWith($targetFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $bd.Substring($targetFull.Length).TrimStart('\') } else { $MachineName }
                $batch = if ($rel -eq '') { $MachineName } else { $rel }
                $orchDir = Join-Path $ImportRoot $batch
                Merge-TaskChecklists -ServerChecklistDir $bd -OrchestratorChecklistDir $orchDir -MachineName $MachineName | Out-Null
                Write-Host "任务清单合并: $bd → $orchDir"
            }
        }
    } catch {
        Write-Host "警告: 任务清单合并失败（不影响导入结果）: $($_.Exception.Message)"
    }

    # import-log 追加一行（首次导入 / 重导，按是否已导入过该 ZipName 判定；追加不覆盖）
    $row = [PSCustomObject][ordered]@{
        ImportTime  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        MachineName = $MachineName
        ZipName     = $zipName
        FileCount   = $fileCount
        SourceDir   = $sourceDir
        Note        = if ($already) { '重导' } else { '首次导入' }
    }
    if (Test-Path -LiteralPath $logFile) {
        $row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -LiteralPath $logFile -Encoding UTF8
    } else {
        $row | Export-Csv -LiteralPath $logFile -NoTypeInformation -Encoding UTF8
    }

    Write-Host "导入完成: $zipName → $targetDir（$fileCount 个文件）"
    Write-CmdLog -Script $scriptName -State End -Result "Imported $fileCount 文件 → $targetDir" -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Write-Host "错误: 导入失败: $($_.Exception.Message)"
    Write-CmdLog -Script $scriptName -State End -Result ("FAIL: " + $_.Exception.Message) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
