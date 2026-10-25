# 设计规格 · Run-MemtestSuite 配置化（config/memtest-suite.conf）

> 状态：[当前有效]（2026-10-25）
> 变更记录：2026-10-25 新建

## 1. 背景与目标

`Run-MemtestSuite.ps1` 目前全部参数靠命令行传入，每次跑验收都要敲一长串
（`-BootMethod SOL -BmcHost ... -MaxPasses ... -MonitorEcc -MonitorTemp -ConfirmSwitch`）。
目标：**把可复用默认参数下沉到配置文件，命令行显式参数优先覆盖**，
让日常验收只需敲 `-BatchName`；改配置即生效，无需改脚本、无需重制 ISO。

## 2. 需求（用户确认）

- 新建配置文件 **`config/memtest-suite.conf`**（方案 B，与 `memtest-presets.conf` 同目录）。
- 支持配置以下默认参数（用户已确认集合）：

| 配置键 | 对应脚本参数 | 类型 | 默认值（用户确认） |
| --- | --- | --- | --- |
| `BOOT_METHOD` | `-BootMethod` | 枚举 SOL/USB/EFI/Serial | `SOL` |
| `BMC_HOST` | `-BmcHost` | 字符串 | `10.0.0.10` |
| `BMC_USER` | `-BmcUser` | 字符串 | `root` |
| `IPMI_TOOL` | `-IpmiTool` | 字符串 | 空（脚本默认自动发现） |
| `MAX_PASSES` | `-MaxPasses` | 整数 | `4` |
| `TEST_LIST` | `-TestList` | 字符串 | 空（全部测试） |
| `SERIAL_PARAM` | `-SerialParam` | 字符串 | `ttyS0,115200` |
| `MONITOR_ECC` | `-MonitorEcc` | 布尔 | `1`（开启） |
| `MONITOR_TEMP` | `-MonitorTemp` | 布尔 | `1`（开启） |
| `RESTART_LOOP` | `-RestartLoop` | 整数 | `0` |
| `CONFIRM_SWITCH` | `-ConfirmSwitch` | 布尔 | `1`（自动确认） |
| `EXPECTED_CSV`（键名 `EXPECTED_CSV`，对应 `-ExpectedCsv`） | `-ExpectedCsv` | 字符串 | 空 |
| `LOG_PATH` | `-LogPath` | 字符串 | 空（脚本默认 `<包根>\results\`） |

- **密码不放配置**：`BMC_PASS` 保持管道/交互输入（安全）。
- **不进配置**：`-BatchName`（每批必不同）、`-ParseOnly`/`-LogFile`（一次性）、`-Help`。

## 3. 设计决策

### 3.1 优先级

`命令行显式参数 > 配置文件 > 脚本内置默认值`。

判断"是否显式指定"用 **`$PSBoundParameters`**（仅当用户显式传了该参数时才含该键），
不能用"是否为默认值"判断（如 `MaxPasses` 默认 4，用户没传也等于 4，无法区分）。

### 3.2 配置读取

复用 lib_common.ps1 现有 **`Get-Config`**（key=value，跳过空行/`#`注释/非法键，缺文件返回空哈希表），
指定路径 `$PSScriptRoot\..\config\memtest-suite.conf`。

### 3.3 合并函数（可测试，放 lib_common.ps1）

新增纯函数 **`Merge-SuiteConfig`**，输入（配置哈希表 + $PSBoundParameters），
输出「待覆盖的默认值哈希表」：

```powershell
function Merge-SuiteConfig {
    param(
        [hashtable]$Cfg,    # Get-Config 结果（config/memtest-suite.conf）
        [hashtable]$Bound   # $PSBoundParameters（区分是否显式传参）
    )
    $r = @{}
    # 配置键 -> 脚本参数名 映射
    $map = @{
        'BOOT_METHOD'    = 'BootMethod'
        'BMC_HOST'       = 'BmcHost'
        'BMC_USER'       = 'BmcUser'
        'IPMI_TOOL'      = 'IpmiTool'
        'MAX_PASSES'     = 'MaxPasses'
        'TEST_LIST'      = 'TestList'
        'SERIAL_PARAM'   = 'SerialParam'
        'MONITOR_ECC'    = 'MonitorEcc'
        'MONITOR_TEMP'   = 'MonitorTemp'
        'RESTART_LOOP'   = 'RestartLoop'
        'CONFIRM_SWITCH' = 'ConfirmSwitch'
        'EXPECTED_CSV'   = 'ExpectedCsv'
        'LOG_PATH'       = 'LogPath'
    }
    foreach ($k in $map.Keys) {
        $param = $map[$k]
        if ($Bound.ContainsKey($param)) { continue }          # 命令行显式指定 → 配置不覆盖
        $val = $Cfg[$k]
        if ($null -eq $val -or $val.Trim() -eq '') { continue } # 配置未填 → 保持脚本默认
        switch ($param) {
            { $_ -in 'MonitorEcc', 'MonitorTemp', 'ConfirmSwitch' } {
                $r[$param] = ($val -match '^(1|true|yes)$')
            }
            { $_ -in 'MaxPasses', 'RestartLoop' } {
                $n = 0
                if ([int]::TryParse($val, [ref]$n)) { $r[$param] = $n }
            }
            'BootMethod' {
                if ($val -in @('SOL', 'USB', 'EFI', 'Serial')) { $r[$param] = $val }
            }
            default { $r[$param] = $val }
        }
    }
    return $r
}
```

