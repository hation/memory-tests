# BMC 网络防护与断电循环风险警示 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"恢复 BMC 静态 IP"固化为 `Set-BmcStaticIp.ps1`、测试启动前自动体检 BMC（中止+指引）、断电循环两入口警示共用电源风险、根因链沉淀进文档 21，杜绝每次测试后手工救火。

**Architecture:** 新增编排机侧前置体检函数（ipmitool lanplus：mc info 可达性 + lan print IP 源静态检查，fail-closed）+ 被测服务器本机恢复脚本（ipmiutil raw 命令 + 回读兜底判据）+ 共享电源警示函数（两处动电入口复用），接入 Run-MemtestSuite 与 Check-ServerCapabilities，配套 fake fixture 测试与打包白名单。

**Tech Stack:** PowerShell 5.1；内置 ipmitool（lanplus 远程）、ipmiutil-win64（本地接口 raw 命令）；cmd 假工具 fixture 测试模式。

**Spec:** [2026-10-28-bmc-net-protect-design.md](../specs/2026-10-28-bmc-net-protect-design.md)（v1.1，已批准）

## Global Constraints

- 脚本沿用既有约定：dot-source `lib_common.ps1`、`Write-CmdLog`（Start/End、密码打码）、`Invoke-IpmiProbe`（stdout/stderr 分离安全包装）、`Read-BmcPass`。
- 所有脚本（含新脚本）必须调用 `Write-CmdLog` Start/End。
- `Set-BmcStaticIp.ps1` 只运行于被测服务器本机（本地接口）；恢复**只用 raw 命令**（`ipmiutil lan -s` 报 Bus Error 不可用）。
- 前置体检：BMC 不可达 / lan print 失败（重试后）/ IP 源非静态 → **中止**（用户已定 fail-closed）；非 SOL 方式与 `-ParseOnly` 不触发。
- 断电循环警示**不阻断**执行；`-ConfirmSwitch` 仍是唯一门禁。
- 打包纪律：逻辑代码变更 → `build.ps1 -Zip`（先删旧 zip 再建新包）→ 校验 zip 时间戳与关键文件 hash；`build.ps1` `$scriptFiles`/`$keyFiles` 白名单须加入新脚本。
- 文档标记：docs 下 `[当前有效]` 标记保持；`memtest/` 镜像目录由 build 自动同步。
- 既有测试（test-lib / test-prime95 等）不得回归。

## Review Focus

1. `lan print` 输出文案差异（`Static Address` / `Static` / 大小写 / DHCP / Unspecified）→ 解析必须大小写不敏感按 `Static` 匹配；DHCP/Unspecified 判 false（Task 1 覆盖）。
2. BMC 密码错误（auth）与网络不可达（unreachable）都应 `Reachable=false`，指引归因准确（Task 1 覆盖）。
3. 非 SOL 方式（Serial/USB/EFI）与 `-ParseOnly` 不得触发前置体检（Task 2 验证断言）。
4. `Set-BmcStaticIp` 非法 IP/掩码、缺 ipmiutil 工具 → 报错退出，绝不写 BMC 配置（Task 4 覆盖）。
5. 断电循环警示打印后不得阻断执行（Task 2/3 验证断言）。

---

### Task 1: lib_common.ps1 —— `Invoke-BmcPreflight` + `Write-PowerCycleWarning`（TDD）

**Files:**
- Modify: `scripts/lib_common.ps1`（新增两函数，放 `Test-BmcRole` 之后）
- Modify: `tests/fixtures/fake-ipmitool.cmd`（新增 lan print 分发 + 3 个模式）
- Create: `tests/test-bmc-net.ps1`

**Interfaces:**
- Produces:
  - `Invoke-BmcPreflight`：`param([string]$BmcHost, [string]$BmcUser='', [string]$BmcPass='', [string]$IpmiTool='ipmitool', [int]$LanRetry=2, [int]$LanRetryIntervalSec=5)` → `[PSCustomObject]@{ Reachable=[bool]; LanPrintOk=[bool]; IpSourceStatic=[bool]; Detail=[string] }`
  - `Write-PowerCycleWarning`：`param()` → 打印警示块，无返回
  - `test-bmc-net.ps1`：dot-source lib_common + Assert 风格，全绿输出 `test-bmc-net: ALL PASS`

