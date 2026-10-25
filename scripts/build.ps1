# build.ps1 — 单源构建：从源码（scripts/docs/boot/config/tools/db + VERSION）一键同步/生成离线包
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 [-KitDir <dir>] [-Bump] [-Zip]
# 幂等：连续两次构建（不带 -Bump），CHECKSUM.txt 逐字节一致。
# 版本：VERSION 文件为单一来源；加 -Bump 每次打包递增（v1->v2->v3...，参考 disk-tests $DKVersion 约定）；
#      加 -Zip 在构建后生成 <离线包名>-<版本>.zip 交付包。

[CmdletBinding()]
param(
    [string]$KitDir = '',
    [switch]$Bump,    # 递增版本号后构建（每次打包用）
    [switch]$Zip,     # 构建后压缩成交付 zip（以版本命名）
    [string]$PythonSrc = ''   # 可选：python 源目录（默认探测 disk-tests\deploy\bin\python）
)

$ErrorActionPreference = 'Stop'

# 默认 KitDir = <repo>\memtest（$PSScriptRoot 不能在 param 默认值中使用）
if ([string]::IsNullOrEmpty($KitDir)) {
    $KitDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'memtest'
}

$Repo = Split-Path -Parent $PSScriptRoot   # <repo> 根目录（scripts 的父目录）
$VERSION_FILE = Join-Path $Repo 'VERSION'

if (-not (Test-Path -LiteralPath $VERSION_FILE)) {
    Write-Error "VERSION file not found: $VERSION_FILE"
    exit 1
}
$ver = (Get-Content -LiteralPath $VERSION_FILE -Raw).Trim()

# -Bump：每次打包递增版本号（v1->v2->v3...，单一来源 VERSION，参考 disk-tests $DKVersion 约定）
if ($Bump) {
    $newVer = if ($ver -match '^v(\d+)$') { "v$([int]$matches[1] + 1)" } else { "v1" }
    [System.IO.File]::WriteAllText($VERSION_FILE, $newVer, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==> 版本递增: $ver -> $newVer"
    $ver = $newVer
}

# 确保 KitDir 存在并规范化（绝对路径）
if (-not (Test-Path -LiteralPath $KitDir)) {
    New-Item -ItemType Directory -Path $KitDir -Force | Out-Null
}
$KitDir = (Resolve-Path -LiteralPath $KitDir).Path

Write-Host "==> Build offline kit: $KitDir"
Write-Host "==> Source version: $ver"

# ---------- ① 同步 ----------
# 通用清理：同步目录先清空再拷贝，源侧删除的文件不会残留进离线包（防陈旧漂移）
function Sync-Dir {
    param([string]$Src, [string]$Dst, [string[]]$Exclude = @(), [switch]$FilesOnly)
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    Get-ChildItem -LiteralPath $Dst -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $items = Get-ChildItem -LiteralPath $Src -Force | Where-Object {
        ($Exclude -notcontains $_.Name) -and (-not ($FilesOnly -and $_.PSIsContainer))
    }
    foreach ($it in $items) {
        Copy-Item -LiteralPath $it.FullName -Destination $Dst -Recurse -Force
    }
}

# scripts：只同步 3 个编排/识别 ps1 + lib_common.ps1（build.ps1 本身不进入离线包）
$scriptSrc = Join-Path $Repo 'scripts'
$scriptDst = Join-Path $KitDir 'scripts'
$scriptFiles = @(
    'lib_common.ps1',
    'Identify-Memory.ps1',
    'Run-BatchScheduler.ps1',
    'Run-MemtestSuite.ps1',
    'Check-ServerCapabilities.ps1',
    'Run-ServerAssessment.ps1',
    'check_env.ps1',
    'Diag-Bmc.ps1',
    'New-MemtestSolIso.ps1',
    'Smoke-MemtestIso.ps1'
)
Sync-Dir -Src $scriptSrc -Dst $scriptDst -Exclude @('build.ps1')
foreach ($f in $scriptFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptSrc $f))) {
        Write-Error "Source script missing: $f"
        exit 1
    }
}

$docSrc = Join-Path $Repo 'docs'
$docDst = Join-Path $KitDir 'docs'
# 只同步 docs 顶层文档文件（FilesOnly：不递归子目录，避免带入 superpowers 等开发工作区目录）
Sync-Dir -Src $docSrc -Dst $docDst -FilesOnly

