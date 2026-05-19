#Requires -Module Pester
# Phase 0j J-2 · FINAL-shape manifest invariants for defender.psd1.
# Layers on top of the candidate-shape Manifest.Schema.Tests.ps1 baseline:
#   - Slug field present (post-Phase-0j enrichment)
#   - Cadence enum populated
#   - RequiresProducts array (may be empty)
#   - LicenseHint present when RequiresProducts non-empty
#   - ReadSemantics = 'read' (Memory Rule contract)
#   - ProjectionMap typed-DSL when populated (any DSL operator with JSONPath)
#
# Tolerates ProjectionMap = @{} for endpoints without live captures (license-gated /
# path-param / mutation). Phase 0j J-3 (E2E.Replay.Defender.Tests.ps1) validates
# actual replay for endpoints WHERE captures exist.

BeforeAll {
    $ManifestPath = Join-Path $PSScriptRoot '..\..\manifests\defender.psd1'
    # No module import needed — this suite asserts manifest invariants only (no runtime calls).
    # Manifest.Schema.Tests.ps1 imports Xdr.Poll because IT uses Test-ApiproxyPathPrefix.
    $script:Manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
}

Describe 'manifests/defender.psd1 · Phase 0j FINAL shape (enriched)' -Tag 'manifest-final' {

    It 'SchemaVersion declares post-J1 enrichment level' {
        $script:Manifest.SchemaVersion | Should -Match '^0\.1\.0-(j1-enriched|step\d+-classified)$'
    }

    It 'every entry has a Slug field (post-Phase-0j canonicalization)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Keys | Should -Contain 'Slug' -Because "entry '$($e.EntryKey)' must declare Slug (post-Phase-0j)"
            $e.Slug | Should -Not -BeNullOrEmpty
        }
    }

    It 'every entry has Cadence in {10m, 30m, 1h, 6h, 24h, daily, weekly} · 6-bucket vocabulary · D-2026-05-18p' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Cadence | Should -Match '^(10m|30m|1h|6h|24h|daily|weekly)$' -Because "entry '$($e.EntryKey)' has cadence '$($e.Cadence)' · 6-bucket vocab post φ.A/φ.2"
        }
    }

    It 'every entry has ReadSemantics = read (Memory Rule contract)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.ReadSemantics | Should -Be 'read' -Because "entry '$($e.EntryKey)' must be read-semantic (no mutations)"
        }
    }

    It 'every entry has RequiresProducts array (may be empty for always-available)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Keys | Should -Contain 'RequiresProducts'
            ,$e.RequiresProducts | Should -BeOfType [System.Array] -Because "entry '$($e.EntryKey)' RequiresProducts must be array literal '@()' even when empty"
        }
    }

    It 'every entry with non-empty RequiresProducts has non-empty LicenseHint' {
        foreach ($e in $script:Manifest.Entries) {
            if ($e.RequiresProducts.Count -gt 0) {
                $e.LicenseHint | Should -Not -BeNullOrEmpty -Because "entry '$($e.EntryKey)' requires $($e.RequiresProducts -join ',') so LicenseHint must be operator-readable"
            }
        }
    }

    It 'every entry has a ProjectionMap (hashtable · may be empty pre-capture)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Keys | Should -Contain 'ProjectionMap'
            $e.ProjectionMap | Should -BeOfType [System.Collections.IDictionary]
        }
    }

    It 'every populated ProjectionMap value uses typed-DSL prefix + JSONPath' {
        # Typed DSL: '$<op>:$.<path>' or '$<op>:$..<path>' (deep-scan) where path may include word chars · '@' (OData) · '[]' (array root)
        # φ.A · stub-source entries use $..fieldName (JSONPath deep-scan) for runtime entity-heuristic
        $dslPattern = '^\$(tostring|toint|tolong|todouble|tobool|todatetime|dynamic|tojson):\$\.{1,2}([\w@_]|\[\])'
        foreach ($e in $script:Manifest.Entries) {
            if ($e.ProjectionMap.Count -eq 0) { continue }
            foreach ($k in $e.ProjectionMap.Keys) {
                $v = $e.ProjectionMap[$k]
                $v | Should -Match $dslPattern -Because "entry '$($e.EntryKey)' projection['$k'] = '$v' must use typed-DSL prefix"
            }
        }
    }

    It 'reports ProjectionMap population coverage (visibility metric · not gating)' {
        $total = @($script:Manifest.Entries).Count
        $populated = @($script:Manifest.Entries | Where-Object { $_.ProjectionMap.Count -gt 0 }).Count
        $pct = if ($total -gt 0) { [math]::Round(100.0 * $populated / $total, 1) } else { 0 }
        Write-Host ("    ProjectionMap populated: {0}/{1} ({2}%)" -f $populated, $total, $pct) -ForegroundColor DarkCyan
        # Floor: at least TenantContext + a smattering of ActionCenter must be populated
        $populated | Should -BeGreaterOrEqual 1 -Because 'at minimum the TenantContext smoke entry must have a ProjectionMap'
    }

    It 'IngestionMode coverage: LIVESTREAM + SNAPSHOT both present' {
        $modes = @($script:Manifest.Entries | ForEach-Object IngestionMode | Sort-Object -Unique)
        $modes | Should -Contain 'LIVESTREAM'
        $modes | Should -Contain 'SNAPSHOT'
    }

    It 'TenantContext entry has populated ProjectionMap (live-fixture-derived contract)' {
        $tc = $script:Manifest.Entries | Where-Object {
            ($_.ContainsKey('Slug') -and $_.Slug -eq 'TenantContext') -or
            ($_.NodocRoute -match 'TenantContext$' -and $_.SubArea -eq 'Configuration')
        } | Select-Object -First 1
        $tc | Should -Not -BeNullOrEmpty
        # TenantContext was the v0.0.1 smoke endpoint · projection must derive from live fixture
        $tc.ProjectionMap | Should -Not -BeNullOrEmpty
        $tc.ProjectionMap.Count | Should -BeGreaterThan 5 -Because 'TenantContext response has > 20 scalar fields · projection should cover at least 5'
        $tc.ProjectionMap.Keys | Should -Contain 'OrgId'
        $tc.ProjectionMap.Keys | Should -Contain 'GeoRegion'
    }
}
