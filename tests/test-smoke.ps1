# ============================================================================
# test-smoke.ps1 — Smoke-MemtestIso.ps1（QEMU 冒烟）回归测试
# 用 fake qemu stub（.cmd，解析参数里 -serial file:<path> 写假 MTLOG）隔离真实 QEMU。
# 覆盖简报 5 个用例 + 评审 I1 竞态回归 3 个用例 + New-MemtestSolIso -Smoke 接线 2 个用例（fake Smoke stub 经
# 环境变量 MT_SMOKE_SCRIPT 注入，避免依赖真实 QEMU/OVMF）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-smoke.ps1
# ============================================================================
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$smokeScript = Join-Path $PSScriptRoot "..\scripts\Smoke-MemtestIso.ps1"
$orchestrator = Join-Path $PSScriptRoot "..\scripts\New-MemtestSolIso.ps1"
Assert (Test-Path -LiteralPath $smokeScript) "冒烟脚本存在"
Assert (Test-Path -LiteralPath $orchestrator) "编排器脚本存在"

$py = Get-PythonExe
Assert (($null -ne $py) -and (Test-Path -LiteralPath $py)) "真实 python 可用（Get-PythonExe）"

$work = Join-Path $env:TEMP ("mt-smoke-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

# fake qemu stub：解析 %* 里的 -serial file:<path>，向该路径写入假 MTLOG 行，然后 exit /b <code>
# 注意 .cmd 变量展开陷阱：只用 %* 与 !var!（EnableDelayedExpansion），不引用 %~f0 之类路径自展开。
# -DelaySeconds >0 时写 MTLOG 后 sleep（ping -n N ≈ N-1s）再退出，模拟 memtest 写完 ev=done 到
# QEMU(-no-reboot) 自然退出之间的延迟窗口 / 长时间不退出（供超时/超限强杀用例）。
function New-FakeQemu([string]$QemuDir, [string[]]$MtlogLines, [int]$ExitCode, [int]$DelaySeconds = 0) {
    New-Item -ItemType Directory -Path $QemuDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $QemuDir "OVMF_CODE.fd") -Value "fake-CODE" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $QemuDir "OVMF_VARS.fd") -Value "fake-VARS" -Encoding ASCII
    $echoLines = $MtlogLines | ForEach-Object { '>> "!MTLOG:~5!" echo ' + $_ }
    $delayLine = ''
    if ($DelaySeconds -gt 0) { $delayLine = "`n    ping 127.0.0.1 -n $($DelaySeconds + 1) > nul" }
    $body = @'
@echo off
setlocal EnableDelayedExpansion
set "MTLOG="
set "NEXT="
for %%a in (%*) do (
    if defined NEXT (
        set "MTLOG=%%a"
        set "NEXT="
    )
    if "%%a"=="-serial" set "NEXT=1"
)
if defined MTLOG (
    if "!MTLOG:~0,5!"=="file:" (
'@ + "`n" + ($echoLines -join "`n") + $delayLine + "`n" + "    )`n)`n" + "exit /b $ExitCode"
    $stub = Join-Path $QemuDir "qemu-system-x86_64.cmd"
    Set-Content -LiteralPath $stub -Value $body -Encoding ASCII
    return $stub
}

# 有状态 fake qemu stub：首次调用只创建标记文件（%~dp0callmark）并 exit /b 1、不写 mtlog（模拟首选加速器
# 非法、启动即退）；二次调用才写完整 MTLOG 并 exit /b 0（供"首选加速器失败 → 回退 tcg"用例）。
function New-FakeQemuStateful([string]$QemuDir, [string[]]$MtlogLines) {
    New-Item -ItemType Directory -Path $QemuDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $QemuDir "OVMF_CODE.fd") -Value "fake-CODE" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $QemuDir "OVMF_VARS.fd") -Value "fake-VARS" -Encoding ASCII
    $echoLines = $MtlogLines | ForEach-Object { '>> "!MTLOG:~5!" echo ' + $_ }
    $body = @'
