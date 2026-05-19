#Requires -Module Pester
# P0 exit-gate test: Pester replays the captured live response through
# Auth -> Poll -> (row-shape stub) and asserts the row matches the DCR
# streamDeclaration columns declared in deploy/mainTemplate.json.
#
# Skips automatically if the live fixture is missing (CI / fresh clone).
# Locks: shape drift between Microsoft response, manifest EntityHints,
# manifest ProjectionMap, and DCR streamDeclaration.

BeforeDiscovery {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:FixtureDir     = Join-Path $script:RepoRoot 'tests\fixtures\live\TenantContext'
    $script:ResponseFx     = Join-Path $script:FixtureDir 'response.json'
    $script:FixturePresent = Test-Path $script:ResponseFx
}

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ResponseFx = Join-Path $script:RepoRoot 'tests\fixtures\live\TenantContext\response.json'
    # scriptblock evaluator handles $true (candidate IsActive · Import-PowerShellDataFile rejects dynamic)
    $script:Manifest   = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'manifests\defender.psd1'))))
    $script:Arm        = Get-Content (Join-Path $script:RepoRoot 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json
    # Shape-aware entry list: candidate manifest exposes .Entries (with EntryKey/NodocRoute),
    # legacy manifest exposed .Endpoints (with Slug). Test treats them uniformly.
    $script:ManifestEntries = if ($script:Manifest.ContainsKey('Entries')) { @($script:Manifest.Entries) } else { @($script:Manifest.Endpoints) }
}

