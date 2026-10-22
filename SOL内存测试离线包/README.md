> 工具版本：v1
# SOL 内存测试离线包（Memtest86+ 全自动验收）

基于 Windows PowerShell 的 **DDR5 内存条 SOL 全自动验收工具包**。编排器远程引导 Memtest86+、抓取 MTLOG 日志、解析并汇总成逐根可追溯的压测报告。

> 用途：1000 根内存条批量验收（配合 17 项验收方案与智能识别），全自动无人值守。

---

## 目录结构

```
SOL内存测试离线包/
├── README.md                  ← 本文件（离线使用说明）
├── scripts/                   ← 编排脚本（离线可用）
│   ├── Run-MemtestSuite.ps1   ← 单批编排（SOL/Serial/USB/EFI 引导 + 抓日志 + 解析 + 汇总）
│   ├── Run-BatchScheduler.ps1 ← 批量调度（读批次清单 CSV 逐批跑 + 全量汇总）
│   └── Identify-Memory.ps1    ← 智能识别建档（序列号/容量/频率/DDR5 判定）
├── tools/                     ← 外部工具
│   ├── Setup-Tools.ps1        ← 首次联网自取 ipmitool.exe（约 1 分钟，之后全离线）
│   └── README-tools.md        ← ipmitool 获取方式说明
├── boot/                      ← Memtest86+ v9.00（已离线打包）
│   ├── memtest.iso            ← 可引导 ISO（BMC 虚拟介质/USB 引导用）
│   ├── mt86plus_9.00_x86_64.iso.zip
│   ├── binaries.zip
│   └── binaries/              ← mt86p_900_x86_64 等（EFI/PXE 链式引导用）
├── config/                    ← 配置模板
│   ├── batches.example.csv    ← 批次清单模板（批量调度用）
│   └── expected.example.csv   ← 预期清单模板（防调包校验用）
└── docs/                      ← 全部文档
```

---

## 组件清单与离线状态

| 组件 | 离线状态 | 说明 |
| --- | --- | --- |
| 编排脚本 ×3 | ✅ 已含 | PowerShell 5.1 原生可跑 |
| Memtest86+ v9.00 ISO | ✅ 已含 | 6.2MB，官方 memtest.org 下载 |
| Memtest86+ binaries | ✅ 已含 | x86_64 等架构 EFI 负载 |
| 文档 ×5 | ✅ 已含 | 含 SOL/Serial 使用指南 |
| **ipmitool.exe** | ⚠️ 需首次联网自取 | 官方不发布 Windows 版；用 `tools\Setup-Tools.ps1` 一次获取（或手动放入 `tools\`） |

> 除 ipmitool 外全部离线可用。ipmitool 获取后，本包即可完全离线运行。

---

## 快速开始（SOL 全自动验收）

### 第 0 步：一次性准备

1. **开启 BMC SOL + BIOS 串口重定向（115200）** —— 详见 `docs\09-SOL使用指南.md` 第 3 节
2. **获取 ipmitool.exe**（一次）：
   ```powershell
   .\tools\Setup-Tools.ps1
   ```
3. **准备 Memtest86+ 引导介质**：BMC 虚拟介质挂载 `boot\memtest.iso`，或写 U 盘（Rufus）

### 第 1 步：确认链路通（可选）

```powershell
.\scripts\Run-MemtestSuite.ps1 -Help
# 手动 SOL 验证
.\tools\ipmitool.exe -I lanplus -H <BMC_IP> -U <user> -P <pass> sol activate
```

### 第 2 步：单批 SOL 全自动验收

```powershell
cd scripts
.\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch
# 可选：-MonitorEcc -MonitorTemp -RestartLoop 2
```

### 第 3 步：批量 1000 根（推荐）

1. 编辑 `config\batches.example.csv` → 复制为 `config\batches.csv`，每行一个批次
2. 运行批量调度（先把 ipmitool 路径加到 PATH，或用 -IpmiTool）：
   ```powershell
   .\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -DryRun   # 先预览
   .\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -ContinueOnError
   ```

### 第 4 步：查看报告

默认输出在 `scripts\memory_results\`；建议统一用 `-LogPath` 指到 `output\` 目录（批量调度用 `-LogPath` 参数），例如：

```powershell
.\scripts\Run-MemtestSuite.ps1 ... -LogPath .\output\memory_results
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv ... -LogPath .\output\memory_results
```

输出文件：
- `memory_results\reports\<批次>-report.csv` —— 每批逐根 pass/fail
- `memory_results\all-batches-report-*.csv` —— 1000 根全量总表
- `memory_results\master_manifest.csv` —— 累计数据库
- `memory_results\raw\` —— 原始 MTLOG/报告备份

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
- ipmitool：BSD 许可，官方不发布 Windows 二进制；Setup-Tools.ps1 仅从文档化来源下载并校验 PE 头，建议核对来源校验和
- 脚本仅做用户态操作与远程管理控制，不修改系统引导配置（EFI 使用一次性启动项）

## 文档索引

- `docs\09-SOL使用指南.md` —— SOL 原理/配置/流程/排查（首选）
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
