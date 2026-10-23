# ============================================================================
# test-iso-build.ps1 — New-MemtestSolIso.ps1 编排器回归测试
# 用 stub 隔离真实工具：fake grub-mkimage.cmd + 空 .mod 模块文件 + 真实 python(iso9660_build.py)。
# 覆盖简报 5 个用例：正常构建 / 改预设 / 缺 default / GrubDir 缺工具 / OutIso 已存在。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-iso-build.ps1
# ============================================================================
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$orchestrator = Join-Path $PSScriptRoot "..\scripts\New-MemtestSolIso.ps1"
Assert (Test-Path -LiteralPath $orchestrator) "编排器脚本存在"

$py = Get-PythonExe
Assert (($null -ne $py) -and (Test-Path -LiteralPath $py)) "真实 python 可用（Get-PythonExe）"

$work = Join-Path $env:TEMP ("mt-iso-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

# 建 fake GRUB 目录：bin\grub-mkimage.cmd（解析 -o <target>，把自身复制为 target）+ lib\grub\x86_64-efi\*.mod 空文件
function New-FakeGrubDir([string]$Dir) {
    New-Item -ItemType Directory -Path (Join-Path $Dir "bin"), (Join-Path $Dir "lib\grub\x86_64-efi") -Force | Out-Null
    $mk = Join-Path $Dir "bin\grub-mkimage.cmd"
    @'
@echo off
setlocal
set "TARGET="
:loop
if "%~1"=="" goto :run
if "%~1"=="-o" (
    set "TARGET=%~2"
    shift
    shift
    goto :loop
)
shift
goto :loop
:run
if "%TARGET%"=="" (
    echo grub-mkimage: missing -o target 1>&2
    exit /b 1
)
echo fake-grub-mkimage-image > "%TARGET%"
if errorlevel 1 exit /b 1
exit /b 0
'@ | Set-Content -LiteralPath $mk -Encoding ASCII
    foreach ($m in @('normal.mod','iso9660.mod','linux.mod','serial.mod','terminal.mod','configfile.mod','echo.mod','sleep.mod','search.mod','all_video.mod','video.mod','gfxterm.mod','font.mod','reboot.mod','halt.mod','test.mod','boot.mod')) {
        Set-Content -LiteralPath (Join-Path $Dir "lib\grub\x86_64-efi\$m") -Value "fake-$m" -Encoding ASCII
    }
}

# 挂载 ISO 并返回根盘符（记录挂载前后 CD-ROM 卷变化，兼容无盘符直接可见情况）
function Get-IsoRoot([string]$IsoPath) {
    $before = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 } | ForEach-Object { $_.DeviceID })
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
    Start-Sleep -Seconds 2
    $after = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 } | ForEach-Object { $_.DeviceID })
    $new = @($after | Where-Object { $_ -notin $before })[0]
    if (-not $new) {
        $vol = Get-Volume -DiskImage $img -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $new = "$($vol.DriveLetter):" }
    }
    if (-not $new) { throw "ISO 挂载失败（未发现新增 CD-ROM 盘符）: $IsoPath" }
    return $new + "\"
}

# 以子进程调用编排器（隔离 exit），返回退出码。
# 注意：调用方必须用 -BuildArgs @{...} 传参，避免字面 hashtable 被当作 splatting 展开。
function Invoke-Build([hashtable]$BuildArgs) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $orchestrator)
    foreach ($k in $BuildArgs.Keys) {
        $argList += "-$k"
        $argList += [string]$BuildArgs[$k]
    }
    & $ps @argList 2>&1 | Out-Null
    return $LASTEXITCODE
}

$defaultConf = @'
# Memtest SOL 引导菜单预设
timeout=10
default=4轮验收
preset.4轮验收.title=Memtest86+ 4轮完整验收（SOL）
preset.4轮验收.cmdline=log=ttyS0,115200 maxpasses=4
preset.2轮.title=Memtest86+ 2轮（SOL）
preset.2轮.cmdline=log=ttyS0,115200 maxpasses=2
preset.1轮快速筛选.title=Memtest86+ 1轮快速筛选（SOL）
preset.1轮快速筛选.cmdline=log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8
preset.交互.title=Memtest86+ 交互界面（无串口日志）
preset.交互.cmdline=nomch
'@