foreach ($d in @('boot', 'config', 'tools', 'conf')) {
    $src = Join-Path $Repo $d
    $dst = Join-Path $KitDir $d
    if (Test-Path -LiteralPath $src) {
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        if ($d -eq 'tools') {
            # QEMU 仅构建机冒烟用，不入离线包；grub 保留随包携带供离线重建
            Get-ChildItem -LiteralPath $src -Force | Where-Object { $_.Name -ne 'qemu' } |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force }
        } else {
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        }
    }
}

# 内置 python：kit 缺失时从源补拷（源默认 disk-tests 便携版，gitignored 不入库）
$kitPy = Join-Path $KitDir 'tools\python\python.exe'
if (-not (Test-Path -LiteralPath $kitPy)) {
    $src = $PythonSrc
    if (-not $src) {
        $defSrc = Join-Path $Repo '..\disk-tests\deploy\bin\python'
        if (Test-Path -LiteralPath $defSrc) { $src = (Resolve-Path -LiteralPath $defSrc).Path }
    }
    if ($src -and (Test-Path -LiteralPath (Join-Path $src 'python.exe'))) {
        $dst = Split-Path -Parent $kitPy
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        Write-Host "==> 内置 Python 已拷入 kit（$src）"
    } else {
        Write-Host "==> 警告：kit 未内置 Python，db 历史库将回退系统 python"
    }
}

# db：可选 Python 历史库（SQLite，需 Python 3），存在则同步（排除 __pycache__ 字节码产物）
$dbSrc = Join-Path $Repo 'db'
$dbDst = Join-Path $KitDir 'db'
if (Test-Path -LiteralPath $dbSrc) {
    Sync-Dir -Src $dbSrc -Dst $dbDst -Exclude @('__pycache__')
}

# ---------- ② 注入版本 ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$utf8Bom   = New-Object System.Text.UTF8Encoding($true)
$verLine = "> 工具版本：$ver"

# KitDir\VERSION
[System.IO.File]::WriteAllText((Join-Path $KitDir 'VERSION'), $ver, $utf8NoBom)

# KitDir\README.md：幂等注入版本行（删除所有旧版本行（v1/v2/...）再插入当前版本行，避免叠加）
# 内容层幂等：TrimEnd 去除末尾换行/空行，避免 -split 产生尾随空元素在尾部累积空行
# 写回带 BOM（UTF8-BOM）：README 为中文内容，PS5 读取无 BOM UTF-8 中文可能乱码
$readmePath = Join-Path $KitDir 'README.md'
if (Test-Path -LiteralPath $readmePath) {
    $raw = [System.IO.File]::ReadAllText($readmePath, $utf8NoBom).TrimEnd("`r", "`n")
    $lines = $raw -split "`r?`n"
    $filtered = @($lines | Where-Object { $_ -notmatch '^>\s*工具版本：' })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine($verLine)
    foreach ($l in $filtered) { [void]$sb.AppendLine($l) }
    [System.IO.File]::WriteAllText($readmePath, $sb.ToString(), $utf8Bom)
}

