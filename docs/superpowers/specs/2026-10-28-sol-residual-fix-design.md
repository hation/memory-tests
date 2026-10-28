# SOL 残留会话修复：启动自动释放 + 结束时 deactivate —— 设计文档

> 日期：2026-10-28 ｜ 状态：待执行 ｜ 关联：[2026-10-28-sol-capture-harden-design.md](./2026-10-28-sol-capture-harden-design.md)（上一轮加固）
> 变更记录：
> - 2026-10-28 v1 初稿：实机复现——r1 正常 PASS 后紧接着启动 ORT，BMC 报 `SOL payload already active on another session`，mtlog 0 字节，测试未跑起来。根因：Run-MemtestSuite 的 Invoke-SolCapture 结束只 Force 杀 ipmitool 客户端，**不释放 BMC 端 SOL payload**（Diag-Bmc 有释放，Run-MemtestSuite 没有）。

## 1. 背景与意图（why）

10-28 实机链条：r1 测试 21:24 正常 PASS（SOL 完整捕获 282KB）→ 21:36 立刻启动 10 分钟 ORT → BMC 报 "SOL payload already active on another session" → ipmitool 退出、mtlog 0 字节 → 测试实际没跑。根因是脚本缺口：

1. **捕获结束不释放 payload**：`Invoke-SolCapture` 末尾仅 `Stop-Process -Force` 杀 ipmitool 客户端，BMC 端 SOL 会话残留（AMI BMC 会话超时通常几分钟~几十分钟）→ 紧接着跑下一轮必撞 "already active"；
2. **启动前不清会话**：没有像 Diag-Bmc 那样先 `sol deactivate`；
3. **不重试**：撞 "already active" 时 ipmitool 直接退出，脚本只能等超时。

目标：捕获**启动前自动清残留**、**结束时自动释放**、**遇 already active 自动重试一次**，彻底杜绝"连跑下一轮撞车"。

## 2. 目标 / 非目标 / 反目标

**目标**
1. `Invoke-SolCapture` 启动 `sol activate` **之前**先静默执行一次 `sol deactivate`（清残留；失败忽略）。
2. 首次 activate 后若在首个轮询内进程即退出且 `.err` 含 `already active`（仍有会话占用）→ 再 `sol deactivate` 一次 → **重试 activate 一次**（最多一次）。
3. 捕获结束（done/stalled/sessionlost/超时任一）后**无条件** `sol deactivate`（静默释放，失败忽略）。
4. 上述 deactivate/重试不影响既有返回对象与流程（SessionLost/FailHint/Done 语义保持）。
5. 测试：语法 + grep 断言（deactivate 出现于启动前/结束后；重试分支含 'already active'）；test-lib/test-bmc-net 无回归。
6. 打包（逻辑代码变更触发，build.ps1 -Zip）+ 推送远程。

**非目标（不做）**
- 不自动重启 BMC；不无限重试（最多 1 次）。
- 不改 Diag-Bmc / 其它路径；不改 ORT 判定语义。
- 不引入新参数。

**反目标（做了就算失败）**
- deactivate 失败阻塞流程（必须静默忽略）。
- 重试破坏已正常开始的捕获（仅当"进程已退出且 .err 含 already active"才重试；进程存活/有输出绝不重试）。
- 既有调用方（只读 Done/Stalled/SessionLost/FailHint/时间字段）被破坏。

## 3. 约束（已核实事实）

- `Invoke-SolCapture` 位于 scripts/Run-MemtestSuite.ps1（约 L199-290，上一轮加固后）：`Start-Process -PassThru` 启动 `sol activate`，`.err` 重定向到 `$OutFile.err`，轮询 `ev=done` + `$p.HasExited` 早期检测（SessionLost），末尾 `Stop-Process -Force`。
- Diag-Bmc.ps1 的释放模式（L140-144，可直接复用）：EAP 临时切 `Continue`，`& $IpmiTool @($a + @('sol','deactivate')) 2>$null | Out-Null`。
- `$a` 为基础 ipmitool 参数数组（`-I lanplus -H ... -U ... -P ...`），在 Invoke-SolCapture 内已构造。
- 本次实机错误签名：`.err` 内容 `Info: SOL payload already active on another session`。
- 打包纪律（AGENTS.md）：逻辑代码变更 → build.ps1 -Zip（先删旧包）→ 校验 zip 时间戳与关键文件 hash；VERSION 单一来源。

