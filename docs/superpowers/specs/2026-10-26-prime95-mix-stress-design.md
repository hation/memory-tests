# 混插压力（第 16 项）Windows 内长压：Prime95 替代 TM5 + 自动化包装 —— 设计文档

> 日期：2026-10-26 ｜ 状态：待评审 ｜ 关联：[20-纯命令行压测手册.md](../../20-纯命令行压测手册.md) 流程 3、[19-测试项执行清单.md](../../19-测试项执行清单.md) 第 16 项
> 变更记录：2026-10-26 初稿 → builder-check 修正（local.txt→prime.txt、实机冒烟升级为前置验收、存活判定改进程为主、-W 目录隔离等）

## 1. 背景与意图（why）

第 16 项「多通道混插压力」手册原口径为：**混插组合跑 Memtest（内置，已可全自动）+ 服务器 Windows 内跑 TM5 2–4h（TM5 未随包，需自备）**。

问题：
- TM5 是 **Windows 图形程序**，**没有无 GUI（headless）版本**；测试必须开着窗口，结果只显示在窗口/其自有日志，**无法像 memtest 那样由编排器 SOL 自动抓取** → 与用户"自动化"诉求冲突。
- 即便下载预置 TM5 进包，也只能 GUI 人工跑 + 人工记录，违背自动化初衷。

用户已拍板（方案 B）：**用 Prime95 替代 TM5 做 Windows 内混插长压**。理由：
- Prime95 **已内置进包**（`tools\prime95\`，v30.19b20，官方 mersenne.org 来源，SHA256 已校验）——零新增下载。
- 支持命令行 `prime95.exe -t` 进 Torture Test；日志落文本文件 `results.txt`（可轮询、可判读）→ **可脚本化自动化**。

## 2. 目标 / 非目标 / 反目标

**目标**
1. 新增脚本 `Run-Prime95Stress.ps1`：自动化跑 Prime95 Torture Test，支持时长（`-Minutes`，混插 2-4h / ORT 可选 72h）与模式（Blend / Large FFTs），到点自动停，判读 `results.txt` 出结论与报告。
2. 报告落盘：`results\reports\<批次>-prime95-report.csv`（时长/模式/错误数/结论），并追加一条到 `master_manifest.csv`（复用 **Export-OrTReport 同一套 14 列投影**，Slot=ALL）。
3. 结论口径（对齐 memtest/ORT 风格）：PASS = 实际运行 ≥ 目标时长 且 `results.txt` 无错误行 且 进程未被判"提前退出"。
4. 文档同步：docs/20 流程 3、docs/19 第 16 项、docs/18、docs/01、docs/02 的 Windows 内长压工具表述统一为 Prime95（内置脚本）；TM5 降级为"可选人工"。
5. 打包：`build.ps1 -Bump -Zip` 重新打包（新脚本进包 + `$keyFiles` 纳入 prime95.exe）。

**非目标（不做）**
- 不下载/不预置 TM5（无 headless，违背自动化诉求；保留"需自备、仅人工"附注）。
- 不做 Prime95 弹窗的"自动化点击"——用 `prime.txt` 预置 + 容错设计（见 §4.4），实机冒烟验证（见 §6.2）。
- 不改 memtest 部分（第 16 项 Memtest 一半保持现状：`-MaxPasses 1` 选「1轮全项」）。
- 不把 Prime95 报告并入 `Run-MemtestSuite.ps1`（独立脚本，职责单一）。

**反目标（做了就算失败）**
- 声称"自动化"但实际仍需人工盯窗口/人工判读。
- 误判 PASS：旧 `results.txt` 残留的 `FATAL ERROR` 污染本次判定；未到点进程退出被当 PASS；到点被杀被当 FAIL（口径混淆）。
- 同目录并发两个 Prime95 进程（官方已知 bug）导致结果错乱。
- 破坏既有 memtest 流程、master_manifest 列结构、build 幂等性。

## 3. 约束（已核实的事实，含 builder-check 修正）

- PowerShell 5.1；脚本风格沿用现有（`Write-CmdLog`、`Get-AppVersion`、固定列投影、`tests\test-*.ps1` Assert 约定）。
- Prime95 已内置 `tools\prime95\prime95.exe`（v30.19b20）。**官方随包文档已核实**：
  - `prime95.exe -t` 启动 Torture Test（readme L524 同义于菜单 Torture Test）。
  - **local.txt 已废弃**：v30.19 的 whatsnew 明示"Settings are no longer stored in local.txt…automatically moved to prime.txt" → **配置写 `prime.txt`，不写 local.txt**。
  - `TortureTest=` / `WorkPreference=` 键名与取值**官方文档未记载**（社区为数字枚举，无官方依据）→ 设计不假设其格式，实机验证后回填（§6.2）。
  - 日志写 `results.txt`（readme L28；v29.6+ 另有 results.json.txt，undoc 默认 OutputJSON=1）；**results.txt 时间戳默认 300 秒才写一次**（undoc ResultsFileTimestampInterval=300）→ **存活判定不能靠 30s 轮询文件变化**。
  - 进程启动后有 **BootDelay 默认 90 秒** 才开工（undoc L207-211）→ ActualMinutes 含此开销（结论注明）。
  - `-W<directory>` 参数可指定工作目录（readme L526）→ 用于批次隔离，天然避免旧日志污染与并发冲突。
  - **同目录并发 torture 有已知 bug**（whatsnew L1100）→ 启动前必须检测已有进程。
- 参数优先级：命令行显式 > 脚本内置默认（本脚本无 config 依赖，保持简单）。
- 打包纪律：改动后 `build.ps1 -Bump -Zip`；`scripts` 列表 `$scriptFiles` 显式加新脚本；**`$keyFiles` 需加 `tools\prime95\prime95.exe`**（否则 hash 比对无从谈起）。
- 报告落盘机器：脚本在**服务器** Windows 跑，report 与 master_manifest 落服务器 `results\`（与建档现状一致，跨机归集沿用现有先例、不做跨机合并）。

## 4. 方案设计（how）

### 4.1 新脚本 `scripts/Run-Prime95Stress.ps1`

**参数**：
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-BatchName` | 时间戳 | 批次标签（文件名/报告归集） |
| `-Prime95Exe` | `tools\prime95\prime95.exe` | Prime95 路径 |
| `-Minutes` | `180`（3h） | 目标时长（分钟）；混插 2-4h → 120-240 |
| `-Mode` | `Blend` | `Blend` / `Large`（Large FFTs） |
| `-LogPath` | `<包根>\results` | 输出目录 |
| `-Help` | - | 帮助 |

