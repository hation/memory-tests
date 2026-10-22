# Memtest86+ 自动化编排与压测报告汇总工具（Windows PowerShell）需求说明

> 依据：《02-批量压力测试方案.md》第 7 章「软件满足度与开源替代对照」
> 定位：**PowerShell 作为编排器（Orchestrator）**——在 Windows PowerShell 中启动/引导 Memtest86+ 执行真正的内存测试，**捕获其输出日志**（MTLOG 机器可解析格式 / USB 报告 / 串口），**解析并汇总**到批量压测报告（与 `Identify-Memory.ps1` 的 `master_manifest.csv` 关联）。
> 运行环境：Windows Server / Windows 10+，PowerShell 5.1+（首选 `powershell.exe`，兼容 `pwsh`）。

---

## 1. 定位与架构

```
┌─────────────────────────────────────────────────────────────┐
│  PowerShell 编排器（本工具）                                  │
│  ① 智能识别建档（复用 Identify-Memory.ps1）                   │
│  ② 引导 Memtest86+（SOL串口 / USB报告 / EFI一次性引导）        │
│  ③ 捕获输出日志（SOL会话抓取 / USB报告读取 / 串口）             │
│  ④ 解析 MTLOG（轮次/错误/地址/测试号）                        │
│  ⑤ 结果判定（PASS / FAIL / INCOMPLETE）                      │
│  ⑥ 汇总报告（合并 master_manifest.csv，逐根可追溯）            │
└─────────────────────────────────────────────────────────────┘
        │ 引导 + 日志
        ▼
  Memtest86+（真实内存测试，UEFI 引导执行全部 13 项测试）
        │ 输出
        ▼
  MTLOG 串口日志 / USB 报告文件
```

**分工**：真正测内存的是 **Memtest86+**（覆盖第 3 项全地址读写、数据保持）；PowerShell 负责**编排、捕获、解析、汇总**，不替代 Memtest86+ 的测试功能。

---

## 2. 范围：17 项在"编排器"架构下的覆盖

| # | 测试项 | 本工具覆盖方式 | 说明 |
| --- | --- | --- | --- |
| 1 | SPD 信息校验 | ✅ FR-1 识别建档 | CIM 读取 + CPU-Z/HWiNFO 导出解析 |
| 2 | 基础识别读取 | ✅ FR-1 | `Get-CimInstance Win32_PhysicalMemory` |
| 3 | 全地址读写覆盖 | ✅ FR-2/3/4/5 | **Memtest86+ 执行**，PowerShell 编排引导 + 解析日志 |
| 4 | ECC 纠错功能验证 | ✅ FR-7 监控 | WHEA 事件日志查询（ECC 平台） |
| 5 | ORT 72h 满载老化 | ✅ FR-2/3/5 | Memtest86+ `maxpasses` 长跑 + 系统满载工具；加压/加温需外部手段 |
| 6 | 电压裕量 | ❌ 外包 | 需可编程电源+示波器 |
| 7 | 时序 / SI | ❌ 外包 | 需示波器 |
| 8 | 高低温循环 | ❌ 外包 | 需高低温箱 |
| 9 | THB | ❌ 外包 | 需恒温恒湿箱 |
| 10 | 上电掉电重启循环 | ✅ FR-8 | Memtest86+ `maxpasses` 完成后自动重启；配合 IPMI 物理断电可扩展 |
| 11 | ESD | ❌ 外包 | 需静电枪 |
| 12 | 机械振动 | ❌ 外包 | 需振动台 |
| 13 | 机械冲击 | ❌ 外包 | 需冲击台 |
| 14 | 弯曲扭曲 | ❌ 外包 | 需治具 |
| 15 | 多平台兼容 | ✅ FR-1/2/5 | 同脚本跨平台编排，输出平台信息 |
| 16 | 混插压力 | ✅ FR-2/3/5 | 满槽位混插配置跑 Memtest86+ |
| 17 | 目检 + 电性复检 | ❌ 人工 | 人工 + 万用表 |

**结论**：本工具覆盖 **8 项**（1 / 2 / 3 / 4 / 5 / 10 / 15 / 16），对应 L1 全量 + 部分 L2；硬件依赖项（6–9、11–14、17）维持外包/人工。

---

## 3. 功能需求（FR）