- [ ] **Step 1: 扩展 `tests/fixtures/fake-ipmitool.cmd`**

在 `sol activate` 分发之后追加 lan print 分发（`findstr /C:"lan print"` → `:lan_print`），并加三种模式输出：
```bat
:lan_print
if "%FAKE_IPMI_MODE%"=="preflight-lanfail" (
    (echo lan print failed) 1>&2
    exit /b 1
)
if "%FAKE_IPMI_MODE%"=="preflight-dhcp" (
    echo IP Address Source : DHCP Address
    exit /b 0
)
echo IP Address Source : Static Address
exit /b 0
```
（`unreachable`/`auth` 模式已在顶部统一拦截，无需改；`preflight-static` 走默认分支。）

- [ ] **Step 2: 写 `tests/test-bmc-net.ps1`（先写测试，预期失败）**

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$fake = Join-Path $PSScriptRoot 'fixtures\fake-ipmitool.cmd'
$env:FAKE_IPMI_MODE = 'unreachable'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert (-not $r.Reachable -and -not $r.LanPrintOk) "unreachable => Reachable=false"
$env:FAKE_IPMI_MODE = 'auth'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert (-not $r.Reachable) "auth => Reachable=false（凭据错误也判不可达）"
$env:FAKE_IPMI_MODE = 'preflight-static'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and $r.LanPrintOk -and $r.IpSourceStatic) "static => 全通过"
$env:FAKE_IPMI_MODE = 'preflight-dhcp'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and $r.LanPrintOk -and -not $r.IpSourceStatic) "dhcp => IpSourceStatic=false"
$env:FAKE_IPMI_MODE = 'preflight-lanfail'
$r = Invoke-BmcPreflight -BmcHost 10.0.0.10 -BmcUser root -BmcPass x -IpmiTool $fake -LanRetry 1 -LanRetryIntervalSec 0
Assert ($r.Reachable -and -not $r.LanPrintOk) "lanfail(重试后) => LanPrintOk=false"
Remove-Item Env:FAKE_IPMI_MODE -ErrorAction SilentlyContinue
Write-Host "test-bmc-net: ALL PASS"
```

- [ ] **Step 3: 运行测试确认失败**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bmc-net.ps1`
Expected: 报 `Invoke-BmcPreflight` 不存在（命令未找到）。

- [ ] **Step 4: 在 `scripts/lib_common.ps1`（`Test-BmcRole` 之后）实现两函数**

`Invoke-BmcPreflight`：
- ① 可达性：循环 `@(@(), @('-C','3'), @('-C','17'))` 用 `Invoke-IpmiProbe` 试 `mc info`，首个 Code=0 且有输出 → `Reachable=$true` 并记生效 `$cipher`；全失败 → 返回 `Reachable=false`。
- ② IP 源：用 `$a + $cipher + @('lan','print','1')` 探测，最多 `LanRetry` 次重试（间隔 `LanRetryIntervalSec`）；成功（Code=0 且有输出）→ `LanPrintOk=$true`，取含 `IP Address Source` 的行，`-match 'Static'`（大小写不敏感）→ `IpSourceStatic=$true`。
- `Detail`：取输出前 3 行 `-join ' | '`。
- 返回 `[PSCustomObject]@{ Reachable; LanPrintOk; IpSourceStatic; Detail }`。

`Write-PowerCycleWarning`：
```powershell
function Write-PowerCycleWarning {
    Write-Host "⚠️ 断电循环风险提示"
    Write-Host "- chassis power cycle 是真断电；若编排机与被测服务器共用同一插线板/PDU，反复断电的电压跌落可能导致编排机网卡 Code 43、被测服务器网卡/BMC 异常（2026-10-28 故障根因）。"
    Write-Host "- 建议：① 编排机先换独立电源回路；② 开始前先停掉本机正在跑的 SOL/长连接；③ 循环中勿动编排机。"
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bmc-net.ps1`
Expected: `test-bmc-net: ALL PASS`