**流程**：
1. 校验：Prime95 存在；`-Minutes>0`；`-Mode` 合法；cmdlog Start。
2. **并发防护**：检测已有同名/同工作目录 prime95 进程 → 存在则报错退出（防官方 bug）。
3. **工作目录隔离**：建批次目录 `results\work\<批次>\`，用 `prime95.exe -t -W<该目录>` 启动（results.txt 写进批次目录，天然防旧日志污染）。`-W` 目录需先创建。
4. **预置 prime.txt**：在 `-W` 工作目录写入 `prime.txt`（含 `OutputJSON=0` 等最小键；Torture 模式键**不假设格式**，首版留空，实机验证后回填）。
5. 启动：`Start-Process $Prime95Exe -ArgumentList "-t", "-W$workDir" -PassThru -WindowStyle Minimized`；记 `StartTime`。
6. 轮询循环（每 30s）：
   - **进程活着判定（主）**：`$p.HasExited`——进程死了且未到时长 → FAIL"提前退出"；
   - **错误判定**：扫批次目录 `results.txt`，出现 `FATAL ERROR` / `Self-test failed` / `FAILED` → 记错误、**提前停止**、FAIL；
   - **文件写入辅助**：`results.txt` LastWriteTime 超过 **10 分钟级阈值** 才提示（不直接判死，仅作日志提示，因为 300s 写入间隔）；
   - **时长判定**：`(Get-Date)-StartTime ≥ Minutes` → 到点 `Stop-Process`，正常收尾。
7. 判读（口径）：`Get-Prime95Verdict`：PASS ⇔ `ActualMinutes ≥ Minutes` 且 `ErrorCount=0` 且 `ExitedEarly=$false`。
8. 报告：`Export-Prime95Report` → `reports\<批次>-prime95-report.csv` + master_manifest 合成行（Slot=ALL）。
9. cmdlog End（Result = PASS/FAIL）。

### 4.2 lib_common.ps1 新增纯函数

- `Get-Prime95Verdict [-ActualMinutes<double>] [-TargetMinutes<int>] [-ErrorCount<int>] [-ExitedEarly<bool>]` → `[PSCustomObject]@{ Status; Conclusion }`（口径如上；文案中文，FAIL 附原因）。
- `Get-Prime95LogStats [-LogFile<string>]` → `[PSCustomObject]@{ ErrorCount; HasErrors; LastWriteTime }`（扫描 results.txt 错误行计数）。
- `Export-Prime95Report [-BatchName] [-ToolVersion] [-StartTime] [-EndTime] [-TargetMinutes<int>] [-ActualMinutes<double>] [-Mode<string>] [-ErrorCount<int>] [-Verdict<object>] [-ReportDir<string>] [-LogPath<string>]` → 写 `<Batch>-prime95-report.csv` + master_manifest 追加（**复用 Export-OrTReport 的 14 列投影与合并逻辑**，Slot=ALL，Result=`Prime95 PASS/FAIL`）。

### 4.3 容错设计（弹窗未验证的处理）

- 若实机出现"Torture Test 参数对话框"，脚本无法点击 → 结果报告里提示"检测到交互弹窗，需人工选择模式后脚本自动继续轮询"（进程仍在跑，脚本等待模式被选定后再判读）；或在 `-Mode` 校验时输出提示。**首版以"无弹窗"为默认假设，实机冒烟后按真实行为回填 prime.txt 键**。
- 明确**不假设** `TortureTest=` 键格式有效——首版 prime.txt 仅写已验证的 `OutputJSON=0`（结果走 results.txt 文本，不依赖 JSON 解析），模式键留待实机回填。

### 4.4 文档同步（范围扩大）

- **docs/20 流程 3**：Memtest 部分不变；Windows 内长压改为 Prime95 自动化命令 + 判读；输出速查表流程 3 行加 `reports\<批次>-prime95-report.csv`；TM5 降级附注。
- **docs/20 流程 6（第 5 项 ORT 可选 Prime95）**：把手工 `prime95.exe -t` 改接 `Run-Prime95Stress.ps1 -Minutes 4320`（与 16 项同一脚本，避免两套用法）。
- **docs/19 第 16 项 + 第 5 项**：怎么做/输出文件两行同步。
- **docs/18 工具映射/软件清单**：第 16 项 Windows 长压工具列改为 Prime95（内置 + 脚本），TM5 移入"可选人工"。
- **docs/01、docs/02**：现有 TM5/OCCT 表述同步处理（改为"可选人工"或 Prime95 脚本）。
- 报告落盘机器写明：Prime95 部分 = **服务器本机** results（与建档现状一致）。

### 4.5 版本与打包

- `build.ps1`：`$scriptFiles` 加 `Run-Prime95Stress.ps1`；`$keyFiles` 加 `tools\prime95\prime95.exe`。
- `build.ps1 -Bump -Zip`（v12→v13）+ 包完整性校验（新脚本 + prime95.exe 在包内、hash 与仓库一致）。

## 5. 交给 builder 的决策点（可自行定夺）

- 轮询间隔 30s 的具体值；错误行精确正则（覆盖 `FATAL ERROR`/`Self-test failed`/`FAILED` 即可）。
- 报告/结论文案措辞；`-W` 目录命名（`results\work\<批次>\`）。
- 进程检测的匹配方式（按进程名 + 工作目录参数）。

## 6. 验收口径

1. **单元验收**：`Get-Prime95Verdict` 五类样例（足时长无错 PASS；时长不足 FAIL；有错误 FAIL；提前退出 FAIL；组合）；`Get-Prime95LogStats` 对含/不含错误行的样例计数正确。
2. **实机冒烟（前置验收，用户有服务器后执行；本次不跑，下次做）**：服务器 Windows 跑 `Run-Prime95Stress.ps1 -Minutes 5 -Mode Blend`——确认无人值守启动（无弹窗卡住）、results.txt 增长、到点自动停、报告 PASS。**通过后回填 prime.txt 模式键**并微调脚本（若弹窗出现则按 §4.3 容错）。
3. 打包：`build.ps1 -Bump -Zip` 成功；包内 `scripts\Run-Prime95Stress.ps1`、`tools\prime95\prime95.exe` 存在且 hash 与仓库一致（CHECKSUM 覆盖）。

## 7. 待办与已知风险

- 实机冒烟是**前置验收**，未通过前"无人值守"结论为"待验证"；文档标注该状态。
- prime.txt 模式键格式未官方记载——首版不假设，冒烟后回填（可能需迭代脚本）。
- results.txt 300s 写入间隔 → 存活判定以进程为主，文件写入仅作辅助提示（已处理，防误判）。
