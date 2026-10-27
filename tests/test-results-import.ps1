# ============================================================================
# test-results-import.ps1 — 结果归集（Export-ServerResults / Import-ServerResults）黑盒测试
# 临时包根拷贝法：把脚本+lib_common 复制到临时目录结构（$tmp\kit\），
#   Write-CmdLog 自动落临时库 results\cmdlog（$PSScriptRoot 指向 kit\scripts），不污染真实库。
# Task 1/2 覆盖：export（zip 生成 + 顶层 7 项 + 失败场景）与 import（导入结构 / import-log /
#   防重复跳过 / -Force 重导 / 累积第二个 zip）。
# Task 4 覆盖：export 打包任务清单（results\<批次>\ → zip 顶层批次目录）+ import 归集合并
#   （Merge-TaskChecklists：服务器独有流程清单带入 / 总览逐行取有状态方 / 写回编排机目录）。
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

# ================ 任务清单打包 + 归集合并断言（Task 4） ================
# ---- 构造服务器任务清单（批次 srv01-a1，置于 results\<批次>\；zip 应带批次目录） ----
$clBatch = "srv01-a1"
$clDir = Join-Path $res $clBatch
New-Item -ItemType Directory -Path $clDir -Force | Out-Null
$clUtf8 = New-Object System.Text.UTF8Encoding($false)
# 服务器总览：项1 ✓（建档已做）、项3 ─（未跑 Memtest）、项15 ✓（服务器15）
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-总览.md"), @(
    "| 项 | 验收项 | 状态 | 结果 | 原因 | 流程 |",
    "| --- | --- | --- | --- | --- | --- |",
    "| 1 | SPD 信息校验 | ✓ 做成 | SPD 匹配 | | 建档 |",
    "| 2 | 基础识别/容量频率 | ─ 等待执行 | | | 建档 |",
    "| 3 | 全地址读写覆盖(Memtest) | ─ 等待执行 | | | Memtest |",
    "| 15 | 多平台兼容 | ✓ 做成 | 服务器15 | | 多平台 |",
    "| 16 | 多通道混插压力 | ─ 等待执行 | | | 混插 |",
    "| 17 | 外观/焊点/电性复检 | ─ 等待执行 | | | 目检电性 |"
), $clUtf8)
# 服务器独有流程清单（建档）+ 共享混插清单
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-建档.md"), @(
    "# 任务清单-建档",
    "| 环节 | 内容 | 状态 | 结果 | 产物 |",
    "| --- | --- | --- | --- | --- |",
    "| 识别条子 | SPD 识别 | ✓ 做成 | SN 已识别 | srv01-a1.csv |",
    "| 生成清单 | 建批次清单 | ─ 等待执行 | | 无 |",
    "| 比对 | 与数据库比对 | ─ 等待执行 | | 无 |"
), $clUtf8)
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-混插.md"), @(
    "# 任务清单-混插",
    "| 环节 | 内容 | 状态 | 结果 | 产物 |",
    "| --- | --- | --- | --- | --- |",
    "| Memtest 混插组合 | 多通道混插 Memtest | ✓ 做成 | PASS | mix-report.csv |",
    "| Prime95 长压 | 混插 Prime95 | ─ 等待执行 | | 无 |"
), $clUtf8)

