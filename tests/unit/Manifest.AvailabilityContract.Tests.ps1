#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.6 manifest schema gate: every endpoint must declare an Availability
    flag with a known value, and the connector must handle every Availability
    class without fatal errors.

.DESCRIPTION
    Live audit (2026-04-27) shows 36/45 endpoints return 200 in a default
    tenant. The 9 non-200s are documented role/tenant gates. This test
    enforces the contract:

      1. Every manifest entry has an Availability field.
      2. Availability is one of: live | tenant-gated | role-gated | deprecated.
      3. For each non-live class, a captured fixture exists in
         tests/fixtures/live-responses/ documenting the actual response shape.
      4. Invoke-MDETierPoll, when faced with a stream returning 4xx/5xx,
         logs a warning + continues to the next stream (per-stream isolation).
         A failure in one stream must NEVER abort the rest of the tier.

    These are behavioral assertions: they execute the production code with
    mocked transport that simulates real failure modes, then assert the
    correct emergent behavior.
#>

BeforeDiscovery {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1'
    $script:Manifest     = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:Entries      = @($script:Manifest.Endpoints)
}

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath     = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1'
    $script:Manifest         = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:Entries          = @($script:Manifest.Endpoints)
    $script:AuthModulePath   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth'   'Xdr.Portal.Auth.psd1'
    $script:IngestModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'
    $script:ClientModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'XdrLogRaider.Client.psd1'
    $script:FixtureDir       = Join-Path $script:RepoRoot 'tests' 'fixtures' 'live-responses'

    function global:Get-AzAccessToken { param([string]$ResourceUrl) [pscustomobject]@{ Token = 'stub'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) } }
    function global:Get-AzTableRow    { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
    function global:Add-AzTableRow    { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }
    function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
    function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }

    Import-Module $script:AuthModulePath   -Force -ErrorAction Stop
    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
    Import-Module $script:ClientModulePath -Force -ErrorAction Stop

    Set-StrictMode -Version Latest
}

