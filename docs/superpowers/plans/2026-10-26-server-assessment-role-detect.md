# 服务器能力评估 · 角色自动识别 + 断电循环真实验证 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `Run-ServerAssessment.ps1` 一条命令先按 BMC 可达性自动判定本机角色（编排机/被测服务器），只跑对应检查；编排机可加 `-VerifyPowerCycle` 真实验证断电循环；两段 cap CSV 可合并成完整 17 项报告。

**Architecture:** 在 `lib_common.ps1` 新增 `Test-BmcRole`（mc info 三套件探测 → 三态角色）；`Check-ServerCapabilities.ps1` 改为角色化入口 + 三态文案 + Role 列 + `-VerifyPowerCycle`；`Run-ServerAssessment.ps1` 透传开关并新增 `-MergeInband/-MergeOob` 合并模式；全部用 `fake-ipmitool.cmd`（新增 `FAKE_IPMI_MODE` 多模式）做 TDD 测试。

**Tech Stack:** PowerShell 5.1、ipmitool（内置 tools\ipmitool）、CIM（Win32_PhysicalMemory）、tests 现有 Assert 约定。

**Spec:** `docs/superpowers/specs/2026-10-26-server-assessment-role-detect-design.md`

## Global Constraints

- 状态文案前缀约定（设计 §3.4/§3.5）：`可测*` / `条件*` / `需*` / `外包*`，供统计与合并优先级使用，不得偏离。
- 角色判据 = 能否与 BMC 建立 IPMI 会话（`mc info` 默认→-C 3→-C 17），不是 ping/外网。
- 角色执行规则（设计 §8-4）：带内跑 ⇔ `-Local` 给出或角色=Server；带外跑 ⇔ `-BmcHost` 给出且角色∈{Orchestrator,AuthError}。
- Role 列取值 = `编排机`（角色∈{Orchestrator,AuthError}）或 `被测服务器`（角色=Server），与是否额外跑带内无关。
- 真实验证基线 off 时**不发** `chassis power cycle`（设计 §8-3）。
- `-VerifyPowerCycle` 本身即授权，脚本内不再二次确认。
- 合并优先级：`已验证/可测* (3) > 外包/条件* (2) > 需* (1) > 其它 (0)`；同级取非空再取 A（A=服务器 CSV）。
- 合并 Role 校验：不符仅警告不失败；无 Role 列旧版 CSV 接受。
- 只改仓库根 `scripts/`、`docs/` 顶层、`tests/`；`memtest/` 镜像由任务 8 的 `build.ps1 -Zip` 同步后一并提交。
- 打包纪律：全部任务完成后必须 `scripts\build.ps1 -Zip` 并校验 zip 时间戳与包内 hash（AGENTS.md）。

## Review Focus

1. **不带 `-BmcHost` 运行**：不得弹密码提示、不得挂起，直接判被测服务器角色并跑带内。（Task 3 测试）
2. **`-VerifyPowerCycle` 但角色=Server（BMC 不可达）**：不得真发命令、不得挂起，第 10 项仍为"需编排机"文案。（Task 4 测试）
3. **合并输入传反**（Inband 实为编排机 CSV）：输出警告但合并结果仍正确，不静默出错。（Task 5 测试）
4. **`-Local -BmcHost` 双通道**：Role 列=编排机且带内也执行（带内项非"需带内"）。（Task 3 测试）
5. **旧版无 Role 列 CSV 合并**：照常合并，不报错。（Task 5 测试）

---

### Task 1: fake-ipmitool.cmd 多模式模拟夹具

**Files:**
- Modify: `tests/fixtures/fake-ipmitool.cmd`

**Interfaces:**
- Consumes: 现有 test-gating 用法（默认输出 "fake-out"、exit 0）
- Produces: 环境变量 `FAKE_IPMI_MODE`（值 `ok`/`unreachable`/`auth`/`verify-transition`/`verify-flat`/`verify-off`），按 `%*` 子命令分支输出；供 Task 2-6 复用

- [ ] **Step 1: 重写 fake-ipmitool.cmd 支持按子命令 + 模式分支**

模式语义（`FAKE_IPMI_MODE` 缺省 = `ok`）：

