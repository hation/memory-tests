# ============================================================================
# New-MemtestSolIso.ps1 — Memtest SOL ISO 编排器
# 把预设 conf + Memtest86+ 内核 + GRUB 组装成 UEFI 可引导的 memtest-sol.iso：
#   1. 检查 GRUB/Python/预设 conf/内核 是否就位
#   2. Get-MemtestPresets 解析预设 -> ConvertTo-GrubCfg 生成 grub.cfg
#   3. 组 layout 临时目录（EFI/BOOT/BOOTX64.EFI、GRUB/GRUB.CFG、GRUB/X86_64-EFI/*.MOD、BOOT/MT86PLUS.BIN）
#   4. grub-mkimage 生成 EFI 引导镜像
#   5. iso9660_build.py 组装 ISO（先写 .tmp 再原子替换正式名）
#   6. Mount-DiskImage 自检 4 关键文件
# 依赖：scripts/lib_common.ps1（Get-MemtestPresets/ConvertTo-GrubCfg/Get-PythonExe）、scripts/iso9660_build.py。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\New-MemtestSolIso.ps1 [-Help]
# ============================================================================

[CmdletBinding()]
param(
    [string]$Kernel = '',            # 内核文件（默认 memtest\boot\binaries\mt86p_900_x86_64）
    [string]$PresetsConf = '',       # 预设配置文件（默认 config\memtest-presets.conf）
    [string]$OutIso = '',            # 输出 ISO（默认 memtest\boot\memtest-sol.iso）
    [string]$GrubDir = '',           # GRUB 工具目录（默认 tools\grub）
    [switch]$DownloadGrub,           # 联网下载 GRUB Windows 构建包并解压到 -GrubDir
    [int]$TimeoutSeconds = -1,       # grub.cfg 超时秒数（覆盖预设）
    [int]$DefaultIndex = -1,         # grub.cfg 默认菜单索引（覆盖预设）
    [string]$Python = '',            # Python 解释器路径（缺省自动探测）
    [switch]$SkipBuild,              # 跳过 ISO 组装与挂载自检（仅 layout + grub-mkimage）
    [switch]$Smoke,                  # 预留：调用 scripts\Smoke-MemtestIso.ps1（Task 4 接线）
    [switch]$DownloadQemu,           # 预留：下载 QEMU（Task 4 接线）
    [switch]$Help                    # 打印帮助并退出 0
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib_common.ps1"

function Print-Help {
    @'
New-MemtestSolIso.ps1 - 生成 Memtest86+ SOL 引导 ISO（memtest-sol.iso）

用法:
  New-MemtestSolIso.ps1 [-Kernel <path>] [-PresetsConf <path>] [-OutIso <path>]
                        [-GrubDir <path>] [-DownloadGrub] [-TimeoutSeconds <int>]
                        [-DefaultIndex <int>] [-Python <path>] [-SkipBuild]
                        [-Smoke] [-DownloadQemu] [-Help]

参数:
  -Kernel          内核文件（默认 memtest\boot\binaries\mt86p_900_x86_64）
  -PresetsConf     预设配置文件（默认 config\memtest-presets.conf）
  -OutIso          输出 ISO 路径（默认 memtest\boot\memtest-sol.iso）
  -GrubDir         GRUB 工具目录（默认 tools\grub；需含 bin\grub-mkimage[.exe|.cmd] 与 lib\grub\x86_64-efi\*.mod）
  -DownloadGrub    联网下载 GRUB Windows 构建包并解压到 -GrubDir
  -TimeoutSeconds  grub.cfg 超时秒数（覆盖预设）
  -DefaultIndex    grub.cfg 默认菜单索引（覆盖预设）
  -Python          Python 解释器路径（缺省自动探测）
  -SkipBuild       跳过 ISO 组装与挂载自检（仅 layout + grub-mkimage）
  -Smoke           预留：调用 scripts\Smoke-MemtestIso.ps1（Task 4 接线）
  -DownloadQemu    预留：下载 QEMU（Task 4 接线）
  -Help            显示本帮助并退出
'@
}

# 报错并退出 1（ErrorActionPreference=Stop 下 Write-Error 会抛，故用 -ErrorAction Continue + exit）
function Fail([string]$Msg) {
    Write-Error $Msg -ErrorAction Continue
    exit 1
}

# 调用原生命令并合并输出流。PS5.1 在 $ErrorActionPreference=Stop 下，原生 stderr 经 2>&1
# 会转成终止错误（NativeCommandError）；这里临时降级为 Continue，保证 stderr 只被捕获不抛出。
function Invoke-NativeCmd {
    param([scriptblock]$Cmd)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Cmd } finally { $ErrorActionPreference = $oldEap }
}

