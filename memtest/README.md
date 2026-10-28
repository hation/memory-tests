> 工具版本：v19
# SOL 内存测试离线包（Memtest86+ 全自动验收）

> 本机 BMC：IP `10.0.0.10` / 用户名 `root`（密码运行中提示输入）；换机器只改这一处。
> 每条命令给两行：**原格式**（通用占位符）+ **本机版**（已填好，复制即用）。

基于 Windows PowerShell 的 **DDR5 内存条 SOL 全自动验收工具包**。编排器远程引导 Memtest86+、抓取 MTLOG 日志、解析并汇总成逐根可追溯的压测报告。

> 用途：1000 根内存条批量验收（配合 17 项验收方案与智能识别），全自动无人值守。

---

## 目录结构

```
memtest/
├── README.md                  ← 本文件（离线使用说明）
├── scripts/                   ← 编排脚本（离线可用）
│   ├── Run-MemtestSuite.ps1   ← 单批编排（SOL/Serial/USB/EFI 引导 + 抓日志 + 解析 + 汇总）
│   ├── Run-BatchScheduler.ps1 ← 批量调度（读批次清单 CSV 逐批跑 + 全量汇总）
│   ├── Identify-Memory.ps1    ← 智能识别建档（序列号/容量/频率/DDR5 判定）
│   ├── Run-ServerAssessment.ps1 ← 服务器能力一键评估（17 项可行性 + 建议动作）
│   ├── Check-ServerCapabilities.ps1 ← 能力探测（带内 CIM + 带外 BMC/IPMI）
│   ├── check_env.ps1          ← 环境自检（首行打印工具版本，核对是否最新版）
│   ├── New-MemtestSolIso.ps1  ← 菜单版 ISO 构建（预设 conf + 内核 + GRUB → memtest-sol.iso，构建机需 Python 3）
│   ├── Smoke-MemtestIso.ps1   ← QEMU/OVMF 冒烟验证 ISO 可引导（构建机）
│   ├── iso9660_build.py       ← ISO 组装脚本（构建机需 Python 3）
│   └── lib_common.ps1         ← 公共函数库（脚本共用）
├── tools/                     ← 外部工具（已内置，免联网）
│   ├── ipmitool/              ← Windows 版 ipmitool 1.8.18（exe + 依赖 DLL）
│   ├── grub/                  ← GRUB 2.06（grub-mkimage + x86_64-efi 模块，离线重建菜单版 ISO 用）
│   └── README-tools.md        ← ipmitool 说明（来源/SHA256/用法）
├── boot/                      ← Memtest86+ v9.00（已离线打包）
│   ├── memtest.iso            ← 可引导 ISO（BMC 虚拟介质/USB 引导用）
│   ├── memtest-sol.iso        ← 菜单版 UEFI ISO（GRUB 引导菜单，超时自动默认，无人值守用，推荐）
│   ├── mt86plus_9.00_x86_64.iso.zip
│   ├── binaries.zip
│   └── binaries/              ← mt86p_900_x86_64 等（EFI/PXE 链式引导用）
├── config/                    ← 配置模板
│   ├── batches.example.csv    ← 批次清单模板（批量调度用）
│   ├── expected.example.csv   ← 预期清单模板（防调包校验用）
│   └── memtest-presets.conf   ← 菜单版 ISO 预设配置（改轮数/预设后重跑构建脚本）
└── docs/                      ← 全部文档
```

---

## 组件清单与离线状态

| 组件 | 离线状态 | 说明 |
| --- | --- | --- |
| 编排脚本 ×9 | ✅ 已含 | 含 check_env 环境自检、能力评估、菜单版 ISO 构建/冒烟工具；PowerShell 5.1 原生可跑（iso9660_build.py 需 Python 3） |
| Memtest86+ v9.00 ISO | ✅ 已内置 | `boot\memtest.iso`（6.2MB，无需下载） |
| **memtest-sol.iso（菜单版 UEFI ISO）** | ✅ **已内置** | `boot\memtest-sol.iso`，GRUB 引导菜单（4轮全项/4轮快筛/2轮全项/2轮快筛/1轮全项/1轮快筛/交互），超时 20s 自动选默认，BMC 虚拟介质无人值守用 |
| **New-MemtestSolIso.ps1 / Smoke-MemtestIso.ps1** | ✅ **已含** | `scripts\`，菜单版 ISO 构建/冒烟工具（构建机需 Python 3；产物 ISO 运行不需要 Python） |
| **memtest-presets.conf** | ✅ **已含** | `config\memtest-presets.conf`，菜单版 ISO 预设配置（改轮数/预设后重跑构建脚本） |
| Memtest86+ binaries | ✅ 已含 | x86_64 等架构 EFI 负载 |
| **ipmitool.exe** | ✅ **已内置** | Windows 版 1.8.18（含依赖 DLL），`tools\ipmitool\`，免联网免配置 |
| GRUB 2.06 构建工具 | ✅ 已含 | `tools\grub\`（grub-mkimage + x86_64-efi 模块），离线重建菜单版 ISO 用 |
| 文档 ×5 | ✅ 已含 | 含 SOL/Serial 使用指南 |

> **完全离线可用**：本包含运行所需全部组件（Memtest86+ 引导镜像 + ipmitool），无需任何联网下载。

---

## 快速开始（SOL 全自动验收）

### 第 0 步：一次性准备

1. **固定部署目录**：将本包拷贝到固定位置（推荐 `C:\memtest\`），拷贝即用、免安装、免联网（脚本用相对路径定位，目录拷到哪都能跑）
2. **开启 BMC SOL + BIOS 串口重定向（115200）** —— 详见 `docs\09-SOL使用指南.md` 第 3 节
3. **（无需任何下载）** 内置 ipmitool 位于 `tools\ipmitool\`，脚本自动发现，开箱即用
4. **准备 Memtest86+ 引导介质**：BMC 虚拟介质挂载 `boot\memtest.iso`，或写 U 盘（Rufus）

### 第 1 步：确认链路通（可选）

```powershell
# 环境自检：首行"工具版本: vN"应与交付包版本一致
.\scripts\check_env.ps1
.\scripts\Run-MemtestSuite.ps1 -Help
# 手动 SOL 验证（内置 ipmitool）
# 原格式（通用）
.\tools\ipmitool\ipmitool.exe -I lanplus -H <BMC_IP> -U <user> -P <pass> sol activate
# 👉 本机版（复制即用，密码运行中提示）
.\tools\ipmitool\ipmitool.exe -I lanplus -H 10.0.0.10 -U root sol activate
```

### 第 2 步：单批 SOL 全自动验收

```powershell
# 在包根目录运行（推荐 C:\memtest\）
# 原格式（通用）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
# 👉 本机版（复制即用，密码运行中提示）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 10.0.0.10 -BmcUser root -MaxPasses 4 -ConfirmSwitch
# 可选：-MonitorEcc -MonitorTemp -RestartLoop 2
```

### 第 3 步：批量 1000 根（推荐）

1. 编辑 `config\batches.example.csv` → 复制为 `config\batches.csv`，每行一个批次
2. 运行批量调度（ipmitool 已内置、脚本自动发现，无需配置）：
   ```powershell
   .\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -DryRun   # 先预览
   .\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -ContinueOnError
   ```

### 第 4 步：查看报告

默认输出在 `results\`；建议统一用 `-LogPath` 指到 `output\` 目录（批量调度用 `-LogPath` 参数），例如：

```powershell
.\scripts\Run-MemtestSuite.ps1 ... -LogPath .\results
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv ... -LogPath .\results
```

输出文件：
- `results\reports\<批次>-report.csv` —— 每批逐根 pass/fail
- `results\all-batches-report-*.csv` —— 1000 根全量总表
- `results\master_manifest.csv` —— 累计数据库
- `results\raw\` —— 原始 MTLOG/报告备份

---

## 常见用法速查

```powershell
# 仅解析已有日志（断点续测/复核）
.\scripts\Run-MemtestSuite.ps1 -ParseOnly -LogFile <raw log 路径>

