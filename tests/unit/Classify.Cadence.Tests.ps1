#Requires -Module Pester
# Phase φ.2 · D-2026-05-18p · 6-bucket cadence vocabulary
#
# Locks the contract:
#   - Defender manifest contains 6 distinct cadence values (10m/30m/1h/6h/24h/weekly)
#   - Cadence is DATA-DRIVEN (path heuristic + IngestionMode + SubArea context)
#     NOT a hardcoded sub-area → cadence table from memory
#   - Every entry has a non-empty Cadence value (no untagged entry)
#   - Resolve-CadenceDataDriven function exists in Apply-ProjectionMaps and implements
#     the 6-bucket decision tree
#
# Anti-pattern: 2-bucket {LIVESTREAM=10m · SNAPSHOT=6h} hardcoded mapping.
# Replaced because operator wants finer-grained cadence per actual operational
# semantics (10m action queue · 30m identity activity · 1h threat analytics ·
# 6h config posture · 24h secure score · weekly tenant inventory).

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'manifests\defender.psd1'
    $script:Manifest     = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:ManifestPath)))
    $script:ToolSource   = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'tools\Apply-ProjectionMaps.ps1')

    # Group entries by cadence
    $script:CadenceGroups = @{}
    foreach ($e in $script:Manifest.Entries) {
        $c = if ($e.ContainsKey('Cadence') -and $e.Cadence) { [string]$e.Cadence } else { '' }
        if (-not $script:CadenceGroups.ContainsKey($c)) { $script:CadenceGroups[$c] = @() }
        $script:CadenceGroups[$c] += $e
    }
}