## 4. 方案设计（how）

### 4.1 `scripts/Run-MemtestSuite.ps1` — `Invoke-SolCapture` 改造

**A. 启动前清残留**（构造 `$args` 后、首次 `Start-Process sol activate` 之前）：
```powershell
# 清残留 SOL 会话（失败忽略；同 Diag-Bmc 释放模式）
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $IpmiTool @($args + @('sol', 'deactivate')) 2>$null | Out-Null } catch {}
finally { $ErrorActionPreference = $prevEap }
```

**B. 遇 already active 自动重试一次**：将"启动 activate + 首个轮询判定"提为局部逻辑，首次 `$p.HasExited` 且 `.err` 含 `already active` 时：
```powershell
# 仍有会话占用：再清一次并重试（最多一次）
if (-not $retried -and $sessionLost -and $failHint -match 'already active') {
    $retried = $true
    # 再次 sol deactivate（静默）
    ...同 A 模式...
    # 重新 Start-Process sol activate，重置 $p/$sessionLost/$failHint/$done，重新进入轮询
    $p = Start-Process -FilePath $IpmiTool -ArgumentList ($args + @('sol','activate')) `
            -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err" -PassThru -WindowStyle Hidden
    $sessionLost = $false; $failHint = ""; $done = $false
    # 继续原轮询循环（循环结构需支持"retried 后继续"）
}
```
（实现上：把轮询循环放进可重复进入的结构，或把"启动+首轮检查+重试"收敛为一个内层辅助——builder 自行取舍，须保持既有轮询/停滞/超时逻辑不变。`.err` 内容在重试前重新读取判断。）

**C. 结束时无条件释放**（`Stop-Process` 之后、return 之前）：
```powershell
# 释放 BMC 端 SOL payload（失败忽略）
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { & $IpmiTool @($args + @('sol', 'deactivate')) 2>$null | Out-Null } catch {}
finally { $ErrorActionPreference = $prevEap }
```

**D. 返回对象/字段语义保持**：Done/Stalled/SessionLost/FailHint/CaptureStart/CaptureEnd 不变；重试后 SessionLost 反映最终状态。

### 4.2 测试

- 语法检查（`[scriptblock]::Create`）。
- grep 断言：`sol deactivate` 出现 ≥2 处（启动前 + 结束后）；重试分支含 `already active` 与 `-match`；`$retried` 存在。
- 既有 `tests/test-lib.ps1`、`tests/test-bmc-net.ps1` 全绿。
- 行为（实机，用户侧）：r1 PASS 后立刻跑下一轮不再撞 "already active"。

### 4.3 文档同步

- `docs/20` 流程 2 指引第 ③ 条措辞微调（"残留 SOL 会话：脚本已自动释放/重试；仍报错再手动 sol deactivate"）——可选，保持与行为一致。

## 5. 交给 builder 的决策点

- 重试的循环结构组织方式（内层辅助 vs 标志位）——builder 判断，保持既有轮询/停滞/超时语义不变。
- `.err` 在重试判定前的读取时机——builder 判断，取首个轮询周期内已写入的内容。

## 6. 验收口径

1. **静态**：语法 OK；grep 断言（deactivate 两处 + already active 重试分支 + $retried）；test-lib/test-bmc-net 全绿。
2. **行为推演**：读代码确认——deactivate 失败被吞（2>$null + catch）；重试仅当"进程已退出 + .err 含 already active"；重试最多 1 次。
3. **实机（前置，用户侧）**：r1 PASS 后立即重跑 10 分钟 ORT → 不再报 already active，正常捕获到输出。
4. **打包**：build.ps1 -Zip → zip 时间戳当前、Run-MemtestSuite.ps1 hash 与仓库一致；推送远程。

## 7. 待办与已知风险

- deactivate 在 BMC 完全不可达时失败——已静默忽略，不阻塞（本次撞车场景 BMC 可达）。
- 重试逻辑新增复杂度集中在一个函数内；若实测发现 .err 读取时序问题（首个轮询时 .err 未写入），builder 可改为"检测 HasExited 且 .err 非空即判定"（保守方向）。
