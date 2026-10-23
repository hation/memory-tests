. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }

$goodConf = @'
# Memtest SOL 引导菜单预设
timeout=10
default=4轮验收
preset.4轮验收.title=Memtest86+ 4轮完整验收（SOL）
preset.4轮验收.cmdline=log=ttyS0,115200 maxpasses=4
preset.2轮.title=Memtest86+ 2轮（SOL）
preset.2轮.cmdline=log=ttyS0,115200 maxpasses=2
preset.1轮快速筛选.title=Memtest86+ 1轮快速筛选（SOL）
preset.1轮快速筛选.cmdline=log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8
preset.交互.title=Memtest86+ 交互界面（无串口日志）
preset.交互.cmdline=nomch
'@

$tmpGood = Join-Path $env:TEMP "mt-presets-good.conf"
[System.IO.File]::WriteAllText($tmpGood, $goodConf, (New-Object System.Text.UTF8Encoding($false)))

# --- 1) 正常 conf → 解析结果 ---
$p = Get-MemtestPresets -Path $tmpGood
Assert ($p.Presets.Count -eq 4) "presets count is 4"
Assert ($p.Presets[0].Key -eq '4轮验收') "preset order #1"
Assert ($p.Presets[1].Key -eq '2轮') "preset order #2"
Assert ($p.Presets[2].Key -eq '1轮快速筛选') "preset order #3"
Assert ($p.Presets[3].Key -eq '交互') "preset order #4"
Assert ($p.Presets[2].Cmdline -eq 'log=ttyS0,115200 maxpasses=1 testlist=0,1,2,3,4,5,6,7,8') "cmdline not truncated"
Assert ($p.Timeout -eq 10) "timeout is 10"
Assert ($p.Default -eq '4轮验收') "default is 4轮验收"

# --- 2) ConvertTo-GrubCfg → grub.cfg 全文 ---
$grub = ConvertTo-GrubCfg -Presets $p
Assert ($grub.StartsWith("set timeout=10")) "first line set timeout=10"
Assert ($grub -match 'set default=0') "set default=0"
Assert ($grub -match 'search --no-floppy --set=root --file /BOOT/MT86PLUS.BIN') "search fallback line"
Assert (([regex]::Matches($grub, 'menuentry')).Count -eq 4) "exactly 4 menuentry"
$linuxLines = ($grub -split "`r?`n") | Where-Object { $_.Trim().StartsWith("linux ") }
Assert ($linuxLines.Count -eq 4) "4 linux lines"
foreach ($l in $linuxLines) { Assert ($l -match '/BOOT/MT86PLUS.BIN') "linux line has kernel path" }
Assert ($grub -match '4轮完整验收') "utf-8 chinese title present"
$grub3 = ConvertTo-GrubCfg -Presets $p -TimeoutSeconds 3
Assert ($grub3 -match 'set timeout=3') "TimeoutSeconds override"
$grubD = ConvertTo-GrubCfg -Presets $p -DefaultIndex 2
Assert ($grubD -match 'set default=2') "DefaultIndex override"

# --- 3) 缺 default → throw ---
$tmpNoDef = Join-Path $env:TEMP "mt-presets-nodef.conf"
[System.IO.File]::WriteAllText($tmpNoDef, "timeout=10`npreset.a.title=A`npreset.a.cmdline=x`n", (New-Object System.Text.UTF8Encoding($false)))
$thrown = $false
try { Get-MemtestPresets -Path $tmpNoDef | Out-Null } catch { $thrown = $true }
Assert $thrown "missing default throws"

# --- 4) timeout=abc → throw ---
$tmpBadT = Join-Path $env:TEMP "mt-presets-badtimeout.conf"
[System.IO.File]::WriteAllText($tmpBadT, "timeout=abc`ndefault=a`npreset.a.title=A`npreset.a.cmdline=x`n", (New-Object System.Text.UTF8Encoding($false)))
$thrown = $false
try { Get-MemtestPresets -Path $tmpBadT | Out-Null } catch { $thrown = $true }
Assert $thrown "invalid timeout throws"

# --- 5) 某 preset 缺 title 或缺 cmdline → throw ---
$tmpNoTitle = Join-Path $env:TEMP "mt-presets-notitle.conf"
[System.IO.File]::WriteAllText($tmpNoTitle, "timeout=10`ndefault=a`npreset.a.cmdline=x`n", (New-Object System.Text.UTF8Encoding($false)))
$thrown = $false
try { Get-MemtestPresets -Path $tmpNoTitle | Out-Null } catch { $thrown = $true }
Assert $thrown "preset missing title throws"
$tmpNoCmd = Join-Path $env:TEMP "mt-presets-nocmd.conf"
[System.IO.File]::WriteAllText($tmpNoCmd, "timeout=10`ndefault=a`npreset.a.title=A`n", (New-Object System.Text.UTF8Encoding($false)))
$thrown = $false
try { Get-MemtestPresets -Path $tmpNoCmd | Out-Null } catch { $thrown = $true }
Assert $thrown "preset missing cmdline throws"

Remove-Item -LiteralPath $tmpGood, $tmpNoDef, $tmpBadT, $tmpNoTitle, $tmpNoCmd -Force -ErrorAction SilentlyContinue
Write-Host "test-presets: ALL PASS"
