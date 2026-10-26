# 设计规格 · 指令记录（cmdlog）

> 状态：[当前有效]（2026-10-25）
> 变更记录：2026-10-25 新建（需求经用户核对确认）

## 1. 背景与目标

项目使用过程中（Diag-Bmc / Run-MemtestSuite / build / 手工 ipmitool 等）执行了哪些指令、
传了什么参数、结果如何，目前没有集中记录，排查问题时只能靠回忆/聊天记录。
目标：**自动记录本项目每个指令**，结构化、可筛选、密码打码，便于后续排查。

## 2. 需求（用户已确认）

| 决策点 | 确认结果 |
| --- | --- |
| 捕获方式 | **脚本级结构化日志（常开） + 可选会话转录（Start-Transcript 包装）** |
| 开关 | **常开**（默认写，无需操作；不做配置开关） |
| 输出格式 | **CSV**（Excel 直接筛选） |
| 敏感信息 | BMC 密码等**必须打码为 \*\*\*** |
| 存储位置 | `<包根>\results\cmdlog\`（按日期滚动） |

## 3. 设计

### 3.1 核心函数 `Write-CmdLog`（lib_common.ps1 新增）

```powershell
function Write-CmdLog {
    param(
        [string]$Script,          # 脚本名（如 Run-MemtestSuite）
        [string]$Args = '',       # 参数原文（$MyInvocation.Line，内部打码）
        [string]$State = 'Start', # Start / End
        [string]$Result = '',     # 结果摘要（OK / FAIL: xxx / 超时 等）
        [int]$ExitCode = 0,       # 退出码
        [double]$DurationSec = 0  # 耗时（秒）
    )
    # 自动字段：Timestamp、Machine($env:COMPUTERNAME)、Dir($PWD)
    # Args 打码：-BmcPass xxxx / -BmcPass=xxxx / -P xxxx / -P=xxxx / password: xxxx → ***
    # 落盘：<包根>\results\cmdlog\commands-YYYY-MM-DD.csv（包根 = $PSScriptRoot\..\，跨脚本自动）
    # 文件不存在 → 写 header；存在 → 追加行（不重复 header）
}
```

**打码规则**（正则，`$Args` 上做）：
- `-BmcPass\s+(\S+)` → `-BmcPass ***`
- `-BmcPass=(\S+)` → `-BmcPass=***`
- `-P\s+(\S+)` → `-P ***`（ipmitool 密码）
- `-P=(\S+)` → `-P=***`
- 交互输入密码（`Read-Host -AsSecureString`）不在命令行，无需处理。

**CSV 字段**：`Timestamp, Machine, Dir, Script, Args, State, Result, ExitCode, DurationSec`
（`Args` 为逗号/引号时用 ConvertTo-Csv 正确转义）。

**包根定位**：`$PSScriptRoot\..\results\cmdlog\`（lib_common 在所有脚本脚本目录，向上两级即包根）。
确保目录不存在时自动创建（`New-Item -Force`）。

### 3.2 各脚本接入（Start + End 两行）

接入范围（本次）：`Run-MemtestSuite`、`Diag-Bmc`、`check_env`、`Run-ServerAssessment`、
`New-MemtestSolIso`、`build`、`Identify-Memory` 共 7 个脚本。

- **Start**：脚本主流程开始处（-Help 处理之后、密码提示之前）记一条：
  `Write-CmdLog -Script '<名>' -Args $MyInvocation.Line -State Start`
- **End**：每个出口（成功结束、各 `exit` 分支）前记一条：
  `Write-CmdLog -Script '<名>' -State End -Result 'OK|FAIL: <原因>|超时' -ExitCode <code> -DurationSec <秒>`
- 为控制改动量，End 记录在现有各 `exit`/结束点插入；`$MyInvocation.Line` 已含完整命令行（含参数），
  由 Write-CmdLog 内部打码。

**约定**：脚本内新增局部变量 `$scriptStartTime = Get-Date` 于 Start 处，End 处
`-DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds`。

### 3.3 可选会话转录 `Start-CommandLog.ps1` / `Stop-CommandLog.ps1`

- `scripts\Start-CommandLog.ps1`：`Start-Transcript -Path "<包根>\results\cmdlog\<yyyy-MM-dd>_<HHmmss>.log" -Append`，打印路径即返回。
- `scripts\Stop-CommandLog.ps1`：`Stop-Transcript`。
- 用途：用户手动开启，记录整个会话所有输入输出（含手工 ipmitool 等命令）；排查时与 CSV 互补。

### 3.4 存储与滚动

`results\cmdlog\`：
- `commands-2026-10-25.csv`（结构化，每日一个文件）
- `2026-10-25_143025.log`（转录，手动开启生成）

## 4. 边界与异常

| 场景 | 行为 |
| --- | --- |
| results\cmdlog 目录不存在 | 自动创建 |
| 文件不存在（当天首次） | 写 header + 首行 |
| 文件已存在 | 追加行，不重复 header |
| 命令含 `-BmcPass xxx` / `-P xxx` | 打码为 `***` |
| 参数含中文/特殊字符 | ConvertTo-Csv 转义，不乱行 |
| 脚本在测试（fake 环境）跑 | 照常写日志（不影响测试断言） |

## 5. 测试策略

新增 `tests/test-cmdlog.ps1`（纯函数级）：
1. 写入 → CSV 文件创建、字段齐全（Timestamp/Machine/Dir/Script/Args/State/Result/ExitCode/DurationSec）
2. 二次写入 → 追加且 header 不重复（首行仍为 header）
3. 密码打码：`-BmcPass secret`、`-BmcPass=secret`、`-P secret`、`-P=secret` → 均无明文
4. 按日期滚动：`commands-<今天>.csv` 命名正确
5. 目录不存在时自动创建

验证命令：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-cmdlog.ps1`

## 6. 文档更新

- `docs/05-使用手册.md`：新增「指令记录（cmdlog）」小节：位置/字段/打码/查看方式/可选转录用法。
- `README.md` / `AGENTS.md`：一句话提及指令记录位置。

## 7. 不做的事（范围外）

- 不做配置开关（用户确认常开）。
- 不记录 agent（本助手）通过终端执行的命令输出（对话内可见）。
- 不记录 GUI/BMC 网页操作（无法捕获）。
- 不做 JSONL（用户确认 CSV）。