- [ ] **Step 6: 回归既有库测试**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1`
Expected: `test-lib: ALL PASS`

- [ ] **Step 7: Commit**

```bash
git add scripts/lib_common.ps1 tests/test-bmc-net.ps1 tests/fixtures/fake-ipmitool.cmd
git commit -m "feat(bmc): Invoke-BmcPreflight 前置体检 + Write-PowerCycleWarning 警示"
```

---

### Task 2: Run-MemtestSuite.ps1 —— SOL 前置体检 + 断电循环警示接入

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`（主流程前置体检；`Invoke-PowerCycleLoop` 警示+复核；`-Help` 文案）

**Interfaces:**
- Consumes: `Invoke-BmcPreflight`、`Write-PowerCycleWarning`（Task 1）
- Produces: SOL 路径在捕获前中止（`exit 1` + `Write-CmdLog End`）；断电循环前打印警示、循环后打印 BMC 复核（不阻断）

- [ ] **Step 1: 主流程接入前置体检**

在 ipmitool 自动发现（L184-188）之后、`Write-Host "===== Memtest86+ 编排开始"`（L491）之前插入（ORT 分支在其后，同样被覆盖）：
```powershell
# SOL 前置体检（fail-closed：BMC 不可达 / IP 源非静态 / lan print 失败均中止并给恢复指引）
if ($BootMethod -eq 'SOL' -and $BmcHost -and -not $ParseOnly) {
    $pre = Invoke-BmcPreflight -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool
    if (-not $pre.Reachable) {
        Write-Host ""
        Write-Host "[FAIL] BMC 前置体检：BMC 不可达（$($pre.Detail)）"
        Write-Host "  指引：① 编排机有线网卡 Code 43 先修（docs/21 §3）；② BMC 无 IP 则去被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复静态 IP；③ 修复后重跑本命令。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检不可达' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    if (-not $pre.LanPrintOk) {
        Write-Host "[FAIL] BMC 前置体检：无法读取 LAN 配置（IP 源未知，fail-closed）"
        Write-Host "  指引：到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 -CheckOnly 人工核实 IP 源后重跑。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检 lan print 失败' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    if (-not $pre.IpSourceStatic) {
        Write-Host "[FAIL] BMC 前置体检：IP 源非静态（DHCP/未指定），断电循环后易丢 IP"
        Write-Host "  指引：到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复静态 IP（默认 10.0.0.10/255.255.255.0），确认后重跑本命令。"
        Write-CmdLog -Script 'Run-MemtestSuite' -State End -Result 'FAIL: BMC 前置体检 IP 源非静态' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    Write-Host "[OK] BMC 前置体检通过：IP 源静态"
}
```

- [ ] **Step 2: `Invoke-PowerCycleLoop` 警示 + 循环后复核**

`for` 循环之前：`Write-PowerCycleWarning`。循环全部完成后（`$rows | Export-Csv` 之后）追加：
```powershell
# 循环后 BMC 复核（只提示不阻断）
$post = Invoke-BmcPreflight -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $BmcPass -IpmiTool $IpmiTool
if (-not $post.Reachable) {
    Write-Warning "断电循环后 BMC 不可达：请到被测服务器本机跑 .\scripts\Set-BmcStaticIp.ps1 恢复（勿配系统网卡 10.0.0.10，那是 BMC 的 IP）。"
} elseif (-not $post.IpSourceStatic) {
    Write-Warning "断电循环后 BMC IP 源非静态：建议 .\scripts\Set-BmcStaticIp.ps1 恢复为静态，防止下次丢 IP。"
}
```

- [ ] **Step 3: `-Help` 文案**

SOL 方式说明行补：`启动前自动 BMC 前置体检（BMC 可达 + IP 源须静态；异常中止并打印恢复指引）`。

- [ ] **Step 4: 验证**

