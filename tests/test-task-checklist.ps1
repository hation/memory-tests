# ============================================================================
# test-task-checklist.ps1 — 任务清单（批次总览 + 流程清单）黑盒测试
# 覆盖：New-TaskChecklist（结构/评估标注/评估缺失）、Update-TaskChecklist、
#       Update-OverviewRow（含非法状态校验）、Merge-TaskChecklists（四场景）、
#       薄壳脚本黑盒（New-TaskChecklist.ps1 / Update-TaskChecklist.ps1，临时包根拷贝法）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-task-checklist.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

# ---- 表格解析辅助（黑盒读文件，UTF-8） ----
function Get-OverviewRows([string]$Path) {
    $rows = @()
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match "^\| \d+ \|") {
            $cols = $line -split "\|"
            $rows += [PSCustomObject]@{
                Item   = $cols[1].Trim()
                Name   = $cols[2].Trim()
                Status = $cols[3].Trim()
                Result = $cols[4].Trim()
                Reason = $cols[5].Trim()
                Flow   = $cols[6].Trim()
            }
        }
    }
    return $rows
}
function Get-FlowRows([string]$Path) {
    $rows = @()
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match "^\| " -and $line -notmatch "^\|-") {
            $cols = $line -split "\|"
            if ($cols.Count -ge 6 -and $cols[1].Trim() -ne '环节') {
                $rows += [PSCustomObject]@{
                    Key     = $cols[1].Trim()
                    Desc    = $cols[2].Trim()
                    Status  = $cols[3].Trim()
                    Result  = $cols[4].Trim()
                    Product = $cols[5].Trim()
                }
            }
        }
    }
    return $rows
}
# 解析总览底部"总结论"行计数（✓/✗/─/⏳/⚠）；无匹配行返回全 -1
function Get-SummaryCounts([string]$Path) {
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^总结论: ') {
            $m = [regex]::Match($line, '^总结论: ✓(\d+) ✗(\d+) ─(\d+) ⏳(\d+) ⚠(\d+)')
            if ($m.Success) {
                return @{ '✓' = [int]$m.Groups[1].Value; '✗' = [int]$m.Groups[2].Value; '─' = [int]$m.Groups[3].Value; '⏳' = [int]$m.Groups[4].Value; '⚠' = [int]$m.Groups[5].Value }
            }
        }
    }
    return @{ '✓' = -1; '✗' = -1; '─' = -1; '⏳' = -1; '⚠' = -1 }
}

