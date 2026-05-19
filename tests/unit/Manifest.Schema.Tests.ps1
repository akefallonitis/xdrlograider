#Requires -Module Pester
# Manifest invariants for the Phase 0h CANDIDATE shape emitted by
# tools/Build-CandidateManifest.ps1 (post Phase 0h step 1 · pre Phase 0j authoring).
#
# Locks: top-level keys, Entries array, Gate O /apiproxy/<service>/ prefix,
# Gate AA Memory Rule 2 wholesale-drops, Gate Y IngestionMode populated,
# Reinforcement-C Capability declared, EntryKey uniqueness, TenantContext smoke
# entry retained for Phase 0h smoke-replay.
#
# Phase 0j (Manifest.Defender.FullCatalogue.Tests.ps1) layers the FINAL-shape
# contract on top of this: ProjectionMap typed-DSL populated, Cadence enum,
# RequiresProducts array, LicenseHint when RequiresProducts non-empty.

BeforeAll {
    $ManifestPath = Join-Path $PSScriptRoot '..\..\manifests\defender.psd1'
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
    # Use scriptblock evaluator (not Import-PowerShellDataFile) because the candidate
    # manifest emits `$true` for IsActive — PS 7.x's strict-static loader rejects that.
    $script:Manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $ManifestPath)))
}

Describe 'manifests/defender.psd1 · Phase 0h CANDIDATE shape' {

    It 'has required top-level keys (Portal · IsActive · SchemaVersion · Provenance · Entries)' {
        $script:Manifest.Keys | Should -Contain 'Portal'
        $script:Manifest.Keys | Should -Contain 'IsActive'
        $script:Manifest.Keys | Should -Contain 'SchemaVersion'
        $script:Manifest.Keys | Should -Contain 'Provenance'
        $script:Manifest.Keys | Should -Contain 'Entries'
    }

    It 'Portal is Defender and IsActive is $true (v0.1.0 active portal)' {
        $script:Manifest.Portal   | Should -Be 'Defender'
        $script:Manifest.IsActive | Should -BeTrue
    }

    It 'Provenance is the nodoc-openapi-candidate provenance string (audit trail)' {
        $script:Manifest.Provenance | Should -Match 'nodoc-openapi-candidate'
    }

    It 'has at least the v0.1.0 catalogue floor (>= 400 entries · scope = ~445 Defender)' {
        @($script:Manifest.Entries).Count | Should -BeGreaterOrEqual 400
    }

    It 'every entry has the required candidate-shape fields' {
        foreach ($e in $script:Manifest.Entries) {
            $e.EntryKey      | Should -Not -BeNullOrEmpty
            $e.SubArea       | Should -Not -BeNullOrEmpty
            $e.Path          | Should -Not -BeNullOrEmpty
            # Defender /apiproxy/ surface uses the full REST method matrix
            $e.Method        | Should -Match '^(GET|POST|PUT|PATCH|DELETE)$'
            $e.Portal        | Should -Be 'Defender'
            $e.AuthScheme    | Should -Not -BeNullOrEmpty
            $e.Stream        | Should -Not -BeNullOrEmpty
            $e.NodocRoute    | Should -Not -BeNullOrEmpty
            $e.SpecFile      | Should -Not -BeNullOrEmpty
            # ProjectionMap is a hashtable — present but may be empty at candidate stage
            # (Phase 0j populates the typed-DSL projection per endpoint)
            $e.Keys | Should -Contain 'ProjectionMap'
        }
    }

    It 'EVERY entry Path starts with /apiproxy/ + known-service prefix (Gate O at manifest layer)' {
        foreach ($e in $script:Manifest.Entries) {
            Test-ApiproxyPathPrefix -Path $e.Path | Should -BeTrue -Because ("entry '{0}' has path '{1}'" -f $e.EntryKey, $e.Path)
        }
    }

    # NOTE: angle-brackets ('<','>') in It-name are Pester TestCase-placeholder syntax and
    # get eaten by name interpolation under StrictMode. Use words instead.
    It 'EVERY Stream matches Defender_subarea_CL shape (pre-deploy table-name shape)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Stream | Should -Match '^Defender_[A-Z][A-Za-z]+_CL$' -Because ("stream '{0}' for entry '{1}'" -f $e.Stream, $e.EntryKey)
        }
    }

    It 'EntryKey is unique across entries (no duplicates after dedup)' {
        $keys = $script:Manifest.Entries | ForEach-Object EntryKey
        @($keys).Count | Should -Be (@($keys | Select-Object -Unique).Count)
    }

    It 'TenantContext smoke entry retained (v0.0.1 smoke contract preserved into v0.1.0)' {
        $tc = $script:Manifest.Entries | Where-Object { $_.NodocRoute -match '\.TenantContext$' -or $_.Path -match 'TenantContext' }
        $tc | Should -Not -BeNullOrEmpty
        # at least one TenantContext entry must exist for E2E.Replay.TenantContext smoke
        ($tc | ForEach-Object { $_.Path } | Where-Object { $_ -match 'TenantContext' }).Count | Should -BeGreaterOrEqual 1
    }

    # Gate Y (Phase 0 Step 7)
    It 'every entry declares an IngestionMode in {LIVESTREAM, SNAPSHOT, EXCLUDED}' {
        foreach ($e in $script:Manifest.Entries) {
            $e.IngestionMode | Should -BeIn @('LIVESTREAM','SNAPSHOT','EXCLUDED') -Because "entry '$($e.EntryKey)' must classify per the 6-rule IngestionMode classifier"
        }
    }

    # Reinforcement C (dynamic capability discovery filter)
    # Candidate stage: Capability KEY must be present on every entry (value population
    # comes from Phase 0j authoring · empty Capability accepted as "always-available").
    It 'every entry declares a Capability key (cold-start filter input · Reinforcement C)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Keys | Should -Contain 'Capability' -Because "entry '$($e.EntryKey)' must declare a Capability key (Reinforcement C)"
        }
    }

    # Gate AA (Memory Rule 2 · wholesale-dropped sub-areas)
    It 'zero entries in wholesale-dropped sub-areas (AdvancedHunting · AlertsIncidents · LiveResponse)' {
        $forbidden = @('AdvancedHunting','AlertsIncidents','LiveResponse')
        foreach ($e in $script:Manifest.Entries) {
            $e.SubArea | Should -Not -BeIn $forbidden -Because "Memory Rule 2: '$($e.SubArea)' is wholesale-dropped (covered by public Graph/MDE APIs)"
        }
    }

    # Gate AE (D-36 host ban · no graph.microsoft.com / graph.windows.net)
    It 'zero entries point at Graph hosts (D-36 host ban · Graph-proxy paths excluded)' {
        foreach ($e in $script:Manifest.Entries) {
            $e.Path | Should -Not -Match 'graph\.microsoft\.com|graph\.windows\.net' -Because "entry '$($e.EntryKey)' must not proxy through Graph hosts"
        }
    }
}
