# ============================================================================
# Run-ServerAssessment.ps1 — 服务器测试能力一键评估
# 自动串联「带内(CIM) + 带外(BMC/IPMI)」探测 → 输出 17 项可行性 + 每项建议动作。
#
# 用法（在离线包根目录运行，如 C:\memtest\）：
#   .\scripts\Run-ServerAssessment.ps1 -Local                                      # 本机（服务器已进 Windows）
#   .\scripts\Run-ServerAssessment.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>    # 编排机远程
#   .\scripts\Run-ServerAssessment.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -MachineName srv01
#   .\scripts\Run-ServerAssessment.ps1 -MergeInband <服务器侧cap.csv> -MergeOob <编排机侧cap.csv> -MachineName srv01   # 合并模式（跳过探测）
#   ... -VerifyPowerCycle    # 实测断电循环验证（透传探测脚本，正常模式生效）
# ============================================================================

param(
    [switch]$Local,              # 带内：本机是/已进被测服务器
    [string]$BmcHost = "",       # 带外：BMC 管理 IP
    [string]$BmcUser = "",
    [string]$BmcPass = "",
    [string]$IpmiTool = "ipmitool",
    [string]$MachineName = "",   # 报告命名用（缺省：本机名 或 BMC IP）
    [string]$OutDir = "",        # 输出目录（缺省 <包根>\results\assessment）
    [string]$CapScript = "",     # Check-ServerCapabilities.ps1 路径（缺省同目录）
    [switch]$Help,
    [switch]$VerifyPowerCycle,   # 实测断电循环验证（透传给 Check-ServerCapabilities，仅正常模式）
    [string]$MergeInband = "",   # 合并模式：服务器侧 cap CSV（A=Inband）
    [string]$MergeOob = ""       # 合并模式：编排机侧 cap CSV（B=Oob）
)

$ErrorActionPreference = 'Stop'

# 共享库（Read-BmcPass 等公共逻辑）
. $PSScriptRoot\lib_common.ps1

# 管道密码优先：脚本顶层 $input 可读外部管道（Read-BmcPass 的函数作用域内读不到，故在此先消费，
# 否则 -File 模式管道场景会落入 Read-Host 等待控制台而挂起）。
$pipeIn = @($input)
if ($BmcPass -eq "" -and $pipeIn.Count -gt 0) { $BmcPass = [string]$pipeIn[0] }

if ($Help) {
    Write-Host @"
服务器测试能力一键评估
-----------------------
自动串联带内(CIM)+带外(BMC/IPMI)探测，输出 17 项可行性 + 每项建议动作。
用法（在离线包根目录运行，如 C:\memtest\）：
  .\scripts\Run-ServerAssessment.ps1 -Local
  .\scripts\Run-ServerAssessment.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>
  .\scripts\Run-ServerAssessment.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -MachineName srv01 -OutDir out
参数：
  -Local/-BmcHost/-BmcUser/-BmcPass  同 Check-ServerCapabilities.ps1
  -MachineName  报告命名（缺省：本机名 或 BMC IP）
  -OutDir       输出目录（缺省 <包根>\results\assessment）
  -CapScript    探测脚本路径（缺省同目录 Check-ServerCapabilities.ps1）
  -VerifyPowerCycle  实测断电循环验证（透传探测脚本）
  -MergeInband/-MergeOob  合并模式：服务器侧+编排机侧 cap CSV（跳过探测；优先级高者胜，同级取服务器侧）
输出：<MachineName>-assessment.csv（Item/Name/Status/建议动作）+ 汇总文本
"@
    exit 0
}

# 指令记录：本次调用入库（Help 已处理；BMC 密码等敏感参数由 Write-CmdLog 打码）
$scriptStartTime = Get-Date
Write-CmdLog -Script 'Run-ServerAssessment' -CmdArgs $MyInvocation.Line -State Start

