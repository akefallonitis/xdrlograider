#requires -Version 7.0
# RE-AUDIT-F · DCR ↔ Manifest ↔ run.ps1 ↔ Sentinel content end-to-end chain trace
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot

$m = & ([scriptblock]::Create((Get-Content -Raw (Join-Path $repo 'manifests/defender.psd1'))))
$manifestSubs = @($m.Entries | ForEach-Object SubArea | Sort-Object -Unique)
Write-Host "1. Manifest sub-areas: $($manifestSubs.Count) ($($manifestSubs -join ','))"

$arm = Get-Content -Raw (Join-Path $repo 'deploy/mainTemplate.json')
$armMatch = [regex]::Match($arm, '"defenderSubAreas"\s*:\s*\[([^\]]+)\]')
if ($armMatch.Success) {
    $armList = ($armMatch.Groups[1].Value -split ',' | ForEach-Object { ($_ -replace '[\s"]','') }) | Where-Object { $_ }
    Write-Host "2. ARM defenderSubAreas variable: $(@($armList).Count)"
    $diff = Compare-Object $manifestSubs $armList -PassThru
    if ($diff) { Write-Host "   DRIFT: $($diff -join ',')" -ForegroundColor Red }
    else       { Write-Host "   aligned (no drift)" -ForegroundColor Green }
}

$hasCopyLoop = [bool]([regex]::IsMatch($arm, 'defenderSubAreaDcrLoop'))
Write-Host "3. ARM DCR copy loop 'defenderSubAreaDcrLoop': $hasCopyLoop"

$hasDcrMap = [bool]([regex]::IsMatch($arm, 'DCR_IMMUTABLE_ID_MAP'))
Write-Host "4. ARM emits DCR_IMMUTABLE_ID_MAP app setting: $hasDcrMap"

$rp = Get-Content -Raw (Join-Path $repo 'src/functions/Xdr-Poll/run.ps1')
$hasRouter = [bool]([regex]::IsMatch($rp, 'ConvertFrom-XdrDcrImmutableIdMap'))
Write-Host "5. run.ps1 stream router consumes DCR_IMMUTABLE_ID_MAP: $hasRouter"

$hasTablesDeployment = [bool]([regex]::IsMatch($arm, 'tablesDeployment'))
Write-Host "6. ARM provisions custom workspace tables (nested deployment): $hasTablesDeployment"

$sc = Get-Content -Raw (Join-Path $repo 'deploy/sentinelContent.json')
$matches = [regex]::Matches($sc, 'Defender_(\w+)_CL')
$sdt = @($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Write-Host "7. Sentinel content references $($sdt.Count) distinct Defender_*_CL tables"

# Check Stream field per entry matches the per-sub-area stream pattern
$badStream = @($m.Entries | Where-Object {
    $expected = "Defender_$($_.SubArea)_CL"
    $actual = if ($_.ContainsKey('Stream')) { [string]$_.Stream } else { '' }
    $actual -ne $expected
})
Write-Host "8. Manifest entries with non-conventional Stream field: $($badStream.Count) (expected 0)"

# ProbeMode distribution + active forecast
Write-Host ""
Write-Host "9. ProbeMode distribution (active = all except Excluded):"
$m.Entries | Group-Object ProbeMode | Sort-Object Count -Descending | ForEach-Object {
    Write-Host "   $($_.Count.ToString().PadLeft(3)) $($_.Name)"
}
$active = @($m.Entries | Where-Object { $_.ProbeMode -ne 'Excluded' }).Count
Write-Host "   Active forecast: $active/$(@($m.Entries).Count) = $([math]::Round(100.0*$active/@($m.Entries).Count,1))%"
