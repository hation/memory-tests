# 一键化改造：内置 Python + BMC 命令双格式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让离线包内置便携 Python（db 历史库一条命令可用）+ 文档命令"双格式"（原格式占位符 + 本机版 10.0.0.10/root 复制即用）+ 脚本缺密码时交互提示，实现"直接复制就能跑"。

**Architecture:** Python 以 kit 内 `tools\python\`（gitignored）提供，`lib_common` 新增 `Get-PythonExe` 统一解析；db 5 个 .py 各加一个 PowerShell 封装；BMC 参数不做配置读取，改在文档给"原格式+本机版"两行，脚本在 `-BmcPass` 为空时用 `Read-BmcPass` 交互提示一次（调度器为调度级单次提示）。

**Tech Stack:** PowerShell 5.1（UTF-8 BOM）、便携 Python 3.12（复用 disk-tests 内置版）、ipmitool（既有）、.NET ZipArchive（build）。

**Spec:** `docs/superpowers/specs/2026-10-22-一键化配置与内置Python-design.md`（本计划从该规格论证；执行者需同时读两者）。

## Global Constraints

- PowerShell 5.1；中文内容脚本文件一律 UTF-8 BOM（写回用 `[System.IO.File]::WriteAllText(..., utf8Bom)`，避免 PS5 按 GBK 误读）。
- 包根 = `Split-Path -Parent $PSScriptRoot`（scripts 上一级）。
- VERSION 单一来源；输出目录 `results\`；build `-Bump/-Zip` + CHECKSUM 前置校验。
- python 二进制**禁止**进 git：`.gitignore` 加 `memtest/tools/python/`。
- 不做任何配置文件读取（无 bmc.csv、无 env var 方案）。
- 显式传 `-BmcPass` 时一律不提示（向后兼容）。

## Review Focus

1. **非 SOL 路径不得误弹密码提示**：Serial/USB/EFI/`-ParseOnly` 在 `-BmcPass` 为空时必须照常运行（Task 4 门控断言）。
2. **批量无人值守不卡死**：`Run-BatchScheduler` 清单含空 `BmcPass` 行时只提示一次并注入全部空行（Task 4 验证）。
3. **密码不落终端/日志**：交互输入的密码在 `-DryRun` 展示、汇总文本中一律 `***`（Task 4 验证）。
4. **git 不含 python 二进制**：构建后 `git check-ignore memtest/tools/python/python.exe` 必须命中（Task 6 验证）。
5. **文档命令可复制性**：所有含 `<BMC_IP>` 的命令旁必须有"本机版"（Task 7/8 grep 验证）。

---

### Task 1: lib_common 新增 `Get-PythonExe` / `Read-BmcPass` / `Invoke-IpmiProbe`

**Files:**
- Modify: `scripts/lib_common.ps1`（末尾追加 3 个函数）
- Test: `tests/test-lib.ps1`（追加断言段）

**Interfaces:**
- Produces:
  - `Get-PythonExe() -> [string|null]`：先 `<包根>\tools\python\python.exe`，再 PATH `python`，都没有返回 `$null`。
  - `Read-BmcPass([string]$Pass="", [string]$Prompt="BMC 密码") -> [string]`：`$Pass` 非空直接返回；为空则 `Read-Host $Prompt -AsSecureString` 并转明文（用 `SecureStringToBSTR`/`PtrToStringUni`/`ZeroFreeBSTR`）。
  - `Invoke-IpmiProbe([string]$IpmiTool, [string[]]$IpmiArgs) -> @{Out:string[]; Err:string[]; Code:int}`：`& $IpmiTool @IpmiArgs 2>&1`，stdout 行取字符串、stderr 行取 ErrorRecord 文本、`Code=$LASTEXITCODE`。

- [ ] **Step 1: 在 `tests/test-lib.ps1` 末尾追加失败测试**

```powershell
# --- 新增：Get-PythonExe / Read-BmcPass / Invoke-IpmiProbe ---
$py = Get-PythonExe
Assert (($null -eq $py) -or ($py -is [string])) "Get-PythonExe returns path or null"
$r1 = "testpass" | Read-BmcPass -Pass "" -Prompt "BMC 密码"
Assert ($r1 -eq "testpass") "Read-BmcPass reads piped input"
$r2 = Read-BmcPass -Pass "given" -Prompt "x"
Assert ($r2 -eq "given") "Read-BmcPass returns given pass without prompting"
$fake = Join-Path $env:TEMP ("fake-ipmitool-" + [guid]::NewGuid().ToString("N") + ".cmd")
@("echo probe-out", "exit /b 0") | Set-Content -LiteralPath $fake -Encoding ASCII
$p = Invoke-IpmiProbe -IpmiTool $fake -IpmiArgs @("mc", "info")
Assert ($p.Out -contains "probe-out") "Invoke-IpmiProbe captures stdout"
Assert ($p.Code -eq 0) "Invoke-IpmiProbe captures exit code"
Remove-Item $fake -Force
```

- [ ] **Step 2: 运行测试确认失败**

Run: `powershell -NoProfile -File tests\test-lib.ps1`
Expected: 报错 `ASSERT FAIL` 或 `Get-PythonExe 不是可识别的...`（函数不存在）

- [ ] **Step 3: 实现 3 个函数（追加到 `scripts/lib_common.ps1` 末尾，文件本身已是 BOM，用 SearchReplace 只加函数块）**

签名与行为见 Interfaces；`Get-PythonExe` 用 `Get-Command python -ErrorAction SilentlyContinue` 取 PATH 命中；`Read-BmcPass` 用 System.Runtime.InteropServices.Marshal 解 SecureString。

- [ ] **Step 4: 运行测试确认通过**

Run: `powershell -NoProfile -File tests\test-lib.ps1`
Expected: 末尾 `test-lib: ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-lib.ps1
git commit -m "feat: lib_common add Get-PythonExe/Read-BmcPass/Invoke-IpmiProbe"
```

---

### Task 2: db PowerShell 封装 ×4 + `check_env` 第 [6] 项

**Files:**
- Create: `db/Db-Import.ps1`、`db/Db-Query.ps1`、`db/Db-Export.ps1`、`db/Db-Merge.ps1`
- Modify: `scripts/check_env.ps1:73-81`（第 [6] 项）

**Interfaces:**
- Consumes: `Get-PythonExe`（Task 1）
- Produces: `db\Db-Query.ps1 -Help` 等 4 个封装，各自透传 `--db/--serial/...` 到同名 .py。

- [ ] **Step 1: 创建 4 个封装（同一模板，改脚本名与用法行）**

`db\Db-Query.ps1` 模板（其余 3 个同构）：

```powershell
# db/Db-Query.ps1 — SQLite 历史库查询封装（自动用包内 python）
# 用法: .\Db-Query.ps1 [--db history.db] [--serial <SN>] [--batch <name>] [--trend]
param(
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)
if ($Help) {
    Write-Host "用法: .\Db-Query.ps1 [--db history.db] [--serial <SN>] [--batch <name>] [--trend]"
    exit 0
}
. (Join-Path $PSScriptRoot "..\scripts\lib_common.ps1")
$py = Get-PythonExe
if (-not $py) { Write-Error "未找到 python（包内 tools\python 或系统 PATH），历史库功能不可用"; exit 1 }
& $py (Join-Path $PSScriptRoot "db_query.py") @Args
exit $LASTEXITCODE
```

（`Db-Import.ps1`→`db_import.py`、`Db-Export.ps1`→`db_export.py`、`Db-Merge.ps1`→`db_merge.py`，用法行分别对应各 .py 头注释。）

- [ ] **Step 2: 冒烟验证封装**

Run: `powershell -NoProfile -File db\Db-Query.ps1 -Help`
Expected: 打印用法行、退出码 0（-Help 在 python 检查前返回，无 python 也通过）

- [ ] **Step 3: 改 `check_env.ps1` 第 [6] 项用 `Get-PythonExe`**

```powershell
if (Test-Path $dbPy) {
    $py = Get-PythonExe
    if ($py) {
        $ver = & $py --version 2>&1 | Select-Object -First 1
        $src = if ($py -like "*tools\python*") { "内置 tools\python" } else { "系统 PATH" }
        Write-Host "[6] SQLite 历史库（可选）: db 存在，Python $ver（$src）"
    } else {
        Write-Host "[6] SQLite 历史库（可选）: db 存在，Python 3 未装（该功能跳过）"
        $warn++
    }
} else {
    Write-Host "[6] SQLite 历史库（可选）: 未随包"
}
```

- [ ] **Step 4: 验证**

Run: `powershell -NoProfile -File scripts\check_env.ps1`
Expected: 第 [6] 项显示 python 状态（内置可用 / 未装跳过），脚本仍以退出码 0 或仅警告结束；全部脚本 `Parser::ParseFile` 通过（复用 `tmp\parse-check.ps1` 脚本并加入 `db\Db-*.ps1`）。

- [ ] **Step 5: Commit**

```bash
git add db/Db-Import.ps1 db/Db-Query.ps1 db/Db-Export.ps1 db/Db-Merge.ps1 scripts/check_env.ps1
git commit -m "feat: db PowerShell wrappers (bundled python) + check_env [6] uses Get-PythonExe"
```

---

### Task 3: `Diag-Bmc.ps1` 新增 + `check_env` 第 [2] 项纳入

**Files:**
- Create: `scripts/Diag-Bmc.ps1`
- Modify: `scripts/check_env.ps1:26`（$scripts 清单加 `Diag-Bmc.ps1`）

**Interfaces:**
- Consumes: `Invoke-IpmiProbe`、`Read-BmcPass`（Task 1）
- Produces: `scripts\Diag-Bmc.ps1` 参数 `-BmcHost -BmcUser -BmcPass -IpmiTool -Help`；内置 ipmitool 自动发现（同 Check-ServerCapabilities：`<包根>\tools\ipmitool\ipmitool.exe`）。

- [ ] **Step 1: 创建 `scripts/Diag-Bmc.ps1`**

结构（仿 Check-ServerCapabilities 带外段 + 密码提示 + 四步诊断）：
- 参数 + `-Help` 用法行；`$BmcHost` 空 → `Write-Error` 退出 1。
- `$BmcPass` 空 → `Read-BmcPass -Prompt "BMC 密码（$BmcHost）"`。
- 诊断函数本地化（复用 `Invoke-IpmiProbe`）：`Test-Step` 输出 `[PASS/FAIL] 步骤名`，失败记录该步 stderr。
- 步骤：① `mc info`（默认套件）→ FAIL 自动 `-C 3` → 再 FAIL `-C 17`，记下生效套件供后续复用；② `chassis status`；③ `sdr elist`（含 `degrees C` 计数）；④ `sol activate` 短探测（~6s，Start-Process 重定向输出，同 Check-ServerCapabilities 现有写法）。
- 末尾汇总：每步 PASS/FAIL 表 + 三大原因提示（对应 docs/15 §2.3：加密套件 / 网络路径 / 账号密码）。
- 中文内容文件写回必须 BOM（Write 工具写完若报 PS5 解析错，用 `[System.IO.File]::WriteAllText(..., utf8Bom)` 补 BOM）。

- [ ] **Step 2: 冒烟验证（无真实 BMC）**

Run: `powershell -NoProfile -File scripts\Diag-Bmc.ps1 -BmcHost ""`
Expected: 报错 `-BmcHost 必填`，退出码 1。

Run: `"pw" | powershell -NoProfile -File scripts\Diag-Bmc.ps1 -BmcHost 127.0.0.1 -BmcUser root -IpmiTool <不存在路径>`
Expected: 提示输入密码后，四步诊断均 FAIL（给出真实报错如 ipmitool 不存在），脚本以非 0 退出且不抛未捕获异常。

- [ ] **Step 3: `check_env.ps1` 第 [2] 项清单加 `Diag-Bmc.ps1`**

`$scripts` 数组末尾追加 `'Diag-Bmc.ps1'`（count 自动变 7）。

- [ ] **Step 4: 全量 parse 检查**

Run: `powershell -NoProfile -File tmp\parse-check.ps1`（内容含 Diag-Bmc.ps1）
Expected: 全部 `PARSE-OK`。

- [ ] **Step 5: Commit**

```bash
git add scripts/Diag-Bmc.ps1 scripts/check_env.ps1
git commit -m "feat: Diag-Bmc one-click BMC diagnostics + check_env [2] includes it"
```

---

### Task 4: 密码空时交互提示接入 4 个脚本

**Files:**
- Modify: `scripts/Check-ServerCapabilities.ps1:87-93`、`scripts/Run-ServerAssessment.ps1:55-66`、`scripts/Run-MemtestSuite.ps1`（初始化段，约 L120 后）、`scripts/Run-BatchScheduler.ps1:64-65`（读取批次后）

**Interfaces:**
- Consumes: `Read-BmcPass`（Task 1）
- 关键门控（Review Focus 1/2/3）：
  - `Check-ServerCapabilities.ps1`：`if ($BmcHost -ne "" -and -not $BmcPass) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }`（置于 `$a` 拼装之前）。
  - `Run-ServerAssessment.ps1`：`if ($BmcHost -and -not $BmcPass) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }`（置于 `& $CapScript @capArgs` 之前）。
  - `Run-MemtestSuite.ps1`：仅当 `$BootMethod -eq 'SOL' -and $BmcHost -and -not $BmcPass -and -not $ParseOnly` 时提示一次（初始化段、任何 BMC 调用前）。
  - `Run-BatchScheduler.ps1`：读批次后，`$need = @($batches | Where-Object { $_.BmcHost -and -not $_.BmcPass })`；`$need.Count -gt 0` 时 `$pw = Read-BmcPass -Prompt "BMC 密码（$($need[0].BmcHost) 等 $($need.Count) 行）"` 并 `foreach ($r in $need) { $r.BmcPass = $pw }`。

- [ ] **Step 1: 改 4 个脚本（见 Interfaces，各 1-3 行）**

- [ ] **Step 2: fake-ipmitool 冒烟验证（Check-ServerCapabilities）**

创建 `tmp\fake-ipmitool.cmd`：`@echo off` + `echo fake-ok` + `exit /b 0`。

Run: `"pw" | powershell -NoProfile -File scripts\Check-ServerCapabilities.ps1 -BmcHost 1.2.3.4 -BmcUser u -IpmiTool tmp\fake-ipmitool.cmd`
Expected: 输出 BMC 行显示 `1.2.3.4`，无"密码为空"类报错；`pw` 未出现在输出中（脱敏，Review Focus 3）。

- [ ] **Step 3: 门控回归验证（Run-MemtestSuite 非 SOL 不提示）**

Run: `powershell -NoProfile -File scripts\Run-MemtestSuite.ps1 -BootMethod Serial -BatchName t -SerialPort COM1 -MaxPasses 1 -Help`（-Help 提前退出即可）→ 先做纯 parse。
Run: `powershell -NoProfile -Command "& scripts\Run-MemtestSuite.ps1 -BootMethod USB -BatchName t -UsbDrive X: -MaxPasses 1"`（USB 无 BmcPass 且无 BmcHost）
Expected: 无密码提示，脚本按 USB 流程走到缺介质报错或提示，绝不出现 `Read-Host` 弹窗（Review Focus 1）。

- [ ] **Step 4: Run-BatchScheduler 单次提示验证**

Run: `powershell -NoProfile -File scripts\Run-BatchScheduler.ps1 -ManifestCsv tests\fixtures\sample-batches.csv -DryRun`
Expected: 若 fixture 含空 BmcPass 行，仅出现一次密码提示（DryRun 也提示一次再继续预览），且每行命令展示为 `-BmcPass ***`（Review Focus 2/3）。

- [ ] **Step 5: 全量 parse 检查**

Run: `powershell -NoProfile -File tmp\parse-check.ps1`
Expected: 全部 `PARSE-OK`。

- [ ] **Step 6: Commit**

```bash
git add scripts/Check-ServerCapabilities.ps1 scripts/Run-ServerAssessment.ps1 scripts/Run-MemtestSuite.ps1 scripts/Run-BatchScheduler.ps1
git commit -m "feat: prompt BMC password once when -BmcPass empty (gated per mode)"
```

---

### Task 5: build.ps1 更新（python 补拷 + 校验 + Diag 纳入）

**Files:**
- Modify: `scripts/build.ps1`（param、tools 同步段、$scriptFiles、CHECKSUM 段）

- [ ] **Step 1: param 加 `-PythonSrc` + `$scriptFiles` 加 `Diag-Bmc.ps1`**

```powershell
param(
    [string]$KitDir = '',
    [switch]$Bump,
    [switch]$Zip,
    [string]$PythonSrc = ''   # 可选：python 源目录（默认探测 disk-tests\deploy\bin\python）
)
```
`$scriptFiles` 数组末尾加 `'Diag-Bmc.ps1'`。

- [ ] **Step 2: tools 同步循环后追加 python 补拷段**

```powershell
# 内置 python：kit 缺失时从源补拷（源默认 disk-tests 便携版，gitignored 不入库）
$kitPy = Join-Path $KitDir 'tools\python\python.exe'
if (-not (Test-Path -LiteralPath $kitPy)) {
    $src = $PythonSrc
    if (-not $src) {
        $defSrc = Join-Path $Repo '..\disk-tests\deploy\bin\python'
        if (Test-Path -LiteralPath $defSrc) { $src = (Resolve-Path -LiteralPath $defSrc).Path }
    }
    if ($src -and (Test-Path -LiteralPath (Join-Path $src 'python.exe'))) {
        $dst = Split-Path -Parent $kitPy
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        Write-Host "==> 内置 Python 已拷入 kit（$src）"
    } else {
        Write-Host "==> 警告：kit 未内置 Python，db 历史库将回退系统 python"
    }
}
```

- [ ] **Step 3: CHECKSUM 段追加 python 文件（若存在）**

在 db 文件块之后加：

```powershell
$kitPyDir = Join-Path $KitDir 'tools\python'
if (Test-Path -LiteralPath $kitPyDir) {
    Get-ChildItem -LiteralPath $kitPyDir -File | ForEach-Object { $keyFiles += $_.FullName }
}
```

- [ ] **Step 4: 幂等构建验证**

Run: `powershell -NoProfile -File scripts\build.ps1`（两次，不带 -Bump/-Zip）
Expected: 两次 `CHECKSUM.txt` 逐字节一致（`fc.exe /b` 或 Compare-Object 输出为空）；日志出现"内置 Python 已拷入 kit"或警告。

- [ ] **Step 5: Commit**

```bash
git add scripts/build.ps1
git commit -m "build: PythonSrc fallback copy + include Diag-Bmc in scriptFiles + checksum python files"
```

---

### Task 6: python 拷入 kit + .gitignore + git 隔离验证

**Files:**
- Create: `memtest/tools/python/`（拷贝 disk-tests 便携 python，21.5MB/35 文件，gitignored）
- Modify: `.gitignore`（加 `memtest/tools/python/`）

- [ ] **Step 1: 拷贝 python 进 kit**

Run: `Copy-Item -Path "disk-tests\deploy\bin\python\*" -Destination "memtest\tools\python\" -Recurse -Force`（先建目录）
Expected: `memtest\tools\python\python.exe` 存在，`& memtest\tools\python\python.exe --version` 输出 `Python 3.12.x`。

