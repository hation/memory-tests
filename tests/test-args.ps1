. "$PSScriptRoot\..\scripts\lib_common.ps1"
function Assert($cond, $msg) { if (-not $cond) { throw "ASSERT FAIL: $msg" } }
$rows = @(Read-CsvManifest -Path "$PSScriptRoot\fixtures\sample-batches.csv")
Assert ($rows.Count -eq 2) "row count"
Assert ($rows[0].TestList -eq "0,1,2,3") "quoted comma TestList"
Assert ($rows[1].LogPath -eq "") "trailing empty kept"
Write-Host "test-args: ALL PASS"