# ---- 临时目录 ----
$tmp = Join-Path $env:TEMP ("tcl-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    # ============ 1) New-TaskChecklist 结构 ============
    $resDir = Join-Path $tmp "results"
    New-Item -ItemType Directory -Path $resDir -Force | Out-Null
    $batch = "testA1"
    $dir = New-TaskChecklist -ChecklistBatch $batch -MachineName "srv01" -ResultsDir $resDir
    Assert ($dir -eq (Join-Path $resDir $batch)) "New 返回清单目录"
    $ovPath = Join-Path $dir "任务清单-总览.md"
    Assert (Test-Path $ovPath) "总览文件存在"
    $ov = @(Get-OverviewRows $ovPath)
    Assert ($ov.Count -eq 17) "总览 17 行（实际 $($ov.Count)）"
    $expectNames = @('SPD 信息校验','基础识别/容量频率','全地址读写覆盖(Memtest)','ECC 纠错功能验证',
        '72h ORT 老化烧机','电压裕量','时序/SI','高低温循环','THB 湿热偏压','反复上电掉电循环',
        '静电ESD','机械振动','机械冲击','弯曲扭曲','多平台兼容','多通道混插压力','外观/焊点/电性复检')
    for ($i = 0; $i -lt 17; $i++) {
        Assert ($ov[$i].Name -eq $expectNames[$i]) "总览第 $($i+1) 项名称"
        Assert ($ov[$i].Status -match '^─') "初始状态 ─（项 $($ov[$i].Item) 实际 $($ov[$i].Status)）"
    }
    $flowOf = @{ 1='建档'; 2='建档'; 3='Memtest'; 4='ECC'; 5='ORT'; 6='L3外包'; 7='L3外包'; 8='L3外包'; 9='L3外包';
                 10='断电循环'; 11='L3外包'; 12='L3外包'; 13='L3外包'; 14='L3外包'; 15='多平台'; 16='混插'; 17='目检电性' }
    foreach ($r in $ov) { Assert ($r.Flow -eq $flowOf[[int]$r.Item]) "项 $($r.Item) 关联流程清单" }
    # 10 张流程清单存在 + 环节数 + 初始状态
    $flowSteps = @{ '建档'=3; 'Memtest'=6; '混插'=2; 'ECC'=2; '断电循环'=2; 'ORT'=3; 'Prime95'=2; '多平台'=3; '目检电性'=2; 'L3外包'=1 }
    foreach ($f in $flowSteps.Keys) {
        $p = Join-Path $dir "任务清单-$f.md"
        Assert (Test-Path $p) "流程清单 $f 存在"
        $fr = @(Get-FlowRows $p)
        Assert ($fr.Count -eq $flowSteps[$f]) "流程 $f 环节数（实际 $($fr.Count)）"
        foreach ($row in $fr) {
            Assert ($row.Status -eq '─ 等待执行') "$f/$($row.Key) 初始状态 ─ 等待执行"
            Assert ($row.Product -eq '无') "$f/$($row.Key) 初始产物 无"
        }
    }

    # ============ 2) New + 评估标注 ============
    $resDir2 = Join-Path $tmp "results2"
    New-Item -ItemType Directory -Path (Join-Path $resDir2 "assessment") -Force | Out-Null
    $csv = Join-Path $resDir2 "assessment\srv01-assessment.csv"
    $lines = @("Item,Name,Status,Action")
    for ($i = 1; $i -le 17; $i++) { $lines += "$i,Item$i,可测,action$i" }
    $lines[4]  = "4,ECC,条件：内存非 ECC,需换 ECC 平台"      # 条件* → ⚠+Action
    $lines[5]  = "5,ORT,需编排机(x),换编排机执行"            # 需编排机 → ─ 待执行
    $lines[6]  = "6,电压,外包(示波器),外包动作"              # 外包* → ⚠+外包送检（L3）
    $lines[10] = "10,断电,需 BMC 后重测,需 BMC 能力"         # 需*（非编排机/带内）→ ⚠+Action
    $lines[15] = "15,多平台,需带内(进OS),进 OS 探测"         # 需带内 → ─ 待执行
    $lines[16] = "16,混插,条件：插满≥2根,插满后重测"         # 条件* → ⚠+Action
    $lines[1]  = "1,SPD,需编排机(x),换编排机"                # 1-3/17 无依赖 → 仍 ─ 等待执行
    [System.IO.File]::WriteAllLines($csv, $lines, (New-Object System.Text.UTF8Encoding($false)))
    $dir2 = New-TaskChecklist -ChecklistBatch "testA2" -MachineName "srv01" -ResultsDir $resDir2
    $ov2 = @(Get-OverviewRows (Join-Path $dir2 "任务清单-总览.md"))
    $r4  = $ov2 | Where-Object { $_.Item -eq '4' }
    Assert ($r4.Status -match '^⚠' -and $r4.Reason -eq '需换 ECC 平台') "项4 条件→⚠+Action 原因"
    $r5  = $ov2 | Where-Object { $_.Item -eq '5' }
    Assert ($r5.Status -eq '─ 待执行') "项5 需编排机→─ 待执行"
    $r6  = $ov2 | Where-Object { $_.Item -eq '6' }
    Assert ($r6.Status -match '^⚠' -and $r6.Reason -eq '外包送检（L3）') "项6 外包→⚠+外包送检（L3）"
    $r10 = $ov2 | Where-Object { $_.Item -eq '10' }
    Assert ($r10.Status -match '^⚠' -and $r10.Reason -eq '需 BMC 能力') "项10 需 BMC→⚠+Action 原因"
    $r15 = $ov2 | Where-Object { $_.Item -eq '15' }
    Assert ($r15.Status -eq '─ 待执行') "项15 需带内→─ 待执行"
    $r16 = $ov2 | Where-Object { $_.Item -eq '16' }
    Assert ($r16.Status -match '^⚠') "项16 条件→⚠"
    $r1  = $ov2 | Where-Object { $_.Item -eq '1' }
    Assert ($r1.Status -eq '─ 等待执行') "项1 无依赖不受评估影响"
    $r3  = $ov2 | Where-Object { $_.Item -eq '3' }
    Assert ($r3.Status -eq '─ 等待执行') "项3 可测→─ 等待执行"

    # ============ 3) New 评估缺失（全 ─ + 提示，不抛异常） ============
    $resDir3 = Join-Path $tmp "results3"
    New-Item -ItemType Directory -Path $resDir3 -Force | Out-Null
    $libPath = Join-Path $PSScriptRoot "..\scripts\lib_common.ps1"
    $out3 = & powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$libPath'; New-TaskChecklist -ChecklistBatch 'testA3' -MachineName 'srv02' -ResultsDir '$resDir3' | Out-Null" 2>&1 | Out-String
    Assert ($out3 -match '评估') "评估缺失有提示（实际输出: $out3）"
    $ov3 = @(Get-OverviewRows (Join-Path (Join-Path $resDir3 "testA3") "任务清单-总览.md"))
    Assert ($ov3.Count -eq 17) "评估缺失清单仍生成 17 行"
    foreach ($r in $ov3) { Assert ($r.Status -match '^─') "评估缺失全 ─（项 $($r.Item)）" }

    # ============ 4) Update-TaskChecklist ============
    $dirA = New-TaskChecklist -ChecklistBatch "testA4" -MachineName "srv01" -ResultsDir $resDir
    $p95Path = Join-Path $dirA "任务清单-Prime95.md"
    Update-TaskChecklist -ChecklistPath $p95Path -Key "正式长压" -Status "✓ 做成" -Result "180min 无错误" -Product "srv01-a1-prime95-report.csv"
    $pRows = @(Get-FlowRows $p95Path)
    $p1 = $pRows | Where-Object { $_.Key -eq '正式长压' }
    Assert ($p1.Status -eq '✓ 做成' -and $p1.Result -eq '180min 无错误' -and $p1.Product -eq 'srv01-a1-prime95-report.csv') "更新行状态/结果/产物"
    $p2 = $pRows | Where-Object { $_.Key -eq '冒烟(首用)' }
    Assert ($p2.Status -eq '─ 等待执行' -and $p2.Product -eq '无') "其他行不变"
    Update-TaskChecklist -ChecklistPath (Join-Path $dirA "任务清单-不存在.md") -Key "x" -Status "✓" -Result "r" -Product "p"
    Assert ($true) "Update 文件不存在静默返回"
    $threw1 = $false
    try { Update-TaskChecklist -ChecklistPath $p95Path -Key "正式长压" -Status "BAD" -Result "r" -Product "p" } catch { $threw1 = $true }
    Assert $threw1 "Update 非法状态抛异常"

    # ============ 5) Update-OverviewRow ============
    $ovPathA = Join-Path $dirA "任务清单-总览.md"
    Update-OverviewRow -OverviewPath $ovPathA -ItemNo 5 -Status "⏳ 进行中" -Result "72h 跑 36h" -Reason "中途巡检"
    $ovA = @(Get-OverviewRows $ovPathA)
    $a5 = $ovA | Where-Object { $_.Item -eq '5' }
    Assert ($a5.Status -eq '⏳ 进行中' -and $a5.Result -eq '72h 跑 36h' -and $a5.Reason -eq '中途巡检') "总览行更新"
    # I2 回归：Update-OverviewRow 写回后立即重算底部"总结论"行（单机行更新 → 计数即时正确）
    $sum5 = Get-SummaryCounts $ovPathA
    Assert ($sum5['⏳'] -eq 1 -and $sum5['─'] -eq 16 -and $sum5['✓'] -eq 0) "Update-OverviewRow 后总结论计数已刷新（期望 ⏳1 ─16，实际 ⏳$($sum5['⏳']) ─$($sum5['─']) ✓$($sum5['✓'])）"
    $a1 = $ovA | Where-Object { $_.Item -eq '1' }
    Assert ($a1.Status -match '^─') "总览其他行不变"
    Update-OverviewRow -OverviewPath (Join-Path $dirA "任务清单-总览-不存在.md") -ItemNo 1 -Status "✓" -Result "r" -Reason "w"
    Assert ($true) "Overview 文件不存在静默返回"
    $threw2 = $false
    try { Update-OverviewRow -OverviewPath $ovPathA -ItemNo 1 -Status "BAD" -Result "r" -Reason "w" } catch { $threw2 = $true }
    Assert $threw2 "Overview 非法状态抛异常"

    # ============ 6) Merge-TaskChecklists（四场景） ============
    $srvRoot = Join-Path $tmp "results-srv"; $orchRoot = Join-Path $tmp "results-orch"
    $srvDir = New-TaskChecklist -ChecklistBatch "srvA1" -MachineName "srv01" -ResultsDir $srvRoot
    $orchDir = New-TaskChecklist -ChecklistBatch "srvA1" -MachineName "orch01" -ResultsDir $orchRoot
    # 编排机侧未跑建档流程：删掉除总览/混插外的流程清单，模拟"编排机无建档清单"
    Get-ChildItem $orchDir -Filter "任务清单-*.md" | Where-Object { $_.Name -notin @('任务清单-总览.md','任务清单-混插.md') } | Remove-Item -Force
    # 服务器：建档行 ✓、项2 ─ 带服务器备注、项15 ✓（与编排机同有状态）
    Update-OverviewRow -OverviewPath (Join-Path $srvDir "任务清单-总览.md") -ItemNo 1 -Status "✓ 做成" -Result "SPD 匹配" -Reason ""
    Update-OverviewRow -OverviewPath (Join-Path $srvDir "任务清单-总览.md") -ItemNo 2 -Status "─" -Result "服务器备注"
    Update-OverviewRow -OverviewPath (Join-Path $srvDir "任务清单-总览.md") -ItemNo 15 -Status "✓ 做成" -Result "服务器15"
    # 服务器更新建档清单 + 混插清单
    Update-TaskChecklist -ChecklistPath (Join-Path $srvDir "任务清单-建档.md") -Key "识别条子" -Status "✓ 做成" -Result "SN 已识别" -Product "srv01-a1.csv"
    Update-TaskChecklist -ChecklistPath (Join-Path $srvDir "任务清单-混插.md") -Key "Memtest 混插组合" -Status "✓ 做成" -Result "PASS" -Product "mix-report.csv"
    # 服务器总览缺项 17 行（模拟服务器没有该行 → 保留编排机行）
    $srvOv = Join-Path $srvDir "任务清单-总览.md"
    $srvTxt = ([System.IO.File]::ReadAllText($srvOv, [System.Text.Encoding]::UTF8) -split "`r?`n" | Where-Object { $_ -notmatch '^\| 17 \|' }) -join "`r`n"
    [System.IO.File]::WriteAllText($srvOv, $srvTxt, (New-Object System.Text.UTF8Encoding($false)))
    # 编排机：项3 ✓（Memtest 行）、项2 ─ 编排机备注、项15 ✓ 编排机
    Update-OverviewRow -OverviewPath (Join-Path $orchDir "任务清单-总览.md") -ItemNo 3 -Status "✓ 做成" -Result "1轮全项 PASS" -Reason ""
    Update-OverviewRow -OverviewPath (Join-Path $orchDir "任务清单-总览.md") -ItemNo 2 -Status "─" -Result "编排机备注"
    Update-OverviewRow -OverviewPath (Join-Path $orchDir "任务清单-总览.md") -ItemNo 15 -Status "✓ 做成" -Result "编排机15"
    Update-TaskChecklist -ChecklistPath (Join-Path $orchDir "任务清单-混插.md") -Key "Prime95 长压" -Status "✓ 做成" -Result "P95 PASS" -Product "p95-report.csv"

    $mergedDir = Merge-TaskChecklists -ServerChecklistDir $srvDir -OrchestratorChecklistDir $orchDir -MachineName "srv01"
    Assert ($mergedDir -eq $orchDir) "Merge 返回编排机清单目录"
    # 场景①：流程清单带入（服务器建档清单 → 编排机）
    $jd = @(Get-FlowRows (Join-Path $orchDir "任务清单-建档.md"))
    Assert ($jd.Count -eq 3) "建档清单带入且 3 环节"
    $j1 = $jd | Where-Object { $_.Key -eq '识别条子' }
    Assert ($j1.Status -eq '✓ 做成' -and $j1.Product -eq 'srv01-a1.csv') "建档清单带服务器状态"
    # 场景②：总览逐行取有状态方
    $ovM = @(Get-OverviewRows (Join-Path $orchDir "任务清单-总览.md"))
    Assert ($ovM.Count -eq 17) "合并后总览仍 17 行"
    $m1 = $ovM | Where-Object { $_.Item -eq '1' }
    Assert ($m1.Status -eq '✓ 做成' -and $m1.Result -eq 'SPD 匹配') "建档行取服务器 ✓"
    $m3 = $ovM | Where-Object { $_.Item -eq '3' }
    Assert ($m3.Status -eq '✓ 做成' -and $m3.Result -eq '1轮全项 PASS') "Memtest 行保留编排机 ✓"
    $m2 = $ovM | Where-Object { $_.Item -eq '2' }
    Assert ($m2.Result -eq '服务器备注') "两边均 ─ 取服务器侧"
    $m15 = $ovM | Where-Object { $_.Item -eq '15' }
    Assert ($m15.Result -eq '服务器15') "两边均有状态取服务器侧"
    $m17 = $ovM | Where-Object { $_.Item -eq '17' }
    Assert ($m17.Status -match '^─') "服务器缺行保留编排机行"
    # 场景⑤（回归，评审 Important）：合并后总览"总结论"行按实际 17 行状态重算，
    # 不再保持编排机旧计数（服务器 ✓ 行并入后 ✓ 计数必须增加）
    $sumLine = (@(([System.IO.File]::ReadAllText((Join-Path $orchDir "任务清单-总览.md"), [System.Text.Encoding]::UTF8) -split "`r?`n") | Where-Object { $_ -match '^总结论: ' }))[0]
    Assert ($null -ne $sumLine -and $sumLine -match '^总结论: ✓') "合并后仍有总结论行（实际: $sumLine）"
    Assert ($sumLine -match '（备注') "总结论行保留备注后缀"
    $sum = Get-SummaryCounts (Join-Path $orchDir "任务清单-总览.md")
    $exp = @{ '✓' = 0; '✗' = 0; '─' = 0; '⏳' = 0; '⚠' = 0 }
    foreach ($r in $ovM) {
        $sym = $r.Status.Substring(0, 1)
        if ($exp.ContainsKey($sym)) { $exp[$sym]++ }
    }
    Assert ($sum['✓'] -eq $exp['✓'] -and $sum['✗'] -eq $exp['✗'] -and $sum['─'] -eq $exp['─'] -and $sum['⏳'] -eq $exp['⏳'] -and $sum['⚠'] -eq $exp['⚠']) "合并后总结论计数与 17 行实际状态一致（期望 ✓$($exp['✓']) ✗$($exp['✗']) ─$($exp['─']) ⏳$($exp['⏳']) ⚠$($exp['⚠'])，实际 ✓$($sum['✓']) ✗$($sum['✗']) ─$($sum['─']) ⏳$($sum['⏳']) ⚠$($sum['⚠'])）"
    Assert (-not ($sum['✓'] -eq 0 -and $sum['─'] -eq 17)) "总结论已重算（不再保持合并前 ✓0 ─17 旧值）"
    # 场景③：混插共享清单逐行取有状态方
    $hx = @(Get-FlowRows (Join-Path $orchDir "任务清单-混插.md"))
    $h1 = $hx | Where-Object { $_.Key -eq 'Memtest 混插组合' }
    $h2 = $hx | Where-Object { $_.Key -eq 'Prime95 长压' }
    Assert ($h1.Status -eq '✓ 做成' -and $h1.Result -eq 'PASS') "混插 Memtest 行取服务器"
    Assert ($h2.Status -eq '✓ 做成' -and $h2.Result -eq 'P95 PASS') "混插 Prime95 行保留编排机"
    # 场景④：服务器目录不存在 → 不抛异常，返回编排机目录
    $m4 = Merge-TaskChecklists -ServerChecklistDir (Join-Path $tmp "no-srv-dir") -OrchestratorChecklistDir $orchDir -MachineName "srv01"
    Assert ($m4 -eq $orchDir) "服务器目录缺失静默返回"

    # ============ 7) 薄壳脚本黑盒（临时包根拷贝法，cmdlog 落临时库） ============
    $src = Split-Path -Parent $PSScriptRoot
    $shellKit = Join-Path $tmp "shellkit"
    New-Item -ItemType Directory -Path (Join-Path $shellKit "scripts"), (Join-Path $shellKit "results") -Force | Out-Null
    foreach ($f in @("New-TaskChecklist.ps1", "Update-TaskChecklist.ps1", "lib_common.ps1")) {
        Copy-Item (Join-Path $src "scripts\$f") (Join-Path $shellKit "scripts\$f") -Force
    }
    $shellNew = Join-Path $shellKit "scripts\New-TaskChecklist.ps1"
    $shellUpd = Join-Path $shellKit "scripts\Update-TaskChecklist.ps1"
    # New 薄壳：生成清单（批次 srv01-a1 → results\srv01-a1\）
    $outN = & powershell -NoProfile -ExecutionPolicy Bypass -File $shellNew -BatchName "srv01-a1" -MachineName "srv01" 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "薄壳 New exit 0（实际 $LASTEXITCODE，输出: $outN）"
    $shellOv = Join-Path $shellKit "results\srv01-a1\任务清单-总览.md"
    Assert (Test-Path $shellOv) "薄壳 New 生成总览"
    $shellOvRows = @(Get-OverviewRows $shellOv)
    Assert ($shellOvRows.Count -eq 17) "薄壳 New 总览 17 行"
    Assert (Test-Path (Join-Path $shellKit "results\srv01-a1\任务清单-建档.md")) "薄壳 New 生成流程清单"
    # Update 薄壳：人工更新目检电性一行
    $outU = & powershell -NoProfile -ExecutionPolicy Bypass -File $shellUpd -BatchName "srv01-a1" -Flow "目检电性" -Key "目检金手指焊点" -Status "✓ 做成" -Result "目检 OK" -Product "无" 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "薄壳 Update exit 0（实际 $LASTEXITCODE，输出: $outU）"
    $mjRows = @(Get-FlowRows (Join-Path $shellKit "results\srv01-a1\任务清单-目检电性.md"))
    $mj1 = $mjRows | Where-Object { $_.Key -eq '目检金手指焊点' }
    Assert ($mj1.Status -eq '✓ 做成' -and $mj1.Result -eq '目检 OK') "薄壳 Update 行状态/结果更新"
    $mj2 = $mjRows | Where-Object { $_.Key -eq '万用表电性' }
    Assert ($mj2.Status -eq '─ 等待执行') "薄壳 Update 其他行不变"
    # Update 薄壳：非法 -Status → 报错 exit 1 且行不变
    $outBad = & powershell -NoProfile -ExecutionPolicy Bypass -File $shellUpd -BatchName "srv01-a1" -Flow "目检电性" -Key "目检金手指焊点" -Status "XYZ" -Result "r" -Product "p" 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 1) "薄壳 Update 非法状态 exit 1（实际 $LASTEXITCODE，输出: $outBad）"
    Assert ($outBad -match "非法状态") "薄壳 Update 非法状态报错（实际输出: $outBad）"
    $mjRows2 = @(Get-FlowRows (Join-Path $shellKit "results\srv01-a1\任务清单-目检电性.md"))
    $mj1b = $mjRows2 | Where-Object { $_.Key -eq '目检金手指焊点' }
    Assert ($mj1b.Status -eq '✓ 做成' -and $mj1b.Result -eq '目检 OK') "薄壳 Update 非法状态后行不变"

    Write-Host "test-task-checklist: ALL PASS"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
