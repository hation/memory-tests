# ============================================================================
# Run-ServerAssessment.ps1 — 服务器测试能力一键评估
# 自动串联「带内(CIM) + 带外(BMC/IPMI)」探测 → 输出 17 项可行性 + 每项建议动作。
#
# 用法：
#   .\Run-ServerAssessment.ps1 -Local                                      # 本机（服务器已进 Windows）
#   .\Run-ServerAssessment.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>    # 编排机远程
#   .\Run-ServerAssessment.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -MachineName srv01
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
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Write-Host @"
服务器测试能力一键评估
-----------------------
自动串联带内(CIM)+带外(BMC/IPMI)探测，输出 17 项可行性 + 每项建议动作。
用法：
  .\Run-ServerAssessment.ps1 -Local
  .\Run-ServerAssessment.ps1 -BmcHost <IP> -BmcUser <u> -BmcPass <p>
  .\Run-ServerAssessment.ps1 -Local -BmcHost <IP> -BmcUser <u> -BmcPass <p> -MachineName srv01 -OutDir out
参数：
  -Local/-BmcHost/-BmcUser/-BmcPass  同 Check-ServerCapabilities.ps1
  -MachineName  报告命名（缺省：本机名 或 BMC IP）
  -OutDir       输出目录（缺省 <包根>\results\assessment）
  -CapScript    探测脚本路径（缺省同目录 Check-ServerCapabilities.ps1）
输出：<MachineName>-assessment.csv（Item/Name/Status/建议动作）+ 汇总文本
"@
    exit 0
}

# ---- 默认值解析 ----
if ($CapScript -eq "") { $CapScript = Join-Path $PSScriptRoot "Check-ServerCapabilities.ps1" }
if (-not (Test-Path -LiteralPath $CapScript)) { Write-Error "探测脚本不存在: $CapScript"; exit 1 }
if ($OutDir -eq "") { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) "results\assessment" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if ($MachineName -eq "") {
    $MachineName = if ($BmcHost -ne "") { $BmcHost } else { $env:COMPUTERNAME }
}

Write-Host "===== 服务器测试能力一键评估：$MachineName ====="

# ---- 调用能力探测脚本（-OutCsv 落盘结构化结果） ----
$capCsv = Join-Path $env:TEMP ("cap_" + [guid]::NewGuid().ToString("N") + ".csv")
# 用 hashtable splat 可靠绑定命名参数（数组 splat 传 -Local 开关会失效）
$capArgs = @{ IpmiTool = $IpmiTool; OutCsv = $capCsv }
if ($Local) { $capArgs['Local'] = $true }
if ($BmcHost) {
    $capArgs['BmcHost'] = $BmcHost
    $capArgs['BmcUser'] = $BmcUser
    $capArgs['BmcPass'] = $BmcPass
}

& $CapScript @capArgs
if (-not (Test-Path -LiteralPath $capCsv)) {
    Write-Error "能力探测未产出报告，中止。"
    exit 1
}
$items = Import-Csv -LiteralPath $capCsv

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
$lines = @(
    "===== 服务器测试能力评估：$MachineName =====",
    ("探测时间: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
    ("带内: {0} | 带外 BMC: {1}" -f $(if ($Local) { "已探测" } else { "未执行(-Local)" }), $(if ($BmcHost) { $BmcHost } else { "未指定" })),
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

Remove-Item -LiteralPath $capCsv -Force -ErrorAction SilentlyContinue
