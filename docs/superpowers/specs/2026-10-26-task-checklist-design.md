# 任务进度追踪（批次总览 + 流程清单）设计

> 日期：2026-10-26 ｜ 状态：待评审 ｜ 对应功能：参考 disk-tests 的"任务清单-结果.md"机制，为 memory-tests 提供批次级任务进度追踪。

## 背景与 Why

memory-tests 验收涉及 17 项测试、跨编排机+服务器双机、长周期（72h ORT），目前进度靠人工对照手册排查。disk-tests 已有成熟机制：测试前生成"任务清单"（计划），每走完一个环节自动更新该行（状态/结果/产物），全跑完得到总结论。本功能把该机制移植到 memory-tests，并适配双机环境与"环境不支持自动标注"。

## Goals

- 批次级**总览清单**一张：17 项测试项一览（状态/结果/原因/关联流程），底部总结论。
- 每个**流程一张明细清单**（建档/Memtest/混插/ECC/断电循环/ORT/Prime95/多平台/目检电性/L3外包），环节表沿用 disk-tests。
- **环境不支持自动标注**：读能力评估（`assessment\srv01-assessment.csv`），`需*/条件*/外包*` → ⚠ 无法测试 + 原因。
- **自动化更新**：Run-MemtestSuite（各档位）、Run-Prime95Stress、断电循环、ORT 完成时自动更新；人工项（目检/L3/多平台）手动更新命令。
- **双机合并**：服务器侧（建档/Prime95）更新服务器副本，编排机侧更新编排机副本；`Import-ServerResults` 归集时并入合并 → 编排机总览 = 完整视图。
- 清单创建 = 手动命令 + 测试脚本自动兜底（幂等）。

## Non-goals（明确不做）

- 不做 GUI/网页视图（纯 Markdown 清单，同 disk-tests）。
- 不做跨机实时同步（服务器隔离断网，归集合并是搬运时的一次性合并）。
- 不做自动跑测试（清单只追踪，不调度）。
- 不追溯历史批次自动补清单（只从本功能上线后新批次开始）。
- 不做"无法测试"的人工绕过校验（用户可用手动命令覆盖标注）。

## 约束（Global Constraints）