- [ ] **Step 2: `.gitignore` 加忽略**

追加一行 `memtest/tools/python/`（注释：便携 Python，不入库）。

- [ ] **Step 3: git 隔离验证（Review Focus 4）**

Run: `git check-ignore memtest/tools/python/python.exe`
Expected: 输出该路径（已忽略）；`git status --short` 不出现 `?? memtest/tools/python/`。

- [ ] **Step 4: 功能冒烟（check_env + Db-Query 用包内 python）**

Run: `powershell -NoProfile -File scripts\check_env.ps1`
Expected: 第 [6] 项显示 `Python 3.12.x（内置 tools\python）`，无"跳过"。
Run: `powershell -NoProfile -File db\Db-Query.ps1 --db C:\不存在\x.db --serial ""`
Expected: 正常调用包内 python 执行 db_query.py（报数据库不存在等正常错误，而非"未找到 python"）。

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: bundle portable python into kit (gitignored), enable db feature offline"
```

---

### Task 7: 文档双格式 A 组（15 / 09 / 12，BMC 重灾区）

**Files:**
- Modify: `docs/15-BMC排查方案.md`、`docs/09-SOL使用指南.md`、`docs/12-离线部署与SOL测试手册.md`

- [ ] **Step 1: 每文档页首加"本机"注记**

在文档标题下方加一行：
```
> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 每条命令给两行：**原格式**（通用占位符，可换用）+ **本机版**（已填好，复制即用）。
```

- [ ] **Step 2: 15 文档 §2 诊断命令序列整段替换**

替换 §2.2 为「原格式 + 本机版」两行（Spec §4.B.4）：

```powershell
# 原格式（通用）
.\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser <用户>
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root
```
§2.3 三大原因表保留；§2.4 判断流程中"跑 ①②"改为"跑 Diag-Bmc 四步"；§4 快速验证清单第一条 `mc info` 命令同样双格式。

- [ ] **Step 3: 09 / 12 逐条命令双格式**

对 09（20 处，含整段裸 ipmitool：`sol activate / chassis power cycle / sdr elist`）与 12 中每条含 `<BMC_IP>`/`-BmcHost` 的命令，在旁补"👉 本机版"一行（`10.0.0.10`/`root`，省略 `-BmcPass`）；裸 ipmitool 段建议替换为 `.\scripts\Diag-Bmc.ps1` 两行 + 保留原 ipmitool 命令为"原格式"。

- [ ] **Step 4: grep 验收（Review Focus 5）**

Run: `Select-String -Path docs\15-BMC排查方案.md,docs\09-SOL使用指南.md,docs\12-离线部署与SOL测试手册.md -Pattern '<BMC_IP>|<密码>|<IP>'`
Expected: 每个匹配行下方紧跟 `👉 本机版` 或 `10.0.0.10`（逐条人工核对）。

- [ ] **Step 5: Commit**

```bash
git add docs/15-BMC排查方案.md docs/09-SOL使用指南.md docs/12-离线部署与SOL测试手册.md
git commit -m "docs: double-format (original + local-machine) BMC commands for 15/09/12"
```

---

### Task 8: 文档双格式 B 组（06/13/05/08/READMEs + 02/04/07 轻量）

**Files:**
- Modify: `docs/06-实践操作教程.md`、`docs/13-服务器信息识别指南.md`、`docs/05-使用手册.md`、`docs/08-报表结构说明.md`、`README.md`、`memtest/README.md`
- Modify（轻量，仅出现命令处）: `docs/02-批量压力测试方案.md`、`docs/04-运行环境与依赖安装说明.md`、`docs/07-离线部署检查清单.md`

- [ ] **Step 1: 06/13/05/08 + 两个 README 双格式**

同 Task 7 规则：页首"本机"注记 + 每条 BMC 命令补"👉 本机版"；db 命令（05 §10、08 报表）从 `python db\db_import.py ...` 改为 `.\db\Db-Import.ps1 ...`（可复制）并补双格式；05 补 Diag-Bmc 与"密码运行中提示"说明。

- [ ] **Step 2: 02/04/07 轻量处理**

仅对出现直接命令处补"👉 本机版"一行，其余不动。

- [ ] **Step 3: 全仓 grep 验收**

Run: `Select-String -Path docs\*.md,README.md,memtest\README.md -Pattern '<BMC_IP>|python db\'
Expected: 无 `<BMC_IP>` 残留（或每处旁有本机版）；无 `python db\` 残留（全部改为 `.\db\Db-*.ps1`）。

- [ ] **Step 4: Commit**

```bash
git add docs/06-实践操作教程.md docs/13-服务器信息识别指南.md docs/05-使用手册.md docs/08-报表结构说明.md README.md memtest/README.md docs/02-批量压力测试方案.md docs/04-运行环境与依赖安装说明.md docs/07-离线部署检查清单.md
git commit -m "docs: double-format commands across usage/tutorial/report docs + READMEs; db commands via wrappers"
```

---

### Task 9: 打包 v10 + 提交推送

**Files:**
- Run: `scripts/build.ps1 -Bump -Zip`（v9 → v10）

- [ ] **Step 1: 构建 v10 交付包**

Run: `powershell -NoProfile -File scripts\build.ps1 -Bump -Zip`
Expected: `版本递增 v9 -> v10`；`memtest-v10.zip` 生成；CHECKSUM 含 `tools/python/*` 与 `docs/15-BMC排查方案.md`；日志含"内置 Python 已拷入 kit"。

- [ ] **Step 2: 包内抽查**

Run: 列出 zip 内 `tools/python/python.exe`、`scripts/Diag-Bmc.ps1`、`db/Db-Query.ps1`、`docs/15-BMC排查方案.md`（`Expand-Archive` 到 tmp 或 `[System.IO.Compression.ZipFile]::OpenRead` 枚举）。
Expected: 全部存在；kit README 首行 `> 工具版本：v10`。

- [ ] **Step 3: 回归测试**

Run: `powershell -NoProfile -File tests\test-lib.ps1` + `tests\test-args.ps1`
Expected: 均 ALL PASS。

- [ ] **Step 4: 提交推送**

```bash
git add -A
git commit -m "release: pack v10 (bundled python + BMC double-format commands + Diag-Bmc)"
git push
```
推送前 `git status --short` 确认无 `memtest/tools/python/`、无 `*.zip`、无 `results/`。
