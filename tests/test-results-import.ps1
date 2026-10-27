# ============================================================================
# test-results-import.ps1 — 结果归集（Export-ServerResults / Import-ServerResults）黑盒测试
# 临时包根拷贝法：把脚本+lib_common 复制到临时目录结构（$tmp\kit\），
#   Write-CmdLog 自动落临时库 results\cmdlog（$PSScriptRoot 指向 kit\scripts），不污染真实库。
# Task 1 覆盖 export 部分（zip 生成 + 顶层 7 项）；import 断言由 Task 2 追加。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-results-import.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

# ---- 临时包根拷贝法：把脚本复制到临时目录结构，cmdlog 落临时库 ----
$tmpRoot = Join-Path $env:TEMP ("rim-" + [guid]::NewGuid().ToString("N"))
$tmpKit = Join-Path $tmpRoot "kit"; $tmpU = Join-Path $tmpRoot "u"
New-Item -ItemType Directory -Path (Join-Path $tmpKit "scripts"), (Join-Path $tmpKit "results"), $tmpU -Force | Out-Null
$src = (Split-Path -Parent $PSScriptRoot)
foreach ($f in @("Export-ServerResults.ps1", "lib_common.ps1")) {
    Copy-Item (Join-Path $src "scripts\$f") (Join-Path $tmpKit "scripts\$f") -Force
}

# ---- 构造假服务器 results（6 项待打包内容；export\ 目录存在但不打包） ----
$res = Join-Path $tmpKit "results"
foreach ($d in @("reports", "work\logs", "cmdlog", "assessment", "export")) { New-Item -ItemType Directory -Path (Join-Path $res $d) -Force | Out-Null }
"a1" | Out-File (Join-Path $res "srv01-a1.csv") -Encoding UTF8
"m"  | Out-File (Join-Path $res "master_manifest.csv") -Encoding UTF8
"p"  | Out-File (Join-Path $res "reports\p95.csv") -Encoding UTF8
"t"  | Out-File (Join-Path $res "work\logs\results.txt") -Encoding UTF8
"c"  | Out-File (Join-Path $res "cmdlog\commands-2026-10-26.csv") -Encoding UTF8
"a"  | Out-File (Join-Path $res "assessment\srv01-cap-被测服务器.csv") -Encoding UTF8

# ---- 跑 Export ----
& (Join-Path $tmpKit "scripts\Export-ServerResults.ps1") -MachineName srv01 -ResultsDir $res -OutDir (Join-Path $res "export")
$zip = @(Get-ChildItem (Join-Path $res "export") -Filter "srv01-results-*.zip")
Assert ($zip.Count -eq 1) "zip 生成"

# ---- 断言 zip 顶层 7 项（首层路径段集合） ----
# 注：PS5.1 Compress-Archive 条目名用反斜杠（如 reports\p95.csv），因此首层段按 / 与 \ 都切
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead($zip[0].FullName)
$tops = @($z.Entries | ForEach-Object { $_.FullName.Split(@('/','\'))[0] })
$z.Dispose()
foreach ($n in @("master_manifest.csv", "srv01-a1.csv", "reports", "work", "assessment", "cmdlog", "_export-meta.txt")) {
    Assert ($tops -contains $n) "zip 顶层含 $n"
}

# ---- 清理临时目录 ----
Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Host "test-results-import (export): ALL PASS"
