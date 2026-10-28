# 21 · BMC 网络与静态 IP 恢复方案

> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 记录 2026-10-28 真实故障：编排机连不上 BMC 10.0.0.10，最终用 ipmiutil raw 命令绕过 BIOS 界面恢复静态 IP。

> 状态：[当前有效]（2026-10-28）
> 变更记录：2026-10-28 创建（实际故障处理全流程沉淀，含两个关键坑：本机网卡 Code 43、BMC BIOS 设静态 IP 失败）
> 适用：编排机 ping 不通 BMC、BMC 管理口灯亮但无 IP、BIOS 里设静态 IP 报错/无提示失败。
> 前置：内置 ipmitool `tools\ipmitool\ipmitool.exe`；备用工具 ipmiutil `tools\ipmiutil-win64\ipmiutil.exe`（Windows 版 3.21，含依赖 DLL）。

---

## 1. 故障现象与结论速查

| 现象 | 结论 |
| --- | --- |
| 编排机 `ping 10.0.0.10` 100% 超时 | 可能本机链路或 BMC 侧，见第 2/3 节 |
| 本机有线网卡设备管理器带感叹号（Code 43） | 网卡驱动层故障，先修本机（第 3 节） |
| BMC 管理口灯亮，但网段里扫不到它 | BMC 无有效 IP（IP 源 = Unspecified 或 DHCP 拿不到） |
| BIOS 里设 BMC 静态 IP 失败（无提示直接失败） | BMC 固件 bug，**别死磕界面**，用第 5 节 raw 命令 |
| `ipmiutil lan -s` 报 Bus Error | 读 SOL 配置失败所致，**设置可能没写入**，改用 raw 命令 |

---

## 2. 排查顺序（先本机，再 BMC）

1. **本机侧**：`ipconfig /all`、`arp -a`、`route print` 确认有没有到管理网段（10.0.0.0/24）的路径；
2. **本机网卡**：`Get-NetAdapter` / 设备管理器看有线网卡是否 Code 43（故障时会连链路都检测不到）；
3. **BMC 侧**：管理口灯亮 = BMC 有电有链路；全段扫 623/443/80 无命中 = BMC 无有效 IP；
4. **确认 BMC IP 状态**：进服务器系统用 ipmiutil `lan -c 1` 看 `Lan Param(4) IP addr src`（01=静态 / 02=DHCP / 00=未指定）与 `Lan Param(3) IP address`。

---

## 3. 本机有线网卡 Code 43（设备管理器感叹号）修复

症状：有线网卡 `MediaConnectionState: Unknown`、`LinkSpeed 0 bps`、`Get-PnpDevice` 显示 `Code 43`。

修复顺序（由轻到重）：

1. **重启电脑**（最常见，驱动挂死重启即恢复）；
2. 设备管理器 → 右键网卡 → **禁用 → 启用**（重置驱动栈）；
3. 设备管理器 → 右键 → **卸载设备（勾选"删除此设备的驱动程序"）→ 操作 → 扫描检测硬件改动**；
4. 仍失败 → 下载官方驱动重装；再不行大概率硬件故障，用 **USB 转 RJ45 网卡** 替代。

> 注意：网卡 Code 43 期间，即使插着网线 `ipconfig` 里也看不到该网卡、静态 IP 配置被隐藏；恢复后自动回来。

---

## 4. BMC 侧判断（管理口灯亮但无 IP）

BMC 灯亮只代表链路层（PHY）有电，**不代表 BMC 有 IP**。典型卡死状态：IP 源 `Unspecified` / DHCP 模式但网内无 DHCP 服务器 → BMC 永远拿不到地址 → 全段扫描 623/443 无命中。

在服务器系统内用 ipmiutil 本地接口确认（`lan -c 1` 能打印配置 = 本地接口正常）：

```bat
ipmiutil.exe lan -c 1
```

关键输出行：
- `Lan Param(3) IP address: 0.0.0.0` → 当前无地址
- `Lan Param(4) IP addr src: 02 : DHCP` → 现在是 DHCP 模式
- `Lan Param(5) MAC addr: e8 61 1a b0 0e e6` → 记住 BMC MAC，稍后从本机 ARP 表核对上线

---

## 5. 核心方案：ipmiutil raw 命令设置静态 IP（绕过 BIOS 界面）

**背景**：海光（Hygon，AMI BMC 定制）BIOS 里设静态 IP **无提示直接失败**（固件 bug）；`ipmiutil lan -s` 也因内部读取 SOL 配置失败报 **Bus Error** 而中止写入。最终用 **raw 命令**（Set LAN Configuration Parameters，NetFn 0x0C）逐参数写入，成功。

### 5.1 工具准备

- 位置：`tools\ipmiutil-win64\`（**整个目录拷贝，含 ipmiutil.exe + libcrypto-3-x64.dll + libssl-3-x64.dll**，只拷 exe 会报 DLL 缺失）；
- 在**服务器系统**（Windows/Linux）内运行，走本地接口，不需要 BMC 有 IP；
- Windows 版内置 ipmitool 缺本地 `open` 接口（`Error loading interface Open`），所以用 ipmiutil。

> 一键恢复（2026-10-28 起，替代手工逐条 raw 命令）：
> `.\scripts\Set-BmcStaticIp.ps1 -CheckOnly`（查询现状并判定）/ `.\scripts\Set-BmcStaticIp.ps1`（恢复 `10.0.0.10/255.255.255.0`，**管理员运行**）。
> `memtest.zip` 内脚本路径同构（`C:\memtest\scripts\Set-BmcStaticIp.ps1`）。

### 5.2 命令序列（管理员 CMD，逐条执行）

```bat
cd /d D:\ipmiutil-win64

