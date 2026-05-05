#Requires -Modules Pester
<#
.SYNOPSIS
    D'.6 v0.1.0 GA Phase 5.3 — manifest entry schema gate.

.DESCRIPTION
    Asserts every entry in `endpoints.manifest.psd1` has the mandatory fields
    declared with valid enum values. Catches drift in:

      Stream         must match ^MDE_[A-Za-z0-9]+_CL$
      Path           must start with /apiproxy/ or /api/
      Tier           one of: ActionCenter | XspmGraph | Configuration | Inventory | Maintenance
      Category       one of the 10 nathanmcnulty taxonomy values
      CategoryId     1..10 (matches the 10-category taxonomy)
      Purpose        non-empty operator-facing description
      Availability   one of: live | tenant-gated | deprecated
      ProjectionMap  required for non-deprecated; >=3 keys; valid type-cast hints

    Conjugates with Manifest.SchemaContract.Tests.ps1 (declares the manifest is
    correctly shaped) and Manifest.ProjectionMap.Coverage.Tests.ps1 (declares
    projections are LA-table-safe). This file specifically gates entry-level
    fields are present + valid enum values.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1'
    $script:Manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:Endpoints = @($script:Manifest.Endpoints)

    $script:ValidTiers = @('ActionCenter', 'XspmGraph', 'Configuration', 'Inventory', 'Maintenance')
    $script:ValidAvailability = @('live', 'tenant-gated', 'deprecated')
    $script:ValidCategories = @(
        'Endpoint Device Management',
        'Endpoint Configuration',
        'Vulnerability Management (TVM)',
        'Identity Protection (MDI)',
        'Configuration and Settings',
        'Exposure Management (XSPM)',
        'Threat Analytics',
        'Action Center',
        'Multi-Tenant Operations',
        'Streaming API'
    )
    $script:CategoryToCategoryId = @{
        'Endpoint Device Management'     = 1
        'Endpoint Configuration'          = 2
        'Vulnerability Management (TVM)' = 3
        'Identity Protection (MDI)'       = 4
        'Configuration and Settings'      = 5
        'Exposure Management (XSPM)'      = 6
        'Threat Analytics'                = 7
        'Action Center'                   = 8
        'Multi-Tenant Operations'         = 9
        'Streaming API'                   = 10
    }
}

Describe 'Manifest.Schema — required fields + valid enum values' {

    It 'every entry has Stream matching ^MDE_[A-Za-z0-9]+_CL$' {
        foreach ($e in $script:Endpoints) {
            $e.Stream | Should -Match '^MDE_[A-Za-z0-9]+_CL$' -Because "Stream '$($e.Stream)' must match the LA custom-table convention"
        }
    }

    It 'every entry has Path starting with /apiproxy/ or /api/' {
        foreach ($e in $script:Endpoints) {
            ($e.Path -match '^/(apiproxy|api)/') | Should -BeTrue -Because "Path '$($e.Path)' must start with /apiproxy/ or /api/ (Stream=$($e.Stream))"
        }
    }

    It 'every entry Tier is one of the 5 valid cadence-tiers' {
        foreach ($e in $script:Endpoints) {
            $script:ValidTiers | Should -Contain $e.Tier -Because "Stream=$($e.Stream) Tier='$($e.Tier)' must be one of: $($script:ValidTiers -join ', ')"
        }
    }

    It 'every entry Category is one of the 10 taxonomy values' {
        foreach ($e in $script:Endpoints) {
            $script:ValidCategories | Should -Contain $e.Category -Because "Stream=$($e.Stream) Category='$($e.Category)' must be one of the 10 nathanmcnulty taxonomy categories"
        }
    }

    It 'every entry CategoryId is 1..10 and matches the Category mapping' {
        foreach ($e in $script:Endpoints) {
            $expectedId = $script:CategoryToCategoryId[$e.Category]
            $e.CategoryId | Should -Be $expectedId -Because "Stream=$($e.Stream) Category='$($e.Category)' must have CategoryId=$expectedId (got $($e.CategoryId))"
        }
    }

    It 'every entry Availability is one of: live | tenant-gated | deprecated' {
        foreach ($e in $script:Endpoints) {
            $script:ValidAvailability | Should -Contain $e.Availability -Because "Stream=$($e.Stream) Availability='$($e.Availability)' must be one of: $($script:ValidAvailability -join ', ')"
        }
    }

    It 'every entry has non-empty Purpose (operator-facing description)' {
        foreach ($e in $script:Endpoints) {
            $e.Purpose | Should -Not -BeNullOrEmpty -Because "Stream=$($e.Stream) Purpose must be a non-empty operator-facing description"
            ([string]$e.Purpose).Length | Should -BeGreaterThan 20 -Because "Stream=$($e.Stream) Purpose='$($e.Purpose)' too terse to be useful for operators"
        }
    }

    It 'every non-deprecated entry has ProjectionMap with >=3 typed columns' {
        foreach ($e in $script:Endpoints) {
            if ($e.Availability -eq 'deprecated') { continue }
            $e.ContainsKey('ProjectionMap') | Should -BeTrue -Because "Stream=$($e.Stream) (non-deprecated) must declare ProjectionMap"
            @($e.ProjectionMap.Keys).Count | Should -BeGreaterOrEqual 3 -Because "Stream=$($e.Stream) ProjectionMap must declare >=3 typed columns (operators query typed cols, not just RawJson)"
        }
    }

    It 'no two entries share the same Stream name (uniqueness gate)' {
        $names = @($script:Endpoints | ForEach-Object { $_.Stream })
        $unique = @($names | Sort-Object -Unique)
        $names.Count | Should -Be $unique.Count -Because 'each Stream name must be unique across the manifest'
    }

    It 'no two entries share the same Path + Method + Body (effective-path uniqueness)' {
        # Different streams may share Path AND Method if their POST Body differs
        # (e.g., XspmAttackPaths/XspmChokePoints/XspmTopTargets all POST to
        # /apiproxy/mtp/xspmatlas/attacksurface/query with different body shapes
        # — the body's `query.kind` field differentiates which response shape
        # the endpoint returns).
        $combos = @($script:Endpoints | ForEach-Object {
            $method = if ($_.ContainsKey('Method')) { $_.Method } else { 'GET' }
            $bodyHash = if ($_.ContainsKey('Body')) {
                ($_.Body | ConvertTo-Json -Compress -Depth 10).GetHashCode().ToString()
            } else { 'no-body' }
            "$method $($_.Path) body=$bodyHash"
        })
        $unique = @($combos | Sort-Object -Unique)
        $combos.Count | Should -Be $unique.Count -Because 'each (Path, Method, Body) combo must be unique'
    }
}

