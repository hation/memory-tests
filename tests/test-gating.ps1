# ============================================================================
# test-gating.ps1 — 门控回归测试（fake-ipmitool 模拟，避免真实 BMC）
# 覆盖本次最易回归的三类行为：
#   1. USB 方式不得弹密码提示（密码门控仅 SOL 生效，防误改导致 Read-Host 阻塞）
#   2. 调度器 DryRun 输出脱敏（-BmcPass ***，不泄漏明文）+ 管道单次供密
#   3. Check-ServerCapabilities 管道密码被脚本顶层消费（不挂起、输出无明文）
# 用法：powershell -NoProfile -File tests\test-gating.ps1
# ============================================================================
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

$ps     = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$suite  = Join-Path $PSScriptRoot "..\scripts\Run-MemtestSuite.ps1"
$sched  = Join-Path $PSScriptRoot "..\scripts\Run-BatchScheduler.ps1"
$caps   = Join-Path $PSScriptRoot "..\scripts\Check-ServerCapabilities.ps1"
$fake   = Join-Path $PSScriptRoot "fixtures\fake-ipmitool.cmd"
Assert (Test-Path -LiteralPath $fake) "fake-ipmitool 夹具存在"

# ---- 用例 1：USB 门控不弹密码 ----
# 空 stdin 启动：若门控回归（USB 也进 Read-BmcPass），Read-Host -AsSecureString
# 在重定向 stdin 下会挂起且无输出；正常路径则会打印编排横幅/进入 USB 等待循环/自行退出。
$outF = Join-Path $env:TEMP ("mt-gate-usb-out-" + [guid]::NewGuid().ToString("N") + ".txt")
$errF = Join-Path $env:TEMP ("mt-gate-usb-err-" + [guid]::NewGuid().ToString("N") + ".txt")
$inF  = Join-Path $env:TEMP ("mt-gate-usb-in-"  + [guid]::NewGuid().ToString("N") + ".txt")
$p = $null
try {
    "" | Set-Content -LiteralPath $inF -Encoding ASCII
    $p = Start-Process -FilePath $ps `
            -ArgumentList @('-NoProfile', '-File', $suite, '-BootMethod', 'USB', '-BatchName', 't') `
            -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF `
            -PassThru -WindowStyle Hidden
    $exited = $p.WaitForExit(20000)
    if (-not $exited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $o = ((Get-Content -LiteralPath $outF -Raw -ErrorAction SilentlyContinue) + "`n" +
          (Get-Content -LiteralPath $errF -Raw -ErrorAction SilentlyContinue))
    Assert ($o -notmatch 'BMC 密码') "USB 门控不得弹密码提示（发现 'BMC 密码'）"
    if ($exited) {
        # 自行退出=已过门控：要么正常走到 USB 流程（缺 -UsbDrive 报 Test-Path 错误退出），
        # 要么识别不到内存早退；两者输出都应含编排横幅或 USB 等待报错（Test-Path）。
        Assert (($o -match '编排开始') -or ($o -match 'Test-Path')) "USB 门控已通过（进程自行退出，码 $($p.ExitCode)），但未见编排横幅/USB 流程报错"
        Write-Host "  [case1] USB 门控 OK：进程自行退出（码 $($p.ExitCode)），无密码提示"
    } else {
        Assert ($o -match '编排开始|USB 方式') "USB 门控已通过（进程停在 USB 等待循环），但输出缺编排横幅——疑似卡在密码门控（回归）"
        Write-Host "  [case1] USB 门控 OK：20s 超时，进程已过门控、停在 USB 等待循环（缺 -UsbDrive），无密码提示"
    }
} finally {
    Remove-Item -LiteralPath $outF, $errF, $inF -Force -ErrorAction SilentlyContinue
}

# ---- 用例 2：调度器 DryRun 脱敏 + 管道单次供密 ----
# 2a：现有夹具（两行均带 BmcPass）→ 不触发密码提示，验证命令展示脱敏
$csvA = Join-Path $PSScriptRoot "fixtures\sample-batches.csv"
$oA = & $ps -NoProfile -File $sched -ManifestCsv $csvA -DryRun 2>&1 | Out-String
Assert ($oA -match '-BmcPass \*\*\*') "DryRun 展示必须脱敏为 -BmcPass ***"
Assert ($oA -notmatch 'pwd') "DryRun 输出不得含明文密码 pwd"
Write-Host "  [case2] 调度器脱敏 OK：-BmcPass *** 出现、无明文 pwd"

# 2b：临时夹具（两行缺 BmcPass）→ 管道单次提供密码，统一赋值且展示脱敏
$csvB = Join-Path $env:TEMP ("mt-gate-batches-" + [guid]::NewGuid().ToString("N") + ".csv")
try {
    "BatchName,BootMethod,BmcHost,BmcUser,BmcPass,UsbDrive,EfiImage,SerialPort,BaudRate,MaxPasses,TestList,ExpectedCsv,MonitorEcc,MonitorTemp,RestartLoop,ConfirmSwitch,LogPath" | Set-Content -LiteralPath $csvB -Encoding ASCII
    "b1,SOL,1.2.3.4,admin,,,,115200,4,,,no,no,0,yes," | Add-Content -LiteralPath $csvB -Encoding ASCII
    "b2,SOL,1.2.3.5,admin,,,,115200,4,,,no,no,0,yes," | Add-Content -LiteralPath $csvB -Encoding ASCII
    $oB = "secretpw" | & $ps -NoProfile -File $sched -ManifestCsv $csvB -DryRun 2>&1 | Out-String
    Assert (([regex]::Matches($oB, '-BmcPass \*\*\*')).Count -ge 2) "单次管道密码应赋给全部缺密行（两行均显示 -BmcPass ***）"
    Assert ($oB -notmatch 'secretpw') "调度器不得泄漏管道密码 secretpw"
    Write-Host "  [case2b] 调度器单次供密 OK：两行均脱敏、无明文 secretpw"
} finally {
    Remove-Item -LiteralPath $csvB -Force -ErrorAction SilentlyContinue
}

# ---- 用例 3：Check-ServerCapabilities 管道密码 ----
$oC = "pw" | & $ps -NoProfile -File $caps -BmcHost 1.2.3.4 -BmcUser u -IpmiTool $fake 2>&1 | Out-String
Assert ($oC -match '1\.2\.3\.4') "能力检查输出应含 BMC 主机 1.2.3.4"
Assert ($oC -notmatch 'pw') "能力检查输出不得含管道密码 pw"
Write-Host "  [case3] 管道密码 OK：BMC 行含 1.2.3.4、无明文 pw"

Write-Host ""
Write-Host "test-gating: ALL PASS"