if ($Help) { Print-Help; exit 0 }

# ---------- 默认路径（相对仓库根） ----------
$Repo = Split-Path -Parent $PSScriptRoot
if ($Kernel -eq '')      { $Kernel = Join-Path $Repo 'memtest\boot\binaries\mt86p_900_x86_64' }
if ($PresetsConf -eq '') { $PresetsConf = Join-Path $Repo 'config\memtest-presets.conf' }
if ($OutIso -eq '')      { $OutIso = Join-Path $Repo 'memtest\boot\memtest-sol.iso' }
if ($GrubDir -eq '')     { $GrubDir = Join-Path $Repo 'tools\grub' }

# ---------- 1. 检查 GRUB / Python / conf / 内核 ----------
$modSrc = Join-Path $GrubDir 'lib\grub\x86_64-efi'
# 判定接受 .exe/.cmd/.bat（.cmd 变体供测试注入 fake 工具）
$mkimage = @('grub-mkimage.exe', 'grub-mkimage.cmd', 'grub-mkimage.bat') |
    ForEach-Object { Join-Path $GrubDir "bin\$_" } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$modsPresent = (Test-Path -LiteralPath $modSrc) -and
    (@(Get-ChildItem -LiteralPath $modSrc -Filter '*.mod' -File -ErrorAction SilentlyContinue).Count -gt 0)

if (-not $mkimage -or -not $modsPresent) {
    if (-not $DownloadGrub) {
        Fail "GRUB 工具未就位：需要 $GrubDir\bin\grub-mkimage.exe 与 $GrubDir\lib\grub\x86_64-efi\*.mod（可用 -DownloadGrub 自动下载）"
    }
    Write-Host "==> -DownloadGrub：联网下载 GRUB Windows 构建包到 $GrubDir"
    $grubUrl = 'https://ftp.gnu.org/gnu/grub/grub-2.12-for-windows.zip'
    try {
        Invoke-WebRequest -Uri $grubUrl -Method Head -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {
        # 404 或 HEAD 不支持：到目录页找 windows 构建包
        Write-Host "==> $grubUrl 不可用（$($_.Exception.Message)），在 https://ftp.gnu.org/gnu/grub/ 目录查找 Windows 构建包"
        try {
            $dirText = (Invoke-WebRequest -Uri 'https://ftp.gnu.org/gnu/grub/' -UseBasicParsing).Content
            $m = [regex]::Match($dirText, 'href="([^"]*windows[^"]*\.zip)"')
            if (-not $m.Success) { Fail "在 https://ftp.gnu.org/gnu/grub/ 未找到 Windows 构建包" }
            $grubUrl = 'https://ftp.gnu.org/gnu/grub/' + $m.Groups[1].Value
        } catch {
            Fail "无法访问 https://ftp.gnu.org/gnu/grub/：$($_.Exception.Message)"
        }
        Write-Host "==> 改用: $grubUrl"
    }
    $zipPath = Join-Path $env:TEMP ("grub-win-" + [guid]::NewGuid().ToString("N") + ".zip")
    $extract = Join-Path $env:TEMP ("grub-win-" + [guid]::NewGuid().ToString("N"))
    try {
        Invoke-WebRequest -Uri $grubUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force
        # 定位 grub-mkimage.exe 与 x86_64-efi 模块目录
        $mkExe = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'grub-mkimage.exe' -File | Select-Object -First 1
        if (-not $mkExe) { Fail "下载包中未找到 grub-mkimage.exe（$grubUrl）" }
        # 官方 grub-2.12-for-windows.zip 把 exe 与 x86_64-efi 模块目录放在包根；
        # 重组为 <GrubDir>\bin\grub-mkimage.exe + <GrubDir>\lib\grub\x86_64-efi\*.mod 以满足就位判定
        New-Item -ItemType Directory -Path (Join-Path $GrubDir 'bin') -Force | Out-Null
        Copy-Item -LiteralPath $mkExe.FullName -Destination (Join-Path $GrubDir 'bin') -Force
        $x64ModDir = Get-ChildItem -LiteralPath $mkExe.Directory.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'x86_64-efi' } | Select-Object -First 1
        if ($x64ModDir) {
            $modDst = Join-Path $GrubDir 'lib\grub\x86_64-efi'
            New-Item -ItemType Directory -Path $modDst -Force | Out-Null
            Copy-Item -Path (Join-Path $x64ModDir.FullName '*') -Destination $modDst -Recurse -Force
        }
        Write-Host "==> GRUB 已解压就位：$GrubDir（来源 $grubUrl）"
    } finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
    # 重新判定
    $mkimage = @('grub-mkimage.exe', 'grub-mkimage.cmd', 'grub-mkimage.bat') |
        ForEach-Object { Join-Path $GrubDir "bin\$_" } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $modsPresent = (Test-Path -LiteralPath $modSrc) -and
        (@(Get-ChildItem -LiteralPath $modSrc -Filter '*.mod' -File -ErrorAction SilentlyContinue).Count -gt 0)
    if (-not $mkimage -or -not $modsPresent) {
        Fail "GRUB 工具仍未就位：$GrubDir（下载或解压后检查失败）"
    }
}

