# build.ps1 — 单源构建：从源码（scripts/docs/boot/config/tools + VERSION）一键同步/生成离线包
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 [-KitDir <dir>]
# 幂等：连续两次构建，CHECKSUM.txt 逐字节一致。

[CmdletBinding()]
param(
    [string]$KitDir = ''
)

$ErrorActionPreference = 'Stop'

# 默认 KitDir = <repo>\SOL内存测试离线包（$PSScriptRoot 不能在 param 默认值中使用）
if ([string]::IsNullOrEmpty($KitDir)) {
    $KitDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'SOL内存测试离线包'
}

$Repo = Split-Path -Parent $PSScriptRoot   # <repo> 根目录（scripts 的父目录）
$VERSION_FILE = Join-Path $Repo 'VERSION'

if (-not (Test-Path -LiteralPath $VERSION_FILE)) {
    Write-Error "VERSION file not found: $VERSION_FILE"
    exit 1
}
$ver = (Get-Content -LiteralPath $VERSION_FILE -Raw).Trim()

# 确保 KitDir 存在并规范化（绝对路径）
if (-not (Test-Path -LiteralPath $KitDir)) {
    New-Item -ItemType Directory -Path $KitDir -Force | Out-Null
}
$KitDir = (Resolve-Path -LiteralPath $KitDir).Path

Write-Host "==> Build offline kit: $KitDir"
Write-Host "==> Source version: $ver"

# ---------- ① 同步 ----------
# scripts：只同步 3 个编排/识别 ps1 + lib_common.ps1（build.ps1 本身不进入离线包）
$scriptSrc = Join-Path $Repo 'scripts'
$scriptDst = Join-Path $KitDir 'scripts'
New-Item -ItemType Directory -Path $scriptDst -Force | Out-Null
$scriptFiles = @(
    'lib_common.ps1',
    'Identify-Memory.ps1',
    'Run-BatchScheduler.ps1',
    'Run-MemtestSuite.ps1'
)
foreach ($f in $scriptFiles) {
    $srcFile = Join-Path $scriptSrc $f
    if (-not (Test-Path -LiteralPath $srcFile)) {
        Write-Error "Source script missing: $srcFile"
        exit 1
    }
    Copy-Item -LiteralPath $srcFile -Destination $scriptDst -Force
}

$docSrc = Join-Path $Repo 'docs'
$docDst = Join-Path $KitDir 'docs'
New-Item -ItemType Directory -Path $docDst -Force | Out-Null
# 只同步 docs 顶层文档文件（不递归子目录，避免带入 superpowers 等开发工作区目录）
Get-ChildItem -LiteralPath $docSrc -File | Copy-Item -Destination $docDst -Force

foreach ($d in @('boot', 'config', 'tools')) {
    $src = Join-Path $Repo $d
    $dst = Join-Path $KitDir $d
    if (Test-Path -LiteralPath $src) {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
    }
}

# ---------- ② 注入版本 ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$verLine = "> 工具版本：$ver"

# KitDir\VERSION
[System.IO.File]::WriteAllText((Join-Path $KitDir 'VERSION'), $ver, $utf8NoBom)

# KitDir\README.md：幂等注入版本行（已存在该行则先删除再插入到文件开头）
# 内容层幂等：TrimEnd 去除末尾换行/空行，避免 -split 产生尾随空元素在尾部累积空行
$readmePath = Join-Path $KitDir 'README.md'
if (Test-Path -LiteralPath $readmePath) {
    $raw = [System.IO.File]::ReadAllText($readmePath, $utf8NoBom).TrimEnd("`r", "`n")
    $lines = $raw -split "`r?`n"
    $filtered = @($lines | Where-Object { $_ -ne $verLine })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($verLine)
    foreach ($l in $filtered) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($readmePath, $sb.ToString(), $utf8NoBom)
}

# ---------- ③ 校验关键文件存在性 ----------
$required = @(
    (Join-Path $KitDir 'scripts\lib_common.ps1'),
    (Join-Path $KitDir 'scripts\Run-MemtestSuite.ps1'),
    (Join-Path $KitDir 'docs\01-验收测试方案.md'),
    (Join-Path $KitDir 'boot\memtest.iso'),
    (Join-Path $KitDir 'tools\README-tools.md')
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    $ErrorActionPreference = 'Continue'
    Write-Error "Missing key files in kit: $($missing -join ', ')"
    exit 1
}

# ---------- ④ 校验清单（SHA256） ----------
$docsList = @(
    '01-验收测试方案.md',
    '02-批量压力测试方案.md',
    '03-PowerShell压测工具需求说明.md',
    '04-运行环境与依赖安装说明.md',
    '05-使用手册.md',
    '06-实践操作教程.md',
    '07-离线部署检查清单.md',
    '08-报表结构说明.md',
    '09-SOL使用指南.md',
    '10-Serial物理串口线使用指南.md',
    '11-引导方式对比评估.md'
)
$keyFiles = @(
    (Join-Path $KitDir 'scripts\lib_common.ps1'),
    (Join-Path $KitDir 'scripts\Identify-Memory.ps1'),
    (Join-Path $KitDir 'scripts\Run-BatchScheduler.ps1'),
    (Join-Path $KitDir 'scripts\Run-MemtestSuite.ps1')
)
foreach ($doc in $docsList) {
    $keyFiles += (Join-Path $KitDir "docs\$doc")
}
$keyFiles += (Join-Path $KitDir 'boot\memtest.iso')
$keyFiles += (Join-Path $KitDir 'tools\README-tools.md')
$keyFiles += (Join-Path $KitDir 'VERSION')

$lines = foreach ($f in $keyFiles) {
    $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
    $rel = $f.Substring($KitDir.Length).TrimStart('\', '/').Replace('\', '/')
    '{0}  {1}' -f $hash, $rel
}
$checksumPath = Join-Path $KitDir 'CHECKSUM.txt'
$lines = @($lines | Sort-Object)   # 固定行序，保证幂等
[System.IO.File]::WriteAllLines($checksumPath, $lines, $utf8NoBom)

Write-Host "==> Done. CHECKSUM.txt written ($($lines.Count) files)."
