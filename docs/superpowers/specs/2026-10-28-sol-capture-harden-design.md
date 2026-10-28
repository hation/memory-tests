# SOL 捕获加固：会话断开早期检测 + 行动指引 —— 设计文档

> 日期：2026-10-28 ｜ 状态：待执行 ｜ 关联：[21-BMC网络与IP恢复方案.md](../../21-BMC网络与IP恢复方案.md)、[15-BMC排查方案.md](../../15-BMC排查方案.md)
> 变更记录：
> - 2026-10-28 v1 初稿：依据实机故障（SOL 会话打开但零输出 + keepalive 超时断开，Run-MemtestSuite 静默空转至中断 → 无报告/无清单）设计。

## 1. 背景与意图（why）

2026-10-28 实机（C:\memtest 部署）故障：
- 17:47 Run-MemtestSuite（SOL，MaxPasses 1）启动；SOL 会话打开（mtlog 仅 `[SOL Session operational]` 45 字节）；
- 17:50 ipmitool 报 `No response to keepalive - Terminating session`，**会话断开**，但 `Invoke-SolCapture` 的轮询循环继续等到 deadline（`MaxPasses*90+30` = 120 分钟）；
- 编排机空转无反馈，最终被中断 → **无 End 记录、无报告 CSV、无任务清单更新**，用户误以为"测完了清单不更新"。

已实测：空日志经 `Invoke-MtlogParser` 可正常解析为 `FinalStatus=INCOMPLETE, Passes=0`（不抛异常）——即**若脚本没有被中断、而是等到超时，parse→report→checklist 留痕路径本就存在**。真正的缺陷是：
1. **会话断开不感知**：ipmitool 进程已退出（HasExited），循环仍空转至 deadline；
2. **无行动指引**：超时提示仅"未收到 ev=done"，不告诉用户查什么（虚拟介质引导/串口重定向/SOL 会话/BMC 链路）；
3. **空转无反馈**：用户不知道是正常等待还是已经失败。

目标：会话断开时**立即结束捕获**并打印**可执行的排查指引**，失败留痕（报告 INCOMPLETE + 清单 ✗）继续生效。

## 2. 目标 / 非目标 / 反目标

**目标**
1. `Invoke-SolCapture` 轮询循环检测 ipmitool 进程已退出（`$p.HasExited`）且输出无 `ev=done` → **提前结束**（不等 deadline），返回会话断开标记。
2. 返回对象扩展：`SessionLost=[bool]`、`FailHint=[string]`（携带 .err 真实错误如 keepalive）。
3. 主流程（SOL 普通分支 + ORT SOL 分支）在 `-not $cap.Done` 时打印**行动指引块**（四查：虚拟介质引导 / BIOS 串口重定向 115200 / sol deactivate 清会话 / BMC 链路与静态 IP）。
4. 超时/断开后仍走 parse→report→checklist（现状已支持，保持并验证）。
5. 测试：空日志解析回归（INCOMPLETE）+ 语法检查 + grep 断言指引存在；既有 test-lib/test-bmc-net 无回归。
6. 文档：docs/20 流程 2 补"SOL 无输出排查指引"；打包（逻辑代码变更触发，build.ps1 -Zip）。

**非目标（不做）**
- 不改 ORT 时长/温度语义；不自动重试捕获；不自动切换 USB 方式。
- 不改 Serial/USB/EFI 路径。
- 不做 SOL 会话自动 deactivate（指引用户手动执行即可，避免编排中误操作）。

**反目标（做了就算失败）**
- 正常捕获被误判断开（进程存活期间不得提前退出；检测条件是 `HasExited` 且无 `ev=done`）。
- 指引误导（虚拟介质/串口重定向/SOL 会话/BMC 四查必须准确，文案与文档 15/20 一致）。
- 破坏既有 cmdlog / 报告 / 清单结构；既有测试回归。

## 3. 约束（已核实事实）

- `Invoke-SolCapture` 位于 [Run-MemtestSuite.ps1](../../scripts/Run-MemtestSuite.ps1)（L199-249）：`Start-Process -PassThru` 拿到 `$p`，轮询 `Select-String ev=done`，结束时 `Stop-Process -Force`；返回 `@{ Done; Stalled; CaptureStart; CaptureEnd }`。
- 非 ORT 模式无 stall 检测（`MaxStallMin` 仅 ORT 传入）；ORT 模式传 `MaxStallMin=OrtMaxGapMin`。
- `.err` 文件 = ipmitool stderr 重定向（`-RedirectStandardError "$OutFile.err"`），keepalive 错误在其中。
- 空日志解析：`Invoke-MtlogParser` 返回 `FinalStatus=INCOMPLETE, PassesCompleted=0`（已实测，不抛异常）。
- 主流程 SOL 分支（L573-578）与 ORT SOL 分支（L510-516）调用 `Invoke-SolCapture`，`-not $cap.Done` 时目前仅 `Write-Warning`。
- 既有约定：`Write-CmdLog`、lib_common 函数库、tests 断言风格（test-lib.ps1 等）；打包纪律（AGENTS.md）。

