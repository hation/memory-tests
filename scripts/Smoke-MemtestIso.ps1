# ============================================================================
# Smoke-MemtestIso.ps1 — QEMU/OVMF 冒烟验证 Memtest SOL ISO
# 用 QEMU(-machine q35 -accel whpx:tcg) + OVMF 引导 ISO，串口重定向到文件，
# 断言 MTLOG 出现 ev=start/ev=spd/ev=pass_end/ev=done 且 QEMU 退出码 0 即冒烟通过。
# 依赖：<QemuDir>/qemu-system-x86_64[.exe|.cmd|.bat] + OVMF CODE/VARS（-DownloadQemu 自动下载）。
# 返回：[PSCustomObject]@{ Pass=[bool]; Mtlog=[path]; Reason=[string] }（stdout 亦打印摘要）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Smoke-MemtestIso.ps1 [-Iso <path>] [-QemuDir <path>] [-TimeLimitSeconds <int>] [-DownloadQemu] [-Help]
# ============================================================================

[CmdletBinding()]
param(
    [string]$Iso = '',
    [string]$QemuDir = '',
    [int]$TimeLimitSeconds = 600,
    [switch]$DownloadQemu,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# 报错并退出 1（Write-Error -ErrorAction Continue 避免 Stop 抛异常打断 exit）
function Fail([string]$Msg) {
    Write-Error $Msg -ErrorAction Continue
    exit 1
}

function Print-Help {
    @'
Smoke-MemtestIso.ps1 - QEMU/OVMF 冒烟验证 Memtest SOL ISO

用法:
  Smoke-MemtestIso.ps1 [-Iso <path>] [-QemuDir <path>] [-TimeLimitSeconds <int>]
                       [-DownloadQemu] [-Help]

参数:
  -Iso              待验证 ISO 路径（必填）
  -QemuDir          QEMU/OVMF 目录（默认 tools\qemu；需 qemu-system-x86_64.exe 与 OVMF CODE/VARS）
  -TimeLimitSeconds 轮询 MTLOG 超时秒数（默认 600，每 5s 查一次）
  -DownloadQemu     联网下载 QEMU Windows 构建 + OVMF 到 -QemuDir
  -Help             显示本帮助并退出 0

返回:
  [PSCustomObject]@{ Pass=[bool]; Mtlog=[path]; Reason=[string] }
'@
}

if ($Help) { Print-Help; exit 0 }

# 默认/相对 QemuDir 一律落到仓库根 tools\qemu
if ($QemuDir -eq '') { $QemuDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\qemu' }
if (-not [System.IO.Path]::IsPathRooted($QemuDir)) {
    $QemuDir = Join-Path (Split-Path -Parent $PSScriptRoot) $QemuDir
}

# ---------- OVMF 定位（接受 QEMU 包 pc-bios 内两种命名） ----------
$codeNames = @('OVMF_CODE.fd', 'edk2-x86_64-code.fd', 'edk2-i386-code.fd')
$varsNames = @('OVMF_VARS.fd', 'edk2-x86_64-vars.fd', 'edk2-i386-vars.fd')
function Find-OvmfFile {
    param([string]$Base, [string[]]$Names)
    foreach ($n in $Names) {
        $f = Get-ChildItem -LiteralPath $Base -Recurse -Filter $n -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

# QEMU/OVMF 就位判定：qemu-system-x86_64[.exe|.cmd|.bat]（.cmd/.bat 供测试注入 stub）
# + OVMF CODE/VARS；直接路径缺失时递归查找（安装器可能放子目录）。
function Resolve-QemuReady {
    $exe = @('qemu-system-x86_64.exe', 'qemu-system-x86_64.cmd', 'qemu-system-x86_64.bat') |
        ForEach-Object { Join-Path $QemuDir $_ } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) {
        $f = Get-ChildItem -LiteralPath $QemuDir -Recurse -Filter 'qemu-system-x86_64.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $exe = $f.FullName }
    }
    $codeFd = Find-OvmfFile $QemuDir $codeNames
    $varsFd = Find-OvmfFile $QemuDir $varsNames
    return @{ Exe = $exe; CodeFd = $codeFd; VarsFd = $varsFd }
}

# -DownloadQemu：下载 QEMU Windows 构建（qemu.weilnetz.de/w64 安装器）静默安装到 QemuDir；
# OVMF 优先取安装包 pc-bios（edk2-*-code.fd / OVMF_CODE.fd + VARS）。来源如实记录。
function Invoke-DownloadQemu {
    param([string]$QemuDir)

    New-Item -ItemType Directory -Path $QemuDir -Force | Out-Null
    Write-Host "==> -DownloadQemu：联网下载 QEMU Windows 构建 + OVMF 到 $QemuDir"

    # 1) 定位最新 QEMU Windows 安装器 URL（qemu.weilnetz.de/w64/），HEAD 测通再下载
    $installerUrl = $null
    try {
        $idxHtml = (Invoke-WebRequest -Uri 'https://qemu.weilnetz.de/w64/' -UseBasicParsing -TimeoutSec 60).Content
        $inst = @([regex]::Matches($idxHtml, 'href="(qemu-w64-setup-(\d{8})\.exe)"')) |
            ForEach-Object { [PSCustomObject]@{ Url = 'https://qemu.weilnetz.de/w64/' + $_.Groups[1].Value; Date = $_.Groups[2].Value } } |
            Sort-Object Date -Descending | Select-Object -First 1
        if ($inst) { $installerUrl = $inst.Url }
    } catch {
        Fail "无法访问 https://qemu.weilnetz.de/w64/：$($_.Exception.Message)"
    }
    if (-not $installerUrl) {
        Fail "在 https://qemu.weilnetz.de/w64/ 未找到 QEMU Windows 安装器（qemu-w64-setup-*.exe）"
    }
    try {
        Invoke-WebRequest -Uri $installerUrl -Method Head -UseBasicParsing -TimeoutSec 60 | Out-Null
    } catch {
        Fail "QEMU 安装器 URL HEAD 测通失败：$installerUrl（$($_.Exception.Message)）"
    }

    # 2) 下载安装器并静默安装（NSIS /S 静默、/D= 安装目录须为最后一个参数且不引号）
    $exePath = Join-Path $env:TEMP ("qemu-w64-setup-" + [guid]::NewGuid().ToString("N") + ".exe")
    try {
        Write-Host "==> 下载 QEMU 安装器（约 200MB，来源 $installerUrl）..."
        Invoke-WebRequest -Uri $installerUrl -OutFile $exePath -UseBasicParsing
        Write-Host "==> 静默安装 QEMU 到 $QemuDir ..."
        $installProc = Start-Process -FilePath $exePath -ArgumentList @('/S', "/D=$QemuDir") -PassThru -Wait
        if ($installProc.ExitCode -ne 0) {
            Fail "QEMU 静默安装失败（退出码 $($installProc.ExitCode)）"
        }
        Write-Host "==> QEMU 已安装到 $QemuDir（来源 $installerUrl）"
    } finally {
        Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
    }

    # 3) OVMF：优先取 QEMU 包 pc-bios；缺失则尝试 tianocore/edk2 release（如实记录来源）
    $code = Find-OvmfFile $QemuDir $codeNames
    $vars = Find-OvmfFile $QemuDir $varsNames
    if (-not $code -or -not $vars) {
        Write-Host "==> 警告：QEMU 安装包内未找到 OVMF CODE/VARS，尝试从 tianocore/edk2 release 下载"
        $ovmfBase = 'https://github.com/tianocore/edk2/releases/download/edk2-stable202411'
        $got = @()
        if (-not $code) {
            $u = "$ovmfBase/OVMF_CODE.fd"
            try {
                Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null
                $code = Join-Path $QemuDir 'OVMF_CODE.fd'
                Invoke-WebRequest -Uri $u -OutFile $code -UseBasicParsing
                $got += 'OVMF_CODE.fd'
            } catch { $code = $null }
        }
        if (-not $vars) {
            $u = "$ovmfBase/OVMF_VARS.fd"
            try {
                Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 30 | Out-Null
                $vars = Join-Path $QemuDir 'OVMF_VARS.fd'
                Invoke-WebRequest -Uri $u -OutFile $vars -UseBasicParsing
                $got += 'OVMF_VARS.fd'
            } catch { $vars = $null }
        }
        if ($got.Count -gt 0) {
            Write-Host "==> OVMF 来源：tianocore/edk2 release（$ovmfBase，$($got -join ', ')）"
        } else {
            Write-Host "==> 警告：tianocore/edk2 release 不附 OVMF 预编译产物（HEAD 404）。"
            Write-Host "    OVMF 主要来源为 QEMU 安装包 pc-bios（share\qemu\edk2-*-code.fd / OVMF_CODE.fd）；请检查安装包或手动放置 OVMF CODE/VARS 到 $QemuDir"
        }
    } else {
        Write-Host "==> OVMF 来源：QEMU 安装包 pc-bios（$code / $vars）"
    }
}

# ---------- QEMU 就位判定（缺失且未 -DownloadQemu → 报错退出 1） ----------
$ready = Resolve-QemuReady
if (-not $ready.Exe -or -not $ready.CodeFd -or -not $ready.VarsFd) {
    if (-not $DownloadQemu) {
        Fail "QEMU/OVMF 未就位：需要 $QemuDir\qemu-system-x86_64.exe 与 OVMF CODE/VARS（可用 -DownloadQemu 自动下载）"
    }
    Invoke-DownloadQemu -QemuDir $QemuDir
    $ready = Resolve-QemuReady
    if (-not $ready.Exe -or -not $ready.CodeFd -or -not $ready.VarsFd) {
        Fail "QEMU 下载后仍未就位：$QemuDir（缺少 qemu-system-x86_64.exe 或 OVMF CODE/VARS）"
    }
}

if (-not $Iso -or -not (Test-Path -LiteralPath $Iso)) {
    Fail "ISO 文件不存在: $Iso"
}

$qemuExe = $ready.Exe
$codeFd  = $ready.CodeFd
$varsFd  = $ready.VarsFd

# ---------- 1. OVMF vars 副本（原 VARS 只读不改，复制到 %TEMP%） ----------
$varsCopy = Join-Path $env:TEMP ("memtest-sol-vars-" + [guid]::NewGuid().ToString("N") + ".fd")
$mtlog = Join-Path $env:TEMP ("memtest-sol-mtlog-" + [guid]::NewGuid().ToString("N") + ".txt")
Remove-Item -LiteralPath $mtlog -Force -ErrorAction SilentlyContinue

try {
    Copy-Item -LiteralPath $varsFd -Destination $varsCopy -Force

    # ---------- 2. 组装 QEMU 参数并启动 ----------
    # -no-reboot：memtest 测完自动重启时 QEMU 直接退出；-display none 无窗口
    $qemuArgs = @(
        '-machine', 'q35',
        '-accel', 'whpx:tcg',
        '-m', '2048',
        '-drive', "if=pflash,format=raw,readonly=on,file=$codeFd",
        '-drive', "if=pflash,format=raw,file=$varsCopy",
        '-cdrom', $Iso,
        '-serial', "file:$mtlog",
        '-display', 'none',
        '-no-reboot'
    )
    $argLine = ($qemuArgs | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
    }) -join ' '

    Write-Host "==> 启动 QEMU 冒烟：$qemuExe"
    Write-Host "    $argLine"
    $p = $null
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($qemuExe -match '\.(cmd|bat)$') {
        # .cmd/.bat stub 经 cmd.exe /c 启动（CreateProcess 不能直接运行批处理）
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/c ""' + $qemuExe + '" ' + $argLine + '"'
    } else {
        $psi.FileName = $qemuExe
        $psi.Arguments = $argLine
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)

    # ---------- 3. 轮询 mtlog 直到 ev=done / 超时 / qemu 进程结束（每 5s） ----------
    $deadline = (Get-Date).AddSeconds($TimeLimitSeconds)
    $done = $false
    while (-not $done -and (Get-Date) -lt $deadline -and -not $p.HasExited) {
        Start-Sleep -Seconds 5
        if (Test-Path -LiteralPath $mtlog) {
            $t = Get-Content -LiteralPath $mtlog -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($t -match 'ev=done') { $done = $true }
        }
    }
    if (-not $p.HasExited) {
        if (-not $done) { Write-Host "==> 冒烟超时（$TimeLimitSeconds s），终止 QEMU 进程" }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $p.WaitForExit()
    $exitCode = $p.ExitCode

    # ---------- 4. 判定：mtlog 含 start/spd/pass_end/done 且 qemu 退出码 0 → Pass ----------
    $logText = if (Test-Path -LiteralPath $mtlog) { Get-Content -LiteralPath $mtlog -Raw -Encoding UTF8 } else { '' }
    $missing = @()
    foreach ($ev in @('start', 'spd', 'pass_end', 'done')) {
        if ($logText -notmatch ("ev=" + $ev)) { $missing += $ev }
    }
    $pass = $false
    $reason = ''
    if ($exitCode -ne 0) {
        $reason = "QEMU 退出码非 0（$exitCode）"
        if ($missing.Count -gt 0) { $reason += "；MTLOG 缺事件: $($missing -join ', ')" }
    } elseif ($missing.Count -gt 0) {
        $reason = "MTLOG 缺少事件: $($missing -join ', ')"
        if ($missing -contains 'done') { $reason += '（可能超时或测试未完成）' }
    } else {
        $pass = $true
        $reason = 'MTLOG 完整（start/spd/pass_end/done），QEMU 退出码 0'
    }

    # ---------- 5. 打印摘要并返回对象 ----------
    if ($pass) {
        Write-Host "==> 冒烟通过：MTLOG 含 start/spd/pass_end/done（$mtlog）"
    } else {
        Write-Host "==> 冒烟失败：$reason（MTLOG: $mtlog）"
    }
    return [PSCustomObject]@{ Pass = $pass; Mtlog = $mtlog; Reason = $reason }
} finally {
    Remove-Item -LiteralPath $varsCopy -Force -ErrorAction SilentlyContinue
}
