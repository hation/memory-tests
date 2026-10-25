# 实施计划 · Run-MemtestSuite 配置化（config/memtest-suite.conf）

> 状态：[当前有效]（2026-10-25）
> 规格：`docs/superpowers/specs/2026-10-25-memtest-suite-config.md`
> 执行方式：subagent-driven development（每任务独立 subagent，主 agent 复核后进入下一个）

## 任务总览

| # | 任务 | 产出 | 验证命令 |
| --- | --- | --- | --- |
| 1 | lib_common.ps1 新增 `Merge-SuiteConfig` | lib_common.ps1 | 语法 + 测试 |
| 2 | Run-MemtestSuite.ps1 集成配置读取 | Run-MemtestSuite.ps1 | 语法 + 测试 |
| 3 | 新建 config/memtest-suite.conf | config/memtest-suite.conf | 读取校验 |
| 4 | tests/test-suite-config.ps1 回归测试 | tests/test-suite-config.ps1 | 测试跑通 |
| 5 | 文档更新（05/17/18/19） | 4 个文档 | grep 校验 |
| 6 | 全量回归 + 打包 + 提交推送 | zip + commit | 全部测试 PASS |

## 任务 1：lib_common.ps1 新增 Merge-SuiteConfig

**位置**：`scripts/lib_common.ps1`，紧跟 `Get-Config` 函数之后（约 346 行后）。

**代码**：

```powershell
# 合并 Run-MemtestSuite 配置默认值：命令行显式参数($Bound)优先，配置未覆盖的键不返回。
# Cfg 来自 Get-Config(config/memtest-suite.conf)；返回「需要覆盖的默认值」哈希表。
function Merge-SuiteConfig {
    param(
        [hashtable]$Cfg,    # Get-Config 结果
        [hashtable]$Bound   # $PSBoundParameters（区分是否显式传参）
    )
    $r = @{}
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
        if ($Bound.ContainsKey($param)) { continue }
        $val = $Cfg[$k]
        if ($null -eq $val -or $val.Trim() -eq '') { continue }
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

**验证**：`powershell -NoProfile -Command ". scripts\lib_common.ps1; (Merge-SuiteConfig -Cfg @{MAX_PASSES='2'} -Bound @{}).MAX_PASSES"` 输出 2。

## 任务 2：Run-MemtestSuite.ps1 集成

**位置**：`scripts/Run-MemtestSuite.ps1`，在 `-Help` 块（`exit 0` 处，约 120 行）之后、
`$pipeIn = @($input)`（约 124 行）之前插入：

```powershell
# 配置化默认参数：命令行显式参数优先，其次 config/memtest-suite.conf，最后脚本内置默认
$suiteCfg = Get-Config -Path (Join-Path $PSScriptRoot '..\config\memtest-suite.conf')
$suiteDef = Merge-SuiteConfig -Cfg $suiteCfg -Bound $PSBoundParameters
foreach ($k in $suiteDef.Keys) { Set-Variable -Name $k -Value $suiteDef[$k] }
```

**验证**：语法 `powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('scripts\Run-MemtestSuite.ps1',[ref]$null,[ref]$err); $err.Count"` 输出 0。

## 任务 3：新建 config/memtest-suite.conf

按规格 §3.5 模板创建（含注释；MONITOR_ECC=1 / MONITOR_TEMP=1 / RESTART_LOOP=0 / CONFIRM_SWITCH=1）。

**验证**：`powershell -NoProfile -Command ". scripts\lib_common.ps1; (Get-Config -Path 'config\memtest-suite.conf').MAX_PASSES"` 输出 4。

## 任务 4：tests/test-suite-config.ps1

**位置**：`tests/test-suite-config.ps1`，复用既有测试风格（`Assert` + dot-source lib_common）。

**代码**（核心用例，完整实现见 subagent brief）：