要点：
- **bool**：`1/true/yes` → `$true`，其余（`0/no/false/非法`）→ `$false`。
- **整数**：`[int]::TryParse` 失败 → 忽略（保持脚本默认），不报错。
- **BOOT_METHOD**：非法值 → 忽略（保持默认 SOL）。
- **空值**：忽略。
- **缺文件**：Get-Config 返回空 → 无覆盖，等价于现状。

### 3.4 集成点（Run-MemtestSuite.ps1）

在 `-Help` 处理块之后、`$pipeIn`/密码提示之前插入（这样 `-Help` 不依赖配置；
BmcHost 来自配置时仍能触发密码提示；LOG_PATH 配置在默认值计算前生效）：

```powershell
# 配置化默认参数：命令行显式参数优先，其次 config/memtest-suite.conf，最后脚本内置默认
$suiteCfg = Get-Config -Path (Join-Path $PSScriptRoot '..\config\memtest-suite.conf')
$suiteDef = Merge-SuiteConfig -Cfg $suiteCfg -Bound $PSBoundParameters
foreach ($k in $suiteDef.Keys) { Set-Variable -Name $k -Value $suiteDef[$k] }
```

### 3.5 配置文件模板

`config/memtest-suite.conf`（含注释说明；用户确认的默认值）。
> ⚠️ 格式约束：**注释必须独占整行（`#` 开头）**。`Get-Config` 只取 `=` 后的 trim 值、
> 不剥离行尾注释——行尾注释（如 `MAX_PASSES=4 # 轮数`）会被当值解析导致 bool/int 误判。

```ini
# ============================================================
# Run-MemtestSuite 默认参数配置（config/memtest-suite.conf）
# 优先级：命令行显式参数 > 本配置 > 脚本内置默认值。
# 改此文件即生效（脚本每次启动读取）；无需重制 ISO。
# 密码不放明文：BMC 密码仍由管道/交互输入。
# 注意：本格式注释须独占整行（# 开头）；行尾注释会被当值解析，勿用。
# ============================================================

# ---- 引导方式（SOL | Serial | USB | EFI）----
BOOT_METHOD=SOL

# ---- BMC 连接（SOL 方式）----
BMC_HOST=10.0.0.10
BMC_USER=root

# ---- Memtest 参数 ----
# 轮数（0=不限）
MAX_PASSES=4
# 测试列表，如 0,1,2,3；空=全部
TEST_LIST=
SERIAL_PARAM=ttyS0,115200

# ---- 监控 / 附加 ----
# 1=开启 ECC/WHEA 监控
MONITOR_ECC=1
# 1=开启 IPMI 温度监控（仅 SOL 方式）
MONITOR_TEMP=1
# 断电-上电循环次数（需 CONFIRM_SWITCH；先实测 power cycle 再启用）
RESTART_LOOP=0
# 1=自动确认引导/重启/断电操作
CONFIRM_SWITCH=1

# ---- 识别 / 输出 ----
# 预期清单路径（如 config\expected.example.csv）
EXPECTED_CSV=
# 输出目录（默认 <包根>\results\）
LOG_PATH=
# ipmitool 路径（默认自动发现内置版）
IPMI_TOOL=
```

## 4. 边界与异常

| 场景 | 行为 |
| --- | --- |
| 配置文件不存在 | Get-Config 返回空 → 全部保持脚本默认（等价现状） |
| 配置值非法（如 `MAX_PASSES=abc`） | 忽略该键，保持脚本默认 |
| BOOT_METHOD 非法 | 忽略，保持默认 SOL |
| bool 非法（如 `MONITOR_ECC=maybe`） | 视为 `$false` |
| 命令行显式传了某参数 | 该参数配置不生效（CLI 优先） |
| 密码 | 绝不写入配置 |

## 5. 测试策略

新增回归测试 **`tests/test-suite-config.ps1`**（纯函数级，不触发真实压测），覆盖：

1. 配置缺失 → 空结果（全部保持默认）
2. 未绑定 + `MAX_PASSES=2` → 返回 `MaxPasses=2`
3. 已绑定（命令行显式传 `-MaxPasses 1`）→ 配置不覆盖（返回不含 MaxPasses）
4. 非法整数 `MAX_PASSES=abc` → 忽略
5. bool 解析：`1/true/yes`→true；`0/no/非法`→false
6. 空值 `BMC_HOST=` → 忽略
7. `BOOT_METHOD=weird` → 忽略；`BOOT_METHOD=Serial` → 生效
8. 映射完整性：13 个键全部映射到正确参数名（逐键断言）

验证命令：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-suite-config.ps1`

## 6. 文档更新

- `docs/05-使用手册.md`：新增「默认参数配置（config/memtest-suite.conf）」小节（键表 + 优先级 + 密码不放配置说明）。
- `docs/17/18/19`：命令示例简化说明（"常用默认参数已配在 config/memtest-suite.conf，可省略"）。
- `docs/19` 第 4 项（ECC）：修正说明——ECC 验证在**服务器本机**查 WHEA/mcelog（编排机 `-MonitorEcc` 读的是编排机自身 WHEA）。
- `docs/19` 第 10 项（断电）：加"先实测 `chassis power cycle` 再启用 `RESTART_LOOP`"提示。
- `config/memtest-suite.conf` 纳入离线包（build.ps1 的 config 目录同步已覆盖）。

## 7. 不做的事（范围外）

- 不改 `config/memtest-presets.conf` / 不重制 ISO（编排器参数与 ISO 引导参数无关）。
- 不改 `BMC_PASS` 存储方式（保持交互/管道）。
- 不修复 `Invoke-PowerCycleLoop` 假阳性隐患（单独任务，另行评估）。