- PowerShell 5.1；函数放 `lib_common.ps1`（双机可调）；cmdlog 记录。
- 文件：各机器 `results\<批次>\任务清单-总览.md` + `任务清单-<流程>.md`，其中 **批次 = 验收批次（-ChecklistBatch，缺省=建档批次 BatchName）**；各测试脚本用 `-ChecklistBatch` 显式指向同一份清单（建档时建好，后续每轮都更新它），保证总览汇总 17 项。
- 状态集：`✓ 做成 / ✗ 没做成 / ─ 本次没做 / ⏳ 进行中 / ⚠ 无法测试`。
- 总览表列：`# / 测试项 / 状态 / 结果摘要 / 原因 / 关联流程清单`。
- 流程清单表列：`环节 / 要做什么 / 状态 / 结果 / 产物`（disk-tests 同款）。
- 总览底部总结论：各状态计数 + 备注。
- 清单按验收批次隔离（`results\<验收批次>\`）；UTF-8 读写（防中文乱码，disk-tests 教训）。
- 环境不支持映射（读 srv01-assessment.csv 的 Status 列，**细化**）：`可测*`→`─ 等待执行`；**`需编排机/需带内`→`─ 待执行`（换执行方，非环境不支持）**；`需 BMC/需条件*`→`⚠ 无法测试`+Action 原因；`外包*`→`⚠ 无法测试`+`外包送检（L3）`。评估 CSV 缺失 → 提示"先跑能力评估（或合并）或手动标注"，清单仍生成（全 `─`）。
- 归集合并规则：流程清单（建档/Prime95 等服务器独有）→ 直接带入；**共享清单（总览/混插）逐行取"有实际状态"的一方**（⚠ 视为有状态；两边均 `─` 取服务器侧）；**Import 合并后写回编排机 `results\<验收批次>\`（不存在则建）**。
- 打包纪律：逻辑代码调整后 `build.ps1 -Zip` 重打包。

## 设计细节

### New-TaskChecklist（手动命令 `New-TaskChecklist.ps1` + lib_common 函数）

```
New-TaskChecklist.ps1 -BatchName <建档批次> [-ChecklistBatch <验收批次，缺省=BatchName>] [-MachineName <机器名>] [-ExpectedCsv <可选>]
```

流程：
1. `Write-CmdLog` Start。
2. 建 `results\<批次>\` 目录（不存在则建）。
3. 写 `任务清单-总览.md`：
   - 头：批次 / 被测服务器（MachineName）/ 条子摘要（读建档 `results\<批次>.csv` 若存在，否则留空）/ 计划（BatchName）/ 开始时间。
   - 表：17 行测试项（编号 1-17，名称与手册 20 流程对应），初始状态 `─ 等待执行`。
   - **环境不支持标注**：读 `results\assessment\<机器名>-assessment.csv`（或 srv01-assessment.csv，按传入 MachineName 匹配），`需*/条件*/外包*` 行 → `⚠ 无法测试` + 原因（Action 列）；评估缺失 → 提示 + 全 `─`。
   - 底部总结论：`总结论: ✓0 ✗0 ─17 ⏳0 ⚠0（备注：评估缺失等）`。
4. 写 10 张流程清单（环节集见下），初始行 `─ 等待执行 | 无`。
5. `Write-CmdLog` End + exit 0。

**测试项 ↔ 流程清单映射**（总览行 → 关联流程清单）：

| 总览测试项 | 关联流程清单 | 环境依赖（评估项） |
| --- | --- | --- |
| 1 SPD 信息校验 / 2 基础识别 | 建档 | 无 |
| 3 全地址读写覆盖(Memtest) | Memtest | 无 |
| 4 ECC 纠错功能验证 | ECC | 4（ECC 平台） |
| 5 72h ORT 老化烧机 | ORT | 5（需 BMC+测温） |
| 6-9 电压/时序/高低温/湿热 | L3外包 | 外包 |
| 10 反复上电掉电循环 | 断电循环 | 10（需 BMC） |
| 11-14 ESD/振动/冲击/弯曲 | L3外包 | 外包 |
| 15 多平台兼容 | 多平台 | 15 |
| 16 多通道混插压力 | 混插 | 16（插满≥2根） |
| 17 外观/焊点/电性复检 | 目检电性 | 无 |

**流程清单环节集**：

| 流程清单 | 环节（f/n 键） |
| --- | --- |
| 建档 | 识别条子 / 生成清单 / 与预期比对(防调包) |
| Memtest | 快筛 / 1轮全项 / 2轮快筛 / 2轮全项 / 4轮快筛 / 4轮全项（对齐 memtest-presets.conf 的 8 档 SOL 预设，含 72hORT 归 ORT 流程） |
| 混插 | Memtest 混插组合 / Prime95 长压 |
| ECC | ECC 计数判读 / WHEA 交叉验证(可选) |
| 断电循环 | 能力确认 / 200 次循环 |
| ORT | 72h 满载 / 全程测温 / 口径B结论 |
| Prime95 | 冒烟(首用) / 正式长压 |
| 多平台 | 另一台识别 / 快筛 / 满载 |
| 目检电性 | 目检金手指焊点 / 万用表电性 |
| L3外包 | 电压/时序/高低温/湿热/ESD/振动/冲击/弯曲 送检 |

### Update-TaskChecklist（lib_common 函数，双机可调）

```
Update-TaskChecklist -ChecklistPath <results\<批次>\任务清单-<流程>.md>
    -Key <环节名> -Status <✓/✗/─/⏳/⚠> -Result <结果说明> -Product <产物文件|无>