```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Run-MemtestSuite.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Run-MemtestSuite.ps1 -Help
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bmc-net.ps1
```
Expected: SYNTAX OK；-Help 含前置体检说明；test-bmc-net ALL PASS。再 grep 断言：
- `Invoke-BmcPreflight` 调用点在 `-ParseOnly` 分支之后、ORT 捕获之前；
- 三个中止分支均 `exit 1` + `Write-CmdLog` End；
- `Write-PowerCycleWarning` 在 `for ($i = 1; $i -le $Cycles` 之前、无 exit/return 阻断。

- [ ] **Step 5: Commit**

```bash
git add scripts/Run-MemtestSuite.ps1
git commit -m "feat(memtest): SOL 前置 BMC 体检（fail-closed）+ 断电循环电源风险警示与循环后复核"
```

---

### Task 3: Check-ServerCapabilities.ps1 —— `-VerifyPowerCycle` 警示接入

**Files:**
- Modify: `scripts/Check-ServerCapabilities.ps1`

**Interfaces:**
- Consumes: `Write-PowerCycleWarning`（Task 1）

- [ ] **Step 1: `-VerifyPowerCycle` 序列前打印警示**

在 `if ($runOob -and $VerifyPowerCycle) {`（约 L196）块内、baseline 检查之前插入 `Write-PowerCycleWarning`。确认该脚本已 dot-source `lib_common.ps1`（若未，补上，与 Run-ServerAssessment 一致）。

- [ ] **Step 2: 验证**

```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Check-ServerCapabilities.ps1')) | Out-Null; 'SYNTAX OK'"
```
Expected: SYNTAX OK；grep 断言 `Write-PowerCycleWarning` 调用点在 `chassis power cycle` 下发之前、无阻断逻辑。

- [ ] **Step 3: Commit**

```bash
git add scripts/Check-ServerCapabilities.ps1
git commit -m "feat(capabilities): VerifyPowerCycle 前打印共用电源风险警示"
```

---

### Task 4: scripts/Set-BmcStaticIp.ps1 —— 新增恢复脚本

**Files:**
- Create: `scripts/Set-BmcStaticIp.ps1`

**Interfaces:**
- Consumes: `Write-CmdLog`、`Invoke-IpmiProbe`（dot-source lib_common）
- Produces: 被测服务器本机一键查询/恢复 BMC 静态 IP；`-CheckOnly` 只读；默认不自动 `reset -c`（`-ColdReset` 开关）

- [ ] **Step 1: 写脚本骨架（param + Help + cmdlog）**

```powershell
param(
    [string]$Ip = "10.0.0.10",
    [string]$Mask = "255.255.255.0",
    [string]$Gateway = "",
    [string]$IpmiUtil = "",
    [switch]$CheckOnly,
    [switch]$ColdReset,
    [switch]$Help
)
```
`-Help` 打印用法（本地接口、需管理员、`-CheckOnly` 只读、`-ColdReset` 自动冷复位 BMC）。`Write-CmdLog -Script 'Set-BmcStaticIp' -State Start`（Help 先处理）。

- [ ] **Step 2: 参数校验 + 工具发现**

- IP/掩码校验：`[System.Net.IPAddress]::TryParse` 或正则 `^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$` + 每段 ≤255；非法 → `Write-Error` + `Write-CmdLog End` + `exit 1`（**在校验不通过时不写任何 BMC 配置**）。
- `IpmiUtil` 为空 → 自动发现 `<包根>\tools\ipmiutil-win64\ipmiutil.exe`；不存在 → 报错提示"整个目录拷贝含 DLL"。
- 可选 `$Gateway` 处理：仅当非空且非 `0.0.0.0` 时下发网关 raw 命令；`0.0.0.0`/空则跳过（d5 属正常）。

- [ ] **Step 3: 读现状 + `-CheckOnly`**

`Invoke-IpmiProbe -IpmiTool $IpmiUtil -IpmiArgs @('lan','-c','1')`，解析 `Lan Param(3) IP address`、`Lan Param(4) IP addr src`、`Lan Param(5) MAC addr`。`-CheckOnly` → 打印现状（IP/源/MAC + 判定：静态=正常、DHCP/未指定=需恢复），`Write-CmdLog End`，`exit 0`。

