$ReferencesRoot = "$PSScriptRoot/../references"
Set-Location $ReferencesRoot

Write-Host "=== All portals — endpoint counts ===" -ForegroundColor Cyan
$totals = @{ ep=0; live=0; le=0; err=0; nl=0 }
Get-ChildItem -Directory | Sort-Object Name | ForEach-Object {
    $portal = $_.Name
    $ep = (Get-ChildItem -Path $portal -Recurse -Filter 'metadata.json').Count
    $sa = (Get-ChildItem -Path $portal -Directory).Count
    $live=0; $le=0; $er=0; $nl=0
    Get-ChildItem -Path $portal -Recurse -Filter 'live.json' | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            switch ($j.successKind) {
                'live'       { $live++ }
                'live-empty' { $le++ }
                'error'      { $er++ }
                default      { $nl++ }
            }
        } catch {}
    }
    $totals.ep += $ep; $totals.live += $live; $totals.le += $le; $totals.err += $er; $totals.nl += $nl
    '{0,-22} {1,3} sa  {2,4} ep | live={3,3} le={4,2} err={5,3} nl={6,3}' -f $portal, $sa, $ep, $live, $le, $er, $nl | Write-Host
}
Write-Host ('TOTAL                          {0,4} ep | live={1,3} le={2,2} err={3,3} nl={4,3}' -f $totals.ep, $totals.live, $totals.le, $totals.err, $totals.nl)

Write-Host ""
Write-Host "=== Defender sub-areas (live-verified portal) ===" -ForegroundColor Cyan
Get-ChildItem 'defender' -Directory | Sort-Object Name | ForEach-Object {
    $idx = Join-Path $_.FullName '_SUBAREA.json'
    if (Test-Path $idx) {
        $sa = Get-Content $idx -Raw | ConvertFrom-Json
        $entsArr = @($sa.entitiesAvailable)
        $ents = if ($entsArr.Count -gt 0) { ($entsArr | Select-Object -First 5) -join ',' } else { '<none>' }
        $pgsArr = @($sa.paginationStyles)
        $pgs = if ($pgsArr.Count -gt 0) { $pgsArr -join ',' } else { 'none' }
        '{0,-26} cad={1,-6} ep={2,3} live={3,2} le={4,2} err={5,3}  paging={6,-30}  top-entities={7}' -f $sa.subArea, $sa.suggestedCadence, $sa.endpointCount, $sa.cntLive, $sa.cntLiveEmpty, $sa.cntError, $pgs, $ents | Write-Host
    }
}

Write-Host ""
Write-Host "=== Global entity occurrence (cross-correlation join keys) ===" -ForegroundColor Cyan
$entityTally = @{}
Get-ChildItem -Path . -Filter 'metadata.json' -Recurse | ForEach-Object {
    try {
        $m = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($m.entities) {
            foreach ($e in @($m.entities)) {
                if (-not $entityTally.ContainsKey($e)) { $entityTally[$e] = 0 }
                $entityTally[$e]++
            }
        }
    } catch {}
}
$entityTally.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25 | ForEach-Object {
    '  {0,-25} {1,5}' -f $_.Key, $_.Value | Write-Host
}