try {
    $grubDir = Join-Path $work "grub"
    New-FakeGrubDir $grubDir
    $kernel = Join-Path $work "kernel.bin"
    Set-Content -LiteralPath $kernel -Value ("FAKE KERNEL BYTES " * 200) -Encoding ASCII

    $conf = Join-Path $work "presets.conf"
    [System.IO.File]::WriteAllText($conf, $defaultConf, (New-Object System.Text.UTF8Encoding($false)))

    # ---- 用例 1：正常构建 ----
    $outIso = Join-Path $work "out1.iso"
    $code = Invoke-Build -BuildArgs @{ GrubDir = $grubDir; Kernel = $kernel; OutIso = $outIso; PresetsConf = $conf; Python = $py }
    Assert ($code -eq 0) "用例1 正常构建退出码 0（实际 $code）"
    Assert (Test-Path -LiteralPath $outIso) "用例1 ISO 产物存在"
    Assert (-not (Test-Path -LiteralPath "$outIso.tmp")) "用例1 无 .tmp 残留"
    $root = $null
    try {
        $root = Get-IsoRoot $outIso
        Assert (Test-Path -LiteralPath (Join-Path $root "EFI\BOOT\BOOTX64.EFI")) "用例1 ISO 内含 EFI\BOOT\BOOTX64.EFI"
        Assert (Test-Path -LiteralPath (Join-Path $root "BOOT\MT86PLUS.BIN")) "用例1 ISO 内含 BOOT\MT86PLUS.BIN"
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $root "GRUB\X86_64-EFI") -Filter "*.MOD" -ErrorAction SilentlyContinue).Count -ge 1) "用例1 ISO 内含至少 1 个 .MOD"
        $cfg = Get-Content -LiteralPath (Join-Path $root "GRUB\GRUB.CFG") -Raw -Encoding UTF8
        Assert (([regex]::Matches($cfg, 'menuentry')).Count -eq 4) "用例1 grub.cfg 含 4 个 menuentry"
        Assert ($cfg -match '/BOOT/MT86PLUS\.BIN') "用例1 grub.cfg 含大写 /BOOT/MT86PLUS.BIN"
    } finally {
        if ($root) { Dismount-DiskImage -ImagePath $outIso -ErrorAction SilentlyContinue | Out-Null }
    }

    # ---- 用例 2：改预设 cmdline -> maxpasses=3 ----
    $conf2 = $defaultConf -replace 'maxpasses=4', 'maxpasses=3'
    [System.IO.File]::WriteAllText($conf, $conf2, (New-Object System.Text.UTF8Encoding($false)))
    $outIso2 = Join-Path $work "out2.iso"
    $code = Invoke-Build -BuildArgs @{ GrubDir = $grubDir; Kernel = $kernel; OutIso = $outIso2; PresetsConf = $conf; Python = $py }
    Assert ($code -eq 0) "用例2 重跑退出码 0（实际 $code）"
    $root = $null
    try {
        $root = Get-IsoRoot $outIso2
        $cfg = Get-Content -LiteralPath (Join-Path $root "GRUB\GRUB.CFG") -Raw -Encoding UTF8
        Assert ($cfg -match 'maxpasses=3') "用例2 grub.cfg 含 maxpasses=3"
    } finally {
        if ($root) { Dismount-DiskImage -ImagePath $outIso2 -ErrorAction SilentlyContinue | Out-Null }
    }
    # 恢复默认 conf 供用例 5 使用
    [System.IO.File]::WriteAllText($conf, $defaultConf, (New-Object System.Text.UTF8Encoding($false)))

    # ---- 用例 3：缺 default -> 退出码 1 且不产出 OutIso ----
    $confNoDef = Join-Path $work "nodef.conf"
    [System.IO.File]::WriteAllText($confNoDef, "timeout=10`npreset.a.title=A`npreset.a.cmdline=x`n", (New-Object System.Text.UTF8Encoding($false)))
    $outIso3 = Join-Path $work "out3.iso"
    $code = Invoke-Build -BuildArgs @{ GrubDir = $grubDir; Kernel = $kernel; OutIso = $outIso3; PresetsConf = $confNoDef; Python = $py }
    Assert ($code -eq 1) "用例3 缺 default 退出码 1（实际 $code）"
    Assert (-not (Test-Path -LiteralPath $outIso3)) "用例3 不产出 OutIso"
    Assert (-not (Test-Path -LiteralPath "$outIso3.tmp")) "用例3 无 .tmp 残留"

    # ---- 用例 4：GrubDir 无 grub-mkimage 且未 -DownloadGrub -> 退出码 1 ----
    $grubEmpty = Join-Path $work "grub-empty"
    New-Item -ItemType Directory -Path $grubEmpty | Out-Null
    $outIso4 = Join-Path $work "out4.iso"
    $code = Invoke-Build -BuildArgs @{ GrubDir = $grubEmpty; Kernel = $kernel; OutIso = $outIso4; PresetsConf = $conf; Python = $py }
    Assert ($code -eq 1) "用例4 缺 grub-mkimage 退出码 1（实际 $code）"

    # ---- 用例 5：-OutIso 已存在 -> 构建后为新 ISO，无 .tmp 残留 ----
    $outIso5 = Join-Path $work "out5.iso"
    Set-Content -LiteralPath $outIso5 -Value "OLD-CONTENT" -Encoding ASCII
    $oldLen = (Get-Item -LiteralPath $outIso5).Length
    $code = Invoke-Build -BuildArgs @{ GrubDir = $grubDir; Kernel = $kernel; OutIso = $outIso5; PresetsConf = $conf; Python = $py }
    Assert ($code -eq 0) "用例5 覆盖构建退出码 0（实际 $code）"
    Assert ((Get-Item -LiteralPath $outIso5).Length -ne $oldLen) "用例5 OutIso 已被新 ISO 覆盖（长度变化）"
    Assert (-not (Test-Path -LiteralPath "$outIso5.tmp")) "用例5 无 .tmp 残留"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "test-iso-build: ALL PASS"
