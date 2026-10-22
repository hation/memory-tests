# ============================================================================
# Setup-Tools.ps1 — 校验内置 ipmitool（免联网）
# 说明：离线包已内置 Windows 版 ipmitool（tools\ipmitool\），本脚本只做存在性
#       与可用性校验；ipmitool 官方不发布 Windows 二进制，故包内预置社区构建。
# 用法：.\Setup-Tools.ps1           # 校验内置 ipmitool 是否可用
# ============================================================================
$ErrorActionPreference = 'Continue'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ipmiExe = Join-Path $toolsDir 'ipmitool\ipmitool.exe'

if (-not (Test-Path -LiteralPath $ipmiExe)) {
    Write-Warning "未找到内置 ipmitool: $ipmiExe"
    Write-Host "离线包应包含 tools\ipmitool\ipmitool.exe 及 3 个依赖 DLL；若缺失请从完整离线包恢复该目录。"
    exit 1
}

Write-Host "内置 ipmitool 存在: $ipmiExe"
& $ipmiExe -V
Write-Host "（以上为版本号即校验通过；脚本会自动发现并使用该内置 ipmitool）"
exit 0
