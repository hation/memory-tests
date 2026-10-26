# ============================================================================
# test-suite-config.ps1 — Merge-SuiteConfig（Run-MemtestSuite 配置默认值）回归测试
# 覆盖规格 8 个用例：空配置 / 未绑定覆盖 / 已绑定不覆盖 / 非法整数 / bool 解析
#   / 空值忽略 / BOOT_METHOD 校验 / 13 键映射完整性。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-suite-config.ps1
# ============================================================================
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

# 1 配置缺失 → 空结果
Assert ((Merge-SuiteConfig -Cfg @{} -Bound @{}).Count -eq 0) "1 空配置应返回空"

# 2 未绑定 + MAX_PASSES=2 → 覆盖
$r = Merge-SuiteConfig -Cfg @{MAX_PASSES='2'} -Bound @{}
Assert ($r.MaxPasses -eq 2) "2 MAX_PASSES=2 应生效"

# 3 已绑定（显式传参）→ 配置不覆盖
$r = Merge-SuiteConfig -Cfg @{MAX_PASSES='2'} -Bound @{MaxPasses=1}
Assert (-not $r.ContainsKey('MaxPasses')) "3 显式传参配置不覆盖"

# 4 非法整数 → 忽略
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_PASSES='abc'} -Bound @{}).ContainsKey('MaxPasses')) "4 非法整数忽略"

# 5 bool 解析：1/true/yes → true；0/非法 → false
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='1'} -Bound @{}).MonitorEcc -eq $true) "5a 1=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='true'} -Bound @{}).MonitorEcc -eq $true) "5b true=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='yes'} -Bound @{}).MonitorEcc -eq $true) "5c yes=true"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='0'} -Bound @{}).MonitorEcc -eq $false) "5d 0=false"
Assert ((Merge-SuiteConfig -Cfg @{MONITOR_ECC='maybe'} -Bound @{}).MonitorEcc -eq $false) "5e 非法=false"

# 6 空值 → 忽略
Assert (-not (Merge-SuiteConfig -Cfg @{BMC_HOST=''} -Bound @{}).ContainsKey('BmcHost')) "6 空值忽略"

# 7 BOOT_METHOD：非法忽略 / 合法生效
Assert (-not (Merge-SuiteConfig -Cfg @{BOOT_METHOD='weird'} -Bound @{}).ContainsKey('BootMethod')) "7a 非法忽略"
Assert ((Merge-SuiteConfig -Cfg @{BOOT_METHOD='Serial'} -Bound @{}).BootMethod -eq 'Serial') "7b Serial 生效"

# 8 映射完整性：13 键全部映射
$cfg = @{ BOOT_METHOD='SOL'; BMC_HOST='h'; BMC_USER='u'; IPMI_TOOL='i'; MAX_PASSES='4';
          TEST_LIST='0,1'; SERIAL_PARAM='ttyS0,115200'; MONITOR_ECC='1'; MONITOR_TEMP='1';
          RESTART_LOOP='5'; CONFIRM_SWITCH='1'; EXPECTED_CSV='e'; LOG_PATH='l' }
Assert ((Merge-SuiteConfig -Cfg $cfg -Bound @{}).Count -eq 13) "8 映射 13 键"
Assert ((Merge-SuiteConfig -Cfg $cfg -Bound @{}).RestartLoop -eq 5) "8b RESTART_LOOP int"

# 9 新增 5 键映射 + int 解析 + Bound 优先
$cfg9 = @{ MAX_MINUTES='4320'; TEMP_LIMIT_C='85'; TEMP_INTERVAL_MIN='60'; ORT_BUFFER_MIN='10'; ORT_MAX_GAP_MIN='30' }
$r9 = Merge-SuiteConfig -Cfg $cfg9 -Bound @{}
Assert ($r9.MaxMinutes -eq 4320 -and $r9.TempLimitC -eq 85 -and $r9.TempIntervalMin -eq 60 -and $r9.OrtBufferMin -eq 10 -and $r9.OrtMaxGapMin -eq 30) "9 新增5键映射"
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_MINUTES='abc'} -Bound @{}).ContainsKey('MaxMinutes')) "9b 非法int忽略"
Assert (-not (Merge-SuiteConfig -Cfg @{MAX_MINUTES='4320'} -Bound @{MaxMinutes=1}).ContainsKey('MaxMinutes')) "9c Bound优先"
# 10 完整映射 18 键
$cfg10 = @{ BOOT_METHOD='SOL'; BMC_HOST='h'; BMC_USER='u'; IPMI_TOOL='i'; MAX_PASSES='4'; TEST_LIST='0,1';
            SERIAL_PARAM='ttyS0,115200'; MONITOR_ECC='1'; MONITOR_TEMP='1'; RESTART_LOOP='5'; CONFIRM_SWITCH='1';
            EXPECTED_CSV='e'; LOG_PATH='l'; MAX_MINUTES='4320'; TEMP_LIMIT_C='85'; TEMP_INTERVAL_MIN='60';
            ORT_BUFFER_MIN='10'; ORT_MAX_GAP_MIN='30' }
Assert ((Merge-SuiteConfig -Cfg $cfg10 -Bound @{}).Count -eq 18) "10 映射 18 键"

Write-Host "ALL PASS"
