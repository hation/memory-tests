# ============================================================================
# check_env.ps1 — 环境自检（参考 disk-tests deploy 目录的 check_env.ps1）
# 首行打印工具版本（与交付包版本核对：不一致 = 没拷到最新）。
# 用途：拷贝离线包到目标机后，先跑本脚本确认环境 OK 再开测。
# 用法：.\check_env.ps1
# ============================================================================

. $PSScriptRoot\lib_common.ps1

$fail = 0
$warn = 0

Write-Host ("工具版本: {0}" -f (Get-AppVersion))
Write-Host ""

# [1] PowerShell 版本（需 5.1+）
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5 -and ($psv.Major -gt 5 -or $psv.Minor -ge 1)) {
    Write-Host "[1] PowerShell $psv ... OK"
} else {
    Write-Host "[1] PowerShell $psv ... 警告：需 5.1+"
    $warn++
}

# [2] 关键脚本齐全
$scripts = @('lib_common.ps1','Identify-Memory.ps1','Run-MemtestSuite.ps1','Run-BatchScheduler.ps1','Check-ServerCapabilities.ps1','Run-ServerAssessment.ps1')
$missing = @($scripts | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_)) })
if ($missing.Count -eq 0) {
    Write-Host "[2] 脚本 $($scripts.Count) 个 ... OK"
} else {
    Write-Host "[2] 缺少脚本: $($missing -join ', ') ... 失败"
    $fail++
}

# [3] 内置 ipmitool（exe + 依赖 DLL）+ 版本
$ipmiDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\ipmitool'
$ipmiExe = Join-Path $ipmiDir 'ipmitool.exe'
$dlls = @('cygwin1.dll','cygcrypto-1.0.0.dll','cygz.dll')
if (Test-Path $ipmiExe) {
    $ver = & $ipmiExe -V 2>&1 | Select-Object -First 1
    $dllOk = @($dlls | Where-Object { Test-Path (Join-Path $ipmiDir $_) }).Count
    if ($dllOk -eq $dlls.Count) {
        Write-Host "[3] 内置 ipmitool: $ver ... OK（DLL $dllOk/3）"
    } else {
        Write-Host "[3] 内置 ipmitool: $ver ... 警告：DLL 缺失 $dllOk/3"
        $warn++
    }
} else {
    Write-Host "[3] 内置 ipmitool 缺失: $ipmiExe ... 失败"
    $fail++
}

# [4] Memtest86+ 引导 ISO
$iso = Join-Path (Split-Path -Parent $PSScriptRoot) 'boot\memtest.iso'
if (Test-Path $iso) {
    $mb = [math]::Round((Get-Item $iso).Length / 1MB, 1)
    Write-Host "[4] Memtest86+ ISO: $mb MB ... OK"
} else {
    Write-Host "[4] memtest.iso 缺失 ... 失败"
    $fail++
}

# [5] 配置模板
$batches = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\batches.example.csv'
$conf = Join-Path (Split-Path -Parent $PSScriptRoot) 'conf\app.conf'
if ((Test-Path $batches) -and (Test-Path $conf)) {
    Write-Host "[5] 配置模板（batches/conf）... OK"
} else {
    Write-Host "[5] 配置模板缺失 ... 警告"
    $warn++
}

# [6] SQLite 历史库（可选，需 Python 3；优先内置 tools\python，其次系统 PATH）
$dbPy = Join-Path (Split-Path -Parent $PSScriptRoot) 'db\db_common.py'
if (Test-Path $dbPy) {
    $py = Get-PythonExe
    if ($py) {
        $ver = & $py --version 2>&1 | Select-Object -First 1
        $src = if ($py -like "*tools\python*") { "内置 tools\python" } else { "系统 PATH" }
        Write-Host "[6] SQLite 历史库（可选）: db 存在，Python $ver（$src）"
    } else {
        Write-Host "[6] SQLite 历史库（可选）: db 存在，Python 3 未装（该功能跳过）"
        $warn++
    }
} else {
    Write-Host "[6] SQLite 历史库（可选）: 未随包"
}

# 汇总
Write-Host ""
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host "环境自检：全部 OK，可开始验收。"
    exit 0
} elseif ($fail -eq 0) {
    Write-Host "环境自检：通过（$warn 项警告，不影响核心功能）。"
    exit 0
} else {
    Write-Host "环境自检：失败 $fail 项，请按 docs/12 手册第一章修复后重试。"
    exit 1
}
