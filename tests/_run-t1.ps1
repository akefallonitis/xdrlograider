$r = Invoke-Pester -Path tests/unit -PassThru -Output None
Write-Host ("T1: {0}/{1} | failed={2}" -f $r.PassedCount, $r.TotalCount, $r.FailedCount)
if ($r.FailedCount -gt 0) {
    $r.Failed | ForEach-Object { Write-Host ("FAIL: " + $_.ExpandedPath) -ForegroundColor Red }
}
