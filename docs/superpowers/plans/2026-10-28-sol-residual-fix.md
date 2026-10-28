# SOL 残留会话修复实施计划：启动自动释放 + 结束时 deactivate + already active 重试

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run-MemtestSuite 的 Invoke-SolCapture 在启动前清残留 SOL 会话、结束时无条件释放 BMC 端 payload、遇 "already active" 自动重试一次，杜绝"连跑下一轮撞车"。

**Architecture:** 改造 `Invoke-SolCapture`：activate 前静默 `sol deactivate`；首个轮询内检测 `HasExited + .err 含 already active` 时再 deactivate 并重试 activate 一次；结束（任一终止路径）后无条件 `sol deactivate`。deactivate 全程静默（失败忽略），返回对象语义不变。

**Tech Stack:** PowerShell 5.1；内置 ipmitool。

**Spec:** [2026-10-28-sol-residual-fix-design.md](../specs/2026-10-28-sol-residual-fix-design.md)（已由用户验证诊断后认可）

## Global Constraints

- 只改 `scripts/Run-MemtestSuite.ps1` 的 `Invoke-SolCapture`；不动 lib_common、其它引导路径、ORT 判定。
- deactivate 必须静默（`2>$null` + catch + EAP 临时 Continue），失败绝不阻塞。
- 重试仅当 `$p.HasExited -and $failHint -match 'already active'`，且最多 1 次；进程存活/有输出绝不重试。
- 返回对象 Done/Stalled/SessionLost/FailHint/CaptureStart/CaptureEnd 语义保持；既有调用方零破坏。
- 既有测试（test-lib/test-bmc-net）无回归。
- git 身份已配置（ganxin）；只 stage 任务文件；打包纪律（build.ps1 -Zip 先删旧包 + hash 校验）。

## Review Focus

1. deactivate 失败不阻塞（静默模式正确）→ Task 1 代码审查 + grep。
2. 重试条件精确（仅 already active + 进程已退出 + 最多一次）→ Task 1 审查。
3. 正常捕获不被重试干扰（进程存活绝无重试）→ Task 1 审查。
4. 结束时无条件释放（所有终止路径都走到）→ Task 1 审查（deactivate 在 Stop-Process 之后、return 之前）。
5. 返回对象/字段向后兼容 → Task 1 审查。

---

### Task 1: Run-MemtestSuite.ps1 —— Invoke-SolCapture 释放与重试

**Files:**
- Modify: `scripts/Run-MemtestSuite.ps1`

**Interfaces:**
- Produces: `Invoke-SolCapture` 内部行为改造（对外签名/返回不变）；`sol deactivate` 出现于启动前与结束后；重试分支。

- [ ] **Step 1: 启动前清残留**

构造 `$args` 之后、首次 `Start-Process sol activate` 之前：
```powershell
# 清残留 SOL 会话（失败忽略；同 Diag-Bmc 释放模式）
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $IpmiTool @($args + @('sol', 'deactivate')) 2>$null | Out-Null } catch {}
finally { $ErrorActionPreference = $prevEap }
```

- [ ] **Step 2: already active 自动重试一次**

首个轮询周期内若 `$sessionLost -and $failHint -match 'already active' -and -not $retried`：
- 再执行一次 deactivate（同 Step 1 静默模式）；
- 重新 `Start-Process sol activate`（同一 `$OutFile`/`.err`），重置 `$done=$false; $sessionLost=$false; $failHint=""; $retried=$true`；
- 继续进入既有轮询循环（实现上可用标志位 + 循环结构，builder 判断，保持轮询/停滞/超时/ev=done 语义不变）。
- `$retried` 循环前初始化 `$false`。

- [ ] **Step 3: 结束时无条件释放**

`Stop-Process -Id $p.Id -Force` 之后、return 之前：
```powershell
# 释放 BMC 端 SOL payload（失败忽略）
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $IpmiTool @($args + @('sol', 'deactivate')) 2>$null | Out-Null } catch {}
finally { $ErrorActionPreference = $prevEap }
```

- [ ] **Step 4: 验证**

```powershell
powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw 'scripts\Run-MemtestSuite.ps1')) | Out-Null; 'SYNTAX OK'"
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-lib.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bmc-net.ps1
```
grep 断言：`sol deactivate` ≥2 处；重试分支含 `already active` + `$retried`；deactivate 调用均在静默模式（`2>$null`）内。

- [ ] **Step 5: Commit**

```bash
git add scripts/Run-MemtestSuite.ps1
git commit -m "fix(memtest): SOL 启动前清残留 + 结束释放 payload + already active 重试一次"
```

---

### Task 2（主 agent 收尾）: 打包 + 推送

- `build.ps1 -Zip`（保持 v19，不 -Bump）→ 校验 zip 内 Run-MemtestSuite.ps1 hash 与仓库一致 → kit 同步提交 → `git push origin main`。

## 备注（用户侧）

- 实机验证：r1 或 10 分钟 ORT PASS 后**立即**再跑下一轮，不应再报 "already active"。