:: ① 验证 raw 通道（Get LAN 参数；若报 c7 数据长度无效，可加 set selector 字节 00）
ipmiutil.exe cmd 00 20 30 02 01 03 00

:: ② 设置 IP 源 = 静态 (01)   ← 成功标志：len=1
ipmiutil.exe cmd 00 20 30 01 01 04 01

:: ③ 设置 IP = 10.0.0.10      ← 0a 00 00 0a（大端）
ipmiutil.exe cmd 00 20 30 01 01 03 0a 00 00 0a

:: ④ 设置掩码 = 255.255.255.0
ipmiutil.exe cmd 00 20 30 01 01 06 ff ff ff 00

:: ⑤ 网关：可跳过。管理网直连无需网关；设 0.0.0.0 会返回 d5（不支持）属正常
:: ipmiutil.exe cmd 00 20 30 01 01 0c 00 00 00 00   ← 可选，d5 忽略

:: ⑥ 冷复位 BMC 让配置生效（执行后服务器会短暂息屏 1~2 分钟，属正常）
ipmiutil.exe reset -c
```

**参数解码**（`ipmiutil cmd bus rsSa netFn/lun cmd [data]`）：
- `00` = 总线；`20` = BMC 从地址 0x20；
- `30` = NetFn 0x0C 编码（0x0C << 2，低 2 位 LUN）；
- `01` = Set LAN Configuration Parameters；`02` = Get LAN Configuration Parameters；
- 后续 `01` = 通道 1；`03/04/06/0c` = 参数选择器（3=IP、4=IP 源、6=掩码、12=网关）。

### 5.3 验证（从编排机）

```powershell
ping 10.0.0.10                     # 应通（<1ms）
arp -a | findstr 10.0.0.10         # MAC 应与 BMC 一致（如 e8-61-1a-b0-0e-e6）
.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root   # 四步全 PASS 即 SOL 可用
```

> 注意：IPMI 端口 623 是 **UDP**，用 TCP 连 623 不通是正常的；用 ipmitool `-I lanplus` 才是正确验证方式。

---

## 6. 备选路径

| 路径 | 说明 |
| --- | --- |
| **Linux Live USB**（最可靠兜底） | U 盘引导进 Linux：`modprobe ipmi_devintf ipmi_si` → `apt install ipmitool` → `ipmitool lan set 1 ipaddr 10.0.0.10`（Linux 原生支持 KCS，基本必成） |
| BIOS 组合尝试 | IPv4 与 IPv6 **同时**切 Static 都填合法值再保存（某些 AMI 版本连带校验）；或先切 DHCP 保存成功再回头改 |
| 恢复出厂 | BIOS 无该选项时：完全断电 1 分钟 / 主板 BMC 复位跳线（JBT1/BMC_RST 类）；注意会清空密码/IP |
| 刷 BMC 固件 | 上述全失败 → 固件 bug → 从厂商下载固件，BIOS 内置升级或 OS 内刷写 |

---

## 7. 本次故障根因回顾（2026-10-28）

1. **本机**：有线网卡 Intel I219-V 驱动故障（Code 43）→ 管理网链路失效 → 修复网卡后恢复 `10.0.0.110/24`；
2. **BMC**：IP 源被置为 DHCP 且管理网无 DHCP 服务器 → BMC 无地址；BIOS 设静态 IP 固件 bug 失败；
3. **解决**：ipmiutil 本地接口 + raw 命令写入 静态 IP `10.0.0.10/255.255.255.0` → `reset -c` 冷复位 → 上线（ping 通 + ARP 确认 MAC）。

> 经验：BMC 管理口灯亮 ≠ BMC 有 IP；BIOS 设 IP 无提示失败时，raw 命令（`ipmiutil cmd`）是可靠绕过手段。

---

## 8. 根因链与预防措施（2026-10-28）

**根因链**（本机 10-28 真实故障完整链路，由 cmdlog + 脚本 + 物理拓扑确认）：

```
chassis power cycle（真断电，几十~200 次） × 编排机与被测服务器共用同一插线板/PDU
  ├─→ 每次断电/上电电压跌落 → 编排机有线网卡 Code 43 → 管理网断
  ├─→ 被测服务器系统网卡同样被电压跌落打坏 → Windows 配不了 IP
  └─→ 服务器反复硬断电 → BMC 反复冷启动 → AMI 固件 bug：IP 源回退 DHCP
      （管理网无 DHCP 服务器 → BMC 无地址；BIOS 设静态 IP 又静默失败）
```

**三层预防**：

| 层 | 措施 |
| --- | --- |
| ① 物理/操作 | 断电循环时编排机**换独立电源回路**（勿与被测服务器共用插线板/PDU）；开始前**先停掉本机正在跑的 SOL/长连接**；被测服务器**系统网卡勿配 10.0.0.10**（那是 BMC 的 IP，配了必冲突） |
| ② 脚本 | `Set-BmcStaticIp.ps1` 一键查询/恢复静态 IP；`Run-MemtestSuite` SOL 启动前自动 BMC 前置体检（BMC 不可达 / IP 源非静态 → 中止并打印恢复指引）；断电循环前自动打印共用电源风险警示 |
| ③ 文档 | 本节沉淀根因链与预防措施，避免每次测试后手工救火 |

> 脚本事实：本项目所有脚本**从不修改系统 IP/网卡配置**——只把 BMC `10.0.0.10` 当作已存在前提来连接，唯一"动电"操作是 `chassis power cycle`（断电循环）。BMC 静态 IP `10.0.0.10` 的恢复在 10-28 是**手工 ipmiutil raw 命令**完成（第 5 节），现已脚本化为 `Set-BmcStaticIp.ps1` 一键恢复（第 5.1 节）。