- [ ] **Step 4: 写路径（raw 命令序列 + 回读兜底）**

按文档 21 §5.2 顺序，每条用 `Invoke-IpmiProbe -IpmiTool $IpmiUtil -IpmiArgs @('cmd', ...)` 执行并打印输出（过程提示；输出形态不同版本有差异，**不作为最终判据**）：
1. 验证通道：`cmd 00 20 30 02 01 03 00`
2. IP 源=静态：`cmd 00 20 30 01 01 04 01`（打印时标注"期望 len=1"）
3. IP：`cmd 00 20 30 01 01 03 <b1> <b2> <b3> <b4>`（`[System.Net.IPAddress]::Parse($Ip).GetAddressBytes()` 转十六进制 `ToString('x2')`）
4. 掩码：`cmd 00 20 30 01 01 06 ff ff ff 00`（同 IP 字节转换）
5. 网关（仅当设置）：`cmd 00 20 30 01 01 0c ...`（d5 忽略）
6. **回读兜底判据**：`lan -c 1` 核对 `Lan Param(3)`=目标 IP、`Lan Param(4)`=01、掩码一致 → 成功；任一不符 → `Write-Error` + `Write-CmdLog End` + `exit 1`。
7. `-ColdReset` → 执行 `ipmiutil.exe reset -c`（打印"服务器会短暂息屏 1~2 分钟"）；否则仅提示用户确认时机手动执行。
`Write-CmdLog End`（OK / FAIL: 具体原因）。

- [ ] **Step 5: 验证（本机 dry）**

```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Set-BmcStaticIp.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Set-BmcStaticIp.ps1 -Help
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Set-BmcStaticIp.ps1 -Ip 999.1.1.1      # 应报参数非法退出 1，不触碰任何工具
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Set-BmcStaticIp.ps1 -CheckOnly         # 本机无 ipmiutil → 报"工具缺失"退出 1
```
Expected: SYNTAX OK；-Help 正常；非法 IP 报错退出 1；无工具时报错路径正确。检查 `results\cmdlog\commands-*.csv` 有 Set-BmcStaticIp Start/End 记录。

- [ ] **Step 6: Commit**

```bash
git add scripts/Set-BmcStaticIp.ps1
git commit -m "feat(bmc): Set-BmcStaticIp 一键查询/恢复 BMC 静态 IP（ipmiutil raw + 回读兜底）"
```

---

### Task 5: 文档同步

**Files:**
- Modify: `docs/21-BMC网络与IP恢复方案.md`
- Modify: `docs/20-纯命令行压测手册.md`（流程 5 风险提示，可选但推荐）
- 注：`memtest/` 镜像目录由 build 自动同步（Task 6）

- [ ] **Step 1: `docs/21` 新增根因与预防章节**

新增章节（放在 §7 之后，如 `## 8. 根因链与预防措施（2026-10-28）`）：
- 根因链：`chassis power cycle`（真断电）× 共用电源 → 编排机网卡 Code 43 + 被测服务器网卡/BMC 异常；BMC 反复冷启动 → AMI 固件 IP 源回退 DHCP。
- 三层预防：① 物理/操作（断电循环时编排机独立电源、先停 SOL、系统网卡**勿配 10.0.0.10**——那是 BMC 的 IP）；② 脚本（`Set-BmcStaticIp.ps1` 一键恢复、`Run-MemtestSuite` 前置体检、断电循环警示）；③ 文档（本节）。
- 明确脚本事实：本项目脚本从不改 IP/网卡配置，BMC 10.0.0.10 是手工 raw 恢复的。

- [ ] **Step 2: `docs/21` §5 引用一键脚本**

§5.1 工具准备处补：`一键恢复：.\scripts\Set-BmcStaticIp.ps1 -CheckOnly（查询）/ .\scripts\Set-BmcStaticIp.ps1（恢复 10.0.0.10/255.255.255.0，管理员运行）`；并注明 `memtest.zip` 内脚本路径同构。

- [ ] **Step 3: `docs/20` 流程 5 补风险提示**

