# BMC 网络防护与断电循环风险警示 —— 设计文档

> 日期：2026-10-28 ｜ 状态：待执行 ｜ 关联：[21-BMC网络与IP恢复方案.md](../../21-BMC网络与IP恢复方案.md)（故障处理沉淀）
> 变更记录：
> - 2026-10-28 v1 初稿：依据 10-28 真实故障根因链设计（断电循环 × 共用电源 → 编排机 Code 43 + BMC IP 丢失）。
> - 2026-10-28 v1.1：builder-check 三问裁决（§4.1 回读兜底判据 / §4.3A lan print 失败 fail-closed / §4.6 VerifyPowerCycle 同步警示）。

## 1. 背景与意图（why）

2026-10-28 真实故障：编排机连不上 BMC 10.0.0.10，本机有线网卡 Code 43，BMC 无有效 IP（IP 源变 DHCP 且管理网无 DHCP 服务器）。系统排查（本项目全部脚本 + cmdlog + results + 用户物理拓扑确认）得到的**根因链**：

```
Run-MemtestSuite -RestartLoop / -VerifyPowerCycle / 手动 ipmitool
        └── chassis power cycle（真断电，几十~200 次）
                │
                ├─【编排机与被测服务器共用同一插线板/PDU】
                │        └─→ 每次断电/上电电压跌落 → 编排机 I219-V 网卡 Code 43 → 管理网断
                │        └─→ 被测服务器系统网卡同样被电压跌落打坏 → Windows 配不了 IP
                │
                └─【服务器被反复硬断电】→ BMC 反复冷启动
                        └─→ AMI 固件 bug：IP 源回退 DHCP（管理网无 DHCP → 无地址）
                        └─→ 恢复静态 IP 只能 ipmiutil raw 命令绕（BIOS 静默失败）
```

**关键事实**：本项目所有脚本**从不修改任何 IP/网卡配置**，只把 BMC 10.0.0.10 当作已存在前提来连接；唯一"动电"的操作是 `chassis power cycle`（[Run-MemtestSuite.ps1](../../scripts/Run-MemtestSuite.ps1) `Invoke-PowerCycleLoop`、[Check-ServerCapabilities.ps1](../../scripts/Check-ServerCapabilities.ps1) `-VerifyPowerCycle`）。BMC 静态 IP 恢复目前只能靠文档 21 的**手工 raw 命令**。

目标：把"恢复 BMC 静态 IP"固化为可复用脚本；测试启动前自动体检 BMC 健康与 IP 源；断电循环执行前警示共用电源风险；把根因链沉淀进文档 21，避免每次测试后手工救火。

## 2. 目标 / 非目标 / 反目标

**目标**
1. 新增 `scripts/Set-BmcStaticIp.ps1`：在**被测服务器本机 Windows** 运行（本地接口，BMC 无 IP 时远程不可达），用 ipmiutil raw 命令把 BMC LAN 参数设为静态 IP/掩码，参数化 `-Ip/-Mask/-Gateway`；支持只读检查模式（查 IP 源）。参考文档 21 §5.2 命令序列。
2. `lib_common.ps1` 新增 BMC 前置体检函数（编排机侧，ipmitool lanplus）：`mc info` 可达性 + `lan print` 检查 IP 源是否静态；返回结构化结果。
3. `Run-MemtestSuite.ps1` SOL 路径（普通 + ORT）在 SOL 捕获前接入前置体检；BMC 不可达 / IP 源非静态 → **中止并打印恢复指引**（引 Set-BmcStaticIp）。
4. `Invoke-PowerCycleLoop` 循环开始前打印共用电源风险警示（编排机 Code 43 风险 + 建议先停 SOL / 独立电源）；循环结束后可选复核 BMC 仍在线。**同警示同样加给 `Check-ServerCapabilities -VerifyPowerCycle`**（同为"动电"入口，根因链同样适用，见 §4.6）。
5. 新增 `tests/test-bmc-net.ps1` 覆盖前置体检分支（复用 fake-ipmitool fixture 模式）；`test-lib.ps1` 等既有用例全绿。
6. 文档同步：21 号文档补根因链 + 三层预防措施；`-Help` 文案同步；memtest 镜像目录同步（打包时自动）。
7. 重新打包（逻辑代码变更触发，`build.ps1 -Zip`）+ zip 校验。**注意 `build.ps1` 的 `$scriptFiles` 显式白名单：新增 `scripts/Set-BmcStaticIp.ps1` 必须加入白名单与 `$keyFiles`，否则 zip 里缺失且 hash 校验覆盖不到**（有先例：prime95 计划同样处理 Run-Prime95Stress.ps1）。

