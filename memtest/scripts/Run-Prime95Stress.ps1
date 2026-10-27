# ============================================================================
# Run-Prime95Stress.ps1
# Prime95 混插长压自动化工具（无界面无人值守，Windows PowerShell）
#
# 定位：以无人值守方式运行 Prime95（torture test），按时长/错误自动判定
#       PASS/FAIL，生成批次报告（results\reports\<批次>-prime95-report.csv）
#       并合成 master_manifest.csv 合成行（Slot=ALL，Result=`Prime95 PASS/FAIL`）。
#
# 用法示例（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Run-Prime95Stress.ps1 -Help
#   .\scripts\Run-Prime95Stress.ps1 -BatchName p95-batch01 -Minutes 180 -Mode Blend
#   .\scripts\Run-Prime95Stress.ps1 -BatchName p95-batch01 -Minutes 1440 -Mode Large -Prime95Exe D:\tools\prime95\prime95.exe
# ============================================================================

#requires -Version 5.1

param(
    [string]$BatchName = "",
    [string]$Prime95Exe = "",
    [int]$Minutes = 180,
    [ValidateSet("Blend", "Large")]
    [string]$Mode = "Blend",
    [string]$LogPath = "",
    [switch]$Help
)

# ----------------------------------------------------------------------------
# 初始化
# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

# 共享库（Get-Prime95Verdict / Get-Prime95LogStats / Export-Prime95Report / Write-CmdLog / Get-AppVersion）
. $PSScriptRoot\lib_common.ps1

if ($Help) {
    Write-Host @"
Prime95 混插长压自动化工具（无界面无人值守）
---------------------------------------------
参数：
  -BatchName      批次名（缺省 p95_<时间戳>），用于文件名、工作目录与归集
  -Prime95Exe     prime95.exe 路径（缺省 <包根>\tools\prime95\prime95.exe）
  -Minutes        目标压测时长（分钟，默认 180；须 > 0，≤0 报错退出）
  -Mode           Blend | Large（默认 Blend）
  -LogPath        输出目录（默认 <包根>\results\）
  -Help           打印本帮助

用法示例（在离线包根目录运行，如 C:\memtest\）：
  .\scripts\Run-Prime95Stress.ps1 -Help
  .\scripts\Run-Prime95Stress.ps1 -BatchName p95-batch01 -Minutes 180 -Mode Blend
  .\scripts\Run-Prime95Stress.ps1 -BatchName p95-batch01 -Minutes 1440 -Mode Large -Prime95Exe D:\tools\prime95\prime95.exe

说明：
  - 无人值守：启动后最小化运行，默认每 30s 轮询；到点主动 Stop 收尾（正常）；
    未到点进程即退出判 FAIL（提前退出）
  - results.txt 出现 FATAL ERROR / Self-test failed / FAILED 立即终止并判 FAIL
  - 判定/报告/合成行由 lib_common.ps1 的 Get-Prime95Verdict / Get-Prime95LogStats /
    Export-Prime95Report 完成（报告 <LogPath>\reports\<批次>-prime95-report.csv +
    master_manifest.csv 合成行）
  - 实机冒烟提示：首次使用建议先 -Minutes 1 跑一遍，确认 prime95 正常启动、
    results.txt 生成后再跑长压；prime.txt 模式键（CpuStress/MemStress）留待实机
    冒烟回填，首版仅写 OutputJSON=0
"@
    exit 0
}

# 指令记录：本次调用入库（Help 已处理；本脚本无敏感参数）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Run-Prime95Stress' -CmdArgs $MyInvocation.Line -State Start

# 默认值
if ($BatchName -eq "") { $BatchName = "p95_" + (Get-Date -Format "yyyyMMdd_HHmmss") }
if ($Prime95Exe -eq "") { $Prime95Exe = Join-Path (Split-Path -Parent $PSScriptRoot) "tools\prime95\prime95.exe" }
if ($LogPath -eq "") { $LogPath = Join-Path (Split-Path -Parent $PSScriptRoot) "results" }
$reportDir = Join-Path $LogPath "reports"
$workDir   = Join-Path $LogPath "work\$BatchName"