## 4. 方案设计（how）

### 4.1 `scripts/Run-MemtestSuite.ps1` — `Invoke-SolCapture` 扩展

轮询循环（L224-241）内、`Start-Sleep 10` 后增加：
```powershell
# 会话断开早期检测：ipmitool 已退出且未收到 ev=done → 立即结束（不等 deadline）
if ($p.HasExited -and -not $done) {
    $sessionLost = $true
    $failHint = "SOL 会话断开（ipmitool 已退出）"
    break
}
```
循环外（return 前）：
- `$failHint` 初始 `""`；从 `$OutFile.err` 读取真实错误（`Get-Content -Raw`，失败忽略）追加到 `$failHint`；
- 返回对象扩展：`@ { Done; Stalled; SessionLost; FailHint; CaptureStart; CaptureEnd }`（SessionLost 默认 `$false`，不影响既有调用方——既有代码只读 Done/Stalled/时间字段）。

### 4.2 指引函数（`scripts/Run-MemtestSuite.ps1` 内新增 `Write-SolTroubleshootHint`）

```powershell
function Write-SolTroubleshootHint {
    param([string]$FailHint = "")
    Write-Host ""
    Write-Host "⚠️ SOL 未收到 Memtest86+ 输出（或会话中断），按序排查："
    Write-Host "  ① 引导方式：必须是 BMC 虚拟介质挂载 memtest-sol.iso（Ventoy U 盘引导时串口走物理 COM，SOL 收不到）；"
    Write-Host "  ② BIOS 串口重定向（Console Redirection → SOL）须开启，波特率 115200 三处一致；"
    Write-Host "  ③ 残留 SOL 会话：sol deactivate 清掉再跑（session already active）；"
    Write-Host "  ④ BMC 链路：编排机能 ping 通 10.0.0.10；被测服务器本机跑 Set-BmcStaticIp.ps1 -CheckOnly 确认 IP 源静态。"
    if ($FailHint) { Write-Host ("  底层错误: " + $FailHint) }
    Write-Host "  参考：docs/15-BMC排查方案.md §3、docs/20 流程 2。"
}
```

### 4.3 主流程接入（SOL 普通分支 + ORT SOL 分支）

两处 `if (-not $cap.Done) { Write-Warning ... }` 改为：
```powershell
if (-not $cap.Done) {
    Write-Warning ("SOL 捕获未收到 ev=done（Done=$($cap.Done) Stalled=$($cap.Stalled) SessionLost=$($cap.SessionLost)）")
    Write-SolTroubleshootHint -FailHint $cap.FailHint
}
```
（ORT 分支 L577 同改；超时/断开后继续 parse→report→checklist 逻辑不变，保证失败留痕。）

### 4.4 测试

- `tests/test-lib.ps1` 或新建 `tests/test-sol-capture.ps1`：回归"空日志解析 INCOMPLETE"（防解析回归）；`Invoke-SolCapture` 的 HasExited 分支不易单测（真实 ipmitool），以语法检查 + grep 断言（`SessionLost`、`Write-SolTroubleshootHint`、四查文案关键词）覆盖。
- 既有 `test-lib`/`test-bmc-net` 无回归。

### 4.5 文档同步

- `docs/20-纯命令行压测手册.md` 流程 2：补"SOL 无输出/会话中断排查指引"（四查），与 4.2 文案一致。
- `docs/15-BMC排查方案.md` 若已有对应内容则只加交叉引用（§3 已有现象-处理表）。

## 5. 交给 builder 的决策点

- 无。四查文案、返回字段、接入点均已固定；`FailHint` 读取 .err 失败时留空（不抛异常）。

## 6. 验收口径

1. **单元**：空日志解析 INCOMPLETE 回归 + 既有 test-lib/test-bmc-net 全绿。
2. **静态**：Run-MemtestSuite 语法检查通过；grep 断言 `SessionLost`/`Write-SolTroubleshootHint`/四查关键词。
3. **行为推演**：模拟 ipmitool 立即退出的场景（用假工具或直接读代码）确认 HasExited 分支会在首个轮询周期 break，不等待 deadline。
4. **实机（前置，用户侧）**：修 SOL 链路后重跑 1 轮全项，SOL 正常收到输出 → ev=done → 报告 + 清单更新（验证加固未破坏正常路径）；若 SOL 仍断 → 立即打印四查指引而非空转。
5. **打包**：`build.ps1 -Zip`（先删旧包）→ zip 时间戳当前、关键文件 hash 与仓库一致。

## 7. 待办与已知风险

- `$p.HasExited` 在进程刚启动尚未完全建立时可能为 false——首个轮询（10s 后）再判，误判风险低；若实测首个周期即误报，可加"输出文件有内容则不算断开"的次级条件（builder 判断）。
- `.err` 读取在文件被占用时可能报错——`-ErrorAction SilentlyContinue` 包裹。
- 加固只解决"感知与指引"；SOL 链路本身（虚拟介质/串口重定向/BMC 网络）需用户侧按指引修复，脚本无法根治。