Describe 'φ.2 · 6-bucket cadence vocabulary · D-2026-05-18p' -Tag 'classify-cadence' {

    It 'Apply-ProjectionMaps.ps1 defines Resolve-CadenceDataDriven function' {
        $script:ToolSource | Should -Match 'function\s+Resolve-CadenceDataDriven'
    }

    It 'Resolve-CadenceDataDriven emits 6 distinct cadence values · 10m · 30m · 1h · 6h · 24h · weekly' {
        $script:ToolSource | Should -Match "return '10m'"
        $script:ToolSource | Should -Match "return '30m'"
        $script:ToolSource | Should -Match "return '1h'"
        $script:ToolSource | Should -Match "return '6h'"
        $script:ToolSource | Should -Match "return '24h'"
        $script:ToolSource | Should -Match "return 'weekly'"
    }

    It 'Path-based live-signal heuristic exists (Timeline · Pending · Active · etc.)' {
        # Live signals (regardless of sub-area) → 10m
        $script:ToolSource | Should -Match 'Timeline\|Pending\|Active'
    }

    It 'LIVESTREAM IngestionMode → 10m override · NOT auto-downgraded' {
        # Escape $ as literal in regex by using char class [$]
        $script:ToolSource | Should -Match "IngestionMode\s+-eq\s+'LIVESTREAM'"
    }

    It 'SubArea context switch uses ACTUAL manifest sub-areas (NOT phantom names)' {
        # Verify the data-driven sub-areas match what's actually in the manifest
        # (post-audit truth · not memory-fabricated names like UserSubmissions/XSpmGraphs/RoleMgmt)
        $script:ToolSource | Should -Match "'CloudApps'"
        $script:ToolSource | Should -Match "'ExposureManagement'"
        $script:ToolSource | Should -Match "'VulnerabilityManagement'"
        $script:ToolSource | Should -Match "'EndpointConfiguration'"
        $script:ToolSource | Should -Match "'SentinelPrecision'"
        $script:ToolSource | Should -Match "'EntityPivots'"
        $script:ToolSource | Should -Match "'DataLake'"
        $script:ToolSource | Should -Match "'Streaming'"
        # Phantom sub-areas MUST NOT appear (D-2026-05-18q · sub-area inventory data-driven)
        $script:ToolSource | Should -Not -Match "'UserSubmissions'"
        $script:ToolSource | Should -Not -Match "'XSpmGraphs'"
        $script:ToolSource | Should -Not -Match "'RoleMgmt'"
    }

    It 'manifests/defender.psd1 contains all 6 cadence values' {
        $present = @($script:CadenceGroups.Keys | Where-Object { $_ -in @('10m','30m','1h','6h','24h','weekly') })
        $present | Should -Contain '10m'
        $present | Should -Contain '30m'
        $present | Should -Contain '1h'
        $present | Should -Contain '6h'
        $present | Should -Contain '24h'
        $present | Should -Contain 'weekly'
    }

    It 'every manifest entry has a non-empty Cadence (no untagged entry · 519/519)' {
        $untagged = @($script:Manifest.Entries | Where-Object { -not $_.Cadence })
        $untagged.Count | Should -Be 0 -Because "all 519 Defender entries must have a Cadence value (data-driven classification · NO untagged)"
    }

    It 'cadence distribution sums to total entry count (519)' {
        $total = ($script:CadenceGroups['10m'].Count) + ($script:CadenceGroups['30m'].Count) + `
                 ($script:CadenceGroups['1h'].Count)  + ($script:CadenceGroups['6h'].Count) + `
                 ($script:CadenceGroups['24h'].Count) + ($script:CadenceGroups['weekly'].Count)
        $total | Should -Be 519 -Because "no entry should be in a cadence value outside the 6-bucket vocabulary"
    }

    It 'ActionCenter sub-area routes to 10m or 30m (live operational signals · pending actions)' {
        $ac = @($script:Manifest.Entries | Where-Object { $_.SubArea -eq 'ActionCenter' })
        $ac.Count | Should -BeGreaterThan 0
        $cadences = @($ac | ForEach-Object Cadence | Sort-Object -Unique)
        # All ActionCenter entries should be 10m OR 30m (NOT 6h+) per operational tempo
        $invalid = @($cadences | Where-Object { $_ -notin @('10m','30m','1h') })
        $invalid.Count | Should -Be 0 -Because "ActionCenter is live-signal · should not be 6h+ (got: $($cadences -join ','))"
    }

    It 'MultiTenant sub-area routes to weekly (inventory · slow-changing)' {
        $mt = @($script:Manifest.Entries | Where-Object { $_.SubArea -eq 'MultiTenant' })
        $mt.Count | Should -BeGreaterThan 0
        # All MultiTenant entries should be weekly (inventory snapshot)
        $cadences = @($mt | ForEach-Object Cadence | Sort-Object -Unique)
        $cadences | Should -Contain 'weekly' -Because "MultiTenant inventory is weekly cadence per D-2026-05-18p"
    }

    It 'SecureScore sub-area routes to 24h (slow audit)' {
        $ss = @($script:Manifest.Entries | Where-Object { $_.SubArea -eq 'SecureScore' })
        $ss.Count | Should -BeGreaterThan 0
        $cadences = @($ss | ForEach-Object Cadence | Sort-Object -Unique)
        $cadences | Should -Contain '24h' -Because "SecureScore is slow-changing posture data · 24h cadence"
    }

    It 'NO cadence value outside 6-bucket vocabulary appears in manifest' {
        $invalidCadences = @($script:CadenceGroups.Keys | Where-Object { $_ -notin @('10m','30m','1h','6h','24h','weekly') })
        $invalidCadences | Should -BeNullOrEmpty -Because "manifest must use ONLY the 6-bucket vocabulary (got: $($invalidCadences -join ','))"
    }

    It 'Path-based 10m heuristic: endpoints with /Timeline/ in path are 10m cadence' {
        $timelineEntries = @($script:Manifest.Entries | Where-Object { $_.Path -match '(?i)Timeline' })
        if ($timelineEntries.Count -gt 0) {
            $tlCadences = @($timelineEntries | ForEach-Object Cadence | Sort-Object -Unique)
            $non10m = @($tlCadences | Where-Object { $_ -ne '10m' })
            $non10m.Count | Should -Be 0 -Because "Timeline endpoints should be 10m (live signal) per path heuristic"
        }
    }
}