| 编号 | 需求 | 说明 |
| --- | --- | --- |
| FR-1 | 智能识别与建档 | 读取槽位、序列号、型号、容量、频率、厂商、DDR5 判定；复用/集成 `Identify-Memory.ps1`，生成批次清单 CSV |
| FR-2 | Memtest86+ 引导编排 | 支持三种引导方式：**SOL 串口**（BMC/IPMI）、**USB 报告**（Memtest86+ v9 报告导出到 U 盘）、**EFI 一次性引导**（bcdedit 创建 UEFI 启动项）；引导参数含 `console=ttyS0,115200`、`log=ttyS0,115200`、`maxpasses=n`、`testlist=x,y,z` |
| FR-3 | 输出日志捕获 | 抓取 Memtest86+ 串口/SOL 会话输出到文件；或读取 U 盘上的报告文件；或串口直连捕获 |
| FR-4 | MTLOG 解析 | 解析机器可解析日志 `MTLOG ts=<秒> ev=<事件> key=value`：start banner、system info、pass/test 生命周期、timed progress、**错误事件（错误地址/测试号/位模式）**、`ev=done` |
| FR-5 | 结果判定与汇总 | 按 PASS / FAIL / INCOMPLETE PASS 判定（参照轮次完成与错误数）；记录每轮起止、错误明细 |
| FR-6 | 报告输出 | 逐批输出 CSV + 文本报告；按槽位/序列号合并进 `master_manifest.csv`，形成逐根可追溯 pass/fail 总表 |
| FR-7 | ECC / WHEA 监控（可选） | 查询 WHEA 事件日志（内存相关 Event ID 18/19/47/0xBC），记录 ECC 纠错/报错 |
| FR-8 | 重启循环 / 批次切换编排 | Memtest86+ 完成后自动重启回系统并续跑下一批；或 IPMI `chassis power cycle` 物理断电循环（接口预留） |
| FR-9 | 批量与参数化 | 全部行为命令行参数化；支持多机器、多批次脚本化调用；结果文件含批次名归集 |
| FR-10 | 可中断与断点续测 | `Ctrl+C` 安全停止并保留已解析结果；支持从日志尾部断点续测 |
| FR-11 | 温度/电压监控（可选） | 调用 HWiNFO64 日志或 IPMI 传感器读取 DIMM 温度 / VDD/VDDQ，辅助温度判定 |

---

## 4. 非功能需求（NFR）

| 编号 | 需求 | 说明 |
| --- | --- | --- |
| NFR-1 | 自动化 | 从引导、测试、捕获、解析到汇总全链路尽量无人值守；USB 方式为半自动（需人工插拔） |
| NFR-2 | 稳定性 | 支持 72h 连续编排不崩；SOL 断连自动重连；解析容错（坏行跳过并告警） |
| NFR-3 | 可操作性 | 全部参数化、缺省即用；内置 `-Help`；错误信息中文可读 |
| NFR-4 | 兼容性 | Windows PowerShell 5.1 原生可跑；ipmitool 等外部依赖说明安装方式 |
| NFR-5 | 可追溯 | 每根条子以序列号关联 Memtest86+ 结果与识别信息，可汇入 `master_manifest.csv` |
| NFR-6 | 安全 | 引导/重启类操作需显式参数确认（-ConfirmSwitch）；不破坏系统引导配置（EFI 引导使用一次性启动项） |

---

## 5. 验收标准

| 对应需求 | 验收判据 |
| --- | --- |
| FR-1 | 批次 CSV 含每根槽位/序列号/型号/容量/频率/DDR5 判定，与 BIOS 一致 |
| FR-2 | 能按指定方式启动 Memtest86+ 并进入测试，参数（maxpasses/testlist/串口日志）生效 |
| FR-3 | 捕获到完整 MTLOG 输出（含 start banner 与 ev=done） |
| FR-4 | 正确解析轮次、错误地址、测试号；错误样例能被识别并记录 |
| FR-5/FR-6 | 4 轮 0 错误 → PASS 并写入报告；人为制造错误 → 判 FAIL 且含错误明细 |
| FR-7 | 有 ECC 事件时能捕获记录；无事件显示"未检测到" |
| FR-8 | `maxpasses` 完成后自动重启回系统，续跑下一批 |
| FR-9 | 相同命令多机运行，结果文件名含批次名无冲突 |
| FR-10 | Ctrl+C 后已解析结果保留，重跑可续测 |
| NFR-2 | SOL 断连一次后自动重连并补抓，不丢结论 |

