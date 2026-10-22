# memory-tests —— DDR5 内存条 SOL 全自动验收工具

> "插满内存，跑一条命令，拿走逐根结论"
>
> 基于 Windows PowerShell 的 DDR5 内存条**批量压力测试与验收**工具：PowerShell 作为编排器，引导 Memtest86+ 执行真正的内存测试（SOL/Serial/USB/EFI 四种方式），抓取并解析 MTLOG，自动汇总成逐根可追溯的压测报告。配套文档见 `docs/`（编号 01-11）。

## 功能

- **全自动验收**：SOL（BMC 串口网络化）无人值守，自动识别槽位内存、引导 Memtest86+、抓日志、判定 PASS/FAIL。
- **四种引导方式**：SOL（机房批量）/ Serial（物理串口线，完全离线）/ USB（半自动）/ EFI（一次性引导）。
- **智能识别建档**：读 SPD（序列号/容量/频率/DDR5 判定）+ 预期清单匹配（防调包）。
- **批量调度**：批次清单 CSV 驱动，逐批自动运行，输出 1000 根全量总表。
- **附加监控**：WHEA/ECC 错误采集、IPMI 温度采样、断电循环（`chassis power cycle`）。
- **断点续测**：日志与解析分离，`-ParseOnly` 可断点续解析。
- **离线包**：Memtest86+ v9.00 ISO/binaries 已打包（`SOL内存测试离线包/`）。
- **自动化测试**：`tests/` 覆盖共享库、参数校验与历史库（`test-lib.ps1` / `test-args.ps1` / `test_db.py`）。
- **单源构建**：`scripts\build.ps1` 一键同步离线包，VERSION 单一来源。
- **JSON 事件流**：主流程输出一行 JSON 事件，供日志/GUI 等外部工具消费。
- **历史库（可选）**：`db/` SQLite 历史库（需 Python 3），支持导入/查询/导出/合并。

## 环境要求

- Windows 10 / Server 2016+，PowerShell 5.1+（系统自带）
- SOL 方式需 ipmitool（**已内置**在离线包 `SOL内存测试离线包\tools\ipmitool\`，免联网免配置；见 [04-运行环境与依赖安装说明.md](docs/04-运行环境与依赖安装说明.md)）
- 被测服务器需开启 BMC SOL + BIOS 串口重定向（115200）
- 历史库可选功能需 Python 3（`db/` 工具，见 [05-使用手册.md](docs/05-使用手册.md) 第 10 节）

## 快速开始

```powershell
# ① 单批 SOL 全自动（4 轮验收）
.\scripts\Run-MemtestSuite.ps1 -BatchName batch01 -BootMethod SOL `
  -BmcHost 192.168.1.10 -BmcUser admin -BmcPass pwd -MaxPasses 4 -ConfirmSwitch

# ② 批量 1000 根：填好批次清单后运行调度器
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -DryRun      # 先预览
.\scripts\Run-BatchScheduler.ps1 -ManifestCsv .\config\batches.csv -ContinueOnError
```

> 第一次使用先走 [06-实践操作教程.md](docs/06-实践操作教程.md) 阶段 1（USB 验证 1 根）跑通链路，再切 SOL。

## 常用命令

```powershell
# 只解析已有日志（断点续测）
.\scripts\Run-MemtestSuite.ps1 -ParseOnly -LogFile .\memory_results\raw\batch01.mtlog.txt

# Serial 完全离线
.\scripts\Run-MemtestSuite.ps1 -BootMethod Serial -SerialPort COM3 -BaudRate 115200 -MaxPasses 4

# USB 半自动
.\scripts\Run-MemtestSuite.ps1 -BootMethod USB -UsbDrive E: -MaxPasses 4

# 智能识别建档
.\scripts\Identify-Memory.ps1 -BatchName batch01
```

## 输出

```text
<LogPath>/（默认 scripts\memory_results\，用 -LogPath 重定向到 output\）
├── <批次>-inventory.csv      # 识别建档
├── <批次>-report.csv         # 单批逐根 pass/fail
├── master_manifest.csv       # 累计数据库
├── raw/                      # 原始 MTLOG/文本报告
└── all-batches-report-*.csv  # 全量总表（调度器）
```

字段说明见 [08-报表结构说明.md](docs/08-报表结构说明.md)。

## 目录结构

```text
memory-tests/
├── README.md
├── docs/                      # 编号文档体系（01-11）
│   ├── 01-验收测试方案.md
│   ├── 02-批量压力测试方案.md
│   ├── 03-PowerShell压测工具需求说明.md
│   ├── 04-运行环境与依赖安装说明.md
│   ├── 05-使用手册.md
│   ├── 06-实践操作教程.md
│   ├── 07-离线部署检查清单.md
│   ├── 08-报表结构说明.md
│   ├── 09-SOL使用指南.md
│   ├── 10-Serial物理串口线使用指南.md
│   └── 11-引导方式对比评估.md
├── scripts/                   # 编排脚本
│   ├── lib_common.ps1         # 共享库（识别/解析/通用工具）
│   ├── Run-MemtestSuite.ps1
│   ├── Run-BatchScheduler.ps1
│   ├── Identify-Memory.ps1
│   └── build.ps1              # 单源构建（同步离线包）
├── tests/                     # 自动化测试（test-lib/test-args/test_db）
├── db/                        # SQLite 历史库（可选，需 Python 3）
├── config/                    # 批次/预期清单模板
├── VERSION                    # 版本单一来源
├── AGENTS.md                  # 协作约定
├── SOL内存测试离线包/          # 离线部署包（含 Memtest86+ v9 ISO/binaries）
└── .gitignore
```

## 文档索引

| 编号 | 文档 | 内容 |
| --- | --- | --- |
| 01 | 验收测试方案 | 单机整机验收：目标/工具/步骤/排查/清单 |
| 02 | 批量压力测试方案 | 17 项行业测试总纲 + 1000 根全检 + 分层执行 + 软件满足度 |
| 03 | PowerShell 压测工具需求说明 | 工具定位、功能需求 FR-1~11 |
| 04 | 运行环境与依赖安装说明 | BMC/ipmitool/Rufus/引导参数前置 |
| 05 | 使用手册 | 三个脚本全参数说明 |
| 06 | 实践操作教程 | 分步演练：USB 验证 → SOL → 批量 |
| 07 | 离线部署检查清单 | 部署前勾选检查表 |
| 08 | 报表结构说明 | 输出 CSV 字段 + MTLOG 事件 + 判定逻辑 |
| 09 | SOL 使用指南 | SOL 原理/配置/流程/排查 |
| 10 | Serial 使用指南 | 物理串口线离线方案 |
| 11 | 引导方式对比评估 | USB/SOL/Serial/EFI 选型 |
