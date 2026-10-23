# Memtest86+ SOL 方式使用指南（Windows 编排器）

> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 每条命令给两行：**原格式**（通用占位符）+ **本机版**（已填好，复制即用）。

> 状态：[当前有效]（2026-10-22）
> 变更记录：2026-10-22 文档体系编号化（对齐 disk-tests）；工程基建优化更新；新增菜单版 ISO（memtest-sol.iso）引导与构建说明

> 适用：服务器批量内存验收场景，**全自动、无人值守**。SOL（Serial over LAN，串口网络化）让 Windows 编排器远程抓到 Memtest86+ 的机器可解析日志（MTLOG），跑完自动汇总报告。
> 对应脚本：[Run-MemtestSuite.ps1](computer://c:\Users\ganxin01\Documents\trae-work\memory-tests\scripts\Run-MemtestSuite.ps1) 的 `-BootMethod SOL`。

---

## 1. SOL 原理与适用场景

```
Memtest86+（服务器本地，UEFI 引导）
   │ log=ttyS0,115200 → 串口字节流
   ▼
服务器 BIOS 串口重定向（Console Redirection）
   ▼
BMC 把串口流转成 IPMI 包（端口 623，走 BMC 管理网口）
   ▼
Windows 编排器：ipmitool sol activate 抓流 → 写文件 → 解析 MTLOG
```

- **Memtest86+ 测内存不碰网络**：日志只走"串口 → BMC"，服务器业务网/互联网完全不需要
- **适用**：机房无显示器、1000 根批量、需要无人值守；只要 BMC 管理口能 ping 通，即使服务器无业务网络也能用
- **vs USB**：USB 要人工插拔+按键，SOL 全自动；**vs Serial（物理串口线）**：SOL 走网络免拉线，Serial 完全离线但需一根串口线

---

## 2. 前置条件清单

| # | 条件 | 说明 |
| --- | --- | --- |
| 1 | 服务器带 BMC/IPMI | Dell iDRAC、Supermicro/浪潮/华硕等 AMI BMC、Lenovo XCC 等 |
| 2 | BMC 已开 SOL | 见第 3 节；这是最常见失败点 |
| 3 | BIOS 开串口重定向 + 波特率 115200 | Memtest86+ `log=ttyS0,115200` 与 BMC SOL 波特率一致，否则乱码 |
| 4 | Windows 编排机可 ping 通 BMC 管理 IP | 同一管理网段即可，无需互联网 |
| 5 | 编排机装 ipmitool（Windows 版） | 在 PATH 或 `-IpmiTool` 指定路径 |
| 6 | 有办法引导 Memtest86+ | BMC 虚拟介质挂 ISO / U 盘 / EFI 一次性引导（见第 4 节） |

---

## 3. 一次性配置（BMC + BIOS）

### 3.1 常见厂商开启 SOL 的路径（不同固件版本略有差异）

| 厂商 | 常见入口 |
| --- | --- |
| Dell iDRAC9 | iDRAC 管理页 → Console/Media → Serial Over LAN（SOL）→ Enabled；或 `racadm set idrac.serial. ...` |
| Supermicro | BIOS → Advanced → **Serial Port Console Redirection** → COM2/SOL Console Redirection → **Enable**；另需 Serial Port 2 Configuration → Attribute 选 **SOL** |
| AMI 通用（浪潮/华硕等） | BIOS → Advanced → Serial Port Console Redirection → SOL/COM2 项 Enable |
| Lenovo XCC | XCC 界面 → Console → Serial over LAN |

### 3.2 BIOS 串口重定向（Console Redirection）要点

1. 进入 BIOS → Advanced → Serial Port Console Redirection
2. **Enable Console Redirection**（COM1 或 SOL/COM2 均可，但需与 Memtest86+ 用的 ttyS 对应）
3. 波特率选 **115200**（与 Memtest86+ `log=ttyS0,115200` 一致）
4. 保存退出

> 判据：配置正确后，用 ipmitool 开 SOL 会话能看到 BIOS 启动自检输出；看不到就说明重定向/波特率没配对。

---

## 4. 引导 Memtest86+（三种方式任选其一）

| 方式 | 做法 | 自动化 |
| --- | --- | --- |
| BMC 虚拟介质（推荐） | 在 BMC 网页的 Virtual Media 挂载 memtest ISO，设置从虚拟光驱一次性引导 | 全自动（远程挂载） |
| U 盘 | 插引导 U 盘，BIOS 设 USB 优先 | 半自动 |
| EFI 一次性引导 | 编排器 `-BootMethod EFI` 用 bcdedit 建一次性启动项指向 `mt86plus.efi`，日志仍走 SOL 抓 | 全自动 |

> Memtest86+ 引导参数（虚拟介质/引导配置里加）：
> ```
> console=ttyS0,115200 log=ttyS0,115200 maxpasses=4
> ```
> - `log=` 输出机器可解析 MTLOG 到串口（与 `console=` 互斥，log 优先）
> - `maxpasses=4` 跑完 4 轮输出 `ev=done` 后自动重启回系统（**这就是全自动的关键**）
> - `testlist=0,1,2,3` 可选，只跑指定测试（快速筛选）

### 4.1 菜单版 ISO（memtest-sol.iso，推荐）

> 已内置 `memtest\boot\memtest-sol.iso` —— 带 **GRUB 引导菜单**的 UEFI 版 ISO。开机出现菜单，可选 4 轮验收 / 2 轮 / 1 轮快速筛选 / 交互界面，超时 10 秒自动选默认项（4 轮验收），适合 BMC 虚拟介质**无人值守**挂载。

普通 ISO 要在虚拟介质/引导配置里手写引导参数；菜单版把这些参数做进了菜单，**选哪项就按哪项跑**：前三个 SOL 预设都是 log 模式，串口输出 MTLOG，跑满自动重启回系统（与上方手写 `log=ttyS0,115200 maxpasses=N` 等价）；「交互界面」预设为界面手动操作（`nomch`，无串口日志、不自动重启），适合有人值守或先界面调参再测：

| 菜单项 | 内置引导参数 | 用途 |
| --- | --- | --- |
| 4 轮验收（默认） | `log=ttyS0,115200 maxpasses=4` | 标准验收（超时 10s 自动选） |
| 2 轮 | `log=ttyS0,115200 maxpasses=2` | 缩短版验收 |
| 1 轮快速筛选 | `log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8` | 快速筛不良 |
| 交互界面 | `nomch` | 手动调试（无串口日志，不自动重启） |

- **改轮数/预设 = 编辑 `config\memtest-presets.conf` 后重跑构建脚本**（约几秒产出新 ISO），不用手改二进制；引导时也可临时在 GRUB 菜单按键选其他预设，不必重新构建：
  ```powershell
  # 构建命令无占位符，原格式 = 本机版（复制即用）
  # 首次构建需联网下载 GRUB；GRUB 已就位后离线可重跑
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\New-MemtestSolIso.ps1
  ```
- 注意：**菜单版 ISO 仅支持 UEFI 引导**（不含 Legacy/软盘模拟）；产物自带 El Torito EFI 引导项，OVMF/QEMU 已实测可引导。
- 构建机需 Python 3（组装 ISO 用）；产物 ISO 运行不需要 Python。完整参数见 [05-使用手册.md](05-使用手册.md) §4.7/4.8。

---

## 5. 使用流程（编排器全自动）

### 5.1 命令行

```powershell
# 标准 SOL 全自动验收（4 轮）
# 原格式（通用）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 10.0.0.10 -BmcUser root -MaxPasses 4 -ConfirmSwitch

# 附加 ECC 监控 + 温度监控 + 测完断电循环 2 次
# 原格式（通用）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 `
  -MonitorEcc -MonitorTemp -RestartLoop 2 -ConfirmSwitch
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 10.0.0.10 -BmcUser root -MaxPasses 4 `
  -MonitorEcc -MonitorTemp -RestartLoop 2 -ConfirmSwitch
```

### 5.2 脚本自动做的事

| 步骤 | 说明 |
| --- | --- |
| ① 识别建档 | 读当前槽位内存序列号/容量/频率 → 批次清单 CSV |
| ② 启动 SOL 抓流 | `ipmitool sol activate` 后台运行，输出重定向到 raw 日志文件 |
| ③ 等待完成 | 轮询日志直到出现 `ev=done`（Memtest86+ 跑完自动重启） |
| ④ 关闭会话 | 结束 ipmitool 进程 |
| ⑤ 解析 MTLOG | 轮次/错误/地址/测试号/SPD → PASS/FAIL 判定 |
| ⑥ 汇总报告 | 合并 `master_manifest.csv`；可选 WHEA/温度/断电循环记录 |

### 5.3 手动验证命令（排查用）

```powershell
# 原格式（通用）
.\scripts\Diag-Bmc.ps1 -BmcHost <BMC_IP> -BmcUser <用户>
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Diag-Bmc.ps1 -BmcHost 10.0.0.10 -BmcUser root
```

> `Diag-Bmc.ps1` 一键诊断四步（`mc info` / `chassis status` / `sdr elist` / `sol activate` 短探测）。需要单独操作某一步时，用下面的原始 ipmitool 命令（每条附本机版，密码运行中提示）：

```powershell
# 原格式（通用）
# 手动开 SOL 看输出（Ctrl+~ 或 ~. 退出会话）
ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass> sol activate
# 👉 本机版
ipmitool -I lanplus -H 10.0.0.10 -U root sol activate

# 退出 SOL
ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass> sol deactivate
# 👉 本机版
ipmitool -I lanplus -H 10.0.0.10 -U root sol deactivate

# 远程设置一次性引导设备并重启（配合虚拟介质/EFI）
ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass> chassis bootdev cdrom   # 或 efi / pxe / hd
# 👉 本机版
ipmitool -I lanplus -H 10.0.0.10 -U root chassis bootdev cdrom

ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass> chassis power cycle
# 👉 本机版
ipmitool -I lanplus -H 10.0.0.10 -U root chassis power cycle

# 读温度传感器（FR-11）
ipmitool -I lanplus -H <BMC_IP> -U <user> -P <pass> sdr elist
# 👉 本机版
ipmitool -I lanplus -H 10.0.0.10 -U root sdr elist
```

---

## 6. 结果判读

| 信号 | 含义 |
| --- | --- |
| `ev=start` | Memtest86+ 启动，日志链路通 |
| `ev=spd slot=N ...` | 识别到各槽位 SPD |
| `ev=pass_end pass=N errors=0 status=pass` | 每轮结果 |
| `ev=done passes=4 status=pass` | **4 轮全部通过 → PASS** |
| `ev=data addr=0x... expect=... actual=...` | 错误明细（地址/期望/实测） |
| `status=fail` | 有错误 → FAIL，进入排查流程 |
| 一直无 `ev=done`（超时） | 见第 7 节排查 |

---

## 7. 常见问题排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| SOL 无任何输出 | BMC 未开 SOL / BIOS 未开重定向 / 没引导进 Memtest86+ | 核对第 3/4 节；手动 `sol activate` 看有无 BIOS 输出 |
| 输出乱码 | 波特率不一致 | 三处统一 115200：BIOS 重定向、BMC SOL、Memtest86+ `log=ttyS0,115200` |
| `sol activate` 报 "Cannot activate SOL" | SOL 会话被占用 / BMC 未配置 | 先 `sol deactivate`；检查 BMC 用户权限（需 Operator/Admin） |
| 编排器超时收不到 `ev=done` | 引导参数没带 `log=`/`maxpasses=`；或没引导进 Memtest86+ | 确认引导介质参数含 `log=ttyS0,115200 maxpasses=N` |
| 抓到的日志是交互界面而非 MTLOG | 只配了 `console=` 没配 `log=` | 引导参数用 `log=ttyS0,115200`（log 优先于 console） |
| 服务器不自动重启 | console 模式 `maxpasses` 不生效 | 必须用 `log=` 模式（log_max_passes 仅在 log 模式触发重启） |
| 同一 BMC 连不上 | 端口 623 被防火墙拦 | 管理网放行 623（UDP）；确保编排机与 BMC 同网段 |

---

## 8. 批量建议（1000 根）

- **推荐 SOL + BMC 虚拟介质挂 ISO**：全自动无人值守，配合批次调度器 `scripts\Run-BatchScheduler.ps1` 逐批跑，最后出全量报告
- 每批插满 8–16 根 → 1 轮快速筛选约 1–1.5 小时；4 轮完整验收约 3–6 小时
- 多台服务器并行（各自独立的 BMC + 编排实例）可把总量压到 2–3 天
- 断电循环/温度/ECC 监控都可在 SOL 方式下用 `-MonitorEcc -MonitorTemp -RestartLoop` 一并做

---

## 参考来源

- Supermicro SOL 设置 FAQ（BIOS → Serial Port Console Redirection → COM2/SOL）：<https://www.supermicro.com/support/faqs/faq.cfm?faq=21816>
- Dell iDRAC9 SOL 使用说明（`ipmitool ... sol activate`、退出 `~.`）：<https://www.dell.com/support/manuals/zh-cn/poweredge-r740/idrac_3.00.00.00_ug/sol-using-ipmi-protocol>
- Supermicro Serial Port 2 Configuration（SOL/COM 属性）：<https://www.supermicro.com/es-es/support/manuals/product/system/sys-422gs-nbrt-lcc/Content/uefi-bios/advanced/serial-port-2-configuration-x14-xeon-6.htm>
- Memtest86+ 引导参数说明（`log=`/`console=`/`maxpasses=`/`testlist=`）：<https://memtest.org/readme>
