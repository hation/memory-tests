# ============================================================================
# Start-CommandLog.ps1 — 开启 PowerShell 会话转录（记录本项目会话所有输入输出）
# 用法（在包根 C:\memtest 下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Start-CommandLog.ps1
# 转录文件：results\cmdlog\<日期>_<时间>.log
# ============================================================================
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'results\cmdlog'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("{0:yyyy-MM-dd}_{0:HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append
Write-Host "会话转录已开启：$logFile"