# ---- 合并模式：-MergeInband(A=服务器侧) + -MergeOob(B=编排机侧) 同给 → 跳过探测，直接合并两侧 cap CSV ----
$mergeMode = ($MergeInband -ne '') -or ($MergeOob -ne '')
# 合并优先级（高者胜；同级取 A=服务器侧）：已验证/可测=3，外包/条件=2，需*=1，其余=0
function Get-StatusPriority([string]$s) {
    if ($s -match '^(已验证|可测)') { 3 }
    elseif ($s -match '^(外包|条件)') { 2 }
    elseif ($s -match '^需') { 1 }
    else { 0 }
}
$items = $null
if ($mergeMode) {
    # 校验 1：两参数必须同时给出（缺一 → 报错并指名缺失参数，非 0 退出）
    if ($MergeInband -eq '') {
        Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'FAIL: 缺少 -MergeInband' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        Write-Error "合并模式需同时提供 -MergeInband 与 -MergeOob；缺少 -MergeInband"
        exit 1
    }
    if ($MergeOob -eq '') {
        Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'FAIL: 缺少 -MergeOob' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        Write-Error "合并模式需同时提供 -MergeInband 与 -MergeOob；缺少 -MergeOob"
        exit 1
    }
    # 校验 2：两文件存在且可读
    if (-not (Test-Path -LiteralPath $MergeInband)) {
        Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'FAIL: -MergeInband 不存在' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        Write-Error "-MergeInband 文件不存在或不可读: $MergeInband"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $MergeOob)) {
        Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'FAIL: -MergeOob 不存在' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        Write-Error "-MergeOob 文件不存在或不可读: $MergeOob"
        exit 1
    }
    $csvA = @(Import-Csv -LiteralPath $MergeInband)
    $csvB = @(Import-Csv -LiteralPath $MergeOob)
    # 校验 3：列头须含 Item/Name/Status
    $reqCols = @('Item', 'Name', 'Status')
    foreach ($f in @(@{ P = '-MergeInband'; Rows = $csvA; Path = $MergeInband }, @{ P = '-MergeOob'; Rows = $csvB; Path = $MergeOob })) {
        if ($f.Rows.Count -eq 0 -or ($reqCols | Where-Object { $f.Rows[0].PSObject.Properties.Name -notcontains $_ }).Count -gt 0) {
            Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result "FAIL: $($f.P) 缺 Item/Name/Status 列" -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
            Write-Error "$($f.P) 文件缺少 Item/Name/Status 列: $($f.Path)"
            exit 1
        }
    }
    # Role 校验：仅警告不失败（传反提示）；旧版无 Role 列照常合并
    if ($csvA[0].PSObject.Properties.Name -contains 'Role') {
        $badA = $csvA | Where-Object { [string]$_.Role -ne '被测服务器' } | Select-Object -First 1
        if ($badA) { Write-Warning "警告：-MergeInband 文件 Role=$($badA.Role)，确认未传反？" }
    }
    if ($csvB[0].PSObject.Properties.Name -contains 'Role') {
        $badB = $csvB | Where-Object { [string]$_.Role -ne '编排机' } | Select-Object -First 1
        if ($badB) { Write-Warning "警告：-MergeOob 文件 Role=$($badB.Role)，确认未传反？" }
    }
    # 合并：以 A（Inband=服务器侧）为基底按 Item 建 map；B（Oob=编排机侧）行无则补、有则优先级高者胜、同级取 A
    $map = @{}
    foreach ($row in $csvA) { $map[[int]$row.Item] = $row }
    foreach ($row in $csvB) {
        $item = [int]$row.Item
        if (-not $map.ContainsKey($item)) { $map[$item] = $row; continue }
        if ((Get-StatusPriority ([string]$row.Status)) -gt (Get-StatusPriority ([string]$map[$item].Status))) { $map[$item] = $row }
    }
    $items = @($map.Keys | Sort-Object | ForEach-Object { $map[$_] })
}

# ---- 默认值解析 ----
if ($CapScript -eq "") { $CapScript = Join-Path $PSScriptRoot "Check-ServerCapabilities.ps1" }
if (-not $mergeMode -and -not (Test-Path -LiteralPath $CapScript)) { Write-Error "探测脚本不存在: $CapScript"; Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result ("FAIL: 探测脚本不存在: " + $CapScript) -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds; exit 1 }
if ($OutDir -eq "") { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results\assessment" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if ($MachineName -eq "") {
    $MachineName = if ($BmcHost -ne "") { $BmcHost } else { $env:COMPUTERNAME }
}

Write-Host "===== 服务器测试能力一键评估：$MachineName ====="

# 密码：指定 BMC 且未显式提供 → 管道/交互提示一次（合并模式无需 BMC，跳过）
if (-not $mergeMode -and $BmcHost -and -not $BmcPass) { $BmcPass = Read-BmcPass -Prompt "BMC 密码（$BmcHost）" }

# ---- 正常模式：调用能力探测脚本（-OutCsv 落盘结构化结果；写入项目内 results\assessment，保留可追溯） ----
if (-not $mergeMode) {
    $capCsv = Join-Path $OutDir ("$MachineName-cap.csv")
    # 用 hashtable splat 可靠绑定命名参数（数组 splat 传 -Local 开关会失效）
    $capArgs = @{ IpmiTool = $IpmiTool; OutCsv = $capCsv }
    if ($Local) { $capArgs['Local'] = $true }
    if ($BmcHost) {
        $capArgs['BmcHost'] = $BmcHost
        $capArgs['BmcUser'] = $BmcUser
        $capArgs['BmcPass'] = $BmcPass
    }
    if ($VerifyPowerCycle) { $capArgs['VerifyPowerCycle'] = $true }

    & $CapScript @capArgs
    if (-not (Test-Path -LiteralPath $capCsv)) {
        Write-Error "能力探测未产出报告，中止。"
        Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'FAIL: 能力探测未产出报告' -ExitCode 1 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
        exit 1
    }
    $items = @(Import-Csv -LiteralPath $capCsv)
}