Describe 'Manifest Availability schema (declarative contract)' {

    It 'every endpoint declares an Availability field' {
        $missing = @()
        foreach ($e in $script:Entries) {
            if (-not $e.ContainsKey('Availability') -or [string]::IsNullOrWhiteSpace([string]$e.Availability)) {
                $missing += $e.Stream
            }
        }
        $missing | Should -BeNullOrEmpty -Because ('every manifest entry must declare Availability so the connector can decide how to handle the response. Missing: ' + ($missing -join ', '))
    }

    It 'Availability values are restricted to the known enum' {
        $allowed = @('live', 'tenant-gated', 'role-gated', 'deprecated')
        $offenders = @()
        foreach ($e in $script:Entries) {
            if ($e.ContainsKey('Availability')) {
                if ($allowed -notcontains $e.Availability) {
                    $offenders += "$($e.Stream) -> Availability='$($e.Availability)'"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ('Availability must be one of {live, tenant-gated, role-gated, deprecated}. Offenders: ' + ($offenders -join '; '))
    }

    It 'every non-live endpoint has a captured live-response fixture' {
        $missingFixtures = @()
        foreach ($e in $script:Entries) {
            if ($e.Availability -ne 'live') {
                $fix = Join-Path $script:FixtureDir "$($e.Stream)-raw.json"
                if (-not (Test-Path $fix)) {
                    $missingFixtures += "$($e.Stream) (Availability=$($e.Availability))"
                }
            }
        }
        $missingFixtures | Should -BeNullOrEmpty -Because ('every gated endpoint must have a captured fixture documenting the actual failure shape so the parsing pipeline can be tested against it. Missing: ' + ($missingFixtures -join '; '))
    }

    It 'manifest contains the expected baseline of <ExpectedCount> endpoints (drift detector)' -ForEach @(
        @{ Description = 'total endpoints';                ExpectedCount = 45; Filter = { $true } }
        @{ Description = 'live endpoints (~80% target)';   ExpectedCount = 36; Filter = { $args[0].Availability -eq 'live' } }
        @{ Description = 'role-gated endpoints';           ExpectedCount = 2;  Filter = { $args[0].Availability -eq 'role-gated' } }
        @{ Description = 'tenant-gated endpoints';         ExpectedCount = 7;  Filter = { $args[0].Availability -eq 'tenant-gated' } }
    ) {
        param($Description, $ExpectedCount, $Filter)
        $matching = @($script:Entries | Where-Object { & $Filter $_ })
        $matching.Count | Should -Be $ExpectedCount -Because ($Description + ' — drift detector. If a new endpoint is added or an existing one re-categorized, update both manifest AND this baseline.')
    }
}

Describe 'Invoke-MDETierPoll — per-stream failure isolation (behavioral gate)' {

    It 'one stream throwing does NOT abort the rest of the tier' {
        $outcome = InModuleScope XdrLogRaider.Client {
            $manifest = Get-MDEEndpointManifest
            $p0Streams = @($manifest.Values | Where-Object { $_.Tier -eq 'P0' })

            $script:CallNumber = 0
            Mock Invoke-MDEEndpoint -ModuleName XdrLogRaider.Client {
                $script:CallNumber++
                if ($script:CallNumber -eq 1) {
                    throw "simulated 4xx for first stream (role-gated)"
                }
                ,@([pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); EntityId = 'x'; SourceStream = 'MDE_Test_CL'; RawJson = '{}' })
            }
            Mock Send-ToLogAnalytics -ModuleName XdrLogRaider.Client {
                [pscustomobject]@{ RowsSent = 1; BatchesSent = 1; LatencyMs = 10; GzipBytes = 100 }
            }
            Mock Set-CheckpointTimestamp -ModuleName XdrLogRaider.Client {}
            Mock Get-CheckpointTimestamp -ModuleName XdrLogRaider.Client { $null }

            $session = [pscustomobject]@{ PortalHost = 'security.microsoft.com'; TenantId = 't'; Cookies = @{} }
            $config  = [pscustomobject]@{
                StorageAccountName = 'stub'; CheckpointTable = 'stub'
                DceEndpoint = 'https://dce.test/'; DcrImmutableId = 'dcr-stub'
            }

            $threw = $false; $errMsg = $null; $result = $null
            try { $result = Invoke-MDETierPoll -Session $session -Tier 'P0' -Config $config }
            catch { $threw = $true; $errMsg = $_.Exception.Message }

            return [pscustomobject]@{
                Threw = $threw; ErrMsg = $errMsg; Result = $result; ExpectedStreams = $p0Streams.Count
            }
        }
        $outcome.Threw | Should -BeFalse -Because "iter 13.6: per-stream failure must NEVER abort the tier. Got error: $($outcome.ErrMsg)"
        $outcome.Result | Should -Not -BeNullOrEmpty
        $outcome.Result.StreamsAttempted | Should -Be $outcome.ExpectedStreams
        $outcome.Result.StreamsSucceeded | Should -Be ($outcome.ExpectedStreams - 1) -Because 'all but the first stream succeed'
        $outcome.Result.Errors.Count | Should -Be 1 -Because 'exactly one stream errored'
        $outcome.Result.RowsIngested | Should -BeGreaterThan 0 -Because 'rest of tier produced rows'
    }

    It 'all streams in a tier returning 4xx still produces a structured result (no fatal)' {
        $outcome = InModuleScope XdrLogRaider.Client {
            Mock Invoke-MDEEndpoint -ModuleName XdrLogRaider.Client { throw "simulated 403 Forbidden -- role-gated" }
            Mock Get-CheckpointTimestamp -ModuleName XdrLogRaider.Client { $null }
            Mock Set-CheckpointTimestamp -ModuleName XdrLogRaider.Client {}

            $session = [pscustomobject]@{ PortalHost = 'security.microsoft.com'; TenantId = 't'; Cookies = @{} }
            $config  = [pscustomobject]@{
                StorageAccountName = 'stub'; CheckpointTable = 'stub'
                DceEndpoint = 'https://dce.test/'; DcrImmutableId = 'dcr'
            }

            $threw = $false; $errMsg = $null; $result = $null
            try { $result = Invoke-MDETierPoll -Session $session -Tier 'P7' -Config $config }
            catch { $threw = $true; $errMsg = $_.Exception.Message }
            return [pscustomobject]@{ Threw = $threw; ErrMsg = $errMsg; Result = $result }
        }
        $outcome.Threw | Should -BeFalse -Because "tier-poll must surface a structured result even when ALL streams fail. Got: $($outcome.ErrMsg)"
        $outcome.Result | Should -Not -BeNullOrEmpty
        $outcome.Result.StreamsSucceeded | Should -Be 0
        $outcome.Result.RowsIngested | Should -Be 0
        $outcome.Result.Errors.Count | Should -BeGreaterThan 0
    }
}
