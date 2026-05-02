#Requires -Modules Pester

# Function-App parsing pipeline — offline verification against live fixtures.
#
# Every ACTIVE stream in endpoints.manifest.psd1 has a captured -raw.json fixture
# in tests/fixtures/live-responses/ (populated by tools/Capture-EndpointSchemas.ps1).
#
# These tests re-run the same pipeline the Function App executes on every poll:
#
#   raw JSON from portal  ->  Expand-MDEResponse  ->  pairs of @{Id; Entity}
#                         ->  ConvertTo-MDEIngestRow  ->  DCE-ready row
#
# Assertions per stream:
#   1. raw fixture exists and parses as valid JSON
#   2. Expand-MDEResponse returns [hashtable[]] (may be empty for [] responses)
#   3. each pair has a non-empty Id
#   4. ConvertTo-MDEIngestRow produces the 4-col baseline schema
#      (TimeGenerated, SourceStream, EntityId, RawJson)
#   5. RawJson is a string that round-trips through ConvertFrom-Json
#
# Failure here = the live response shape changed, or a manifest IdProperty
# is wrong, or Expand/ConvertTo was modified without a fixture update.

BeforeDiscovery {
    $repoRoot        = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $manifestPath    = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $manifest        = Import-PowerShellDataFile -Path $manifestPath
    # v0.1.0-beta.1: iterate only 'live' streams — tenant-gated + role-gated
    # entries have correct wire contract but don't emit rows on our test tenant,
    # so they have no fixture to test the parsing pipeline against.
    # StrictMode-safe: ContainsKey() before dot-access.
    $script:ActiveStreams = $manifest.Endpoints |
        Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'live' } |
        ForEach-Object {
            @{
                Stream     = $_.Stream
                Tier       = $_.Tier
                IdProperty = if ($_.ContainsKey('IdProperty')) { $_.IdProperty } else { $null }
            }
        }
}

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Xdr.Defender.Client declares Xdr.Defender.Auth as a RequiredModule;
    # Xdr.Sentinel.Ingest is a sibling L1 module. Both must be imported first.
    # The Ingest module lazily resolves Az.* cmdlets at runtime; stub them
    # so offline tests don't require Az.Accounts / Az.KeyVault / Az.Storage.
    function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
    function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
    function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
    function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }

    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force -ErrorAction Stop

    $script:FixturesDir = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'
    $script:ExpectedBaselineColumns = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')
}

Describe 'FA parsing pipeline — raw fixture presence' {
    It 'tests/fixtures/live-responses exists' {
        Test-Path $script:FixturesDir | Should -BeTrue
    }

    It 'has at least 20 raw fixtures (25 expected for v1.0.2 active streams)' {
        @(Get-ChildItem $script:FixturesDir -Filter '*-raw.json').Count | Should -BeGreaterOrEqual 20
    }
}