```

- 复用 disk-tests 实现：UTF-8 读全文 → 按 `^\| \d+ \|` 定位表格行、第 3 列（环节）匹配 Key → 更新 状态/结果/产物 三列 → 写回（UTF-8 无 BOM，`\r\n`）。
- 同时提供 `Update-OverviewRow`（lib_common）：更新总览某测试项行的状态/结果/原因（按测试项编号或名称定位）。

### 自动化挂点（改现有脚本）

- `Run-MemtestSuite.ps1`：新增 `-ChecklistBatch`（验收批次，缺省=BatchName）与 `-Scenario`（`标准`/`混插`，缺省标准）参数。
  - 标准场景：压测完成（报告生成后）更新 Memtest 流程清单对应档位行 + 总览第 3 项（**摘要保留最高档位结论**：同一验收批次多次跑，第 3 项只记录最新一次 PASS/FAIL 且 Result 注明档位，最终验收看 4 轮全项行；`PASS`→✓、`FAIL`→✗）。
  - 混插场景（`-Scenario 混插`）：更新混插清单"Memtest 混插组合"环节 + 总览第 16 项。
  - RestartLoop 完成 → 更新断电循环"200 次循环"环节（Result 记实际 N 次）+ 总览第 10 项。
  - 清单缺失时自动 `New-TaskChecklist`（兜底，编排机侧）。
- `Run-Prime95Stress.ps1`：新增 `-ChecklistBatch`（缺省=BatchName）。完成 → 更新 Prime95 流程清单（冒烟/正式按 Minutes 判定）+ 混插清单"Prime95 长压"环节；**不直接标总览第 5 项**（第 5 项由 ORT（Memtest）流程更新，口径 B 需 Memtest 报告温度/ECC）；总览第 16 项由混插流程在 Prime95 环节完成时汇总。清单缺失自动建（服务器侧）。
- `Identify-Memory.ps1`：完成后更新建档清单（识别/生成清单/比对三环节）+ 总览第 1/2 项；**此处建立验收批次清单**（-ChecklistBatch=BatchName），供后续脚本指向。
- 归集脚本 `Export-ServerResults.ps1`：打包范围加 `results\<验收批次>\任务清单-*.md`（若存在）。
- `Import-ServerResults.ps1`：导入后合并任务清单——流程清单直接带入；共享清单（总览/混插）逐行取有状态方；**合并结果写回编排机 `results\<验收批次>\`（不存在则建）**。

### 人工更新命令

```
Update-TaskChecklist.ps1 -BatchName <批次> -Flow <目检电性|L3外包|多平台> -Key <环节> -Status <✓|✗|─> -Result <...> -Product <...>
```

## 验收

- 单元测试 `tests/test-task-checklist.ps1`（临时目录黑盒）：New 生成总览+10 流程清单（结构/状态初始）；评估 CSV 有/无两种标注；Update 按环节更新单行/多行；总览更新；合并规则（流程清单带入、总览逐行取有状态方）。
- 手动冒烟（编排机本机）：`New-TaskChecklist.ps1 -BatchName demo` → 看 results\demo\ 结构；跑一条人工更新 → 看文件变化。
- 回归：test-prime95 / test-results-import / test-ort 等全绿。
- 打包：`build.ps1 -Zip` 后包内含新脚本/函数、hash 一致。
- 双机验证（服务器侧）：建档/Prime95 跑完更新服务器副本 → 归集 → 编排机合并后总览完整。

## 交付物

- 脚本：`scripts\New-TaskChecklist.ps1`、`scripts\Update-TaskChecklist.ps1`（薄壳调用 lib_common）
- lib_common：`New-TaskChecklist`、`Update-TaskChecklist`、`Update-OverviewRow`、总览/清单生成辅助
- 改：`Run-MemtestSuite.ps1`、`Run-Prime95Stress.ps1`、`Identify-Memory.ps1`、`Export-ServerResults.ps1`、`Import-ServerResults.ps1`
- 测试：`tests\test-task-checklist.ps1`
- 文档：手册 20 加"流程 11 · 任务进度追踪"；docs/19 同步
- 打包 v15（bump；基线 v14 已由另一会话 prime95-mode-log-fix 提交并打包）→ 交 U盘
