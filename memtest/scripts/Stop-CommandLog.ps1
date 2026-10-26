# ============================================================================
# Stop-CommandLog.ps1 — 停止 PowerShell 会话转录
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Stop-CommandLog.ps1
# ============================================================================
Stop-Transcript
Write-Host "会话转录已停止"