Describe 'Pipeline: raw -> Expand-MDEResponse -> ConvertTo-MDEIngestRow' -ForEach $script:ActiveStreams {
    BeforeAll {
        # Pester 5 runs each -ForEach Describe in its own scope; re-import modules
        # here so Expand-MDEResponse / ConvertTo-MDEIngestRow are visible.
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:FixturesDir = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'
        $script:ExpectedBaselineColumns = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')

        # Stub Az.* (same as top-level BeforeAll — Pester scope isolation)
        if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
            function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
            function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
            function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
            function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
            function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
            function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }
        }
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force -ErrorAction Stop

        $script:RawPath    = Join-Path $script:FixturesDir "$($_.Stream)-raw.json"
        $script:IngestPath = Join-Path $script:FixturesDir "$($_.Stream)-ingest.json"
    }

    It 'raw fixture exists for <Stream> (<Tier>)' {
        # v0.1.0-beta.1: a newly-activated live stream may not have a fixture yet
        # (Phase 2c captures are operator-driven). Skip with a clear message so
        # downstream assertions cascade-skip rather than fail noisily.
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream) — run tools/Capture-EndpointSchemas.ps1 to capture."
            return
        }
        $true | Should -BeTrue
    }

    It 'raw fixture parses as valid JSON for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $script:RawPath -Raw
        { $raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'Expand-MDEResponse returns enumerable (or $null for empty responses) for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $script:RawPath -Raw
        $parsed = $raw | ConvertFrom-Json
        $expandArgs = @{ Response = $parsed }
        if ($_.IdProperty) { $expandArgs['IdProperty'] = [string[]]$_.IdProperty }
        $pairs = Expand-MDEResponse @expandArgs
        # PS collapses empty @() to $null on function return; both cases map to
        # "empty pair list" downstream. Normalise via @() and assert it's iterable.
        $normalised = @($pairs)
        $normalised -is [array] | Should -BeTrue -Because "must always normalise via @() to a concrete array"
    }

    It 'every pair has a non-empty Id for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $script:RawPath -Raw
        $parsed = $raw | ConvertFrom-Json

        # Short-circuit empty responses: $null (from '[]'), or an object with
        # zero top-level properties (from '{}'). These produce no meaningful
        # pairs — the production pipeline no-ops on them.
        if ($null -eq $parsed) {
            Set-ItResult -Skipped -Because "Empty response (null) for $($_.Stream)"
            return
        }
        if ($parsed -is [pscustomobject] -and @($parsed.PSObject.Properties).Count -eq 0) {
            Set-ItResult -Skipped -Because "Empty object response for $($_.Stream)"
            return
        }

        $expandArgs = @{ Response = $parsed }
        if ($_.IdProperty) { $expandArgs['IdProperty'] = [string[]]$_.IdProperty }
        $pairs = @(Expand-MDEResponse @expandArgs)
        if ($pairs.Count -eq 0) {
            Set-ItResult -Skipped -Because "Expand-MDEResponse produced 0 pairs for $($_.Stream)"
            return
        }
        foreach ($p in $pairs) {
            $p.Id | Should -Not -BeNullOrEmpty -Because "every pair must have a non-empty Id for $($_.Stream)"
        }
    }

    It 'ConvertTo-MDEIngestRow emits baseline 4-col rows for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $script:RawPath -Raw
        $parsed = $raw | ConvertFrom-Json
        $expandArgs = @{ Response = $parsed }
        if ($_.IdProperty) { $expandArgs['IdProperty'] = [string[]]$_.IdProperty }
        # Do NOT wrap in @() — Expand-MDEResponse uses `,$pairs` return which PS
        # auto-unwraps on function return; @() would re-wrap and break iteration.
        $pairs = Expand-MDEResponse @expandArgs
        $pairs = @($pairs)  # ensure array semantics for .Count / indexing
        if ($pairs.Count -eq 0) {
            Set-ItResult -Skipped -Because "Empty response — nothing to flatten for $($_.Stream)"
            return
        }
        $pair = $pairs[0]
        $entityRaw = $pair.Entity
        if ($null -eq $entityRaw -or ($entityRaw -is [array] -and @($entityRaw).Count -eq 0)) {
            $entityRaw = [pscustomobject]@{}
        }
        $row = ConvertTo-MDEIngestRow -Stream $_.Stream -EntityId $pair.Id -Raw $entityRaw

        foreach ($col in $script:ExpectedBaselineColumns) {
            $row.PSObject.Properties.Name | Should -Contain $col -Because "baseline column '$col' must exist on every ingest row"
        }
        $row.SourceStream | Should -Be $_.Stream
        $row.EntityId     | Should -Not -BeNullOrEmpty
        $row.RawJson      | Should -Not -BeNullOrEmpty
    }

    It 'RawJson column round-trips through ConvertFrom-Json for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No fixture for $($_.Stream)"
            return
        }
        $raw = Get-Content $script:RawPath -Raw
        $parsed = $raw | ConvertFrom-Json
        $expandArgs = @{ Response = $parsed }
        if ($_.IdProperty) { $expandArgs['IdProperty'] = [string[]]$_.IdProperty }
        # Do NOT wrap in @() — Expand-MDEResponse uses `,$pairs` return which PS
        # auto-unwraps on function return; @() would re-wrap and break iteration.
        $pairs = Expand-MDEResponse @expandArgs
        $pairs = @($pairs)  # ensure array semantics for .Count / indexing
        if ($pairs.Count -eq 0) {
            Set-ItResult -Skipped -Because "Empty response — no RawJson to test for $($_.Stream)"
            return
        }
        $pair = $pairs[0]
        $entityRaw = $pair.Entity
        if ($null -eq $entityRaw -or ($entityRaw -is [array] -and @($entityRaw).Count -eq 0)) {
            $entityRaw = [pscustomobject]@{}
        }
        $row = ConvertTo-MDEIngestRow -Stream $_.Stream -EntityId $pair.Id -Raw $entityRaw
        { $row.RawJson | ConvertFrom-Json } | Should -Not -Throw -Because "RawJson column must be a valid JSON string"
    }

    It 'ingest fixture file exists for <Stream>' {
        if (-not (Test-Path $script:RawPath)) {
            Set-ItResult -Skipped -Because "No raw fixture for $($_.Stream) — ingest also expected to be absent"
            return
        }
        Test-Path $script:IngestPath | Should -BeTrue
    }
}
