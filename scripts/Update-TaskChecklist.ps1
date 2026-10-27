# ============================================================================
# Update-TaskChecklist.ps1 — 人工更新流程清单某环节（状态/结果/产物）
# 薄壳：只做参数默认值/校验/cmdlog/组装清单路径/调用 lib_common 的
#       Update-TaskChecklist；核心逻辑（行定位/UTF-8 写回）在 lib_common.ps1。
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Update-TaskChecklist.ps1 -BatchName srv01-a1 -Flow 目检电性 -Key 目检金手指焊点 -Status ✓ -Result 无氧化 -Product 无
#   .\scripts\Update-TaskChecklist.ps1 -BatchName srv01-a1 -Flow L3外包 -Key 电压/时序/高低温/湿热/ESD/振动/冲击/弯曲 送检 -Status ⚠ -Result 外包送检
# ============================================================================

#requires -Version 5.1

param(
    [string]$BatchName = "",       # 验收批次（必填）
    [ValidateSet('建档','Memtest','混插','ECC','断电循环','ORT','Prime95','多平台','目检电性','L3外包')]
    [string]$Flow = "",            # 流程清单名（必填，10 选一）
    [string]$Key = "",             # 环节名（必填）
    [string]$Status = "",          # 状态（✓/✗/─/⏳/⚠ 前缀，必填）
    [string]$Result = "",          # 结果摘要（可选）
    [string]$Product = ""          # 产物（可选）
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（Update-TaskChecklist / Write-CmdLog）
. $PSScriptRoot\lib_common.ps1

# 指令记录：本次调用入库（本脚本无敏感参数）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Update-TaskChecklist' -CmdArgs $MyInvocation.Line -State Start

# 主流程：校验 → 更新一行 → cmdlog End → exit 0
# 失败路径由 catch 兜底补写 cmdlog End（FAIL）后 exit 1（沿用 Run-Prime95Stress 教训）
try {
    if ($BatchName -eq "") { throw "错误: -BatchName 必填（验收批次）" }
    if ($Flow -eq "") { throw "错误: -Flow 必填（建档/Memtest/混插/ECC/断电循环/ORT/Prime95/多平台/目检电性/L3外包）" }
    if ($Key -eq "") { throw "错误: -Key 必填（环节名）" }
    if ($Status -eq "") { throw "错误: -Status 必填（✓/✗/─/⏳/⚠ 前缀）" }
    if ($Status -notmatch '^[✓✗─⏳⚠]') { throw "非法状态值: '$Status'（状态集：✓ 做成 / ✗ 没做成 / ─ 本次没做 / ⏳ 进行中 / ⚠ 无法测试）" }
    $resultsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results"
    $checklistPath = Join-Path $resultsDir "$BatchName\任务清单-$Flow.md"
    if (-not (Test-Path -LiteralPath $checklistPath)) {
        Write-Host "提示：清单不存在（$checklistPath），未更新（先运行 New-TaskChecklist.ps1 建档）"
    } else {
        Update-TaskChecklist -ChecklistPath $checklistPath -Key $Key -Status $Status -Result $Result -Product $Product
        Write-Host "已更新：$checklistPath（$Key → $Status）"
    }
    Write-CmdLog -Script 'Update-TaskChecklist' -State End -Result ("OK: " + $checklistPath) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Write-Host "错误: $($_.Exception.Message)"
    Write-CmdLog -Script 'Update-TaskChecklist' -State End -Result ("FAIL: " + $_.Exception.Message) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