| 子命令（按 %* 匹配，先精确后模糊） | ok | unreachable | auth | verify-transition | verify-flat | verify-off |
|---|---|---|---|---|---|---|
| `mc info` | `Manufacturer: FakeCorp` + `Firmware Revision: 1.0`，exit 0 | stderr `Could not open socket!`，exit 1 | stderr `Invalid password`，exit 1 | 同 ok | 同 ok | 同 ok |
| `chassis status` | `Chassis Power is on`，exit 0 | stderr 同上 | stderr 同上 | 同 ok | 同 ok | 同 ok |
| `chassis power cycle` | `Chassis Power Control: Cycle`，exit 0 | 同上 | 同上 | 同 ok | 同 ok | 同 ok |
| `chassis power status` | `Chassis Power is on` | 同上 | 同上 | 计数：第 1 次 `on`、第 2 次 `off`、≥3 次 `on` | `Chassis Power is on` | `Chassis Power is off` |
| `sdr elist` | `Inlet Temp \| 01h \| ok \| 26.0 \| degrees C`，exit 0 | 同上 | 同上 | 同 ok | 同 ok | 同 ok |
| `sol activate` | `SOL: connected`，exit 0 | 同上 | 同上 | 同 ok | 同 ok | 同 ok |
| `sol deactivate` | 无输出，exit 0 | exit 1 | exit 1 | 同 ok | 同 ok | 同 ok |

要点：错误行写 stderr（`echo ... 1>&2`）；`verify-transition` 用计数器文件 `%TEMP%\fake_ipmi_pwrcount` 记录 `chassis power status` 调用次数（每次 `set /p c=<...` 自增后写回）；stderr/exit 由 `Invoke-IpmiProbe` 的 Err/Code 语义消费。

- [ ] **Step 2: 逐模式冒烟验证**

Run（PowerShell）：
```powershell
$env:FAKE_IPMI_MODE='ok'; & tests\fixtures\fake-ipmitool.cmd -I lanplus -H 1.2.3.4 mc info
$env:FAKE_IPMI_MODE='unreachable'; & tests\fixtures\fake-ipmitool.cmd mc info; echo "exit=$LASTEXITCODE"
$env:FAKE_IPMI_MODE='auth'; & tests\fixtures\fake-ipmitool.cmd mc info; echo "exit=$LASTEXITCODE"
$env:FAKE_IPMI_MODE='verify-transition'; Remove-Item $env:TEMP\fake_ipmi_pwrcount -ErrorAction SilentlyContinue; & tests\fixtures\fake-ipmitool.cmd chassis power status; & tests\fixtures\fake-ipmitool.cmd chassis power status; & tests\fixtures\fake-ipmitool.cmd chassis power status
```
Expected: ok 模式 mc info 输出含 `Manufacturer: FakeCorp`；unreachable 输出 stderr `Could not open socket!` 且 exit 1；auth 输出 `Invalid password` exit 1；verify-transition 三次 status 依次输出 `on`/`off`/`on`。

- [ ] **Step 3: Commit**

```bash
git add tests/fixtures/fake-ipmitool.cmd
git commit -m "test: fake-ipmitool 支持 FAKE_IPMI_MODE 多模式（ok/unreachable/auth/verify-*）"
```

---

### Task 2: lib_common.ps1 新增 Test-BmcRole

**Files:**
- Modify: `scripts/lib_common.ps1`
- Create: `tests/test-assessment-role.ps1`（本任务先放角色判定用例）

**Interfaces:**
- Consumes: `Invoke-IpmiProbe`（lib_common 已有）、Task 1 fake 夹具
- Produces:
```powershell
function Test-BmcRole {
    param([string]$IpmiTool, [string[]]$IpmiArgsBase)
    # 返回 [PSCustomObject]@{ Role; Detail; CipherArgs; BmcVendor }
    # Role: 'Orchestrator'|'Server'|'AuthError'
    # Detail: Orchestrator="" / Server="BMC 不可达: <err>" / AuthError="BMC 可达但凭据/权限失败: <err>"
    # CipherArgs: 生效的完整参数（含 -C N 回退），供后续 OOB 复用
    # BmcVendor: mc info 的 Manufacturer 解析值
}
```