# ---- Export（第三次导出；zip 顶层含清单批次目录 srv01-a1\） ----
& (Join-Path $tmpKit "scripts\Export-ServerResults.ps1") -MachineName srv01 -ResultsDir $res -OutDir (Join-Path $res "export")
$zip3 = @(Get-ChildItem (Join-Path $res "export") -Filter "srv01-results-*.zip")
Assert ($zip3.Count -eq 1) "第三次导出覆盖同名 zip"
$z3 = [System.IO.Compression.ZipFile]::OpenRead($zip3[0].FullName)
$tops3 = @($z3.Entries | ForEach-Object { $_.FullName.Split(@('/','\'))[0] })
Assert ($tops3 -contains $clBatch) "zip 顶层含清单批次目录 $clBatch"
Assert (@($z3.Entries | Where-Object { $_.FullName -match ([regex]::Escape($clBatch) + '\\任务清单-总览\.md') }).Count -eq 1) "zip 内含 $clBatch\任务清单-总览.md"
$z3.Dispose()

# ---- 编排机侧预置清单（模拟编排机已跑部分项：覆盖 $res\$clBatch\ 为编排机版本；zip 已带走服务器版本） ----
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-总览.md"), @(
    "| 项 | 验收项 | 状态 | 结果 | 原因 | 流程 |",
    "| --- | --- | --- | --- | --- | --- |",
    "| 1 | SPD 信息校验 | ─ 等待执行 | | | 建档 |",
    "| 3 | 全地址读写覆盖(Memtest) | ✓ 做成 | 1轮全项 PASS | | Memtest |",
    "| 15 | 多平台兼容 | ✓ 做成 | 编排机15 | | 多平台 |"
), $clUtf8)
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-混插.md"), @(
    "# 任务清单-混插",
    "| 环节 | 内容 | 状态 | 结果 | 产物 |",
    "| --- | --- | --- | --- | --- |",
    "| Memtest 混插组合 | 多通道混插 Memtest | ─ 等待执行 | | 无 |",
    "| Prime95 长压 | 混插 Prime95 | ✓ 做成 | P95 PASS | p95-report.csv |"
), $clUtf8)

# ---- Import（zip3 改名"明日批次"防与今日 zip1 判重；导入触发清单归集合并） ----
$zip3Name = $zip3[0].Name -replace '\d{8}', (Get-Date).AddDays(1).ToString("yyyyMMdd")
Copy-Item $zip3[0].FullName (Join-Path $tmpU $zip3Name) -Force | Out-Null
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath (Join-Path $tmpU $zip3Name) -ImportRoot $res

# ---- 断言合并结果（写回编排机 <ImportRoot>\<批次>\ == $res\srv01-a1） ----
function Get-OvRowVal([string]$Path, [string]$ItemNo, [int]$Col) {
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match ("^\| " + $ItemNo + " \|")) {
            $cols = $line -split "\|"
            if ($cols.Count -gt $Col) { return $cols[$Col].Trim() }
        }
    }
    return $null
}
function Get-FlowRowVal([string]$Path, [string]$Key, [int]$Col) {
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\| ' -and $line -notmatch '^\|-') {
            $cols = $line -split "\|"
            if ($cols.Count -ge 5 -and $cols[1].Trim() -eq $Key) { return $cols[$Col].Trim() }
        }
    }
    return $null
}
$ovPath = Join-Path $clDir "任务清单-总览.md"
Assert (Test-Path $ovPath) "合并后总览写回编排机目录"
Assert ((Get-OvRowVal $ovPath '1' 3) -eq '✓ 做成' -and (Get-OvRowVal $ovPath '1' 4) -eq 'SPD 匹配') "总览项1 取服务器 ✓（服务器有状态、编排机 ─）"
Assert ((Get-OvRowVal $ovPath '3' 3) -eq '✓ 做成' -and (Get-OvRowVal $ovPath '3' 4) -eq '1轮全项 PASS') "总览项3 保留编排机 ✓（服务器 ─、编排机有状态）"
Assert ((Get-OvRowVal $ovPath '15' 3) -eq '✓ 做成' -and (Get-OvRowVal $ovPath '15' 4) -eq '服务器15') "总览项15 取服务器 ✓（两边均有状态取服务器）"
$jdPath = Join-Path $clDir "任务清单-建档.md"
Assert (Test-Path $jdPath) "服务器独有流程清单（建档）带入编排机"
Assert ((Get-FlowRowVal $jdPath '识别条子' 3) -eq '✓ 做成' -and (Get-FlowRowVal $jdPath '识别条子' 4) -eq 'SN 已识别') "建档清单带服务器状态/结果"
$hxPath = Join-Path $clDir "任务清单-混插.md"
Assert ((Get-FlowRowVal $hxPath 'Memtest 混插组合' 3) -eq '✓ 做成' -and (Get-FlowRowVal $hxPath 'Memtest 混插组合' 4) -eq 'PASS') "混插 Memtest 行取服务器"
Assert ((Get-FlowRowVal $hxPath 'Prime95 长压' 3) -eq '✓ 做成' -and (Get-FlowRowVal $hxPath 'Prime95 长压' 4) -eq 'P95 PASS') "混插 Prime95 行保留编排机"

