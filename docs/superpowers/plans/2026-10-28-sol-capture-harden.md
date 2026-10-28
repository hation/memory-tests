# SOL 捕获加固实施计划：会话断开早期检测 + 行动指引

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run-MemtestSuite 的 SOL 捕获在 ipmitool 会话断开时立即结束（不等 120 分钟超时），并打印四查行动指引；失败留痕（INCOMPLETE 报告 + 清单 ✗）保持。

**Architecture:** 在 `Invoke-SolCapture` 轮询循环加 `$p.HasExited` 检测 → 提前 break 并返回 `SessionLost/FailHint`；新增 `Write-SolTroubleshootHint` 四查指引函数；SOL 普通 + ORT 两个接入点在 `-not $cap.Done` 时打印指引。文档同步 + 打包。

**Tech Stack:** PowerShell 5.1；内置 ipmitool。

**Spec:** [2026-10-28-sol-capture-harden-design.md](../specs/2026-10-28-sol-capture-harden-design.md)（已批准）

## Global Constraints

- 只改 `scripts/Run-MemtestSuite.ps1`（Invoke-SolCapture + 主流程两处 + 新函数）与 `docs/20`；不动 lib_common、不动 Serial/USB/EFI 路径。
- 返回对象在既有字段后**追加** `SessionLost/FailHint`（既有调用方只读 Done/Stalled/时间字段，不得破坏）。
- 检测条件：`$p.HasExited -and -not $done`；进程存活期间绝不提前退出。
- 失败留痕保持：超时/断开后继续 parse→report→checklist。
- 既有测试（test-lib/test-bmc-net）不得回归；空日志解析 INCOMPLETE 回归测试加入。
- 打包纪律：逻辑代码变更 → `build.ps1 -Zip`（先删旧包）→ 校验 zip 时间戳与关键文件 hash。
- git 身份：仓库本地已配置 `ganxin <331596350@qq.com>`，提交直接可用；只 stage 任务列出的文件，严禁纳入无关改动（db/* 等用户 WIP）。

## Review Focus

1. 正常捕获不被误判（进程存活 + 输出中不得提前 break）→ Task 1 检测条件断言（grep HasExited 条件含 `-and -not $done`）。
2. 返回对象向后兼容（新字段追加不改旧字段）→ Task 1 grep/审查。
3. 指引文案与文档 15/20 一致（虚拟介质/串口重定向/SOL 会话/BMC 四查）→ Task 1/2 文案断言。
4. 空日志仍解析 INCOMPLETE 且流程走完（失败留痕）→ Task 1 回归测试。
5. ORT 分支同点覆盖 → Task 1 grep 断言两处接入。

---

### Task 1: Run-MemtestSuite.ps1 —— SessionLost 检测 + 指引函数 + 主流程接入

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`

**Interfaces:**
- Produces: `Invoke-SolCapture` 返回追加 `SessionLost=[bool]`、`FailHint=[string]`；新增 `Write-SolTroubleshootHint -FailHint`；两处 `-not $cap.Done` 分支打印指引。

- [ ] **Step 1: 空日志解析回归测试（先写，预期失败）**

在 `tests/test-lib.ps1` 末尾追加（若文件已有相似断言则合并）：
```powershell
# --- SOL 捕获加固：空日志（SOL 会话头仅此而已）应解析为 INCOMPLETE，不抛异常 ---
$tmpSol = Join-Path $env:TEMP ("sol-empty-" + [guid]::NewGuid().ToString("N") + ".txt")
"[SOL Session operational.  Use ~? for help]" | Set-Content -LiteralPath $tmpSol -Encoding UTF8
$sol = Invoke-MtlogParser -LogFile $tmpSol
Assert ($sol.FinalStatus -eq "INCOMPLETE") "empty SOL log => INCOMPLETE"
Assert ($sol.PassesCompleted -eq 0) "empty SOL log => 0 passes"
Remove-Item $tmpSol -Force
```
Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1`
Expected: 失败（新断言未加前为空——先加断言确认文件现状）——若现版本已含断言则跳过；实质是确保这条回归断言存在。

- [ ] **Step 2: 实现 `Invoke-SolCapture` 扩展**

轮询循环（`Start-Sleep -Seconds 10` 之后、`Select-String` 检查之前或之后均可）加：
```powershell
# 会话断开早期检测：ipmitool 已退出且未收到 ev=done → 立即结束（不等 deadline）
if ($p.HasExited -and -not $done) {
    $sessionLost = $true
    $failHint = "SOL 会话断开（ipmitool 已退出）"
    break
}
```
循环前初始化 `$sessionLost = $false; $failHint = ""`；return 前（`Stop-Process` 之后、return 之前）：
```powershell
# 携带底层错误（如 keepalive）到指引
if (-not $sessionLost -and Test-Path "$OutFile.err") {
    $errRaw = Get-Content -LiteralPath "$OutFile.err" -Raw -ErrorAction SilentlyContinue
    if ($errRaw) { $failHint = $errRaw.Trim() }
}
return [PSCustomObject]@{ Done = $done; Stalled = $stalled; SessionLost = $sessionLost; FailHint = $failHint; CaptureStart = $capStart; CaptureEnd = Get-Date }
```

- [ ] **Step 3: 新增 `Write-SolTroubleshootHint`**

（放在 `Invoke-SolCapture` 之后或脚本函数区）按 spec §4.2 原文实现（四查文案逐字）。

- [ ] **Step 4: 主流程两处接入**

SOL 普通分支（`switch "SOL"` 内）与 ORT SOL 分支的 `if (-not $cap.Done) { Write-Warning ... }` 改为：
```powershell
if (-not $cap.Done) {
    Write-Warning ("SOL 捕获未收到 ev=done（Done=$($cap.Done) Stalled=$($cap.Stalled) SessionLost=$($cap.SessionLost)）")
    Write-SolTroubleshootHint -FailHint $cap.FailHint
}
```
（ORT 分支同款；两处都改。）

- [ ] **Step 5: 验证**

```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Run-MemtestSuite.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bmc-net.ps1
```
Expected: SYNTAX OK；test-lib 含空日志 INCOMPLETE 断言全绿；test-bmc-net ALL PASS。grep 断言：`SessionLost` 出现于函数定义与返回；`Write-SolTroubleshootHint` 定义 + 两处调用；检测条件含 `$p.HasExited -and -not $done`；四查关键词（`Ventoy`/`串口重定向`/`sol deactivate`/`Set-BmcStaticIp`）在指引函数内。

- [ ] **Step 6: Commit**

```bash
git add scripts/Run-MemtestSuite.ps1 tests/test-lib.ps1
git commit -m "fix(memtest): SOL 会话断开早期检测 + 四查指引（避免静默空转）"
```

---

### Task 2: 文档同步 + 打包

**Files:**
- Modify: `docs/20-纯命令行压测手册.md`（流程 2 补 SOL 无输出排查指引）

**Interfaces:**
- Consumes: Task 1 的四查文案（保持一致）

- [ ] **Step 1: docs/20 流程 2 补指引**

在流程 2"顺序铁律"段之后补一段：
```markdown
> ⚠️ SOL 未收到输出/会话中断时，按序排查：① 引导方式必须是 BMC 虚拟介质挂载 memtest-sol.iso（Ventoy U 盘引导时串口走物理 COM，SOL 收不到）；② BIOS 串口重定向（Console Redirection → SOL）须开启，波特率 115200 三处一致；③ 残留 SOL 会话用 `sol deactivate` 清掉再跑；④ 编排机 ping 通 BMC，服务器本机 `Set-BmcStaticIp.ps1 -CheckOnly` 确认 IP 源静态。参考 docs/15 §3。
```

- [ ] **Step 2: 验证**

grep 断言 docs/20 含 `Ventoy`/`串口重定向`/`sol deactivate`/`Set-BmcStaticIp` 四查关键词。

- [ ] **Step 3: 打包**

`powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip`（先跑 `-Help` 确认参数；版本递增按先例 `-Bump` 或保持 v18——以 -Help 为准）。校验：zip 时间戳当前；zip 内 `scripts\Run-MemtestSuite.ps1`、`scripts\lib_common.ps1`、`docs\20-纯命令行压测手册.md` hash 与仓库一致。

- [ ] **Step 4: Commit**

```bash
git add docs/20-纯命令行压测手册.md
git commit -m "docs(memtest): 流程 2 补 SOL 无输出四查排查指引"
```
（打包产物 kit 同步按先例纳入；`db/*`、`memtest/db/*` 等无关改动严禁纳入。）

---

## 备注（用户侧）

- 加固交付后需重新部署 `C:\memtest`（新 zip）。
- 实机验证：修 SOL 链路后重跑 1 轮全项——正常路径报告+清单更新；若 SOL 仍断则立即打印四查指引。