---

## 6. 参数定义（CLI）

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `-BatchName` | string | 时间戳 | 批次名，用于文件名与归集 |
| `-BootMethod` | enum | SOL | `SOL`（BMC 串口）/ `USB`（U 盘报告）/ `EFI`（一次性引导） |
| `-BmcHost` / `-IpmiArgs` | string | — | SOL 方式：BMC IP 与 ipmitool 连接参数 |
| `-SerialPort` | string | COM1 | 串口直连方式端口 |
| `-UsbDrive` | string | — | USB 方式：U 盘盘符（报告导出目录） |
| `-EfiImage` | string | — | EFI 方式：`mt86plus.efi` 路径 |
| `-MaxPasses` | int | 4 | Memtest86+ `maxpasses` 轮数（0=不限） |
| `-TestList` | string | 全测试 | Memtest86+ `testlist`（如 `0,1,2,3`） |
| `-ExpectedCsv` | string | — | 预期清单（FR-1 匹配用） |
| `-MonitorEcc` | switch | off | 是否同时监控 WHEA/ECC |
| `-RestartLoop` | int | 0 | 批次切换重启循环次数 |
| `-LogPath` | string | `.\memory_results\` | 输出目录 |
| `-ConfirmSwitch` | switch | off | 确认允许执行引导/重启操作 |
| `-Help` | switch | off | 打印参数说明 |

---

## 7. 技术方案要点

- **MTLOG 日志格式**（Memtest86+ `log=` 模式）：每事件一行 `MTLOG ts=<seconds> ev=<event> key=value ...`，事件包括 start banner、system info、pass/test 生命周期、定时进度、**错误**（含错误地址/测试号）、`ev=done`（测试完成信号，`maxpasses` 后输出并重启）
- **SOL 捕获（推荐服务器方案）**：PowerShell `Start-Process ipmitool sol activate`（Windows 版 ipmitool / 厂商 SOL 工具）抓取 BMC 串口会话到文件 → 后台持续读取 → 解析 MTLOG
- **USB 报告**：Memtest86+ v9 支持将报告导出到 U 盘；PowerShell 在测试完成后读取 U 盘报告文件解析合并
- **EFI 一次性引导**：`bcdedit /set {fwbootmgr} bootsequence {guid}` 指向 `mt86plus.efi`，一次性引导不影响默认启动项
- **识别与汇总**：`Get-CimInstance Win32_PhysicalMemory`（SMBIOSMemoryType=34 判定 DDR5）；结果按槽位映射序列号，`Export-Csv` 合并 `master_manifest.csv`

---

## 8. 与 17 项方案的映射（追溯矩阵）

| 17 项 | 本工具需求 | 归属阶段 |
| --- | --- | --- |
| 1 SPD 校验 | FR-1 | L1 全量 |
| 2 基础识别 | FR-1 | L1 全量 |
| 3 全地址覆盖 | FR-2/3/4/5（Memtest86+ 执行） | L1 全量 |
| 4 ECC 验证 | FR-7 | L2 抽样 |
| 5 ORT 72h | FR-2/3/5（`maxpasses` 长跑） | L2 抽样 |
| 10 重启循环 | FR-8 | L2 抽样 |
| 15 多平台兼容 | FR-1/2/5 | L2 抽样 |
| 16 混插压力 | FR-2/3/5 | L1 全量 |
| 6–9, 11–14, 17 | 不在范围（外包/人工） | L3 |

---

## 9. 风险与限制（明确声明）

1. **引导方式依赖环境**：SOL 方式需服务器带 BMC/IPMI 串口重定向（SOL）；USB 方式需人工插拔；EFI 方式需 UEFI 且一次性引导在部分固件上不可用。实现时三种方式并存，按环境选择。
2. **不替代 Memtest86+ 本身**：本工具只编排与汇总，测试能力完全依赖 Memtest86+。
3. **重启行为**：`maxpasses` 后 Memtest86+ 自动重启，需确保重启回到系统并续跑批次（FR-8 处理）。
4. **性能受限项**：系统满载 ORT（第 5 项）如需 85%+ 满负载，可另配合 stress-ng/stressapptest 补充。