@echo off
setlocal EnableDelayedExpansion
if exist "%~dp0callmark" goto :run
echo 1 > "%~dp0callmark"
exit /b 1
:run
set "MTLOG="
set "NEXT="
for %%a in (%*) do (
    if defined NEXT (
        set "MTLOG=%%a"
        set "NEXT="
    )
    if "%%a"=="-serial" set "NEXT=1"
)
if defined MTLOG (
    if "!MTLOG:~0,5!"=="file:" (
'@ + "`n" + ($echoLines -join "`n") + "`n" + "    )`n)`n" + "exit /b 0"
    $stub = Join-Path $QemuDir "qemu-system-x86_64.cmd"
    Set-Content -LiteralPath $stub -Value $body -Encoding ASCII
    return $stub
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
    $fullMtlog = @(
        'MTLOG ts=1.00 ev=start version=5.20',
        'MTLOG ts=1.10 ev=info cpu=Fake mem_mb=2048',
        'MTLOG ts=1.20 ev=spd slot=0 size_mb=2048 type=DDR5 freq=4800 ecc=off',
        'MTLOG ts=1.30 ev=pass_start pass=0',
        'MTLOG ts=1.40 ev=pass_end pass=0 errors=0 status=pass',
        'MTLOG ts=1.50 ev=done passes=1 status=pass'
    )

    $dummyIso = Join-Path $work "dummy.iso"
    Set-Content -LiteralPath $dummyIso -Value "FAKE ISO" -Encoding ASCII

    # ---- 用例 1：完整 MTLOG + stub 退出码 0 → Pass=$true ----
    $q1 = Join-Path $work "qemu1"
    New-FakeQemu $q1 $fullMtlog 0
    $r1 = . $smokeScript -Iso $dummyIso -QemuDir $q1 -TimeLimitSeconds 30
    Assert ($r1.Pass -eq $true) "用例1 Pass=$true（实际 $($r1.Pass)，Reason=$($r1.Reason)）"
    Assert (Test-Path -LiteralPath $r1.Mtlog) "用例1 Mtlog 路径有效"
    Assert ($r1.Reason -notmatch '回退') "用例1 首选加速器正常运行不回退（$($r1.Reason)）"

    # ---- 用例 2：缺 ev=done → Pass=$false 且 Reason 提及 done ----
    $q2 = Join-Path $work "qemu2"
    New-FakeQemu $q2 ($fullMtlog | Where-Object { $_ -notmatch 'ev=done' }) 0
    $r2 = . $smokeScript -Iso $dummyIso -QemuDir $q2 -TimeLimitSeconds 30
    Assert ($r2.Pass -eq $false) "用例2 Pass=$false（实际 $($r2.Pass)）"
    Assert ($r2.Reason -match 'done') "用例2 Reason 提及 done（$($r2.Reason)）"

    # ---- 用例 3：缺 ev=start → Pass=$false 且 Reason 提及 start ----
    $q3 = Join-Path $work "qemu3"
    New-FakeQemu $q3 ($fullMtlog | Where-Object { $_ -notmatch 'ev=start' }) 0
    $r3 = . $smokeScript -Iso $dummyIso -QemuDir $q3 -TimeLimitSeconds 30
    Assert ($r3.Pass -eq $false) "用例3 Pass=$false（实际 $($r3.Pass)）"
    Assert ($r3.Reason -match 'start') "用例3 Reason 提及 start（$($r3.Reason)）"

    # ---- 用例 4：QemuDir 缺 qemu-system-x86_64.exe 且未 -DownloadQemu → 报错退出 1 ----
    # （dot-source 冒烟脚本会把 EAP 设为 Stop 泄漏到本作用域，这里恢复 Continue 使 2>&1 不抛终止错误）
    $ErrorActionPreference = 'Continue'
    $q4 = Join-Path $work "qemu4"
    New-Item -ItemType Directory -Path $q4 | Out-Null
    & $ps -NoProfile -ExecutionPolicy Bypass -File $smokeScript -Iso $dummyIso -QemuDir $q4 2>&1 | Out-Null
    Assert ($LASTEXITCODE -eq 1) "用例4 缺 QEMU 退出码 1（实际 $LASTEXITCODE）"

    # ---- 用例 5：stub 退出码非 0（MTLOG 完整）→ Pass=$false 且 Reason 提及退出码 ----
    $q5 = Join-Path $work "qemu5"
    New-FakeQemu $q5 $fullMtlog 3
    $r5 = . $smokeScript -Iso $dummyIso -QemuDir $q5 -TimeLimitSeconds 30
    Assert ($r5.Pass -eq $false) "用例5 Pass=$false（实际 $($r5.Pass)）"
    Assert ($r5.Reason -match '退出码') "用例5 Reason 提及退出码（$($r5.Reason)）"
    Assert ($r5.Reason -notmatch '回退') "用例5 MTLOG 有输出时不回退（$($r5.Reason)）"

    # ---- 用例 6：ev=done 后 QEMU 延迟自然退出（stub 写 done 后 sleep ~8s 再退出 0）→ Pass=$true ----
    # （回归评审 I1：旧实现检测到 done 后立即强杀 → 退出码非 0 误判；新实现等待自然退出）
    $ErrorActionPreference = 'Continue'
    $q6 = Join-Path $work "qemu6"
    New-FakeQemu $q6 $fullMtlog 0 -DelaySeconds 8
    $r6 = . $smokeScript -Iso $dummyIso -QemuDir $q6 -TimeLimitSeconds 30
    Assert ($r6.Pass -eq $true) "用例6 done 后延迟退出 Pass=$true（实际 $($r6.Pass)，Reason=$($r6.Reason)）"

    # ---- 用例 7：ev=done 后 QEMU 始终不退（-ExitWaitSeconds 3 等待超限强杀）→ 仍判 Pass ----
    $q7 = Join-Path $work "qemu7"
    New-FakeQemu $q7 $fullMtlog 0 -DelaySeconds 60
    $r7 = . $smokeScript -Iso $dummyIso -QemuDir $q7 -TimeLimitSeconds 30 -ExitWaitSeconds 3
    Assert ($r7.Pass -eq $true) "用例7 done 后等待超限强杀仍 Pass=$true（实际 $($r7.Pass)，Reason=$($r7.Reason)）"
    Assert ($r7.Reason -match 'ev=done') "用例7 Reason 按 ev=done 判 Pass（$($r7.Reason)）"

    # ---- 用例 8：超时无 ev=done（stub 只写非 done 事件且不退出，-TimeLimitSeconds 10）→ 超时强杀 → Pass=$false ----
    $q8 = Join-Path $work "qemu8"
    New-FakeQemu $q8 ($fullMtlog | Where-Object { $_ -notmatch 'ev=done' }) 0 -DelaySeconds 60
    $r8 = . $smokeScript -Iso $dummyIso -QemuDir $q8 -TimeLimitSeconds 10
    Assert ($r8.Pass -eq $false) "用例8 超时无 done Pass=$false（实际 $($r8.Pass)，Reason=$($r8.Reason)）"
    Assert ($r8.Reason -match 'done') "用例8 Reason 提及 done（$($r8.Reason)）"

    # ---- 用例 9/10：New-MemtestSolIso -Smoke 接线 ----
    $ErrorActionPreference = 'Continue'   # 用例5/6/7/8 dot-source 再次泄漏 Stop，恢复
    # fake GRUB 目录（同 test-iso-build 做法）
    $grubDir = Join-Path $work "grub"
    New-Item -ItemType Directory -Path (Join-Path $grubDir "bin"), (Join-Path $grubDir "lib\grub\x86_64-efi") -Force | Out-Null
    $mk = Join-Path $grubDir "bin\grub-mkimage.cmd"
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
        Set-Content -LiteralPath (Join-Path $grubDir "lib\grub\x86_64-efi\$m") -Value "fake-$m" -Encoding ASCII
    }
    $kernel = Join-Path $work "kernel.bin"
    Set-Content -LiteralPath $kernel -Value ("FAKE KERNEL BYTES " * 200) -Encoding ASCII
    $conf = Join-Path $work "presets.conf"
    [System.IO.File]::WriteAllText($conf, $defaultConf, (New-Object System.Text.UTF8Encoding($false)))

    # fake Smoke stub（经环境变量 MT_SMOKE_SCRIPT 注入编排器）
    $fakeSmokePass = Join-Path $work "fake-smoke-pass.ps1"
    @'
param([string]$Iso, [string]$QemuDir, [switch]$DownloadQemu, [int]$TimeLimitSeconds = 600, [switch]$Help)
[PSCustomObject]@{ Pass = $true; Mtlog = ''; Reason = 'fake-smoke-pass' }
'@ | Set-Content -LiteralPath $fakeSmokePass -Encoding UTF8
    $fakeSmokeFail = Join-Path $work "fake-smoke-fail.ps1"
    @'
param([string]$Iso, [string]$QemuDir, [switch]$DownloadQemu, [int]$TimeLimitSeconds = 600, [switch]$Help)
[PSCustomObject]@{ Pass = $false; Mtlog = ''; Reason = 'fake-smoke-fail' }
'@ | Set-Content -LiteralPath $fakeSmokeFail -Encoding UTF8

    # 用例 9：-Smoke 且冒烟成功 → 退出码 0，正式 ISO 产出，输出含"冒烟通过"
    $env:MT_SMOKE_SCRIPT = $fakeSmokePass
    $outIso6 = Join-Path $work "out6.iso"
    $argList6 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $orchestrator,
        '-GrubDir', $grubDir, '-Kernel', $kernel, '-OutIso', $outIso6,
        '-PresetsConf', $conf, '-Python', $py, '-Smoke')
    $out6 = & $ps @argList6 2>&1 | Out-String
    $code6 = $LASTEXITCODE
    Assert ($code6 -eq 0) "用例9 冒烟通过退出码 0（实际 $code6）"
    Assert (Test-Path -LiteralPath $outIso6) "用例9 正式 ISO 产出"
    Assert ($out6 -match '冒烟通过') "用例9 输出含'冒烟通过'"

    # 用例 10：-Smoke 且冒烟失败 → 退出码 1，正式 ISO 仍产出，输出含"未验证"
    $env:MT_SMOKE_SCRIPT = $fakeSmokeFail
    $outIso7 = Join-Path $work "out7.iso"
    $argList7 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $orchestrator,
        '-GrubDir', $grubDir, '-Kernel', $kernel, '-OutIso', $outIso7,
        '-PresetsConf', $conf, '-Python', $py, '-Smoke')
    $out7 = & $ps @argList7 2>&1 | Out-String
    $code7 = $LASTEXITCODE
    Assert ($code7 -eq 1) "用例10 冒烟失败退出码 1（实际 $code7）"
    Assert (Test-Path -LiteralPath $outIso7) "用例10 冒烟失败仍产出正式 ISO"
    Assert ($out7 -match '未验证') "用例10 输出含'未验证'"

    # ---- 用例 11：首选加速器（默认 whpx）启动即失败 → 自动回退 tcg 重试一次 → Pass=$true 且 Reason 提及回退 ----
    # （回归集成缺陷：QEMU 11.1.0 拒绝 -accel whpx:tcg 报 "invalid accelerator"、启动即退出码 1，mtlog 无输出；
    #   修复后应先跑 whpx 失败 → 回退 tcg 再跑一次并成功）
    $ErrorActionPreference = 'Continue'   # 用例 8 dot-source 泄漏 Stop，恢复
    $q11 = Join-Path $work "qemu11"
    New-FakeQemuStateful $q11 $fullMtlog
    $r11 = . $smokeScript -Iso $dummyIso -QemuDir $q11 -TimeLimitSeconds 30
    Assert ($r11.Pass -eq $true) "用例11 回退 tcg 后 Pass=$true（实际 $($r11.Pass)，Reason=$($r11.Reason)）"
    Assert ($r11.Reason -match '回退') "用例11 Reason 提及回退 tcg（$($r11.Reason)）"
    Assert (Test-Path -LiteralPath (Join-Path $q11 "callmark")) "用例11 首次调用（退出码 1）确实发生过"

    # ---- 用例 12：显式 -Accel tcg（无 tcg 兜底）启动即失败 → 不回退 → Pass=$false 且 Reason 不提及回退 ----
    $q12 = Join-Path $work "qemu12"
    New-FakeQemuStateful $q12 $fullMtlog
    $r12 = . $smokeScript -Iso $dummyIso -QemuDir $q12 -TimeLimitSeconds 30 -Accel tcg
    Assert ($r12.Pass -eq $false) "用例12 -Accel tcg 无兜底 Pass=$false（实际 $($r12.Pass)，Reason=$($r12.Reason)）"
    Assert ($r12.Reason -notmatch '回退') "用例12 Reason 不提及回退（$($r12.Reason)）"

    Remove-Item Env:MT_SMOKE_SCRIPT -ErrorAction SilentlyContinue
} finally {
    Remove-Item Env:MT_SMOKE_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "test-smoke: ALL PASS"
