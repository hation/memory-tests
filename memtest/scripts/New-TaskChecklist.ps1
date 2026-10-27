# ============================================================================
# New-TaskChecklist.ps1 — 建立验收批次任务清单（总览 17 项 + 10 张流程清单）
# 薄壳：只做参数默认值/校验/cmdlog/调用 lib_common 的 New-TaskChecklist；
#       核心逻辑（清单结构/评估标注/UTF-8 写入）在 lib_common.ps1。
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\New-TaskChecklist.ps1 -BatchName srv01-a1
#   .\scripts\New-TaskChecklist.ps1 -BatchName srv01-a1 -ChecklistBatch srv01-a1 -MachineName srv01
#   .\scripts\New-TaskChecklist.ps1 -BatchName srv01-a1 -ExpectedCsv D:\cap\srv01-assessment.csv
# ============================================================================

#requires -Version 5.1

param(
    [string]$BatchName = "",       # 建档批次（必填）
    [string]$ChecklistBatch = "",  # 验收批次（缺省=BatchName）
    [string]$MachineName = "",     # 机器名（评估 CSV 匹配用，缺省=本机）
    [string]$ExpectedCsv = ""      # 能力评估 CSV（可选，缺省自动按 MachineName 定位）
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（New-TaskChecklist / Write-CmdLog / Get-AppVersion）
. $PSScriptRoot\lib_common.ps1

# 指令记录：本次调用入库（本脚本无敏感参数）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'New-TaskChecklist' -CmdArgs $MyInvocation.Line -State Start

# 主流程：校验 → 建清单 → cmdlog End → exit 0
# 失败路径由 catch 兜底补写 cmdlog End（FAIL）后 exit 1（沿用 Run-Prime95Stress 教训）
try {
    if ($BatchName -eq "") { throw "错误: -BatchName 必填（建档批次）" }
    if ($ChecklistBatch -eq "") { $ChecklistBatch = $BatchName }
    $resultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results"
    $dir = New-TaskChecklist -ChecklistBatch $ChecklistBatch -MachineName $MachineName -ResultsDir $resultsDir -AssessmentCsv $ExpectedCsv
    Write-Host "任务清单已生成：$dir"
    Write-CmdLog -Script 'New-TaskChecklist' -State End -Result ("OK: " + $dir) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Write-Host "错误: $($_.Exception.Message)"
    Write-CmdLog -Script 'New-TaskChecklist' -State End -Result ("FAIL: " + $_.Exception.Message) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
