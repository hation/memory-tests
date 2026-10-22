# db/Db-Merge.ps1 — 历史库幂等合并封装（自动用包内 python）
# 用法: .\Db-Merge.ps1 --db1 <path> --db2 <path> --out <path>
param(
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)
if ($Help) {
    Write-Host "用法: .\Db-Merge.ps1 --db1 <path> --db2 <path> --out <path>"
    exit 0
}
. (Join-Path $PSScriptRoot "..\scripts\lib_common.ps1")
$py = Get-PythonExe
if (-not $py) { Write-Error "未找到 python（包内 tools\python 或系统 PATH），历史库功能不可用"; exit 1 }
& $py (Join-Path $PSScriptRoot "db_merge.py") @Args
exit $LASTEXITCODE
