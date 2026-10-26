# ============================================================================
# test-cmdlog.ps1 — Write-CmdLog 指令记录回归测试
# 覆盖 5 个用例：写入建文件字段齐全 / 追加不重复 header / 密码打码 /
#   按日期滚动命名 / 目录自动创建。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-cmdlog.ps1
# ============================================================================
. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'results\cmdlog'
$f = Join-Path $logDir ("commands-{0:yyyy-MM-dd}.csv" -f (Get-Date))
Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
# 1 写入 → 建文件、字段齐全
Write-CmdLog -Script test -CmdArgs '-BmcHost 10.0.0.10' -State Start
Assert (Test-Path -LiteralPath $f) "1 文件已创建"
$rows = @(Import-Csv -LiteralPath $f)
Assert ($rows.Count -eq 1) "1b 首行"
Assert ($rows[0].Script -eq 'test' -and $rows[0].State -eq 'Start') "1c 字段"
# 2 追加不重复 header
Write-CmdLog -Script test -CmdArgs '-BmcHost 10.0.0.10' -State End -Result OK
$lines = Get-Content -LiteralPath $f
Assert ($lines[0] -like '"Timestamp"*') "2a 首行仍 header"
Assert (@(Import-Csv -LiteralPath $f).Count -eq 2) "2b 2 行数据"
# 3 密码打码
Write-CmdLog -Script test -CmdArgs '-BmcPass secret -BmcPass=sec2 -P p1 -P=p2' -State Start
$txt = Get-Content -LiteralPath $f -Raw
Assert (-not ($txt -match 'secret|sec2|\bp1\b|\bp2\b')) "3 密码已打码"
Assert (($txt -split '\*{3}').Count -ge 5) "3b 有 4 处 ***"
# 4 日期命名
Assert ($f -match 'commands-\d{4}-\d{2}-\d{2}\.csv$') "4 按日期滚动命名"
# 5 目录自动创建（先删目录再写）
Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
Write-CmdLog -Script test -State Start
Assert (Test-Path -LiteralPath $logDir) "5 目录自动创建"
Write-Host "ALL PASS"
