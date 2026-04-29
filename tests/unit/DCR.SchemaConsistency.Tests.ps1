#Requires -Modules Pester

# DCR schema ↔ FA ingest-row consistency.
#
# The Data Collection Rule's `streamDeclarations` block is the contract between
# the Function App and Log Analytics. Columns declared there get persisted;
# anything not declared is silently dropped by the DCE at ingest time; any
# declared-but-never-emitted column stays NULL forever and causes empty KQL
# analytics.
#
# These tests close the loop by comparing:
#
#   a) the columns each ConvertTo-MDEIngestRow call actually produces (from the
#      live fixtures under tests/fixtures/live-responses/)
#   b) the columns the DCR declares for the same stream (from the compiled ARM
#      at deploy/compiled/mainTemplate.json)
#
# Per-stream invariant: every active stream's DCR streamDeclaration carries the
# 4 base columns (TimeGenerated/SourceStream/EntityId/RawJson) PLUS typed columns
# derived from the manifest ProjectionMap. The FA-side ConvertTo-MDEIngestRow
# uses the same ProjectionMap, so the row column set matches exactly.
#
# System-stream invariant:
#   MDE_Heartbeat_CL     — must include the 9 fields Write-Heartbeat emits
#   MDE_AuthTestResult_CL — must include the 12 fields Write-AuthTestResult emits

BeforeDiscovery {
    $repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $manifestPath = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $manifest     = Import-PowerShellDataFile -Path $manifestPath

    # StrictMode-safe enumeration: ContainsKey() before dot-access.
    # v0.1.0-beta.1: 'live' availability = streams returning 200 on test tenant.
    # tenant-gated/role-gated entries have correct wire contract but no fixture.
    $script:ActiveStreams = $manifest.Endpoints |
        Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'live' } |
        ForEach-Object { @{ Stream = $_.Stream; Tier = $_.Tier } }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    $script:FixturesDir  = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'
    $script:ArmPath      = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:BaselineCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')

    # Heartbeat columns per Write-Heartbeat.ps1 lines 55-65.
    $script:HeartbeatCols = @(
        'TimeGenerated', 'FunctionName', 'Tier', 'StreamsAttempted', 'StreamsSucceeded',
        'RowsIngested', 'LatencyMs', 'HostName', 'Notes'
    )
    # AuthTestResult columns per Write-AuthTestResult.ps1 lines 31-44.
    $script:AuthTestCols = @(
        'TimeGenerated', 'Method', 'PortalHost', 'Upn', 'Success', 'Stage', 'FailureReason',
        'EstsMs', 'SccauthMs', 'SampleCallHttpCode', 'SampleCallLatencyMs', 'SccauthAcquiredUtc'
    )

    # Pull every streamDeclaration out of the compiled ARM so we don't have to
    # parse Bicep. ARM is the single source of truth for what gets deployed.
    $arm = Get-Content -Raw -Path $script:ArmPath | ConvertFrom-Json
    $dcr = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' } | Select-Object -First 1
    $script:DcrStreamDecls = @{}
    foreach ($prop in $dcr.properties.streamDeclarations.PSObject.Properties) {
        # Strip the 'Custom-' prefix that DCR uses internally.
        $name = $prop.Name -replace '^Custom-', ''
        $script:DcrStreamDecls[$name] = @($prop.Value.columns | ForEach-Object { $_.name })
    }

    # Manifest's ProjectionMap is the source of truth for typed cols. Build a
    # lookup so per-stream tests can compute the expected column set.
    $manifestData = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
    $script:ManifestProjections = @{}
    foreach ($entry in $manifestData.Endpoints) {
        if ($entry.ContainsKey('ProjectionMap')) {
            $script:ManifestProjections[$entry.Stream] = $entry.ProjectionMap
        } else {
            $script:ManifestProjections[$entry.Stream] = @{}
        }
    }
}

Describe 'DCR stream declarations — invariants' {

    It 'DCR declares MDE_Heartbeat_CL with the 9 Write-Heartbeat columns (BUG #1 fix)' {
        $cols = $script:DcrStreamDecls['MDE_Heartbeat_CL']
        $cols | Should -Not -BeNullOrEmpty
        foreach ($c in $script:HeartbeatCols) {
            $cols | Should -Contain $c -Because "Heartbeat column '$c' must be declared in the DCR or Write-Heartbeat emits it to a table that silently drops it"
        }
        # No extras (would be NULL forever).
        $extras = @($cols | Where-Object { $_ -notin $script:HeartbeatCols })
        $extras.Count | Should -Be 0 -Because "DCR Heartbeat schema has extra columns that Write-Heartbeat never populates: $($extras -join ', ')"
    }

    It 'DCR declares MDE_AuthTestResult_CL with the 12 Write-AuthTestResult columns' {
        $cols = $script:DcrStreamDecls['MDE_AuthTestResult_CL']
        $cols | Should -Not -BeNullOrEmpty
        foreach ($c in $script:AuthTestCols) {
            $cols | Should -Contain $c -Because "AuthTestResult column '$c' must be declared in the DCR"
        }
        $extras = @($cols | Where-Object { $_ -notin $script:AuthTestCols })
        $extras.Count | Should -Be 0 -Because "DCR AuthTestResult schema has extra columns: $($extras -join ', ')"
    }

    It 'DCR declares exactly 48 streams (46 data + 2 system)' {
        $script:DcrStreamDecls.Count | Should -Be 48
    }
}

