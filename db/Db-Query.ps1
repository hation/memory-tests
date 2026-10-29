# db/Db-Query.ps1 — SQLite 历史库查询封装（自动用包内 python）
# 用法（在离线包根目录运行）: .\db\Db-Query.ps1 [--db history.db] [--serial <SN>] [--batch <name>] [--trend]
param(
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)
if ($Help) {
    Write-Host "用法: .\db\Db-Query.ps1 [--db history.db] [--serial <SN>] [--batch <name>] [--trend]"
    exit 0
}
. (Join-Path $PSScriptRoot "..\scripts\lib_common.ps1")
$py = Get-PythonExe
if (-not $py) { Write-Error "未找到 python（包内 tools\python 或系统 PATH），历史库功能不可用"; exit 1 }
& $py (Join-Path $PSScriptRoot "db_query.py") @Args
exit $LASTEXITCODE
