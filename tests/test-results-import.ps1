# ============================================================================
# test-results-import.ps1 — 结果归集（Export-ServerResults / Import-ServerResults）黑盒测试
# 临时包根拷贝法：把脚本+lib_common 复制到临时目录结构（$tmp\kit\），
#   Write-CmdLog 自动落临时库 results\cmdlog（$PSScriptRoot 指向 kit\scripts），不污染真实库。
# Task 1/2 覆盖：export（zip 生成 + 顶层 7 项 + 失败场景）与 import（导入结构 / import-log /
#   防重复跳过 / -Force 重导 / 累积第二个 zip）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-results-import.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

# ---- 临时包根拷贝法：把脚本复制到临时目录结构，cmdlog 落临时库 ----
$tmpRoot = Join-Path $env:TEMP ("rim-" + [guid]::NewGuid().ToString("N"))
$tmpKit = Join-Path $tmpRoot "kit"; $tmpU = Join-Path $tmpRoot "u"
New-Item -ItemType Directory -Path (Join-Path $tmpKit "scripts"), (Join-Path $tmpKit "results"), $tmpU -Force | Out-Null
$src = (Split-Path -Parent $PSScriptRoot)
foreach ($f in @("Export-ServerResults.ps1", "Import-ServerResults.ps1", "lib_common.ps1")) {
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
$zip1EntryCount = $z.Entries.Count   # 首次导入 zip 的条目数，供 import-log FileCount 断言
$tops = @($z.Entries | ForEach-Object { $_.FullName.Split(@('/','\'))[0] })
$z.Dispose()
foreach ($n in @("master_manifest.csv", "srv01-a1.csv", "reports", "work", "assessment", "cmdlog", "_export-meta.txt")) {
    Assert ($tops -contains $n) "zip 顶层含 $n"
}

# ---- 失败场景回归：默认 ResultsDir（<包根>\results）缺失 → 报"结果目录不存在"，不误报"无结果可导出" ----
$tmpKit2 = Join-Path $tmpRoot "kit2"
New-Item -ItemType Directory -Path (Join-Path $tmpKit2 "scripts") -Force | Out-Null
foreach ($f in @("Export-ServerResults.ps1", "lib_common.ps1")) {
    Copy-Item (Join-Path $src "scripts\$f") (Join-Path $tmpKit2 "scripts\$f") -Force
}
$out2 = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmpKit2 "scripts\Export-ServerResults.ps1") -MachineName srv01 2>&1 | Out-String
Assert ($LASTEXITCODE -eq 1) "默认 ResultsDir 缺失 exit 1"
Assert ($out2 -match "结果目录不存在") "默认 ResultsDir 缺失报'结果目录不存在'（实际输出: $out2）"
Assert ($out2 -notmatch "无结果可导出") "不得误报'无结果可导出'（实际输出: $out2）"

# ================ import 断言（Task 2） ================
# ---- 模拟 U盘搬运：把 zip 复制到 tmp\u\ ----
$zipPath = Copy-Item $zip[0].FullName (Join-Path $tmpU $zip[0].Name) -PassThru
# ---- 跑 Import（首次导入） ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res
$imp = Join-Path $res "imported\srv01"
Assert (Test-Path (Join-Path $imp "master_manifest.csv")) "导入 master_manifest"
Assert (Test-Path (Join-Path $imp "srv01-a1.csv")) "导入建档"
Assert (Test-Path (Join-Path $imp "reports\p95.csv")) "导入 reports"
Assert (Test-Path (Join-Path $imp "work\logs\results.txt")) "导入 work"
Assert (Test-Path (Join-Path $imp "cmdlog\commands-2026-10-26.csv")) "导入 cmdlog"
Assert (Test-Path (Join-Path $imp "assessment\srv01-cap-被测服务器.csv")) "导入 assessment"
Assert (Test-Path (Join-Path $imp "_export-meta.txt")) "导入 meta"
$log = @(Import-Csv (Join-Path $res "imported\import-log.csv"))
Assert ($log.Count -eq 1 -and $log[0].ZipName -eq $zip[0].Name -and $log[0].MachineName -eq 'srv01' -and $log[0].Note -eq '首次导入') "import-log 首次导入"
Assert ($log[0].SourceDir -eq $res) "SourceDir=meta 的 ServerResultsDir"
Assert ([int]$log[0].FileCount -eq $zip1EntryCount) "import-log FileCount=zip 条目数（$zip1EntryCount）"
# ---- 二次导入同一 zip → 跳过（log 不追加） ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res 2>$null | Out-Null
$log2 = @(Import-Csv (Join-Path $res "imported\import-log.csv"))
Assert ($log2.Count -eq 1) "二次导入跳过，log 不追加"
# ---- -Force 重导 → 重新解压 + log 追加 Note=重导 ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res -Force
$log3 = @(Import-Csv (Join-Path $res "imported\import-log.csv"))
Assert ($log3.Count -eq 2 -and $log3[1].Note -eq '重导') "Force 重导 log 追加"
# ---- 累积：第二个 zip（新建档 + 改旧建档） ----
# 注：Export 的 zip 名只到日期粒度（srv01-results-YYYYMMDD.zip），同日再导出覆盖同名 zip；
#     复制后改名成"昨日批次"模拟次日第二个 zip，走首次导入路径（不同 ZipName 不判重）。
"srv01-a1-v2" | Out-File (Join-Path $res "srv01-a1.csv") -Encoding UTF8
"a2" | Out-File (Join-Path $res "srv01-a2.csv") -Encoding UTF8
& (Join-Path $tmpKit "scripts\Export-ServerResults.ps1") -MachineName srv01 -ResultsDir $res -OutDir (Join-Path $res "export")
$zip2 = @(Get-ChildItem (Join-Path $res "export") -Filter "srv01-results-*.zip")
Assert ($zip2.Count -eq 1) "第二次导出覆盖同名 zip"
$zip2Name = $zip2[0].Name -replace '\d{8}', (Get-Date).AddDays(-1).ToString("yyyyMMdd")
Copy-Item $zip2[0].FullName (Join-Path $tmpU $zip2Name) -Force | Out-Null
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath (Join-Path $tmpU $zip2Name) -ImportRoot $res
Assert ((Get-Content (Join-Path $imp "srv01-a1.csv")) -contains 'srv01-a1-v2') "同名覆盖为新内容"
Assert (Test-Path (Join-Path $imp "srv01-a2.csv")) "新建档并入"
Assert (Test-Path (Join-Path $imp "reports\p95.csv")) "旧批次独有文件保留"

# ---- 清理临时目录 ----
Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Host "test-results-import: ALL PASS"