- [ ] **Step 1: 写失败测试（tests/test-assessment-role.ps1）**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$fake = Join-Path $PSScriptRoot "fixtures\fake-ipmitool.cmd"
$base = @('-I', 'lanplus', '-H', '1.2.3.4', '-U', 'u', '-P', 'pw')

$env:FAKE_IPMI_MODE = 'ok'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'Orchestrator') "ok → Orchestrator"
Assert ($r.BmcVendor -eq 'FakeCorp') "ok → BmcVendor=FakeCorp"
Assert ($r.CipherArgs.Count -ge $base.Count) "ok → CipherArgs 含基础参数"

$env:FAKE_IPMI_MODE = 'unreachable'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'Server') "unreachable → Server"
Assert ($r.Detail -match '^BMC 不可达') "unreachable → Detail 前缀"

$env:FAKE_IPMI_MODE = 'auth'
$r = Test-BmcRole -IpmiTool $fake -IpmiArgsBase $base
Assert ($r.Role -eq 'AuthError') "auth → AuthError"
Assert ($r.Detail -match '^BMC 可达但凭据/权限失败') "auth → Detail 前缀"
Write-Host "  [role] Test-BmcRole 三态 OK"
```

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`
Expected: FAIL（Test-BmcRole 未定义）。

- [ ] **Step 3: 在 scripts/lib_common.ps1 实现 Test-BmcRole**

分类正则（设计 §3.1）：
```powershell
$connRe = 'Could not open socket|Unable to connect|Connection refused|Network is unreachable|No route|Timed out|timeout'
$authRe = 'Invalid password|Unauthorized|Authentication type|not supported|Unable to establish|Insufficient privilege|RAKP'
```
算法：依次 `mc info`（base → base+-C 3 → base+-C 17），首个 `Code -eq 0` 且 `Out.Count -gt 0` 即 Orchestrator（记生效参数为 CipherArgs、解析 Manufacturer 为 BmcVendor）；全部失败则把 Err 文本合并，先匹配 `$connRe` → Server，再匹配 `$authRe` → AuthError，都不中 → Server（Detail 用原始错误）。错误行拼接用 `' | '`。

- [ ] **Step 4: 运行确认通过**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`
Expected: PASS（三态断言全过）。另跑 `powershell -NoProfile -File tests\test-lib.ps1` 确认无回归。

- [ ] **Step 5: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-assessment-role.ps1
git commit -m "feat: lib_common 新增 Test-BmcRole（三态角色判定）"
```

---

### Task 3: Check-ServerCapabilities.ps1 角色化入口 + 三态文案 + Role 列

**Files:**
- Modify: `scripts/Check-ServerCapabilities.ps1`（整体重写主流程 + 头注释）
- Modify: `tests/test-assessment-role.ps1`（追加角色化端到端用例）

**Interfaces:**
- Consumes: Task 2 `Test-BmcRole`；Task 1 fake 夹具
- Produces:
  - 新增行为：`-BmcHost` 给定时先角色判定再执行对应探测块；未给 `-BmcHost` 时按被测服务器跑带内
  - 控制台首行 `角色: 编排机(BMC <ip> 可达)` / `角色: 被测服务器(BMC 不可达: <原因>)` / `角色: 被测服务器(未提供 -BmcHost)` / `角色: 编排机(BMC <ip> 可达，凭据/权限失败)`
  - cap CSV 增加 `Role` 列（`编排机`/`被测服务器`，见 Global Constraints）
  - 第 5/10 项三态文案（见 Step 3 状态表）

- [ ] **Step 1: 写失败测试（追加到 tests/test-assessment-role.ps1）**