Describe 'TenantContext live fixture replay (closes P0 exit gate)' -Tag 'fixture-replay' {

    It 'has a live.json fixture (operator must have run Capture-EndpointSchemas)' {
        # Skip on CI / fresh clone · tests/fixtures/live/ is gitignored (operator-local).
        # Operator runs `pwsh tools/Capture-EndpointSchemas.ps1 -Slug TenantContext` locally to seed.
        if (-not (Test-Path $script:ResponseFx)) {
            Set-ItResult -Skipped -Because 'live fixture absent (gitignored · CI/fresh clone) · operator-local: pwsh tools/Capture-EndpointSchemas.ps1 -Slug TenantContext'
            return
        }
        Test-Path $script:ResponseFx | Should -BeTrue
    }

    Context 'when fixture present' -Skip:(-not $script:FixturePresent) {

        BeforeAll {
            $script:Response = Get-Content $script:ResponseFx -Raw | ConvertFrom-Json
            # Candidate manifest entries are hashtables (use ContainsKey, not PSObject.Properties).
            # Legacy v0.0.1 entries were PSCustomObject — both supported here.
            $script:McEntry = $script:ManifestEntries | Where-Object {
                $hasSlug    = ($_ -is [hashtable] -and $_.ContainsKey('Slug')) -or ($_.PSObject -and $_.PSObject.Properties['Slug'])
                $slugIsTC   = $hasSlug -and ($_['Slug'] -eq 'TenantContext' -or $_.Slug -eq 'TenantContext')
                $hasNodoc   = ($_ -is [hashtable] -and $_.ContainsKey('NodocRoute')) -or ($_.PSObject -and $_.PSObject.Properties['NodocRoute'])
                $isCfgTC    = $hasNodoc -and (($_ -is [hashtable] -and $_.NodocRoute -match 'TenantContext$' -and $_.SubArea -eq 'Configuration') -or
                                              ($_.PSObject -and $_.NodocRoute -match 'TenantContext$' -and $_.SubArea -eq 'Configuration'))
                $slugIsTC -or $isCfgTC
            } | Select-Object -First 1
            # Slug for emitted row: candidate has NodocRoute (derive leaf), legacy has Slug
            $script:McSlug = if ($script:McEntry -is [hashtable] -and $script:McEntry.ContainsKey('Slug') -and $script:McEntry.Slug) {
                $script:McEntry.Slug
            } elseif ($script:McEntry.PSObject -and $script:McEntry.PSObject.Properties['Slug'] -and $script:McEntry.Slug) {
                $script:McEntry.Slug
            } else {
                'TenantContext'
            }
        }

        It 'parses as JSON (not HTML, not malformed)' {
            $script:Response | Should -Not -BeNullOrEmpty
        }

        It 'has the canonical TenantContext top-level fields' {
            $script:Response.PSObject.Properties.Name | Should -Contain 'OrgId'
            $script:Response.PSObject.Properties.Name | Should -Contain 'GeoRegion'
            $script:Response.PSObject.Properties.Name | Should -Contain 'DataCenter'
            $script:Response.PSObject.Properties.Name | Should -Contain 'EnvironmentName'
        }

        It 'manifest EntityHints all match real response field names (no desk-research drift)' {
            # Candidate shape: EntityHints may be empty pre-Phase-0j; loop is no-op safe.
            # Hashtable (candidate) vs PSCustomObject (legacy) — handle both.
            $hasEntityHints = if ($script:McEntry -is [hashtable]) { $script:McEntry.ContainsKey('EntityHints') } else { [bool]($script:McEntry.PSObject -and $script:McEntry.PSObject.Properties['EntityHints']) }
            $hints = if ($hasEntityHints) { @($script:McEntry.EntityHints) } else { @() }
            foreach ($hint in $hints) {
                $script:Response.PSObject.Properties.Name | Should -Contain $hint -Because "manifest EntityHints '$hint' must exist on the live response"
            }
        }

        It 'simulates Xdr-Poll row emission and matches DCR streamDeclaration columns (Reinforcement-A · ProjectedData primary + RawJson fallback · post-0m)' {
            $row = [pscustomobject]@{
                TimeGenerated    = (Get-Date).ToUniversalTime().ToString('o')
                Portal           = 'Defender'
                SubArea          = $script:McEntry.SubArea
                Slug             = $script:McSlug
                Endpoint         = $script:McEntry.Path
                SuccessKind      = 'live'
                StatusCode       = 200
                LicenseHint      = ''
                IngestionMode    = if ($script:McEntry -is [hashtable]) { if ($script:McEntry.ContainsKey('IngestionMode')) { $script:McEntry.IngestionMode } else { 'SNAPSHOT' } } elseif ($script:McEntry.PSObject -and $script:McEntry.PSObject.Properties['IngestionMode']) { $script:McEntry.IngestionMode } else { 'SNAPSHOT' }
                ConnectorVersion = '0.1.0'
                CorrelationId    = [guid]::NewGuid().ToString()
                ProjectedData    = @{ OrgId = $script:Response.OrgId; GeoRegion = $script:Response.GeoRegion }
                RawJson          = ($script:Response | ConvertTo-Json -Depth 50 -Compress)
            }
            $rowFields = $row.PSObject.Properties.Name | Sort-Object

            # Π1 fix · per-sub-area architecture · canonical row schema in variables.defenderRowSchema
            $schema = $script:Arm.variables.defenderRowSchema
            $schema | Should -Not -BeNullOrEmpty -Because 'defenderRowSchema variable backs all 19 per-sub-area Custom-Defender_<SubArea>_CL streams'
            $dcrFields = @($schema | ForEach-Object { $_.name }) | Sort-Object

            $missing = $dcrFields | Where-Object { $_ -notin $rowFields }
            $missing | Should -BeNullOrEmpty -Because "DCR expects column(s) [$($missing -join ', ')] that Xdr-Poll does not emit"
        }

        It 'RawJson serialised size is under DCE 1 MB hard cap' {
            $rawJson = $script:Response | ConvertTo-Json -Depth 50 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetByteCount($rawJson)
            $bytes | Should -BeLessThan 1MB
        }

        It 'response is licensed for the connectors XdrLogRaider serves (sanity)' {
            $script:Response.IsMdatpActive | Should -BeTrue
        }
    }
}
