# 动态温度采样间隔（ORT 模式）Design

> 状态：[草稿，待 builder-check 与用户确认]
> 变更记录：2026-10-28 新建

## 背景

ORT 模式温度采样目前固定 `-TempIntervalMin 60`（默认）。用户短测（10min/20min/30min/1h）时 60 分钟间隔导致整个测试只有 1 轮采样，看不到温度趋势；长测（24h+）60 分钟恰好合理。需求：**采样间隔按时长动态自适应**，短测多轮、长测每小时 1 点。

## 策略（用户已确认）

分档期望轮数 + 间隔截断（**修正版，builder-check 后**）：

```
期望轮数 TargetSamples = MaxMinutes ≤ 60  → 4
                         否则              → 12        ← 修正：12h 档也按 12 折算 → 60min（与表格一致）
间隔 IntervalMin = clamp( ceil(MaxMinutes / TargetSamples), 下限1, 上限60 )
```

验算：120→ceil(120/12)=10 ✓、180→15 ✓、360→30 ✓、720→60 ✓、1440→120→clamp 60 ✓、4320→360→clamp 60 ✓——与表格全一致（12h 起全部 60min）。

| 时长 | 期望轮数 | 间隔 | 实际轮数 |
|---|---|---|---|
| 10/20/30/60 min | 4 | 3/5/8/15 min | ≈3.3 / 4 / 3.8 / 4 |
| 2/3/6 h | 12 | 10/15/30 min | 12 |
| 12 h | 24 | 60 min | 12 |
| 24/36/48/72 h | 24 | 60 min | 24/36/48/72 |

## 设计

### 1. 新增纯函数（lib_common.ps1，可单测）

`Get-DynamicTempIntervalMin [-MaxMinutes<int>]` → 按上表分档 + clamp 返回间隔分钟（≥1）。

### 2. 参数语义变更（Run-MemtestSuite.ps1）

- `[int]$TempIntervalMin = 60` → **默认改 0**：`0 = 动态自适应`；`>0 = 显式固定间隔`（命令行 `-TempIntervalMin` 或 config `TEMP_INTERVAL_MIN` 显式值优先，与动态互斥）。
- ORT 模式（`-MaxMinutes>0`）：`if ($TempIntervalMin -le 0) { $TempIntervalMin = Get-DynamicTempIntervalMin -MaxMinutes $MaxMinutes }`，然后打印实际间隔（`===== ORT 模式：目标 X 分钟，温度上限 Y°C，采样间隔 Z 分钟(动态) =====`）。
- **config `TEMP_INTERVAL_MIN` 默认值必须改 0**（`config\memtest-suite.conf` + `memtest\config\memtest-suite.conf` 两处 `TEMP_INTERVAL_MIN=60`→`0`）——否则 config 会覆盖脚本默认 0，动态永不生效；显式数值 → 固定（映射已支持）。
- **兼容性**：Start-OrTTempSampling 的 `IntervalMin -gt 0` 判断保留（动态结果 ≥1，不会 0 死循环）；普通压测（非 ORT）不受影响（`-MonitorTemp` 单点读取路径不变）。

### 3. 文档

- `docs/20-纯命令行压测手册.md`：流程 6 ORT 参数说明补一行——`-TempIntervalMin 0=动态自适应（默认：≤1h→4轮、2-6h→12轮、12h+→60分钟）`；`>0` 显式固定。**并修订流程 6 现有文案 L212"全程自动测温（默认每小时一次）"为"全程自动测温（间隔按时长动态自适应）"**。
- Run-MemtestSuite Help 文本同步（L125 处，默认 60 → 0=动态）。

### 4. 测试

- `tests/test-ort.ps1` 追加 `Get-DynamicTempIntervalMin` 用例：断言 12 个时长档（10→3、20→5、30→8、60→15、120→10、180→15、360→30、720→60、1440→60、2160→60、2880→60、4320→60）。
- 回归：test-ort / test-lib / test-task-checklist 等全绿。

### 5. 打包

- 逻辑代码调整 → `build.ps1 -Bump -Zip`（v17→v18），hash 校验 + kit 同步提交。

## 验收

- 函数单测 12 档全断言通过；
- ORT 冒烟（如 `-MaxMinutes 10`）打印实际间隔 3 分钟（动态），无显式参数时生效；
- 显式 `-TempIntervalMin 60` 仍固定 60（覆盖动态）。

## 影响范围

- 改：lib_common.ps1（加 Get-DynamicTempIntervalMin，可顺手把 Start-OrTTempSampling 参数默认 60 对齐 0）、Run-MemtestSuite.ps1（默认 0 + 动态计算 + 打印）、config\memtest-suite.conf（+kit 副本，TEMP_INTERVAL_MIN 60→0）、docs/20（补参数说明 + 修订 L212 文案）、Help。
- config 映射逻辑不动。
- 行为变化：`-TempIntervalMin` 默认语义从"固定 60"变为"动态"，已用显式值的用户不受影响。