```powershell
$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$caps = Join-Path $PSScriptRoot "..\scripts\Check-ServerCapabilities.ps1"
function Run-Caps([string]$mode, [string[]]$extra) {
    $env:FAKE_IPMI_MODE = $mode
    $csv = Join-Path $env:TEMP ("cap-" + [guid]::NewGuid().ToString("N") + ".csv")
    $out = "pw" | & $ps -NoProfile -File $caps -BmcHost 1.2.3.4 -BmcUser u -IpmiTool $fake @extra -OutCsv $csv 2>&1 | Out-String
    return @{ Out = $out; Csv = $csv }
}
function Get-CapStatus($csv, [int]$item) {
    (Import-Csv -LiteralPath $csv | Where-Object { [int]$_.Item -eq $item }).Status
}

# 编排机：ok
$t = Run-Caps 'ok' @()
Assert ($t.Out -match '角色: 编排机') "ok → 角色行=编排机"
Assert ((Import-Csv $t.Csv)[0].Role -eq '编排机') "ok → cap CSV Role=编排机"
Assert ((Get-CapStatus $t.Csv 10) -match '^可测') "ok → 第10项可测"

# 被测服务器：unreachable（自动跑带内）
$t = Run-Caps 'unreachable' @()
Assert ($t.Out -match '角色: 被测服务器') "unreachable → 角色行=被测服务器"
Assert ((Import-Csv $t.Csv)[0].Role -eq '被测服务器') "unreachable → cap CSV Role=被测服务器"
Assert ((Get-CapStatus $t.Csv 10) -match '^需编排机') "unreachable → 第10项需编排机"
Assert ((Get-CapStatus $t.Csv 1) -match '^可测') "unreachable → 自动跑带内(第1项可测)"

# 凭据失败：auth（不跑带内，如实报告）
$t = Run-Caps 'auth' @()
Assert ($t.Out -match '凭据/权限失败') "auth → 输出含凭据失败"
Assert ((Get-CapStatus $t.Csv 10) -match '^条件: BMC 可达但凭据/权限失败') "auth → 第10项条件文案"
Assert ((Get-CapStatus $t.Csv 1) -match '^需带内') "auth → 不跑带内(第1项需带内)"

# 不带 -BmcHost：不得弹密码、判被测服务器
$env:FAKE_IPMI_MODE = 'ok'
$csv2 = Join-Path $env:TEMP ("cap2-" + [guid]::NewGuid().ToString("N") + ".csv")
$o2 = & $ps -NoProfile -File $caps -OutCsv $csv2 2>&1 | Out-String
Assert ($o2 -notmatch 'BMC 密码') "无 -BmcHost 不弹密码提示"
Assert ($o2 -match '角色: 被测服务器') "无 -BmcHost → 被测服务器角色"
Assert ((Import-Csv $csv2)[0].Role -eq '被测服务器') "无 -BmcHost → Role=被测服务器"

# 双通道 -Local -BmcHost（ok）：Role=编排机 且 带内也执行
$t = Run-Caps 'ok' @('-Local')
Assert ((Import-Csv $t.Csv)[0].Role -eq '编排机') "-Local -BmcHost → Role=编排机"
Assert ((Get-CapStatus $t.Csv 1) -match '^可测') "-Local -BmcHost → 带内也执行(第1项可测)"
Remove-Item $t.Csv, $csv2 -Force -ErrorAction SilentlyContinue
```