Describe 'Per-data-stream: DCR typed-column schema matches manifest' -ForEach $script:ActiveStreams {
    It 'DCR declares <Stream> with base 4 columns + manifest ProjectionMap typed columns' {
        $cols = $script:DcrStreamDecls[$_.Stream]
        $cols | Should -Not -BeNullOrEmpty -Because "<Stream> must have a DCR streamDeclaration"
        # Base 4 columns are always present.
        foreach ($base in $script:BaselineCols) {
            $cols | Should -Contain $base -Because "DCR for $($_.Stream) must include base column '$base'"
        }
        # Typed columns derived from the manifest ProjectionMap must appear.
        $proj = $script:ManifestProjections[$_.Stream]
        if ($proj -and @($proj.Keys).Count -gt 0) {
            foreach ($typedCol in $proj.Keys) {
                $cols | Should -Contain $typedCol -Because "DCR for $($_.Stream) must include manifest-projected column '$typedCol'"
            }
        }
        # Expected total = base 4 + ProjectionMap keys.
        $projKeyCount = 0
        if ($proj) { $projKeyCount = @($proj.Keys).Count }
        $expectedCount = $script:BaselineCols.Count + $projKeyCount
        $cols.Count | Should -Be $expectedCount -Because "DCR for $($_.Stream) has $($cols.Count) cols; expected base 4 + $projKeyCount ProjectionMap cols = $expectedCount"
    }
}

Describe 'Per-data-stream: ingest row matches DCR schema' -ForEach $script:ActiveStreams {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:FixturesDir  = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'
        $script:BaselineCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')

        # Need the Client module to build an ingest row via the same pipeline
        # as the Function App. Import deps + stub Az (same pattern as
        # FA.ParsingPipeline.Tests.ps1 BeforeAll).
        if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
            function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
            function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
            function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
            function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
            function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
            function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }
        }
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Portal.Auth'     'Xdr.Portal.Auth.psd1')     -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force -ErrorAction Stop

        # Re-parse DCR — Pester 5 runs -ForEach Describes in their own scope.
        $arm = Get-Content -Raw -Path (Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json') | ConvertFrom-Json
        $dcr = $arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' } | Select-Object -First 1
        $script:DcrStreamDecls = @{}
        foreach ($prop in $dcr.properties.streamDeclarations.PSObject.Properties) {
            $name = $prop.Name -replace '^Custom-', ''
            $script:DcrStreamDecls[$name] = @($prop.Value.columns | ForEach-Object { $_.name })
        }
    }

    It 'ConvertTo-MDEIngestRow output for <Stream> matches DCR declared columns' {
        $rawPath = Join-Path $script:FixturesDir "$($_.Stream)-raw.json"
        if (-not (Test-Path $rawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $rawPath -Raw
        $parsed = $raw | ConvertFrom-Json

        # Short-circuit empty responses (null or no-prop object).
        if ($null -eq $parsed) {
            Set-ItResult -Skipped -Because "Empty response for $($_.Stream)"
            return
        }
        if ($parsed -is [pscustomobject] -and @($parsed.PSObject.Properties).Count -eq 0) {
            Set-ItResult -Skipped -Because "Empty object response for $($_.Stream)"
            return
        }

        # Do NOT wrap in @() — Expand-MDEResponse returns via `,$pairs` which PS
        # unwraps on function call; an outer @() re-wraps and breaks indexing.
        $pairs = Expand-MDEResponse -Response $parsed
        $pairs = @($pairs)  # second-step normalisation keeps array semantics
        if ($pairs.Count -eq 0) {
            Set-ItResult -Skipped -Because "Expand-MDEResponse produced 0 pairs for $($_.Stream)"
            return
        }
        $pair = $pairs[0]
        $entity = $pair.Entity
        if ($null -eq $entity -or ($entity -is [array] -and @($entity).Count -eq 0)) {
            $entity = [pscustomobject]@{}
        }

        # Pass the manifest's ProjectionMap so the row gets typed columns
        # alongside the 4 base columns — matches the FA dispatcher path
        # (Invoke-MDEEndpoint resolves ProjectionMap from the manifest entry).
        $streamName = $_.Stream
        $manifestData = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
        $projMap = $null
        foreach ($e in $manifestData.Endpoints) {
            if ($e.Stream -eq $streamName) {
                if ($e.ContainsKey('ProjectionMap')) { $projMap = $e.ProjectionMap }
                break
            }
        }
        $row = ConvertTo-MDEIngestRow -Stream $streamName -EntityId $pair.Id -Raw $entity -ProjectionMap $projMap

        $rowCols = @($row.PSObject.Properties.Name)
        $dcrCols = $script:DcrStreamDecls[$_.Stream]

        # Every row column must be declared in the DCR (else silent drop).
        foreach ($c in $rowCols) {
            $dcrCols | Should -Contain $c -Because "Ingest row column '$c' is not declared in DCR for $($_.Stream) — will be silently dropped"
        }
        # Every DCR column must be present on the row (else NULL forever).
        foreach ($c in $dcrCols) {
            $rowCols | Should -Contain $c -Because "DCR declares column '$c' for $($_.Stream) but ingest row doesn't emit it — will be NULL forever"
        }
    }
}