断电循环流程（`## 流程 5`）第一步前补："⚠️ 若编排机与被测服务器共用电源，断电循环可能把编排机网卡打坏（Code 43，2026-10-28 根因）；先把编排机换独立电源回路、停掉 SOL 会话再跑。"

- [ ] **Step 3b: `Run-BatchScheduler.ps1 -Help` 文案**

SOL 方式说明补"每个批次启动前自动 BMC 前置体检（异常中止）"（与 Run-MemtestSuite -Help 一致；若 Help 中无 SOL 细节行则跳过此步并说明原因）。

- [ ] **Step 4: 验证**

grep 断言：`docs/21` 含 `Set-BmcStaticIp`、`勿配 10.0.0.10`、根因链关键词；`docs/20` 流程 5 含风险提示；`scripts\Run-BatchScheduler.ps1 -Help` 输出含前置体检（若适用）。

- [ ] **Step 5: Commit**

```bash
git add docs/21-BMC网络与IP恢复方案.md docs/20-纯命令行压测手册.md
git commit -m "docs(bmc): 21 号文档补根因链与预防措施，20 号流程 5 补电源风险提示"
```

---

### Task 6: build.ps1 白名单 + 打包 + 整支复查（主 agent）

**Files:**
- Modify: `scripts/build.ps1`（`$scriptFiles` L73-87、`$keyFiles` L202-222）

- [ ] **Step 1: 白名单加入新脚本**

`$scriptFiles` 加 `'Set-BmcStaticIp.ps1'`（按字母序在 `Run-ServerAssessment.ps1` 附近）；`$keyFiles` 加 `(Join-Path $KitDir 'scripts\Set-BmcStaticIp.ps1')`（紧邻 Run-Prime95Stress 一行）。

- [ ] **Step 2: 回归测试全量**

运行全部 `tests\test-*.ps1`（test-lib / test-bmc-net / test-prime95 / test-gating / test-presets / test-suite-config / test-ort / test-cmdlog / test-assessment-role / test-iso-build / test-smoke / test-results-import / test-task-checklist / test-args / test-ort），记录哪些受影响；至少 `test-lib`、`test-bmc-net`、`test-prime95` 必须全绿。

- [ ] **Step 3: 打包并校验**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip
```
（版本递增按既有先例 `-Bump`，若本次不递增则纯 `-Zip`；以 build.ps1 `-Help` 为准。）
校验：zip 时间戳为当前；zip 内 `scripts\Set-BmcStaticIp.ps1`、`scripts\lib_common.ps1`、`scripts\Run-MemtestSuite.ps1`、`scripts\Check-ServerCapabilities.ps1`、`docs\21-BMC网络与IP恢复方案.md` hash 与仓库一致（build.ps1 输出校验行）。

- [ ] **Step 4: 整支复查（主 agent）**

- 逐 Task 复查：preflight 三中止分支、警示不阻断、Set-BmcStaticIp 参数校验/回读兜底、build 白名单、文档标记保持 `[当前有效]`。
- 汇总变更给用户，标注待用户实机执行项（验收口径 4/5：被测服务器实机采集 ipmiutil 输出校准 + `Set-BmcStaticIp -CheckOnly` 实机验证 + 编排机重跑前置体检）。

- [ ] **Step 5: Commit**

```bash
git add scripts/build.ps1
git commit -m "build: 白名单纳入 Set-BmcStaticIp.ps1 并重新打包"
```

---

## 备注（用户侧实机待办）

- 被测服务器本机：跑一次 `ipmiutil.exe cmd 00 20 30 02 01 03 00` + `lan -c 1` 采集真实输出，校准 Task 4 过程提示解析（成功/失败形态），记录到文档 21 或脚本注释。
- 被测服务器本机：`Set-BmcStaticIp.ps1 -CheckOnly` 看当前 IP 源；BMC 掉线则跑恢复命令，`lan -c 1` 回读静态。
- 编排机：重跑 `Run-MemtestSuite.ps1`（SOL）前置体检通过后再开测。
- 物理层：断电循环期间编排机换独立电源回路；系统网卡不配 10.0.0.10。