（清理各临时 CSV 于用例结尾；密码管道沿用 test-gating 用例 3 约定。）

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`
Expected: 本任务新增用例 FAIL。

- [ ] **Step 3: 重写 scripts/Check-ServerCapabilities.ps1 主流程**

结构（builder 可自行组织内部变量）：
1. 顶部 `. lib_common.ps1`、管道消费 `$input` → `BmcPass`（沿用现有）。
2. `-BmcHost` 为空 → `$role='Server'`，Detail=“未提供 -BmcHost”；否则缺密码先 `Read-BmcPass`，构建 base 参数调 `Test-BmcRole`。
3. 按 Global Constraints 执行规则决定带内/带外探测块：
   - 带内跑（`-Local` 或 role=Server）：现有 CIM 块原样执行。
   - 带外跑（`-BmcHost` 且 role∈{Orchestrator,AuthError}）：现有 chassis status / sdr elist / sol 探测用 `CipherArgs` 执行。
   - AuthError：不逐个探测，第 5/10 项直接置 `条件: BMC 可达但凭据/权限失败(<Detail>)`，SOL/断电/测温均记不可用。
   - role=Server：第 5/10 项置 `需编排机(<Detail>)`。
4. 第 5/10 项状态表（其余 15 项状态文案保持现状）：

| 项 | 条件 | Status |
|---|---|---|
| 5 ORT | role=Server | `需编排机(<Detail>)` |
| 5 ORT | AuthError | `条件: BMC 可达但凭据/权限失败(<Detail>)` |
| 5 ORT | 可断电且测温 | `可测(需满载72h)` |
| 5 ORT | 可断电无测温 | `条件：需测温传感器` |
| 5 ORT | 断电命令不可用 | `条件: BMC 通但断电循环命令不可用(<err>)` |
| 10 | role=Server | `需编排机(<Detail>)` |
| 10 | AuthError | `条件: BMC 可达但凭据/权限失败(<Detail>)` |
| 10 | 命令可用（未置 -VerifyPowerCycle） | `可测(IPMI 断电循环)` |
| 10 | 命令失败 | `条件: BMC 通但断电循环命令不可用(<err>)` |
| 10 | `-VerifyPowerCycle` 结果 | Task 4 接管 |

5. 输出：首行角色行 + `BMC: SOL=.. · 断电循环=.. · 测温=..`（沿用）+ 17 项表；$items 各对象加 `Role` 属性再 Export-Csv。
6. 头注释用法更新：`-BmcHost` 自动分角色；`-Local` 显式带内；`-VerifyPowerCycle` 说明。

- [ ] **Step 4: 运行确认通过 + 回归**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`；`powershell -NoProfile -File tests\test-gating.ps1`
Expected: 全部 PASS（test-gating 用例 3 在 fake 默认 ok 下应仍过；若断言因新行为失败，在 Task 6 处理，此处先记录）。

- [ ] **Step 5: Commit**

```bash
git add scripts/Check-ServerCapabilities.ps1 tests/test-assessment-role.ps1
git commit -m "feat: Check-ServerCapabilities 角色化入口 + 三态文案 + Role 列"
```

---

### Task 4: Check-ServerCapabilities.ps1 新增 -VerifyPowerCycle 真实验证

**Files:**
- Modify: `scripts/Check-ServerCapabilities.ps1`
- Modify: `tests/test-assessment-role.ps1`（追加验证用例）

**Interfaces:**
- Consumes: Task 3 角色化入口、Task 1 fake（verify-* 模式）
- Produces:
  - 新增 `[switch]$VerifyPowerCycle` 参数
  - 第 10 项新增状态：`可测(已验证：实测断电重启成功)` / `可测(命令已接受，未观察到掉电跳变，断电窗口极短，建议人工确认一次)` / `条件: 服务器当前关机，无法验证断电循环（请先开机）`

- [ ] **Step 1: 写失败测试（追加到 tests/test-assessment-role.ps1）**

```powershell
# transition → 已验证
$t = Run-Caps 'verify-transition' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '可测\(已验证') "transition → 已验证断电重启"

# flat → 未观察跳变
$t = Run-Caps 'verify-flat' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '未观察到掉电跳变') "flat → 未观察跳变文案"

# off → 关机中止（不发 power cycle）
$t = Run-Caps 'verify-off' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '服务器当前关机') "off → 关机中止文案"

# unreachable + -VerifyPowerCycle → 仍需编排机，不挂起
$t = Run-Caps 'unreachable' @('-VerifyPowerCycle')
Assert ((Get-CapStatus $t.Csv 10) -match '^需编排机') "unreachable+Verify → 第10项需编排机"
```