# ================ M3 回归：Import 只合并本次 zip 携带的任务清单 ================
# 场景：编排机在导入 a1 后继续推进（项15 改为"编排机复核"）；随后导入的新 zip（zip4）
#   只携带新批次 srv01-a2 清单（a1 清单不在导出范围）。旧实现扫描整个累积解压目标，
#   会把此前导入的 a1 服务器旧状态（项15=服务器15）回扫进合并、覆盖编排机推进行；
#   新实现按 zip 条目名限定本次 zip 携带的批次 → a1 不再被触碰。
[System.IO.File]::WriteAllLines((Join-Path $clDir "任务清单-总览.md"), @(
    "| 项 | 验收项 | 状态 | 结果 | 原因 | 流程 |",
    "| --- | --- | --- | --- | --- | --- |",
    "| 1 | SPD 信息校验 | ✓ 做成 | SPD 匹配 | | 建档 |",
    "| 3 | 全地址读写覆盖(Memtest) | ✓ 做成 | 1轮全项 PASS | | Memtest |",
    "| 15 | 多平台兼容 | ✓ 做成 | 编排机复核 | | 多平台 |"
), $clUtf8)
# 服务器新批次 a2 清单（zip4 唯一携带的清单批次）
$clDir2 = Join-Path $res "srv01-a2"
New-Item -ItemType Directory -Path $clDir2 -Force | Out-Null
[System.IO.File]::WriteAllLines((Join-Path $clDir2 "任务清单-总览.md"), @(
    "| 项 | 验收项 | 状态 | 结果 | 原因 | 流程 |",
    "| --- | --- | --- | --- | --- | --- |",
    "| 1 | SPD 信息校验 | ✓ 做成 | SPD 匹配 a2 | | 建档 |",
    "| 3 | 全地址读写覆盖(Memtest) | ─ 等待执行 | | | Memtest |"
), $clUtf8)
[System.IO.File]::WriteAllLines((Join-Path $clDir2 "任务清单-建档.md"), @(
    "# 任务清单-建档",
    "| 环节 | 内容 | 状态 | 结果 | 产物 |",
    "| --- | --- | --- | --- | --- |",
    "| 识别条子 | SPD 识别 | ✓ 做成 | SN a2 | srv01-a2.csv |"
), $clUtf8)
# 按 Export 的 staging 打包形态构造 zip4（顶层为 srv01-a2\ 批次目录）
$stage4 = Join-Path $tmpRoot "stage4"
New-Item -ItemType Directory -Path $stage4 -Force | Out-Null
Copy-Item $clDir2 $stage4 -Recurse -Force
$zip4Name = "srv01-results-" + (Get-Date).AddDays(2).ToString("yyyyMMdd") + ".zip"
$zip4Path = Join-Path $tmpU $zip4Name
Compress-Archive -Path (Join-Path $stage4 '*') -DestinationPath $zip4Path -CompressionLevel Optimal -Force
$z4 = [System.IO.Compression.ZipFile]::OpenRead($zip4Path)
Assert (@($z4.Entries | Where-Object { $_.FullName -match '任务清单-' }).Count -gt 0) "zip4 携带 a2 清单条目"
Assert (@($z4.Entries | Where-Object { $_.FullName -match 'srv01-a1' }).Count -eq 0) "zip4 不携带 a1 清单"
$z4.Dispose()
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zip4Path -ImportRoot $res
Assert ((Get-OvRowVal $ovPath '15' 3) -eq '✓ 做成' -and (Get-OvRowVal $ovPath '15' 4) -eq '编排机复核') "新 zip 不携带 a1 时 a1 保持编排机推进行（旧实现会回扫累积目标覆盖为服务器15）"
Assert (Test-Path (Join-Path $res "srv01-a2\任务清单-总览.md")) "新批次 a2 清单归集合并写回编排机目录"
Assert ((Get-OvRowVal (Join-Path $res "srv01-a2\任务清单-总览.md") '1' 3) -eq '✓ 做成' -and (Get-OvRowVal (Join-Path $res "srv01-a2\任务清单-总览.md") '1' 4) -eq 'SPD 匹配 a2') "a2 清单合并带服务器状态"

# ---- 清理临时目录 ----
Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Host "test-results-import: ALL PASS"