**非目标（不做）**
- 不做"自动等待 BMC 恢复后继续"（用户已定：中止 + 打印指引）。
- 不自动执行恢复（恢复只能在被测服务器本机跑，编排机无路可通；由指引带用户去跑 Set-BmcStaticIp）。
- 不改 BMC 固件 / 不解决 BIOS 静默失败 bug 本身（属厂商问题，raw 命令是绕行方案）。
- 不改编排机网卡 Code 43 修复流程（已有文档 21 §3；物理电源隔离是用户侧动作）。
- 不为"服务器系统网卡别再配 10.0.0.10"写脚本（属操作规范，进文档提示即可）。

**反目标（做了就算失败）**
- 恢复脚本把 BMC 配置写坏（参数校验 + 写前读 + 写后回读校验必须）。
- 前置体检误伤正常测试（BMC 可达且 IP 源静态时必须放行；非 SOL 方式不触发）。
- 断电循环被意外阻塞（警示不阻断执行；ConfirmSwitch 仍是唯一门禁）。
- 破坏既有 cmdlog / 报表 / master_manifest 结构；既有测试用例回归。

## 3. 约束（已核实事实）

- PowerShell 5.1；脚本沿用既有约定：dot-source `lib_common.ps1`、`Write-CmdLog`（Start/End + 密码打码）、`Get-AppVersion`（仅报表类用）、`Read-BmcPass`（管道/交互）、`Invoke-IpmiProbe`（stdout/stderr 分离安全包装）。
- 工具：内置 `tools\ipmitool\ipmitool.exe`（Windows，**缺本地 open 接口**，只做 lanplus 远程）；`tools\ipmiutil-win64\`（含 DLL，**本地接口**，用于被测服务器本机恢复）。
- 文档 21 §5.2 raw 命令序列（已实机验证有效）：
  - 验证通道：`ipmiutil.exe cmd 00 20 30 02 01 03 00`
  - IP 源=静态：`ipmiutil.exe cmd 00 20 30 01 01 04 01`（成功标志 len=1）
  - IP=10.0.0.10：`ipmiutil.exe cmd 00 20 30 01 01 03 0a 00 00 0a`（大端）
  - 掩码=255.255.255.0：`ipmiutil.exe cmd 00 20 30 01 01 06 ff ff ff 00`
  - 网关：可选，设 0.0.0.0 返回 d5（不支持）属正常
  - 生效：`ipmiutil.exe reset -c`（BMC 冷复位，服务器短暂息屏 1~2 分钟属正常）
  - 回读：`ipmiutil.exe lan -c 1` → `Lan Param(3) IP address` / `Lan Param(4) IP addr src`（01=静态 / 02=DHCP / 00=未指定）
- `ipmiutil lan -s` 报 Bus Error（读 SOL 配置失败导致中止）→ 恢复**只用 raw 命令**。
- ipmitool `lan print` 输出含 `IP Address Source : Static Address|DHCP Address|Unspecified`（不同版本文案有差异，解析需容错：文本含 `Static` 或值 `01`）。
- 测试基础设施：`tests/fixtures/fake-ipmitool.cmd` + `test-lib.ps1`（既有模式：调用 fake 工具断言输出/分支）；tests 由 `tests\test-*.ps1` 独立脚本组成，无统一 runner（各脚本直接运行断言）。
- 打包纪律（AGENTS.md）：逻辑代码变更 → `build.ps1 -Zip`（先删旧 zip 再建新包）→ 校验 zip 时间戳与包内 hash 一致；`memtest/` 镜像目录由 build 自动同步。
- 文档标记：docs 下 `[当前有效]` 标记；21 号文档保持有效并追加内容。

## 4. 方案设计（how）

### 4.1 `scripts/Set-BmcStaticIp.ps1`（新增）

定位：在被测服务器本机 Windows 运行（本地接口），一键查询/恢复 BMC 静态 IP。**不支持远程**（BMC 无 IP 时远程不可达；远程体检由前置体检函数负责）。

参数：
```powershell
param(
    [string]$Ip = "10.0.0.10",        # 目标静态 IP
    [string]$Mask = "255.255.255.0",  # 子网掩码
    [string]$Gateway = "",            # 网关（默认不设；设 0.0.0.0 返回 d5 忽略）
    [string]$IpmiUtil = "",           # 默认自动发现 tools\ipmiutil-win64\ipmiutil.exe（校验 DLL 随目录）
    [switch]$CheckOnly,               # 只读：查当前 IP/掩码/IP 源并显示，不写
    [switch]$Help
)
```

流程（管理员 CMD/PowerShell）：
1. `Write-CmdLog -Script 'Set-BmcStaticIp' -State Start`；管道密码不需要（本地接口无需密码）。
2. 自动发现 ipmiutil：`<包根>\tools\ipmiutil-win64\ipmiutil.exe`；不存在 → 报错退出（提示拷整个目录含 DLL）。
3. IP 参数校验：IPv4 四段数字；掩码合法；无效 → 报错退出（防写坏）。
4. 读现状：`ipmiutil.exe lan -c 1`，解析 `Lan Param(3) IP address`、`Lan Param(4) IP addr src`、`Lan Param(5) MAC addr`。`-CheckOnly` → 打印现状 + 判定（静态/正常或 DHCP/未指定需恢复），`Write-CmdLog End`，退出。
5. 写（仅非 CheckOnly）：按文档 21 §5.2 顺序逐条 raw 命令；每条检查退出码（作为过程提示，**不作最终判据**）；**写前先确认 IP 源已设为静态（参数 04）成功**。
6. **回读兜底判据（最终成败以回读为准）**：`lan -c 1` 核对 IP/掩码/IP 源与目标一致即为成功；不一致 → 失败退出（防写坏）。raw 命令的输出/退出码仅作过程提示（`ipmiutil cmd` 输出形态不同版本有差异、退出码可能恒 0，失败要靠输出解析——故不依赖它判成败，回读兜底；"成功标志 len=1"、"d5 网关不支持属正常"仅作参考日志）。**计划需包含"在被测服务器实机先采集一次 raw 命令真实输出、校准过程提示解析"的前置任务**（文档 21 §7 已标注需复验）。
7. 提示执行 `ipmiutil.exe reset -c` 冷复位生效（脚本不自动执行，避免编排中意外断网；由用户确认时机执行——文档 21 §5.2 ⑥）。加 `-ColdReset` 开关可让脚本自动执行（默认 off）。
8. `Write-CmdLog End`（OK/FAIL + 退出码）。

### 4.2 `scripts/lib_common.ps1`（新增函数）

**`Invoke-BmcPreflight`**（编排机侧，远程 lanplus）：
```powershell
function Invoke-BmcPreflight {
    param([string]$BmcHost, [string]$BmcUser, [string]$BmcPass, [string]$IpmiTool = "ipmitool")
    # 返回 [PSCustomObject]@{ Reachable=[bool]; IpSourceStatic=[bool]; Detail=[string] }
}
```
- 复用 `Invoke-IpmiProbe` 安全包装（工具缺失/终止错误也转 Code=1 结果，不抛未捕获异常）。
- ① 可达性：`ipmitool -I lanplus -H <host> -U <u> -P <p> mc info`（可含 -C 3/-C 17 回退，同 Diag-Bmc）；失败 → `Reachable=$false`。
- ② IP 源：`ipmitool -I lanplus -H <host> -U <u> -P <p> lan print 1`；解析 `IP Address Source`（容错：文本 `Static` 或值 `01`）；`IpSourceStatic = ($out -match 'Static|01')`（排除 `Static Address` 之外的误匹配需按上下文处理，见 §5 决策点）。
- `Detail` 汇总关键行（IP/源/MAC），便于打印。

**（可选）`Get-BmcLanStatus`**：抽取 `lan print 1` 解析逻辑（IP/源/MAC），供 preflight 与诊断复用。若仅一处使用则不抽（避免过度抽象）。

### 4.3 `scripts/Run-MemtestSuite.ps1`（改造）

**A. SOL 前置体检（接入点）**：在 BMC 密码已解析（L173 之后）、`Write-Host "===== Memtest86+ 编排开始"` 附近，当 `$BootMethod -eq 'SOL' -and $BmcHost` 时调用 `Invoke-BmcPreflight`（ORT 分支同点覆盖，因其在 SOL 捕获前）：
- `Reachable=$false` → 打印指引（① 编排机网卡 Code 43 先修（文档 21 §3）② BMC 无 IP 则去被测服务器跑 `Set-BmcStaticIp -CheckOnly`/恢复），`Write-CmdLog End` + `exit 1`。
- `Reachable=$true -and IpSourceStatic=$false` → 打印警告 + 指引（IP 源非静态，断电循环后易丢 IP；建议 `Set-BmcStaticIp` 恢复为静态后再跑），按用户已定策略**中止**（`Write-CmdLog End` + `exit 1`）。
- `Reachable=$true -and lan print 读取失败`（非认证原因，如旧版 ipmitool / BMC 权限限制 / 临时超时）→ **重试 2 次（间隔 5s）**；仍失败 → fail-closed **中止**，打印"无法确认 IP 源是否静态，请人工核实（`Set-BmcStaticIp -CheckOnly`）后重跑"（与用户"宁可中止"立场一致；该分支计入 `test-bmc-net.ps1` 测试矩阵）。
- 通过 → 正常继续（打印一行 `[OK] BMC 前置体检通过：IP 源静态`）。
- `-ParseOnly` / 非 SOL 方式不触发。

**B. `Invoke-PowerCycleLoop` 风险警示**：循环 `for` 之前打印警示块：
```
⚠️ 断电循环风险提示
- chassis power cycle 是真断电；若编排机与被测服务器共用同一插线板/PDU，
  反复断电的电压跌落可能导致编排机网卡 Code 43、被测服务器网卡/BMC 异常（本次 10-28 故障根因）。