Describe 'Manifest.Schema — Defaults block contract' {

    It 'manifest exposes a Defaults block with the per-entry baseline fields' {
        $script:Manifest.ContainsKey('Defaults') | Should -BeTrue -Because 'Get-XdrEndpointManifest layers per-entry overrides on top of Defaults'
        $defaults = $script:Manifest.Defaults
        # The Defaults block carries the per-entry baseline (cross-cutting fields
        # that every Endpoint entry inherits unless explicitly overridden).
        # Per-call HTTP defaults (Method/UserAgent/Headers/Timeout) live in
        # Invoke-DefenderPortalRequest, NOT in the manifest data.
        foreach ($key in 'IdProperty','Portal','SchemaSource') {
            $defaults.ContainsKey($key) | Should -BeTrue -Because "Defaults must declare '$key' baseline (each entry inherits unless overridden)"
        }
    }
}

Describe 'Manifest.Schema — Optional-field contract' {

    It 'every entry with UnwrapProperty has a non-empty string value' {
        foreach ($e in $script:Endpoints) {
            if ($e.ContainsKey('UnwrapProperty')) {
                $e.UnwrapProperty | Should -Not -BeNullOrEmpty -Because "Stream=$($e.Stream) UnwrapProperty must be non-empty if declared"
                ([string]$e.UnwrapProperty).Length | Should -BeGreaterThan 0
            }
        }
    }

    It 'every entry with SingleObjectAsRow=$true has no UnwrapProperty (mutually exclusive)' {
        foreach ($e in $script:Endpoints) {
            if ($e.ContainsKey('SingleObjectAsRow') -and $e.SingleObjectAsRow) {
                $e.ContainsKey('UnwrapProperty') | Should -BeFalse -Because "Stream=$($e.Stream) cannot have both SingleObjectAsRow and UnwrapProperty"
            }
        }
    }

    It 'every entry with IdProperty has non-empty string array' {
        foreach ($e in $script:Endpoints) {
            if ($e.ContainsKey('IdProperty')) {
                @($e.IdProperty).Count | Should -BeGreaterThan 0 -Because "Stream=$($e.Stream) IdProperty array must be non-empty"
                foreach ($p in $e.IdProperty) {
                    ([string]$p).Length | Should -BeGreaterThan 0 -Because "Stream=$($e.Stream) IdProperty entry must be non-empty string"
                }
            }
        }
    }
}
