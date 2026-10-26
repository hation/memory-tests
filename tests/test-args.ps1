. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$rows = @(Read-CsvManifest -Path "$PSScriptRoot\fixtures\sample-batches.csv")
Assert ($rows.Count -eq 2) "row count"
Assert ($rows[0].TestList -eq "0,1,2,3") "quoted comma TestList"
Assert ($rows[1].LogPath -eq "") "trailing empty kept"

# ORT 参数校验用例（子进程方式：Run-MemtestSuite.ps1 内部 exit 会终止调用进程，须用 powershell.exe 子进程；
# 30s 超时同时验证"无密码交互"——若卡在 Read-BmcPass 交互则 WaitForExit 超时即失败；
# 子进程强制 UTF-8 输出编码 + 父进程按 UTF-8 解码，避免 Start-Process 重定向文件的 ANSI/UTF-8 编码歧义）
$ortScript = Join-Path $PSScriptRoot '..\scripts\Run-MemtestSuite.ps1'
function Invoke-OrTArgCheck {
    param([string[]]$ArgsList)
    $cmd = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '" + $ortScript + "' " + ($ArgsList -join ' ') + " 2>&1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(30000)) {
        $p.Kill()
        $p.WaitForExit()
        throw "ASSERT FAIL: 子进程 30s 未退出（疑似卡在密码交互）"
    }
    $output = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    return [PSCustomObject]@{ ExitCode = $p.ExitCode; Output = $output }
}

# 用例 1：-MaxMinutes 与 -RestartLoop 互斥 → 报错 + 退出码非 0 + 无密码交互
$r = Invoke-OrTArgCheck @("-MaxMinutes", "4320", "-RestartLoop", "5")
Assert ($r.ExitCode -ne 0) "ORT 与 RestartLoop 互斥退出码非 0"
Assert ($r.Output -match '互斥') "ORT 与 RestartLoop 互斥报错"

# 用例 2：ORT 仅支持 SOL/Serial，-BootMethod USB → 报错 + 退出码非 0
$r = Invoke-OrTArgCheck @("-MaxMinutes", "4320", "-BootMethod", "USB")
Assert ($r.ExitCode -ne 0) "ORT USB 退出码非 0"
Assert ($r.Output -match '仅支持 SOL/Serial') "ORT USB 报错仅支持 SOL/Serial"

Write-Host "test-args: ALL PASS"