- 建议：① 编排机先换独立电源回路；② 开始前先停掉本机正在跑的 SOL/长连接；③ 循环中勿动编排机。
- 循环结束后将自动复核 BMC 是否仍在线（调用 Invoke-BmcPreflight 只读检查）。
```
- 循环结束后：调用 `Invoke-BmcPreflight`，打印复核结果（BMC 掉线 → 提示用 Set-BmcStaticIp 恢复）；**不阻断**（仅提示）。

### 4.4 `tests/test-bmc-net.ps1`（新增）

复用 `tests/fixtures/fake-ipmitool.cmd` 模式（或新增 fake-ipmiutil fixture）：
- `Invoke-BmcPreflight` 分支：mc info 失败（Reachable=false）；mc info 成功 + lan print 无 Static（IpSourceStatic=false）；两者通过（全 true）。
- 容错解析：lan print 输出含 `IP Address Source : Static Address` → true；含 `DHCP Address` / `Unspecified` → false。
- 断言输出/返回结构字段，不依赖真实 BMC。
- 运行方式与既有 tests 一致（直接 `.\tests\test-bmc-net.ps1`，断言失败非零退出）。

### 4.5 文档同步

- `docs/21-BMC网络与IP恢复方案.md`：
  - 新增章节：根因链（断电循环 × 共用电源 → Code 43 + BMC IP 丢失）与三层预防措施（物理/操作、脚本、文档）；
  - §5 工具准备处引用 `Set-BmcStaticIp.ps1` 作为"一键恢复"替代手工 raw 命令；
  - 提示：被测服务器系统网卡**勿配 10.0.0.10**（那是 BMC 的 IP，配了必冲突）。
- `memtest/docs/21-…` 由打包自动同步（build.ps1）。
- `Run-MemtestSuite.ps1 -Help` 与 `Run-BatchScheduler` 帮助文案：SOL 方式说明补"启动前自动 BMC 前置体检"。
- （可选）`docs/20-纯命令行压测手册.md` 流程 5（断电循环）补风险提示 + 编排机独立电源要求。

### 4.6 `scripts/Check-ServerCapabilities.ps1`（改造，`-VerifyPowerCycle` 同警示）

根因链点名两个"动电"入口，`-VerifyPowerCycle`（真下发 `chassis power cycle`）同样适用。在 `VerifyPowerCycle` 执行序列（baseline → cycle → 轮询）**之前**打印与 §4.3 B 相同的共用电源风险警示块（复用一段共享文案或函数）；`-VerifyPowerCycle` 开关本身即同意（既有行为），警示**不阻断**。此改造同时把警示收敛到 lib_common（一段函数 `Write-PowerCycleWarning` 供两处调用，避免文案漂移）。

## 5. 交给 builder 的决策点

- **lan print 解析容错**：不同 ipmitool 版本 `IP Address Source` 文案（`Static Address` vs 值 `01`）。解析优先文本 `Static`（大小写不敏感、排除 `IP Address` 行内其它词）；若实机发现文案不同，补分支。此为 builder 判断项，不改变方案结构。
- **`Get-BmcLanStatus` 是否抽取**：若 preflight 仅此一处解析 `lan print`，则不抽（避免过度抽象）；若 `Set-BmcStaticIp` 回读也想复用远程解析（虽然它走本地 lan -c 1，格式不同），保持各自解析。
- **已裁决项（v1.1，无需再问用户）**：
  - lan print 失败 → fail-closed（重试 2 次仍失败则中止），与用户"宁可中止"立场一致；
  - raw 命令成败以**回读兜底**为准，过程输出仅参考；计划含实机采集校准任务；
  - `-VerifyPowerCycle` 同步加警示（同为动电入口）；
  - `Set-BmcStaticIp` 默认不自动 `reset -c`，提供 `-ColdReset` 开关（默认 off）。

## 6. 验收口径

1. **单元**：`tests/test-bmc-net.ps1` 全绿（含 lan print 失败重试分支）；`test-lib.ps1` 等既有用例无回归。
2. **静态**：新增/改动脚本语法检查通过（`Get-Command`/`[scriptblock]::Create` 或 pwsh 解析）。
3. **本机 dry 验证**：`Set-BmcStaticIp -CheckOnly` 在无 ipmiutil 环境报错路径正确；fake fixture 断言 preflight 分支。
4. **实机采集（前置任务，用户侧）**：在被测服务器本机跑一次 `ipmiutil.exe cmd 00 20 30 02 01 03 00` + `lan -c 1`，抓真实输出供过程提示解析校准（成功/失败形态），记录到文档 21 或测试注释。
5. **实机（前置，用户侧）**：在被测服务器本机跑 `Set-BmcStaticIp -CheckOnly` 看到当前 IP 源；若 BMC 已掉线，跑恢复命令后 `lan -c 1` 回读静态；编排机重跑 `Run-MemtestSuite` 前置体检通过后正常开测。
6. **打包**：`build.ps1 -Zip`（先删旧包）→ zip 时间戳当前、包内关键文件 hash 与仓库一致；确认 zip 内含 `scripts/Set-BmcStaticIp.ps1`（白名单已加）。

## 7. 待办与已知风险

- raw 命令实机复验：文档 21 已实机成功一次，但脚本化后需再跑一次确认参数拼接与回读判据无偏差（验收口径 4/5）。
- `reset -c` 冷复位期间服务器短暂息屏 1~2 分钟：恢复脚本提示用户避开测试窗口执行。
- preflight 对 BMC 可达但 IP 源非静态的**中止**策略是用户明确选择（宁可中止也不让"每次测试后丢 IP"反复发生）；若未来有 DHCP 可用的管理网，需再评估（记录在案）。
- 编排机 Code 43 的物理电源隔离是用户侧动作，脚本只能警示无法根治。
- `lan print` 文案差异：若实机 ipmitool 输出不含 `Static` 字样，需按实际补解析分支（builder 判断项，不影响结构）。
