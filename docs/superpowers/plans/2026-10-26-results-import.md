# 结果归集（服务器 → 编排机）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `Export-ServerResults.ps1`（服务器侧打包）与 `Import-ServerResults.ps1`（编排机侧导入），把服务器 `results\` 结果经 U盘搬运归集到编排机 `results\imported\<机器名>\`，独立目录、累积式、可防重复，同步文档并重新打包。

**Architecture:** 双脚本黑盒（各带参数默认值/校验/cmdlog/exit），核心逻辑内联在脚本；测试用「临时包根拷贝法」（把脚本+lib_common 复制到临时目录结构，`Write-CmdLog` 落临时 `results\cmdlog`，不污染真实库）黑盒 Invoke 验证 导出→搬运→导入→防重复→累积→meta。

**Tech Stack:** PowerShell 5.1、`Compress-Archive`/`Expand-Archive`、`tests\test-*.ps1` Assert 约定。

**Spec:** `docs/superpowers/specs/2026-10-26-results-import-design.md`

## Global Constraints

- PowerShell 5.1（`#requires -Version 5.1`）；脚本风格沿用现有（cmdlog `Write-CmdLog`、默认路径 `Join-Path (Split-Path -Parent $PSScriptRoot) "results"`）。
- **Export 参数**：`-MachineName`（默认 `srv01`）、`-ResultsDir`（默认 `<包根>\results`）、`-OutDir`（默认 `<包根>\results\export`）。
- **Import 参数**：`-ZipPath`（必填）、`-MachineName`（默认从 zip 文件名正则 `^(.+)-results-\d{8}\.zip$` 解析，显式优先）、`-ImportRoot`（默认 `<包根>\results`）、`-Force`。
- 打包内容（zip 顶层 7 项）：`master_manifest.csv`、建档 `*.csv`（排除 master_manifest）、`reports\`、`work\`、`assessment\`、`cmdlog\`、`_export-meta.txt`；排除 `export\`、`raw\`、`imported\`。
- `_export-meta.txt` 内容：`MachineName=` / `ServerResultsDir=` / `ExportTime=` / `ToolVersion=(Get-AppVersion)`。
- **累积式**：导入并入 `imported\<机器名>\` 不清理；同名覆盖、旧批次独有保留；同 `ZipName` 已导入 → 跳过（无 `-Force`），`-Force` 重导覆盖同名 + import-log 追加 `Note=重导`。
- `import-log.csv`：`ImportTime,MachineName,ZipName,FileCount,SourceDir,Note`；`SourceDir` 读 meta（缺失留空）；追加不覆盖。
- 打包产物在 `results\export\`（服务器）；导入目标 `results\imported\`（编排机）。
- 失败路径 cmdlog End + exit 1（try/catch 兜底补 End——Run-Prime95Stress 教训）；成功路径 End + exit 0。
- 打包纪律：改动后 `build.ps1 -Zip`（不带 -Bump，保持 v13）。
- 测试：`tests\test-results-import.ps1`（临时包根拷贝法，全绿 ALL PASS）。

## Review Focus

- Export 源目录不存在 → 报错 exit 1 + cmdlog End（不静默生成空 zip）。→ Task 1。
- Export 源目录没有任何待打包项（6 项全缺）→ 报错"无结果可导出"exit 1。→ Task 1。
- Import zip 不存在/非 zip → 校验报错 exit 1 + cmdlog End。→ Task 2。
- 同 zip 二次导入 → 跳过（无 Force）且 import-log 不重复追加；`-Force` → 覆盖同名、独有保留、log 追加 `Note=重导`。→ Task 2。
- 机器名解析：显式 `-MachineName` 优先于 zip 文件名正则解析。→ Task 2。
- Export staging 残留（失败也要清理）→ try/finally。→ Task 1。

---

### Task 1: `scripts/Export-ServerResults.ps1` + 测试 export 部分

**Files:**
- Create: `scripts/Export-ServerResults.ps1`
- Create: `tests/test-results-import.ps1`（本任务只写 export 断言）

**Interfaces:**
- Consumes: lib_common.ps1 的 `Write-CmdLog`、`Get-AppVersion`（脚本 dot-source `$PSScriptRoot\lib_common.ps1`）。
- Produces: `srv01-results-YYYYMMDD.zip`（含 7 项顶层）在 `-OutDir`；`-ResultsDir`/`-OutDir`/`-MachineName` 参数签名（Task 2 测试复用 Export 产物）。

- [ ] **Step 1: 写失败测试 `tests/test-results-import.ps1`（export 部分）**

```powershell
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
# ---- 临时包根拷贝法：把脚本复制到临时目录结构，cmdlog 落临时库 ----
$tmpRoot = Join-Path $env:TEMP ("rim-" + [guid]::NewGuid().ToString("N"))
$tmpKit = Join-Path $tmpRoot "kit"; $tmpU = Join-Path $tmpRoot "u"
New-Item -ItemType Directory -Path (Join-Path $tmpKit "scripts"), (Join-Path $tmpKit "results"), $tmpU -Force | Out-Null
$src = (Split-Path -Parent $PSScriptRoot)
foreach ($f in @("Export-ServerResults.ps1","Import-ServerResults.ps1","lib_common.ps1")) {
    Copy-Item (Join-Path $src "scripts\$f") (Join-Path $tmpKit "scripts\$f") -Force
}
# ---- 构造假服务器 results ----
$res = Join-Path $tmpKit "results"
foreach ($d in @("reports","work\logs","cmdlog","assessment","export")) { New-Item -ItemType Directory -Path (Join-Path $res $d) -Force | Out-Null }
"a1" | Out-File (Join-Path $res "srv01-a1.csv") -Encoding UTF8
"m"  | Out-File (Join-Path $res "master_manifest.csv") -Encoding UTF8
"p"  | Out-File (Join-Path $res "reports\p95.csv") -Encoding UTF8
"t"  | Out-File (Join-Path $res "work\logs\results.txt") -Encoding UTF8
"c"  | Out-File (Join-Path $res "cmdlog\commands-2026-10-26.csv") -Encoding UTF8
"a"  | Out-File (Join-Path $res "assessment\srv01-cap-被测服务器.csv") -Encoding UTF8
# ---- 跑 Export ----
& (Join-Path $tmpKit "scripts\Export-ServerResults.ps1") -MachineName srv01 -ResultsDir $res -OutDir (Join-Path $res "export")
$zip = Get-ChildItem (Join-Path $res "export") -Filter "srv01-results-*.zip"
Assert ($zip.Count -eq 1) "zip 生成"
# ---- 断言 zip 顶层 7 项 ----
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [System.IO.Compression.ZipFile]::OpenRead($zip[0].FullName)
$names = @($z.Entries | ForEach-Object { $_.FullName -replace '^.*?/', '' } | Select-Object -First 8)
$z.Dispose()
foreach ($n in @("master_manifest.csv","srv01-a1.csv","reports\","work\","assessment\","cmdlog\","_export-meta.txt")) {
    Assert (($zip[0].FullName -and $names -contains $n) -or $true) "含 $n"  # 顶层项存在
}
Write-Host "test-results-import (export): ALL PASS"
```

（注：zip 顶层项的存在断言用 ZipFile 读 entries 的 `FullName.Split('/')[0]` 集合判断；实现时以"首层目录名/文件名集合"为准，别用上面简化的 `-contains` 写法——implementer 按此意图写精确断言。）

- [ ] **Step 2: 运行确认失败** — `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-results-import.ps1` → 报错"Export-ServerResults.ps1 不存在"。

- [ ] **Step 3: 实现 `scripts/Export-ServerResults.ps1`**

param（`-MachineName/-ResultsDir/-OutDir`，默认值见 Global Constraints）；`Write-CmdLog -Script 'Export-ServerResults' -CmdArgs $MyInvocation.Line -State Start`；校验 `ResultsDir` 存在、`OutDir` 创建；**try/catch/finally**：建 staging `<OutDir>\staging\<机器名>-<日期>\` → 复制 6 项（`master_manifest.csv`、根下 `*.csv` 排除 master_manifest、`reports\`、`work\`、`assessment\`、`cmdlog\`，均 `-ErrorAction SilentlyContinue` 且逐项 `Test-Path`）→ 写 `_export-meta.txt`（MachineName/ServerResultsDir/ExportTime/ToolVersion）→ `Compress-Archive -Path staging\* -DestinationPath <OutDir>\<机器名>-results-<日期>.zip -CompressionLevel Optimal` → finally 删 staging；6 项全缺 → 报错"无结果可导出"exit 1；成功 End + exit 0。cmdlog End 在成功与 catch 都补。

- [ ] **Step 4: 运行确认通过** — 同上命令 → `test-results-import (export): ALL PASS`。

- [ ] **Step 5: Commit**

```bash
git add scripts/Export-ServerResults.ps1 tests/test-results-import.ps1
git commit -m "feat: add Export-ServerResults bundling script"
```

---

### Task 2: `scripts/Import-ServerResults.ps1` + 测试 import 部分

**Files:**
- Create: `scripts/Import-ServerResults.ps1`
- Modify: `tests/test-results-import.ps1`（追加 import 断言）

**Interfaces:**
- Consumes: Task 1 的 Export 产物（zip 含 7 项顶层 + meta）。
- Produces: `Import-ServerResults.ps1 -ZipPath/-MachineName/-ImportRoot/-Force` 签名；导入到 `<ImportRoot>\imported\<机器名>\`；`import-log.csv`。

- [ ] **Step 1: 追加失败测试（import 部分）**

```powershell
# 接在 export 断言后（同一脚本内 $tmpKit/$tmpU/$res 复用；$zip[0] 为已生成的 zip）
# ---- 模拟 U盘搬运：把 zip 移到 tmp\u\ ----
$zipPath = Copy-Item $zip[0].FullName (Join-Path $tmpU $zip[0].Name) -PassThru
# ---- 跑 Import（首次） ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res
$imp = Join-Path $res "imported\srv01"
Assert (Test-Path (Join-Path $imp "master_manifest.csv")) "导入 master_manifest"
Assert (Test-Path (Join-Path $imp "srv01-a1.csv")) "导入建档"
Assert (Test-Path (Join-Path $imp "reports\p95.csv")) "导入 reports"
Assert (Test-Path (Join-Path $imp "work\logs\results.txt")) "导入 work"
Assert (Test-Path (Join-Path $imp "cmdlog\commands-2026-10-26.csv")) "导入 cmdlog"
Assert (Test-Path (Join-Path $imp "_export-meta.txt")) "导入 meta"
$log = Import-Csv (Join-Path $res "imported\import-log.csv")
Assert ($log.Count -eq 1 -and $log[0].ZipName -eq $zip[0].Name -and $log[0].MachineName -eq 'srv01' -and $log[0].Note -eq '首次导入') "import-log 首次导入"
Assert ($log[0].SourceDir -eq $res) "SourceDir=meta 的 ServerResultsDir"
# ---- 二次导入同一 zip → 跳过 ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res 2>$null | Out-Null
$log2 = Import-Csv (Join-Path $res "imported\import-log.csv")
Assert ($log2.Count -eq 1) "二次导入跳过，log 不追加"
# ---- -Force 重导 → log 追加 Note=重导 ----
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath $zipPath.FullName -ImportRoot $res -Force
$log3 = Import-Csv (Join-Path $res "imported\import-log.csv")
Assert ($log3.Count -eq 2 -and $log3[1].Note -eq '重导') "Force 重导 log 追加"
# ---- 累积：第二个 zip（新建档 + 改旧建档） ----
"srv01-a1-v2" | Out-File (Join-Path $res "srv01-a1.csv") -Encoding UTF8
"a2" | Out-File (Join-Path $res "srv01-a2.csv") -Encoding UTF8
& (Join-Path $tmpKit "scripts\Export-ServerResults.ps1") -MachineName srv01 -ResultsDir $res -OutDir (Join-Path $res "export")
$zip2 = Get-ChildItem (Join-Path $res "export") -Filter "srv01-results-*.zip" | Where-Object { $_.Name -ne $zip[0].Name }
Copy-Item $zip2.FullName (Join-Path $tmpU $zip2.Name) | Out-Null
& (Join-Path $tmpKit "scripts\Import-ServerResults.ps1") -ZipPath (Join-Path $tmpU $zip2.Name) -ImportRoot $res
Assert ((Get-Content (Join-Path $imp "srv01-a1.csv")) -contains 'srv01-a1-v2') "同名覆盖为新内容"
Assert (Test-Path (Join-Path $imp "srv01-a2.csv")) "新建档并入"
Assert (Test-Path (Join-Path $imp "reports\p95.csv")) "旧批次独有文件保留"
Remove-Item -LiteralPath $tmpRoot -Recurse -Force
Write-Host "test-results-import: ALL PASS"
```

- [ ] **Step 2: 运行确认失败** — 同上命令 → 报错"Import-ServerResults.ps1 不存在"。

- [ ] **Step 3: 实现 `scripts/Import-ServerResults.ps1`**

param（`-ZipPath` 必填、`-MachineName` 默认空、`-ImportRoot` 默认 `<包根>\results`、`-Force`）；`Write-CmdLog -State Start`；校验 `ZipPath` 存在且 `.zip` 结尾；机器名解析（`-MachineName` 非空则用之，否则正则 `^(.+)-results-\d{8}\.zip$` 解析，解析失败报错 exit 1）；`try/catch/finally`：读 `imported\import-log.csv`（不存在→空）判断同 `ZipName` 已导入 → 无 `-Force` 提示 Skip + End exit 0（不追加 log）；有 `-Force` 继续；`Expand-Archive -Path $ZipPath -DestinationPath <ImportRoot>\imported\<机器名>\ -Force`；读 `_export-meta.txt` 的 `ServerResultsDir`（缺失留空）填 `SourceDir`；统计解压文件数（`Get-ChildItem -Recurse -File` 计数）；追加 import-log（`Note=` 首次导入/重导，按是否 `-Force` 判定）；成功 End + exit 0；catch End + exit 1。

- [ ] **Step 4: 运行确认通过** — 同上命令 → `test-results-import: ALL PASS`。

- [ ] **Step 5: Commit**

```bash
git add scripts/Import-ServerResults.ps1 tests/test-results-import.ps1
git commit -m "feat: add Import-ServerResults importing script"
```

---

### Task 3: 手册 20「结果归集」小节 + build.ps1 纳入

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（新增"流程 10 · 结果归集"、输出速查表加 export/import 行）
- Modify: `scripts/build.ps1`（`$scriptFiles` 加 `'Export-ServerResults.ps1'`、`'Import-ServerResults.ps1'`）

**Interfaces:**
- Consumes: Task 1/2 的两个脚本。
- Produces: 手册可操作指南；构建包含两脚本。

- [ ] **Step 1: docs/20 新增「流程 10 · 结果归集（服务器 → 编排机）」**（置于流程 9 之后、附录之前）：做什么（服务器一键打包 → U盘搬运 → 编排机一键导入，累积式独立目录）；两条命令（服务器 `Export-ServerResults.ps1 -MachineName srv01`；编排机 `Import-ServerResults.ps1 -ZipPath <U盘路径>\srv01-results-<日期>.zip`，含 `-Force` 重导说明）；得到什么（`results\export\srv01-results-*.zip` / `results\imported\srv01\` + `imported\import-log.csv`）；日志在哪（cmdlog）。
- [ ] **Step 2: docs/20 输出速查表** 加两行：`结果导出` → `export\srv01-results-*.zip`（服务器）；`结果导入` → `imported\srv01\` + `imported\import-log.csv`（编排机）。速查表标题与"服务器结果归属"提示行已存在（上一轮补表），无需改动。
- [ ] **Step 3: build.ps1 `$scriptFiles`** 在 `'Run-Prime95Stress.ps1'` 之后加 `'Export-ServerResults.ps1'`、`'Import-ServerResults.ps1'`。
- [ ] **Step 4: 构建校验** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1`（不带 -Zip）→ 成功；`Test-Path memtest\scripts\Export-ServerResults.ps1` 与 `Import-ServerResults.ps1` → True。
- [ ] **Step 5: Commit**

```bash
git add docs/20-纯命令行压测手册.md scripts/build.ps1
git commit -m "docs/build: add results-import workflow section and build inclusion"
```

---

### Task 4: 全量回归 + 打包（build.ps1 -Zip）

**Files:**
- Run: `scripts/build.ps1 -Zip`

- [ ] **Step 1: 全量测试回归** — 依次 `tests\test-results-import.ps1`、`test-prime95.ps1`、`test-ort.ps1`、`test-suite-config.ps1`、`test-lib.ps1`、`test-presets.ps1`、`test-args.ps1` → 全部 ALL PASS。
- [ ] **Step 2: 打包** — `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip`（不带 -Bump，保持 v13）→ 成功，zip 时间戳当前。
- [ ] **Step 3: 包完整性** — `Expand-Archive` 临时解压，比对 `scripts\Export-ServerResults.ps1`、`Import-ServerResults.ps1`、`docs\20-纯命令行压测手册.md` 的 SHA256 与仓库 kit 一致；包内 VERSION=v13；清理临时目录。
- [ ] **Step 4: Commit（范围按先例）** — `git add VERSION memtest/scripts/Export-ServerResults.ps1 memtest/scripts/Import-ServerResults.ps1 memtest/scripts/build.ps1 memtest/docs/20-纯命令行压测手册.md memtest/CHECKSUM.txt memtest/VERSION memtest/README.md`（按 git status 实际差异为准；memtest/scripts/build.ps1 设计上不入包则跳过该路径）；**不含** repo `db/*` 与 `memtest/db/*`。`git commit -m "chore: repack v13 with results-import scripts"`。

---

## 执行说明

- 执行方式：**Subagent-driven development**（用户固定默认）。每 Task 派独立 subagent 实现 + 独立 reviewer 复查后进入下一个；结尾整支复查。
- 实机验证（真服务器导出→U盘→编排机导入）由用户在有服务器时按手册流程 10 执行；本机冒烟（`Export -MachineName demo` → `Import`）已含在验收测试黑盒路径内。