# ---- 每项建议动作 ----
function Get-Recommendation {
    param([int]$Item, [string]$Status)
    $ok = $Status -like "可测*"
    switch ($Item) {
        1  { "运行编排脚本自动采集 SPD（Identify-Memory / Run-MemtestSuite）" }
        2  { "同上，识别/容量/频率自动建档" }
        3  { "用内置 memtest.iso 引导跑筛选轮（Run-MemtestSuite SOL/USB）" }
        4  { if ($ok) { "ECC 平台：满载 + WHEA/mcelog 监控（-MonitorEcc）" } else { "非 ECC 平台，此项不可行（跳过）" } }
        5  { if ($ok) { "满载 72h + 测温（-MonitorTemp）" } else { "需 BMC + 测温传感器后重测" } }
        6  { "外包：可编程电源+示波器（02 方案 L3 送检）" }
        7  { "外包：≥20GHz 示波器眼图（L3 送检）" }
        8  { "外包：高低温箱（L3 送检）" }
        9  { "外包：恒温恒湿箱（L3 送检）" }
        10 { if ($ok) { "IPMI 断电循环（Run-MemtestSuite -RestartLoop）" } else { "需 BMC（chassis power cycle 能力）后重测" } }
        11 { "外包：静电枪（L3 送检）" }
        12 { "外包：振动台（L3 送检）" }
        13 { "外包：冲击台（L3 送检）" }
        14 { "外包：治具（L3 送检）" }
        15 { if ($ok) { "本机平台已具备；补另一平台（Intel/AMD）对比" } else { "需带内探测 CPU 平台" } }
        16 { if ($ok) { "插满槽位跑混插压力" } else { "插满 ≥2 根后重测" } }
        17 { "人工目检 + 万用表电性复检" }
        default { "" }
    }
}

$assess = @()
foreach ($it in $items) {
    $assess += [PSCustomObject]@{
        Item     = [int]$it.Item
        Name     = $it.Name
        Status   = $it.Status
        Action   = Get-Recommendation -Item ([int]$it.Item) -Status $it.Status
    }
}

# ---- 汇总统计 ----
$can   = ($assess | Where-Object { $_.Status -like "可测*" }).Count
$cond  = ($assess | Where-Object { $_.Status -like "条件*" }).Count
$need  = ($assess | Where-Object { $_.Status -like "需*" }).Count
$out   = ($assess | Where-Object { $_.Status -like "外包*" }).Count

Write-Host ""
Write-Host "17 项可行性 + 建议动作："
$assess | Format-Table Item, Name, Status, Action -AutoSize -Wrap

Write-Host ("汇总：可直接开测 {0} 项 | 需条件 {1} 项 | 需补探测 {2} 项 | 外包 {3} 项" -f $can, $cond, $need, $out)

# ---- 输出文件 ----
$assFile = Join-Path $OutDir "$MachineName-assessment.csv"
$assess | Export-Csv -LiteralPath $assFile -NoTypeInformation -Encoding UTF8
Write-Host "评估报告已保存: $assFile"

# ---- 汇总文本（下一步动作） ----
# 正常模式 → 角色行；合并模式 → 合并来源行
$roleOrMerge = if ($mergeMode) {
    "合并来源: 服务器 $MergeInband + 编排机 $MergeOob"
} else {
    $roleTxt = if ($items.Count -gt 0 -and $items[0].PSObject.Properties.Name -contains 'Role') { [string]$items[0].Role } else { '未知' }
    "角色: $roleTxt"
}
$lines = @(
    "===== 服务器测试能力评估：$MachineName =====",
    ("探测时间: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
    ("带内: {0} | 带外 BMC: {1}" -f $(if ($Local) { "已探测" } else { "未执行(-Local)" }), $(if ($BmcHost) { $BmcHost } else { "未指定" })),
    $roleOrMerge,
    ("汇总: 可直接开测 $can 项 | 需条件 $cond 项 | 需补探测 $need 项 | 外包 $out 项"),
    ""
)
if ($can -gt 0) {
    $passShow = if ($BmcPass) { "***" } else { "" }
    $lines += @(
        "建议下一步（SOL 全自动验收）：",
        ("  .\scripts\Run-MemtestSuite.ps1 -BatchName $MachineName-a1 -BootMethod SOL -BmcHost $BmcHost -BmcUser $BmcUser -BmcPass $passShow -MaxPasses 4 -ConfirmSwitch"),
        ""
    )
}
if ($out -gt 0) {
    $lines += "外包项（$out 项）送第三方实验室，见 docs/02-批量压力测试方案.md L3。"
}
$sumTxt = Join-Path $OutDir "$MachineName-assessment.txt"
$lines | Out-File -LiteralPath $sumTxt -Encoding UTF8
Write-Host "汇总文本已保存: $sumTxt"
Write-CmdLog -Script 'Run-ServerAssessment' -State End -Result 'OK' -ExitCode 0 -DurationSec ((Get-Date) - $scriptStartTime).TotalSeconds