```powershell
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

# 1 配置缺失 → 空结果
Assert ((Merge-SuiteConfig -Cfg @{} -Bound @{}).Count -eq 0) "1 空配置应返回空"
# 2 未绑定 + MAX_PASSES=2 → 覆盖
$r = Merge-SuiteConfig -Cfg @{MAX_PASSES='2'} -Bound @{}
Assert ($r.MaxPasses -eq 2) "2 MAX_PASSES=2 应生效"
# 3 已绑定 → 不覆盖
$r = Merge-SuiteConfig -Cfg @{MAX_PASSES='2'} -Bound @{MaxPasses=1}
Assert (-not $r.ContainsKey('MaxPasses')) "3 显式传参配置不覆盖"
# 4 非法整数 → 忽略
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_PASSES='abc'} -Bound @{}).ContainsKey('MaxPasses')) "4 非法整数忽略"
# 5 bool 解析
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='1'} -Bound @{}).MonitorEcc -eq $true) "5a 1=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='true'} -Bound @{}).MonitorEcc -eq $true) "5b true=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='yes'} -Bound @{}).MonitorEcc -eq $true) "5c yes=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='0'} -Bound @{}).MonitorEcc -eq $false) "5d 0=false"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='maybe'} -Bound @{}).MonitorEcc -eq $false) "5e 非法=false"
# 6 空值 → 忽略
Assert (-not (Merge-SuiteConfig -Cfg @{BMC_HOST=''} -Bound @{}).ContainsKey('BmcHost')) "6 空值忽略"
# 7 BOOT_METHOD
Assert (-not (Merge-SuiteConfig -Cfg @{BOOT_METHOD='weird'} -Bound @{}).ContainsKey('BootMethod')) "7a 非法忽略"
Assert ((Merge-SuiteConfig -Cfg @{BOOT_METHOD='Serial'} -Bound @{}).BootMethod -eq 'Serial') "7b Serial 生效"
# 8 映射完整性：13 键全部映射
$cfg = @{ BOOT_METHOD='SOL'; BMC_HOST='h'; BMC_USER='u'; IPMI_TOOL='i'; MAX_PASSES='4';
          TEST_LIST='0,1'; SERIAL_PARAM='ttyS0,115200'; MONITOR_ECC='1'; MONITOR_TEMP='1';
          RESTART_LOOP='5'; CONFIRM_SWITCH='1'; EXPECTED_CSV='e'; LOG_PATH='l' }
Assert ((Merge-SuiteConfig -Cfg $cfg -Bound @{}).Count -eq 13) "8 映射 13 键"
Write-Host "ALL PASS"
```

**验证**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-suite-config.ps1` 输出 ALL PASS。

## 任务 5：文档更新

- `docs/05-使用手册.md`：新增「默认参数配置（config/memtest-suite.conf）」小节：键表 + 优先级（CLI > 配置 > 内置默认）+ 密码不放配置 + 改配置即生效/无需重制 ISO。
- `docs/17-逐步压测操作手册.md`：命令示例注释补充「常用默认参数已配在 config/memtest-suite.conf（MONITOR_ECC/MONITOR_TEMP 等），可省略」。
- `docs/18-测试方案总览.md`：§5 软件校验表或 §9 FAQ 提一句配置化；第 4 项（ECC）修正为「在服务器本机查 WHEA/mcelog，编排机 -MonitorEcc 读的是编排机自身 WHEA」。
- `docs/19-测试项执行清单.md`：第 4 项 ECC 修正同上；第 10 项断电加「先实测 chassis power cycle 再启用 RESTART_LOOP」。

**验证**：`grep` 各文档包含新增关键词。

## 任务 6：全量回归 + 打包 + 提交推送

1. 全量回归：`tests\test-presets.ps1`、`tests\test-iso-build.ps1`、`tests\test-smoke.ps1`、`tests\test-suite-config.ps1` 全部 PASS。
2. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Zip`（先删旧包再建新包，打包纪律）。
3. 提交信息：`feat: configurable Run-MemtestSuite defaults via config/memtest-suite.conf (CLI overrides config)`
4. `git push origin main`（必要时 `-c http.postBuffer=524288000`）。

## 提交粒度建议

- commit 1（任务 1+2+3）：lib_common/Run-MemtestSuite/config 配置化实现
- commit 2（任务 4）：tests 回归测试
- commit 3（任务 5）：文档更新
- commit 4（任务 6）：离线包同步 + zip