# ---------- ③ 校验关键文件存在性 ----------
$required = @(
    (Join-Path $KitDir 'scripts\lib_common.ps1'),
    (Join-Path $KitDir 'scripts\Run-MemtestSuite.ps1'),
    (Join-Path $KitDir 'docs\01-验收测试方案.md'),
    (Join-Path $KitDir 'boot\memtest.iso'),
    (Join-Path $KitDir 'tools\README-tools.md'),
    (Join-Path $KitDir 'scripts\iso9660_build.py')
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
    '11-引导方式对比评估.md',
    '12-离线部署与SOL测试手册.md',
    '13-服务器信息识别指南.md',
    '14-术语解释.md',
    '15-BMC排查方案.md'
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
$keyFiles += (Join-Path $KitDir 'tools\ipmitool\ipmitool.exe')
$keyFiles += (Join-Path $KitDir 'README.md')
$keyFiles += (Join-Path $KitDir 'VERSION')
# db 脚本（可选功能，同步进包则一并纳入校验清单；不存在则跳过，保持向后兼容）
if (Test-Path -LiteralPath (Join-Path $KitDir 'db')) {
    Get-ChildItem -LiteralPath (Join-Path $KitDir 'db') -File | ForEach-Object {
        $keyFiles += $_.FullName
    }
}
$kitPyDir = Join-Path $KitDir 'tools\python'
if (Test-Path -LiteralPath $kitPyDir) {
    Get-ChildItem -LiteralPath $kitPyDir -File | ForEach-Object { $keyFiles += $_.FullName }
}

$lines = foreach ($f in $keyFiles) {
    $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()
    $rel = $f.Substring($KitDir.Length).TrimStart('\', '/').Replace('\', '/')
    '{0}  {1}' -f $hash, $rel
}
$checksumPath = Join-Path $KitDir 'CHECKSUM.txt'
$lines = @($lines | Sort-Object)   # 固定行序，保证幂等
[System.IO.File]::WriteAllLines($checksumPath, $lines, $utf8NoBom)

Write-Host "==> Done. CHECKSUM.txt written ($($lines.Count) files)."

# -Zip：构建后压缩成交付包 <离线包名>.zip（固定命名，如 memtest.zip；放在离线包同级的仓库根目录）
# 参考 disk-tests scripts/make_deploy_zip.ps1：打包前完整性校验 + .NET ZipArchive 保留空目录
# 覆盖可靠性：先删旧包 → 写 .tmp → 原子替换正式名；失败即无包（不留旧包，避免旧版被误用）
if ($Zip) {
    $kitName = Split-Path -Leaf $KitDir
    $zipPath = Join-Path $Repo "$kitName.zip"   # 固定命名（版本号写在包内 VERSION / README 首行）
    $zipTmp  = "$zipPath.tmp"
    $zipBak  = "$zipPath.bak"
    if (-not (Test-Path -LiteralPath $checksumPath)) {
        Write-Error "CHECKSUM.txt 缺失，打包被拒绝（先构建生成 CHECKSUM 再打包）"
        exit 1
    }
    # 结果目录保留在包内（空目录也留条目，对齐 disk-tests 保留 logs/results）
    $resDir = Join-Path $KitDir 'results'
    if (-not (Test-Path -LiteralPath $resDir)) { New-Item -ItemType Directory -Path $resDir | Out-Null }

    # 清除只读属性（防覆盖失败）并清理上一次残留的 .tmp
    foreach ($f in @($zipPath, $zipTmp)) {
        if (Test-Path -LiteralPath $f) {
            Set-ItemProperty -LiteralPath $f -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $zipTmp -Force -ErrorAction SilentlyContinue
    # 打包纪律（AGENTS.md）：先删旧包，再建新包——保证失败后也不残留旧包，杜绝旧版被误用
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:zipCount = 0
    function Add-ZipDir([string]$base, [string]$rel, $archive) {
        $full = if ($rel) { Join-Path $base $rel } else { $base }
        foreach ($item in Get-ChildItem -LiteralPath $full -Force) {
            $childRel = if ($rel) { "$rel/$($item.Name)" } else { $item.Name }
            if ($item.PSIsContainer) {
                [void]$archive.CreateEntry("$childRel/")
                Add-ZipDir $base $childRel $archive
            } else {
                $entry = $archive.CreateEntry($childRel)
                $s = $entry.Open()
                $in = [System.IO.File]::OpenRead($item.FullName)
                $in.CopyTo($s)
                $in.Dispose(); $s.Dispose()
                $script:zipCount++
            }
        }
    }
    # 写入临时文件（期间不影响现有正式包；写坏/中断也不会损坏 memtest.zip）
    $fs = [System.IO.Compression.ZipFile]::Open($zipTmp, 'Create')
    Add-ZipDir $KitDir '' $fs
    $fs.Dispose()

    # 原子替换：旧包 → .bak，新包(.tmp) → 正式名；任一步失败回滚并保留旧包
    try {
        Remove-Item -LiteralPath $zipBak -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $zipPath) { Move-Item -LiteralPath $zipPath -Destination $zipBak -Force }
        Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force
        Remove-Item -LiteralPath $zipBak -Force -ErrorAction SilentlyContinue
    } catch {
        if (-not (Test-Path -LiteralPath $zipPath) -and (Test-Path -LiteralPath $zipBak)) {
            Move-Item -LiteralPath $zipBak -Destination $zipPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $zipTmp -Force -ErrorAction SilentlyContinue
        Write-Error ("交付包替换失败（{0} 可能被占用）：{1}。旧包已保留。" -f $zipPath, $_.Exception.Message)
        exit 1
    }
    $info = Get-Item $zipPath
    Write-Host ("==> 交付包已生成: {0} ({1} MB, {2} 文件) 版本 {3}（解压后核对 VERSION 或 README 首行）" -f $zipPath, [math]::Round($info.Length/1MB,1), $script:zipCount, $ver)
}