# Serial 物理串口线（完全离线，零网络零按键）
.\scripts\Run-MemtestSuite.ps1 -BootMethod Serial -SerialPort COM3 -BaudRate 115200 -MaxPasses 4

# USB 半自动
.\scripts\Run-MemtestSuite.ps1 -BootMethod USB -UsbDrive E: -MaxPasses 4
```

---

## 判读标准

| 结果 | 含义 |
| --- | --- |
| `ev=done passes=4 status=pass` | 4 轮全过 → PASS |
| `status=fail` / 错误明细 | 有错误 → 排查（单条单槽隔离、降频复测） |
| 超时无 `ev=done` | 见 SOL 指南第 7 节排查 |

---

## 安全与来源

- Memtest86+ v9.00：官方 https://memtest.org/download/v9.00/ （GPLv2）
- ipmitool 1.8.18：BSD 许可，内置 Windows 构建（含 Cygwin 运行时 DLL）；exe SHA256 = `2EF7D24E2E5CFD674AD1FCC694DEA6ED79A026C9F17D584DAA745A106F11EEC3`
- 脚本仅做用户态操作与远程管理控制，不修改系统引导配置（EFI 使用一次性启动项）

## 文档索引

- `docs\09-SOL使用指南.md` —— SOL 原理/配置/流程/排查（首选）；菜单版 ISO 用法见 §4.1（菜单版 ISO）
- `docs\16-新工具压力测试使用指南.md` —— 用菜单版 ISO + 新工具跑压测的完整操作（首选）
- `docs\10-Serial物理串口线使用指南.md` —— 离线物理串口方案
- `docs\02-批量压力测试方案.md` —— 17 项验收总纲 + 1000 根全检
- `docs\03-PowerShell压测工具需求说明.md` —— 工具需求与 FR
- `docs\01-验收测试方案.md` —— 单机验收与批量全检流程
- `docs\05-使用手册.md` —— 三个脚本全参数手册
- `docs\06-实践操作教程.md` —— 分步上手演练
- `docs\07-离线部署检查清单.md` —— 部署前勾选检查表
- `docs\04-运行环境与依赖安装说明.md` —— 环境与依赖安装
- `docs\08-报表结构说明.md` —— 输出字段说明
- `docs\11-引导方式对比评估.md` —— USB/SOL/Serial/EFI 选型
- `docs\12-离线部署与SOL测试手册.md` —— 机房落地三步走（部署→能力验证→SOL 开测）
- `docs\13-服务器信息识别指南.md` —— 服务器信息识别指南
- `docs\14-术语解释.md` —— 验收测试词汇表（状态/分层/硬件/工具/外包项）
- `docs\15-BMC排查方案.md` —— BMC 连通与 SOL 排查（评估「需 BMC」/SOL 无输出乱码时先查）

---

## 版本信息

> 核对：`check_env.ps1` 首行"工具版本: vN"应与交付包版本一致；不一致 = 没拷到最新，更新流程见 `docs\12` 手册 1.6。

- **v4**：打包与部署对齐 disk-tests —— `build.ps1 -Zip` 改为 .NET ZipArchive（保留空目录）+ 打包前完整性校验
- **v3**：新增 `check_env.ps1` 环境自检（首行显示版本）；固定部署目录 `C:\memtest\`；版本行幂等注入
- **v2**：内置 ipmitool 1.8.18（免联网）；文档统一为"应用内使用"
- **v1**：初始发布（SOL 全自动验收工具包）