（`Run-Caps`/`Get-CapStatus` 复用 Task 3 定义；transition 用例前先 `Remove-Item $env:TEMP\fake_ipmi_pwrcount -ErrorAction SilentlyContinue`。）

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`
Expected: 验证用例 FAIL。

- [ ] **Step 3: 实现验证逻辑（scripts/Check-ServerCapabilities.ps1）**

仅 role=Orchestrator 且 `-VerifyPowerCycle` 置位时执行；AuthError/Server 跳过。序列（设计 §3.2）：
```
baseline = chassis power status
若 baseline 非 on → 第10项='条件: 服务器当前关机，无法验证断电循环（请先开机）'，不发 cycle，结束
r = chassis power cycle；Code≠0 或输出不含 'Cycle' → 第10项='条件: BMC 通但断电循环命令不可用(<err>)'，结束
轮询 chassis power status，每 1s，窗口 30s：任一次含 'off' 记 observedOff；出现 off 后再见 on 即跳变完成，提前结束
收尾 chassis power status：BMC 仍响应且 on
observedOff → '可测(已验证：实测断电重启成功)'；否则 → '可测(命令已接受，未观察到掉电跳变，断电窗口极短，建议人工确认一次)'
```
实现建议：验证函数内自行 `& $IpmiTool @($CipherArgs + 'chassis','power',...)` 并经 `Invoke-IpmiProbe` 包装；轮询用 `Start-Sleep -Seconds 1`。

- [ ] **Step 4: 运行确认通过 + 回归**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`；`tests\test-gating.ps1`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add scripts/Check-ServerCapabilities.ps1 tests/test-assessment-role.ps1
git commit -m "feat: Check-ServerCapabilities -VerifyPowerCycle 实测断电重启"
```

---

### Task 5: Run-ServerAssessment.ps1 透传开关 + 合并模式

**Files:**
- Modify: `scripts/Run-ServerAssessment.ps1`（参数 + 合并分支 + 头注释）
- Modify: `tests/test-assessment-role.ps1`（追加合并用例）

**Interfaces:**
- Consumes: Task 3/4 Check-ServerCapabilities（-VerifyPowerCycle、Role 列）；现有 Get-Recommendation 逻辑
- Produces:
  - 新增 `[switch]$VerifyPowerCycle`（透传给探测脚本）、`[string]$MergeInband=''`、`[string]$MergeOob=''`
  - 合并模式：`Get-StatusPriority`（见下）+ 复用现有评估/汇总/CSV+TXT 输出
  - 汇总文本追加 `角色: ...`（正常模式）与 `合并来源: 服务器 <file> + 编排机 <file>`（合并模式）

```powershell
function Get-StatusPriority([string]$s) {
    if ($s -match '^(已验证|可测)') { 3 }
    elseif ($s -match '^(外包|条件)') { 2 }
    elseif ($s -match '^需') { 1 }
    else { 0 }
}
```

- [ ] **Step 1: 写失败测试（追加到 tests/test-assessment-role.ps1）**

```powershell
$assess = Join-Path $PSScriptRoot "..\scripts\Run-ServerAssessment.ps1"
$dir = Join-Path $env:TEMP ("assess-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $dir | Out-Null
# 服务器侧 CSV（含 Role 列）
$csvA = Join-Path $dir "srv-inband.csv"
@("Item,Name,Status,Role","4,ECC 纠错功能验证,可测(ECC 平台),被测服务器","10,反复上电掉电循环,需编排机(BMC 不可达: x),被测服务器","6,电压裕量,外包(可编程电源+示波器),被测服务器") | Set-Content $csvA -Encoding UTF8
# 编排机侧 CSV（含 Role 列）
$csvB = Join-Path $dir "srv-oob.csv"
@("Item,Name,Status,Role","4,ECC 纠错功能验证,需带内(服务器本机跑),编排机","10,反复上电掉电循环,可测(IPMI 断电循环),编排机","6,电压裕量,外包(可编程电源+示波器),编排机") | Set-Content $csvB -Encoding UTF8
$outDir = Join-Path $dir "out"
$o = & $ps -NoProfile -File $assess -MergeInband $csvA -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
$merged = Import-Csv (Join-Path $outDir "srv01-assessment.csv")
Assert ((($merged | Where-Object { $_.Item -eq '10' }).Status) -match '^可测') "合并 → 第10项取编排机(可测)"
Assert ((($merged | Where-Object { $_.Item -eq '4' }).Status) -match '^可测') "合并 → 第4项取服务器(可测 ECC)"
Assert ((($merged | Where-Object { $_.Item -eq '6' }).Status) -match '^外包') "合并 → 第6项外包"

# Role 传反 → 警告但结果正确
$csvA2 = Join-Path $dir "srv-inband-roleOob.csv"
@("Item,Name,Status,Role","10,反复上电掉电循环,需编排机(BMC 不可达: x),编排机") | Set-Content $csvA2 -Encoding UTF8
$o2 = & $ps -NoProfile -File $assess -MergeInband $csvA2 -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
Assert ($o2 -match '警告：-MergeInband') "Role 不符 → 输出警告"

# 旧版无 Role 列 → 照常合并
$csvA3 = Join-Path $dir "srv-inband-legacy.csv"
@("Item,Name,Status","10,反复上电掉电循环,需编排机(BMC 不可达: x)") | Set-Content $csvA3 -Encoding UTF8
$o3 = & $ps -NoProfile -File $assess -MergeInband $csvA3 -MergeOob $csvB -MachineName srv01 -OutDir $outDir 2>&1 | Out-String
$merged3 = Import-Csv (Join-Path $outDir "srv01-assessment.csv")
Assert ((($merged3 | Where-Object { $_.Item -eq '10' }).Status) -match '^可测') "旧版无Role → 照常合并(第10项可测)"

# 只给一个合并参数 → 报错非0退出
$o4 = & $ps -NoProfile -File $assess -MergeInband $csvA -MachineName srv01 2>&1 | Out-String
Assert ($o4 -match 'MergeOob') "只给 MergeInband → 报错提示 MergeOob"
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 2: 运行确认失败**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`
Expected: 合并用例 FAIL（参数未实现）。

- [ ] **Step 3: 实现（scripts/Run-ServerAssessment.ps1）**

1. param 追加 `[switch]$VerifyPowerCycle`、`[string]$MergeInband=''`、`[string]$MergeOob=''`。
2. 正常模式：`$capArgs` splat 追加 `VerifyPowerCycle = $true`（仅开关置位时）；汇总文本加 `角色` 行（来源：cap CSV 的 Role 列或探测输出）。
3. 合并模式（两参数同给）：
   - 两文件 `Test-Path` 且可读，否则 Write-Error + exit 1；只给一个 → Write-Error 提示另一参数 + exit 1。
   - `Import-Csv` 两文件；校验首行含 `Item/Name/Status` 属性，缺 → 报错退出。
   - Role 校验：对象含 `Role` 属性时——Inband 任一行 Role≠`被测服务器` → `Write-Warning "警告：-MergeInband 文件 Role=...，确认未传反？"`；Oob 任一行 Role≠`编排机` → 对应警告。仅警告。
   - 合并：按 Item 建 map（来源 Inband），遍历 Oob 行——无则加入；有则 `Get-StatusPriority` 高者胜，同级取 Inband（A=服务器 CSV）。
   - 复用现有 `Get-Recommendation` + 汇总统计 + assessment CSV/TXT 输出；TXT 加 `合并来源: 服务器 <MergeInband> + 编排机 <MergeOob>`。
4. 头注释补合并用法示例。

- [ ] **Step 4: 运行确认通过 + 回归**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`；`tests\test-gating.ps1`；`tests\test-smoke.ps1`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add scripts/Run-ServerAssessment.ps1 tests/test-assessment-role.ps1
git commit -m "feat: Run-ServerAssessment 合并模式 + VerifyPowerCycle 透传"
```

---

### Task 6: test-gating.ps1 回归适配

**Files:**
- Modify: `tests/test-gating.ps1`（如需要）

- [ ] **Step 1: 运行回归**

Run: `powershell -NoProfile -File tests\test-gating.ps1`
Expected: 全 PASS。若用例 3 失败，分析新行为（fake 默认 ok → 编排机角色），微调断言使其与新行为一致（断言对象仍是：输出含 `1.2.3.4`、不含明文密码 `pw`）。

- [ ] **Step 2: 若改动则 Commit**

```bash
git add tests/test-gating.ps1
git commit -m "test: test-gating 适配角色化后的能力检查输出"
```

---

### Task 7: 文档 15/19/20 更新

**Files:**
- Modify: `docs/19-测试项执行清单.md`、`docs/20-纯命令行压测手册.md`、`docs/15-BMC排查方案.md`

- [ ] **Step 1: 更新 docs/19-测试项执行清单.md 的 ③ 能力评估步骤**

原第 44 行命令改为三步（同一脚本两台机器各跑一次 + 合并）：
```text
③ 能力评估（两段式+合并）：
  服务器本机（自动判为被测服务器，免密码提示）：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-ServerAssessment.ps1 -MachineName srv01
  编排机（自动判为编排机；-VerifyPowerCycle 真实验证断电循环）：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-ServerAssessment.ps1 -BmcHost 10.0.0.10 -BmcUser root -BmcPass <密码> -VerifyPowerCycle -MachineName srv01
  合并完整 17 项：
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-ServerAssessment.ps1 -MergeInband <服务器cap.csv> -MergeOob <编排机cap.csv> -MachineName srv01
```
完成标准改为：两段各产出 cap CSV、合并报告确认第 4 项 ECC、第 10 项电源（已验证/条件）、第 15 项平台。

- [ ] **Step 2: 更新 docs/20-纯命令行压测手册.md 流程 5 第一步**

"先实测一次 power cycle"改为：用 `-VerifyPowerCycle` 自动验证（编排机跑评估时置位，脚本自动实测断电重启并给结论；已验证可跳过人工确认）。保留原始 `chassis power cycle` 手工命令作为兜底参考。

- [ ] **Step 3: 更新 docs/15-BMC排查方案.md**

三原因表（§2.3）后补一段：能力评估/一键评估已自动按 BMC 可达性分类角色——`Could not open socket`/`Unable to connect` 会判为被测服务器角色并提示换编排机（管理网）跑带外；凭据失败单独标为"条件: BMC 可达但凭据/权限失败"。

- [ ] **Step 4: Commit**

```bash
git add docs/19-测试项执行清单.md docs/20-纯命令行压测手册.md docs/15-BMC排查方案.md
git commit -m "docs: 评估改两段式+合并，断电循环验证改 -VerifyPowerCycle"
```

---

### Task 8: 打包交付（build.ps1 -Zip + 校验 + 同步提交 memtest/ 镜像）

**Files:**
- 生成：`memtest.zip`（gitignored）、`memtest/` 镜像同步（build.ps1 产物）

- [ ] **Step 1: 重新打包**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip`
Expected: 输出 `==> 交付包已生成: memtest.zip`，无 `Missing key files` 错误。

- [ ] **Step 2: 校验 zip 时间戳与包内 hash 一致**

Run（PowerShell）：
```powershell
$z = Get-Item memtest.zip
# 时间戳为当前
if ((Get-Date) - $z.LastWriteTime -gt [TimeSpan]::FromMinutes(10)) { throw "zip 时间戳非当前" }
# 包内关键文件与仓库 hash 一致（解包到临时目录比对）
$tmp = Join-Path $env:TEMP ("zipchk-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -LiteralPath memtest.zip -DestinationPath $tmp
foreach ($f in @('scripts/Check-ServerCapabilities.ps1','scripts/Run-ServerAssessment.ps1','scripts/lib_common.ps1')) {
  $a = (Get-FileHash (Join-Path $tmp $f) -Algorithm SHA256).Hash
  $b = (Get-FileHash (Join-Path $PWD $f) -Algorithm SHA256).Hash   # 仓库根相对路径（命令在仓库根运行）
  if ($a -ne $b) { throw "hash 不一致: $f" }
}
Remove-Item $tmp -Recurse -Force
```
Expected: 通过（无 throw）。

- [ ] **Step 3: 提交 memtest/ 镜像同步的改动文件**

build.ps1 已把根目录改动同步进 memtest/；提交这些镜像副本（未变化的文件内容相同、git 无 diff）：
```bash
git add memtest/scripts/lib_common.ps1 memtest/scripts/Check-ServerCapabilities.ps1 memtest/scripts/Run-ServerAssessment.ps1
git add memtest/docs/15-BMC排查方案.md memtest/docs/19-测试项执行清单.md memtest/docs/20-纯命令行压测手册.md
git commit -m "chore: 同步 memtest 离线包镜像（角色化评估）"
```

- [ ] **Step 4: 全量回归（最终验收）**

Run: `powershell -NoProfile -File tests\test-assessment-role.ps1`；`tests\test-gating.ps1`；`tests\test-smoke.ps1`；`tests\test-lib.ps1`
Expected: 全部 PASS。
