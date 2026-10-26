# Memtest86+ 72h ORT 老化模式 + 可选 Windows 整机满载 —— 设计文档

> 日期：2026-10-26 ｜ 状态：待评审 ｜ 关联：[20-纯命令行压测手册.md](../../20-纯命令行压测手册.md) 流程 6

## 1. 背景与意图（why）

被测服务器（Hygon · 64GB · DDR5-5600 · ECC=True）验收需覆盖第 5 项「72h ORT 满载老化」。原手册写的是"软件需自备：stress-ng / stressapptest / TM5"——但：

- `stress-ng` 只有 Linux 版，被测服务器是 Windows，装不了；
- 同类工具中语义最接近的 `stressapptest` 也没有原生 Windows 版（需 WSL2/Cygwin 编译）；
- 而套件**已内置 Memtest86+**（`boot\memtest-sol.iso` + 编排器 SOL 抓日志/逐轮报告/ECC 轮询/测温全自动化），只是现有 `Run-MemtestSuite.ps1` 是"跑 N 轮"的语义，**没有"时长达标 + 结论判据"的 72h ORT 维度**——`-MaxPasses 40` 只是"碰巧跑够久"，判不了"72h 老化通过"。

用户已拍板：**主 = Memtest86+ 72h ORT 模式（结论口径 B）**；测完没问题后再决定是否补 **Windows 内整机满载（Prime95，可选测试项）**。

## 2. 目标 / 非目标 / 反目标