# 校验
if ($Minutes -le 0) {
    Write-Host "错误: -Minutes 非法（$Minutes），须为大于 0 的整数"
    Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result 'FAIL: Minutes 非法' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
if (-not (Test-Path -LiteralPath $Prime95Exe)) {
    Write-Host "错误: Prime95 不存在（$Prime95Exe）"
    Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result 'FAIL: Prime95 不存在' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# 校验通过后才建目录（校验失败不留空目录）
foreach ($d in @($LogPath, $reportDir, $workDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# 并发防护：检测已有 prime95 进程（同名进程，排除自身 PID）
$existing = @(Get-Process -Name 'prime95' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
if ($existing.Count -gt 0) {
    Write-Host "错误: prime95 已在运行（PID: $($existing.Id -join ', ')），请先结束后再启动本工具"
    Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result 'FAIL: prime95 已在运行' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}

# Prime95 以可执行文件所在目录为基础工作目录（-W 命令行实测无效，见 2026-10 实机冒烟）。
# 服务器实测：exe 目录无 prime.txt（首次运行）+ `-t` 即自动开始默认 Blend，results.txt 写进 exe 目录。
# 因此：运行前清空 exe 目录旧运行产物（恢复"首次"自动跑条件）；运行期间轮询 exe 目录 results.txt 判错；
# 结束后把结果文件归档到批次目录 workDir（合适目录，归集脚本可带走）。
$prime95Dir = Split-Path -Parent $Prime95Exe
foreach ($f in @('prime.txt', 'results.txt', 'screen.log', 'local.txt')) {
    Remove-Item (Join-Path $prime95Dir $f) -Force -ErrorAction SilentlyContinue
}

# 主流程：启动 → 轮询 → 判定 → 报告 → cmdlog End → exit 0
# 运行期异常由 catch 兜底补写 cmdlog End（FAIL）后 exit 1（参照 build.ps1 失败路径风格）
try {
    # 启动：-t 自动开始默认 Blend（无需模式键，2026-10 服务器实测）；不带 -W（实测无效），结果落在 exe 目录
    $p = Start-Process -FilePath $Prime95Exe -ArgumentList @("-t") -PassThru
    $startTime = Get-Date
    Write-Host "Prime95 已启动（PID $($p.Id)），目标时长 $Minutes 分钟，模式 $Mode，结果目录 $prime95Dir"

    # 轮询循环（每 30s）：进程 HasExited 为主 + exe 目录 results.txt 错误扫描 + 时长判定
    $exitedEarly = $false
    $stats = $null
    do {
        Start-Sleep -Seconds 30
        if ($p.HasExited) { if ((Get-Date) - $startTime -lt [TimeSpan]::FromMinutes($Minutes)) { $exitedEarly = $true; break } }
        $stats = Get-Prime95LogStats -LogFile (Join-Path $prime95Dir 'results.txt')
        if ($stats.HasErrors) { break }   # 提前停（错误数见 $stats.ErrorCount）
        # 辅助：results.txt 长时间未写入仅提示（官方 300s 写入间隔，不判死）
        if ($stats.LastWriteTime -and ((Get-Date) - $stats.LastWriteTime).TotalMinutes -gt 10) {
            Write-Host "提示：results.txt 已 10+ 分钟未更新（Prime95 写入间隔约 300s，持续观察）"
        }
    } while ((Get-Date) - $startTime -lt [TimeSpan]::FromMinutes($Minutes))

    $endTime = Get-Date
    if (-not $exitedEarly -and $stats -and -not $stats.HasErrors) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    # 先取最终判定数据（exe 目录），再归档（Move 失败不影响判定）
    $finalStats = if ($exitedEarly) { [PSCustomObject]@{ ErrorCount = 0 } } else { Get-Prime95LogStats -LogFile (Join-Path $prime95Dir 'results.txt') }
    foreach ($f in @('prime.txt', 'results.txt', 'screen.log')) {
        Move-Item (Join-Path $prime95Dir $f) (Join-Path $workDir $f) -Force -ErrorAction SilentlyContinue
    }
    $actualMin = [math]::Round((($endTime - $startTime).TotalMinutes), 2)
    $verdict = Get-Prime95Verdict -ActualMinutes $actualMin -TargetMinutes $Minutes -ErrorCount $finalStats.ErrorCount -ExitedEarly $exitedEarly
    Write-Host ("Prime95 结果: 时长=$actualMin 错误=$($finalStats.ErrorCount) 状态=$($verdict.Status) 结论=$($verdict.Conclusion)")
    Export-Prime95Report -BatchName $BatchName -ToolVersion (Get-AppVersion) -StartTime $startTime -EndTime $endTime `
        -TargetMinutes $Minutes -ActualMinutes $actualMin -Mode $Mode -ErrorCount $finalStats.ErrorCount `
        -Verdict $verdict -ReportDir $reportDir -LogPath $LogPath
    Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result ("Prime95 " + $verdict.Status) -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 0
} catch {
    Write-Host "错误: Prime95 压测运行期异常: $($_.Exception.Message)"
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Write-CmdLog -Script 'Run-Prime95Stress' -State End -Result ("FAIL: " + $_.Exception.Message) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
    exit 1
}