if ($Python -eq '') { $Python = Get-PythonExe }
if (-not $Python -or -not (Test-Path -LiteralPath $Python)) {
    Fail "找不到 Python 解释器（可用 -Python <path> 指定）"
}

if (-not (Test-Path -LiteralPath $PresetsConf)) { Fail "预设配置文件不存在: $PresetsConf" }
if (-not (Test-Path -LiteralPath $Kernel))       { Fail "内核文件不存在: $Kernel" }

# ---------- 2-3. 解析预设并生成 grub.cfg ----------
try {
    $presets = Get-MemtestPresets -Path $PresetsConf
    $grubArgs = @{ Presets = $presets }
    if ($TimeoutSeconds -ge 0) { $grubArgs.TimeoutSeconds = $TimeoutSeconds }
    if ($DefaultIndex -ge 0)   { $grubArgs.DefaultIndex = $DefaultIndex }
    $grubCfg = ConvertTo-GrubCfg @grubArgs
} catch {
    Fail "预设配置解析失败: $($_.Exception.Message)"
}

# ---------- 4. 组 layout 临时目录 ----------
$layout = Join-Path $env:TEMP ("memtest-sol-build-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $layout | Out-Null
try {
    # EFI/BOOT/BOOTX64.EFI —— grub-mkimage 产物
    $efiOut = Join-Path $layout 'EFI\BOOT\BOOTX64.EFI'
    New-Item -ItemType Directory -Path (Split-Path $efiOut) -Force | Out-Null

    # GRUB/GRUB.CFG —— UTF-8 无 BOM
    $grubCfgPath = Join-Path $layout 'GRUB\GRUB.CFG'
    New-Item -ItemType Directory -Path (Split-Path $grubCfgPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($grubCfgPath, $grubCfg, (New-Object System.Text.UTF8Encoding($false)))

    # GRUB/X86_64-EFI/*.MOD —— 原样复制（ISO 组装时转大写 8.3）
    $modDst = Join-Path $layout 'GRUB\X86_64-EFI'
    New-Item -ItemType Directory -Path $modDst -Force | Out-Null
    $modList = @('normal.mod', 'iso9660.mod', 'linux.mod', 'serial.mod', 'terminal.mod', 'configfile.mod',
                 'echo.mod', 'sleep.mod', 'search.mod', 'all_video.mod', 'video.mod', 'gfxterm.mod',
                 'font.mod', 'reboot.mod', 'halt.mod', 'test.mod', 'boot.mod')
    # iso9660_build.py 对文件名为严格 Level-1 8.3（base<=8, ext<=3, 单点）；超长名无法进 ISO
    function Test-Iso83Name([string]$Name) {
        $up = $Name.ToUpperInvariant()
        $dot = $up.IndexOf('.')
        if ($dot -lt 0) { return ($up.Length -ge 1 -and $up.Length -le 8) }
        if ($up.IndexOf('.', $dot + 1) -ge 0) { return $false }
        $base = $up.Substring(0, $dot); $ext = $up.Substring($dot + 1)
        return ($base.Length -ge 1 -and $base.Length -le 8) -and ($ext.Length -ge 1 -and $ext.Length -le 3)
    }
    $skippedMods = @()
    foreach ($m in $modList) {
        $srcMod = Join-Path $modSrc $m
        if (-not (Test-Path -LiteralPath $srcMod)) { $skippedMods += "$m(缺失)"; continue }
        if (-not (Test-Iso83Name $m)) { $skippedMods += "$m(非8.3)"; continue }
        Copy-Item -LiteralPath $srcMod -Destination (Join-Path $modDst $m) -Force
    }
    if ($skippedMods.Count -gt 0) {
        Write-Host "==> 警告：以下 GRUB 模块跳过（grub-mkimage 已内嵌模块，运行时无需 insmod）：$($skippedMods -join ', ')"
    }

    # BOOT/MT86PLUS.BIN —— 内核复制
    $binOut = Join-Path $layout 'BOOT\MT86PLUS.BIN'
    New-Item -ItemType Directory -Path (Split-Path $binOut) -Force | Out-Null
    Copy-Item -LiteralPath $Kernel -Destination $binOut -Force

    # ---------- 5. grub-mkimage 生成 EFI 镜像 ----------
    # 内嵌模块（core 常驻，ISO 内的 .MOD 仅作运行时 insmod 备份；grub-mkimage 需能找到同名模块）
    $efiMods = @('normal', 'iso9660', 'linux', 'serial', 'terminal', 'configfile', 'echo', 'sleep',
                 'search', 'all_video', 'video', 'gfxterm', 'font', 'reboot', 'halt', 'test', 'boot')
    $mkOk = $false
    $errText = ''
    # 阶段 A：按简报命令（不带 -d）
    $out = Invoke-NativeCmd { & $mkimage -O x86_64-efi -o $efiOut -p /GRUB @($efiMods) 2>&1 }
    $errText = $out | Out-String
    $mkOk = ($LASTEXITCODE -eq 0)
    $removedAny = $true
    while (-not $mkOk -and $removedAny) {
        $removedAny = $false
        if ($errText -match "cannot find module ['`"]([^'`"]+)['`"]" -and $efiMods -contains $matches[1]) {
            $efiMods = @($efiMods | Where-Object { $_ -ne $matches[1] })
            $removedAny = $true
            Write-Host "==> 警告：grub-mkimage 找不到模块 $($matches[1])，已从参数列表移除后重试"
            $out = Invoke-NativeCmd { & $mkimage -O x86_64-efi -o $efiOut -p /GRUB @($efiMods) 2>&1 }
            $errText = $out | Out-String
            $mkOk = ($LASTEXITCODE -eq 0)
        }
    }
    # 阶段 B：grub-mkimage 需要 -d 指定模块目录（找不到模块路径时）
    if (-not $mkOk) {
        $out = Invoke-NativeCmd { & $mkimage -d $modSrc -O x86_64-efi -o $efiOut -p /GRUB @($efiMods) 2>&1 }
        $errText = $out | Out-String
        $mkOk = ($LASTEXITCODE -eq 0)
        $removedAny = $true
        while (-not $mkOk -and $removedAny) {
            $removedAny = $false
            if ($errText -match "cannot find module ['`"]([^'`"]+)['`"]" -and $efiMods -contains $matches[1]) {
                $efiMods = @($efiMods | Where-Object { $_ -ne $matches[1] })
                $removedAny = $true
                Write-Host "==> 警告：grub-mkimage(-d) 找不到模块 $($matches[1])，已从参数列表移除后重试"
                $out = Invoke-NativeCmd { & $mkimage -d $modSrc -O x86_64-efi -o $efiOut -p /GRUB @($efiMods) 2>&1 }
                $errText = $out | Out-String
                $mkOk = ($LASTEXITCODE -eq 0)
            }
        }
    }
    if (-not $mkOk) { Fail "grub-mkimage 失败（退出码 $LASTEXITCODE）: $errText" }
    Write-Host "==> EFI 镜像已生成: $efiOut"

    # ---------- 6. 组装 ISO（先写 .tmp，成功原子替换正式名） ----------
    if (-not $SkipBuild) {
        $isoScript = Join-Path $PSScriptRoot 'iso9660_build.py'
        if (-not (Test-Path -LiteralPath $isoScript)) { Fail "iso9660_build.py 不存在: $isoScript" }
        $outTmp = "$OutIso.tmp"
        Remove-Item -LiteralPath $outTmp -Force -ErrorAction SilentlyContinue
        Write-Host "==> 组装 ISO: $OutIso"
        Invoke-NativeCmd { & $Python $isoScript $layout $outTmp } | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $outTmp -Force -ErrorAction SilentlyContinue
            Fail "ISO 组装失败（iso9660_build.py 退出码 $LASTEXITCODE）"
        }
        try {
            Move-Item -LiteralPath $outTmp -Destination $OutIso -Force
        } catch {
            Remove-Item -LiteralPath $outTmp -Force -ErrorAction SilentlyContinue
            Fail "ISO 写入失败（$($_.Exception.Message)）"
        }
        Write-Host "==> ISO 已生成: $OutIso"

        # ---------- 7. 自检：挂载断言 4 关键文件 ----------
        $img = $null
        try {
            $before = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 } | ForEach-Object { $_.DeviceID })
            $img = Mount-DiskImage -ImagePath $OutIso -PassThru
            Start-Sleep -Seconds 2
            $after = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 } | ForEach-Object { $_.DeviceID })
            $drive = @($after | Where-Object { $_ -notin $before })[0]
            if (-not $drive) {
                $vol = Get-Volume -DiskImage $img -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter) { $drive = "$($vol.DriveLetter):" }
            }
            if (-not $drive) { Fail "自检失败：ISO 挂载后未发现新盘符（$OutIso）" }
            $root = "$drive\"
            $keyFiles = @(
                (Join-Path $root 'EFI\BOOT\BOOTX64.EFI'),
                (Join-Path $root 'GRUB\GRUB.CFG'),
                (Join-Path $root 'BOOT\MT86PLUS.BIN')
            )
            $modsInIso = @(Get-ChildItem -LiteralPath (Join-Path $root 'GRUB\X86_64-EFI') -Filter '*.MOD' -File -ErrorAction SilentlyContinue)
            if ($modsInIso.Count -gt 0) { $keyFiles += $modsInIso[0].FullName }
            $missing = @($keyFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
            if ($missing.Count -gt 0) { Fail "自检失败：ISO 缺少关键文件: $($missing -join ', ')" }
            Write-Host "==> 自检通过：EFI\BOOT\BOOTX64.EFI、GRUB\GRUB.CFG、BOOT\MT86PLUS.BIN、$($modsInIso.Count) 个 .MOD"
        } catch {
            Fail "自检失败：$($_.Exception.Message)"
        } finally {
            if ($img) { Dismount-DiskImage -ImagePath $OutIso -ErrorAction SilentlyContinue | Out-Null }
        }
    } else {
        Write-Host "==> -SkipBuild：跳过 ISO 组装与挂载自检（layout: $layout）"
    }
} finally {
    Remove-Item -LiteralPath $layout -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 8. -Smoke / -DownloadQemu 预留接线（Task 4） ----------
if ($Smoke) {
    $smokeScript = Join-Path $PSScriptRoot 'Smoke-MemtestIso.ps1'
    if (Test-Path -LiteralPath $smokeScript) {
        Write-Host "==> -Smoke：调用 $smokeScript"
        & $smokeScript -Iso $OutIso
    } else {
        Write-Host "==> -Smoke 预留接线：scripts\Smoke-MemtestIso.ps1 尚不存在（Task 4 实现），跳过。"
    }
}
if ($DownloadQemu) {
    Write-Host "==> -DownloadQemu 预留参数：Task 4 接线 QEMU 下载，当前跳过。"
}

Write-Host "==> 完成: $OutIso"
exit 0