**目标**
1. 给 `Run-MemtestSuite.ps1` 增加 **ORT 模式**（新参数 `-MaxMinutes`），支持"引导 Memtest86+ 无限轮跑 + 按目标时长终止 + 时长/错误/ECC/中断/温度全量留痕 + 给出 72h 老化结论"。
2. 新增 ISO 预设「72h ORT 无限轮」并重制 `memtest-sol.iso`（GRUB 菜单可选手动选此项引导）。
3. ORT 结论口径 B（用户确认）：**PASS = 实际运行时长 ≥ 目标时长 且 Errors=0 且 EccErrors=0 且 日志无中断 且 全程温度采样不超阈值**。
4. 新增批次级 ORT 报告 `reports\<批次>-ort-report.csv`，并追加一条到 `master_manifest.csv`。
5. 温度监控升级：ORT 模式下**自动**全程定时采样（默认每小时一次），落盘 `reports\<批次>-temp.csv`。
6. 可选：内置 **Prime95**（官方 mersenne.org Windows 版）进 `tools\`，作为可选测试项，手册给出"服务器进 Windows 后整机满载"的命令与判读；**不作为主流程**。
7. 文档同步：手册 20 流程 6 改写；18/19/02/03 中 "stress-ng 需自备" 相关描述更新。

**非目标（不做）**
- 不打包 stress-ng / stressapptest（无原生 Windows 版，装不上）。
- 不写 Prime95 的自动化包装脚本（保持最小改动；仅打包 + 手册命令）。
- 不做 SOL 断线自动重连（断线即判 FAIL 重跑，见 §4.2——诚实且简单，避免 72h 后"假 PASS"）。
- ORT 主用 SOL；Serial 方式可同逻辑支持；USB/EFI 方式不支持时长终止 → 报错退出。

**反目标（做了就算失败）**
- 结论里出现"跑了 72h 但没证据"的模糊 PASS（必须有时长/错误/ECC/中断/温度五项留痕）。
- 破坏现有 `-MaxPasses` 快筛/全项流程（向后兼容，默认行为不变）。
- 破坏 `master_manifest.csv` 既有列结构（ORT 行复用现有列，不加新列）。
- 破坏 build.ps1 的离线幂等性（Prime95 由人工预置，build 不联网）。

## 3. 约束（已核实的事实）

- PowerShell 5.1；脚本风格沿用现有 `Run-MemtestSuite.ps1`（cmdlog、`Get-AppVersion`、固定列投影写 CSV）。
- 参数优先级：命令行显式参数 > `config\memtest-suite.conf` > 脚本内置默认。
- SOL 引导用的是**预制 ISO**（`boot\memtest-sol.iso`），其 GRUB 预设由 `config\memtest-presets.conf` + `New-MemtestSolIso.ps1` 生成；**现有预设全部带 `maxpasses=N`，无无限轮预设** → ORT 需新增预设并重制 ISO，服务器侧需重新挂载新 ISO。
- MTLOG 格式已确认：每事件 `MTLOG ts=<float> ev=<name> ...`，带时间戳；事件含 `start / spd / pass_start / pass_end / test_start / test_end / done / addr / data / parity / ecc / uecc`（见 `tests\fixtures\sample-pass.mtlog.txt`）。
- `pass_end` 的 `errors` 字段按现有解析器（`Invoke-MtlogParser`，lib_common.ps1 L186-188）为**累计语义**（`$summary.Errors` 被最后一条 pass_end 覆盖 = 全程累计）。ORT 结论的 `Errors` 取最后一条 `pass_end` 的 errors。
- 无限轮模式下 Memtest86+ **不会主动发 `ev=done`** → ORT 终止只能靠"到达目标时长掐断 SOL"。
- 打包纪律（AGENTS.md）：改动后必须 `build.ps1 -Bump -Zip` 重新打包，先删旧包再建，校验 hash。

## 4. 方案设计（how）

### 4.1 新参数（Run-MemtestSuite.ps1 + config\memtest-suite.conf）

| 参数 | config 键 | 默认 | 说明 |
| --- | --- | --- | --- |
| `-MaxMinutes` | `MAX_MINUTES` | `0`（不启用） | ORT 目标时长（分钟），如 72h=4320。>0 即进入 ORT 模式 |
| `-TempLimitC` | `TEMP_LIMIT_C` | `85` | 温度判 FAIL 阈值（°C），任一采样超限即 FAIL；≤0 = 不启用温度判据 |
| `-TempIntervalMin` | `TEMP_INTERVAL_MIN` | `60` | ORT 模式温度采样间隔（分钟） |
| `-OrtBufferMin` | `ORT_BUFFER_MIN` | `10` | SOL 捕获在目标时长后再多留的缓冲分钟（覆盖引导延迟） |
| `-OrtMaxGapMin` | `ORT_MAX_GAP_MIN` | `30` | 日志连续判定：相邻事件 ts 间隔超过该值即视为"日志中断"（含 SOL 断线静默期） |

**ORT 模式触发规则**：`$MaxMinutes -gt 0`。
- 引导说明：ORT 需服务器引导菜单选「72h ORT 无限轮」预设（新预设，见 §4.8）。
- `-RestartLoop -gt 0` 与 ORT 模式**互斥**：同时启用 → 报错退出。
- 显式同时给了 `-MaxPasses` 与 `-MaxMinutes` → `-MaxMinutes` 优先，警告提示。
- 非 SOL 引导方式：Serial 支持同逻辑；USB/EFI 不支持时长终止 → 报错退出。

### 4.2 SOL 捕获（Invoke-SolCapture 扩展）与时长/中断判定

- 超时参数 = `$MaxMinutes + $OrtBufferMin`；终止条件 = 出现 `ev=done`（异常早停）或达到超时。
- **ActualMinutes**（口径 B 的时长判据）取两个证据的最小值，防"捕获窗口够了但日志实际没跑够"：
  1. 捕获窗口 = `CaptureEnd - CaptureStart`；
  2. 日志证据 = 最后一条事件 ts − `ev=start` 的 ts（memtest 内部时钟，秒）。
- **日志中断判定**（口径 B 的中断判据，任一即 FAIL）：
  1. `ev=start` 出现 >1 次（memtest 中途重启）；
  2. 相邻事件 `ts` 最大间隔 > `OrtMaxGapMin` 分钟（覆盖 SOL 静默断线——memtest 持续输出，间隔异常即断线证据）；
  3. 捕获窗口内、目标时刻前，日志文件停止增长超过 `OrtMaxGapMin` 分钟（SOL 会话断线的直接信号）。
- 不做自动重连：出现上述断线信号 → 结论 FAIL（注明"SOL 中断于第 X 分钟"），按反目标"不做假 PASS"处理。

### 4.3 ORT 结论口径（口径 B，抽成纯函数便于验收）

抽独立纯函数 `Get-OrTVerdict`（输入：ActualMinutes / TargetMinutes / Errors / EccErrors / StartEventCount / MaxEventGapMin / MaxTempC / TempSamples / TempLimitC；输出：Status / Conclusion），便于 §6 单元验收。

**PASS** 需同时满足：
1. `ActualMinutes ≥ MaxMinutes`；
2. `Errors == 0`（取最后一条 `pass_end` 的 errors）；
3. `EccErrors == 0`；
4. 日志无中断（§4.2 三条判定全不触发）；
5. 温度：`TempSamples ≥ 1` 且 `MaxTempC ≤ TempLimitC`（`TempLimitC ≤ 0` 时跳过温度判据）。

**FAIL** 触发条件（结论标注原因）：
- 时长不足（含出现 `ev=done` 的异常早停、SOL 中断）；
- `Errors > 0` 或 `EccErrors > 0`；
- 日志中断（多次 `ev=start` / ts 大间隔 / 日志停止增长）；
- 超温或温度采样全失败（`TempSamples = 0` → FAIL，注明"温度数据缺失"）；
- 捕获失败/无日志（沿用现有失败路径）。

### 4.4 ORT 报告与留痕

新增批次级 `reports\<批次>-ort-report.csv`（一行）：

```
Batch, ToolVersion, Mode, StartTime, EndTime, TargetMinutes, ActualMinutes,
TotalPasses, Errors, EccErrors, MaxTempC, TempSamples, MaxEventGapMin,
Interrupted, Status, Conclusion
```

- `Mode` = `ORT`；`Status` = `PASS` / `FAIL`；`Interrupted` = 中断判定结果（true/false）；`Conclusion` = 结论文本（PASS 或对应 FAIL 原因）。
- `TotalPasses` 取最后一条 `pass_end` 的 `pass+1`（截断日志无 `ev=done` 时的正确口径）。

`master_manifest.csv` 追加一行（**复用现有列，不加新列**）：
`Slot=ALL, SerialNumber/PartNumber=空, CapacityGB=0, SpeedMTs=0, MemType=空, MatchState=空, TestDate=EndTime, Passes=TotalPasses, Errors=Errors, EccErrors=EccErrors, Result=ORT PASS/FAIL`。

### 4.5 ORT 主流程结构（独立分支）

- ORT 模式走**独立分支**：**跳过** `Get-MemoryInventory` 的强制校验与 per-slot `Export-TestReport`（编排机本机 WMI 清单与服务器无关，避免误导性 per-slot 行）。
- 条子信息改从 mtlog 的 `ev=spd` 事件收集（`SpdInfo`），有则附入结论/报告（`SpdSummary` 列），无则空。
- 报告流程 = 生成 `ort-report.csv` + `temp.csv`（若有采样）+ `master_manifest` 追加一条合成行 + cmdlog 记录。

### 4.6 温度全程采样（ORT 模式，自动启用）

- ORT 模式**自动**启用（不依赖 `-MonitorTemp`；`-MonitorTemp` 保持原语义供非 ORT 使用）。
- 复用 `Get-IPMITempSensors`（读 BMC `sdr elist`）；`Start-Job` 后台循环，每 `TempIntervalMin` 分钟采样一次，长表追加写 `reports\<批次>-temp.csv`（`Timestamp, Sensor, TempC`）。
- 采样失败不中止主流程，记 warning；`TempSamples` = 成功采样次数；收尾时取全采样 `MaxTempC`（含 DIMM 传感器）。
- BMC 多会话并发：ipmitool 短命令与长 SOL 会话通常可并存；若实测并发受限（流程 0 可先验证），采样失败按 §4.3 判 FAIL 并注明。

### 4.7 可选：Prime95（Windows 整机满载，可选测试项）

- **来源**：人工预置（执行时由我下载官方 [mersenne.org](https://www.mersenne.org/download/) Windows x64 zip 并解压到 `repo\tools\prime95\`；build.ps1 零改动自动带入 kit 与 zip，保持离线幂等）。
- 用法（手册流程 6 可选章节）：服务器进 Windows 后
  - `prime95.exe -t`（Torture Test：选 "Blend" 或 "Custom→Large FFTs" 压内存）；
  - 时长 72h，日志 `results.txt`；判读：`results.txt` 无错误行 + 72h 无死机/重启 = 通过。
- **地位**：可选。先 Memtest86+ 72h ORT（口径 B）通过后，由用户决定是否再跑整机满载。
- 不做自动化包装脚本（本轮非目标；如需留痕用现有 cmdlog 转录 `Start-CommandLog.ps1`）。

### 4.8 改动清单与打包

| 文件 | 改动 |
| --- | --- |
| `config\memtest-presets.conf` | 新增预设 `preset.72hORT.title=Memtest86+ 72h ORT 无限轮（SOL）`、`preset.72hORT.cmdline=log=ttyS0,115200 ecc`（不带 maxpasses = 无限轮） |
| `boot\memtest-sol.iso` | 用 `New-MemtestSolIso.ps1` 按新预设**重制**（服务器侧需重新挂载新 ISO，引导菜单选「72h ORT 无限轮」） |
| `config\memtest-suite.conf` | 新增 `MAX_MINUTES / TEMP_LIMIT_C / TEMP_INTERVAL_MIN / ORT_BUFFER_MIN / ORT_MAX_GAP_MIN`（并入 `Merge-SuiteConfig` map） |
| `scripts\Run-MemtestSuite.ps1` | 新参数、ORT 分支、`Get-OrTVerdict`、SOL 捕获扩展、温度采样 Job、ORT 报告 |
| `tools\prime95\` | 人工预置 Prime95（可选测试项） |
| `docs\20 / 18 / 19 / 02 / 03` | 流程 6 改写 + stress-ng 描述更新 + 输出文件速查表 |

完成后 `build.ps1 -Bump -Zip`（VERSION 递增 + 先删旧包再建 + 校验 hash）。

## 5. 交给 builder 的决策点（可自行定夺）

- `Start-Job` 后台温度采样 vs 主循环内同步采样的实现选择（不改变对外行为）。
- `ActualMinutes` 分钟取整细节、`Get-OrTVerdict` 的参数形态。
- 报告 `Conclusion` 文案措辞。
- 是否过滤 DIMM 温度传感器（有更好，无则记录全部）。
- SOL 日志增长检测的实现方式（文件长度/最后写入时间轮询）。

## 6. 验收口径（改动后如何验证）

1. **单元验收**：`Get-OrTVerdict` 对五类样例分别判对：
   - 足时长+全零+无中断 → PASS；
   - 时长不足 → FAIL（原因：时长不足）；
   - Errors>0 或 EccErrors>0 → FAIL；
   - 多次 `ev=start` 或 ts 大间隔 → FAIL（中断）；
   - 超温或 TempSamples=0 → FAIL（超温/温度数据缺失）。
2. 解析回归：用 `tests\fixtures\sample-pass.mtlog.txt`（PASS）与 `sample-fail.mtlog.txt`（FAIL）跑 `-ParseOnly`，确认现有解析不受影响。
3. 实机冒烟（可选）：编排机 + 服务器跑短时长（如 `-MaxMinutes 15`），确认 ort-report/temp.csv/master_manifest 落盘格式与结论正确。
4. 打包：`build.ps1 -Bump -Zip` 成功，`memtest.zip` 时间戳为当前、包内关键文件 hash 与仓库一致；ISO 重制后 `Smoke-MemtestIso.ps1` 冒烟通过。
