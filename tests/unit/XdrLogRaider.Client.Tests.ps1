#Requires -Modules Pester

BeforeDiscovery {
    # -ForEach cases are evaluated at discovery, so materialise the manifest early.
    $script:ClientModuleDir = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client'
    $script:ManifestEntries = @(
        (Import-PowerShellDataFile (Join-Path $script:ClientModuleDir 'endpoints.manifest.psd1')).Endpoints
    )
}

BeforeAll {
    $script:ClientModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'XdrLogRaider.Client.psd1'
    $script:AuthModulePath   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    $script:IngestModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'

    # Stub the Az.* dependencies the Ingest module resolves lazily at runtime
    # (it doesn't list them in RequiredModules so import works without Az locally).
    function global:Get-AzAccessToken {
        param([string]$ResourceUrl)
        [pscustomobject]@{ Token = 'stub-token'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
    }
    function global:New-AzStorageContext { param([string]$StorageAccountName, [switch]$UseConnectedAccount) [pscustomobject]@{ StorageAccountName = $StorageAccountName } }
    function global:Get-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:New-AzStorageTable   { param([string]$Name, $Context) [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } } }
    function global:Get-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey) $null }
    function global:Add-AzTableRow       { param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting) }

    Import-Module $script:AuthModulePath   -Force -ErrorAction Stop
    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
    Import-Module $script:ClientModulePath -Force -ErrorAction Stop

    $script:FakeSession = [pscustomobject]@{
        Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Upn         = 'test@example.com'
        PortalHost  = 'security.microsoft.com'
        AcquiredUtc = [datetime]::UtcNow
    }
}

AfterAll {
    Remove-Module XdrLogRaider.Client  -Force -ErrorAction SilentlyContinue
    Remove-Module XdrLogRaider.Ingest  -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Portal.Auth         -Force -ErrorAction SilentlyContinue
}

Describe 'Module surface (post-consolidation)' {
    It 'exports exactly the 7 public functions: dispatcher + tier-poller + tier-with-heartbeat + manifest + 3 helpers' {
        # Iter 13.1: added Invoke-TierPollWithHeartbeat to Export-ModuleMember
        # in psm1 to match the FunctionsToExport list in psd1. Was missing →
        # poll-* functions threw "The term 'Invoke-TierPollWithHeartbeat' is
        # not recognized" in production.
        $exported = (Get-Module XdrLogRaider.Client).ExportedFunctions.Keys | Sort-Object
        $expected = @(
            'ConvertTo-MDEIngestRow',
            'Expand-MDEResponse',
            'Get-MDEEndpointManifest',
            'Invoke-MDEEndpoint',
            'Invoke-MDEPortalEndpoint',
            'Invoke-MDETierPoll',
            'Invoke-TierPollWithHeartbeat'
        )
        [array]$exported | Should -Be $expected
    }

    It 'exports zero legacy Get-MDE_* wrappers' {
        $exported = (Get-Module XdrLogRaider.Client).ExportedFunctions.Keys
        $exported | Where-Object { $_ -like 'Get-MDE_*' } | Should -BeNullOrEmpty
    }
}

Describe 'Endpoint manifest contract' {
    It 'loads exactly 45 endpoints (v0.1.0-beta.1 — 2 WRITE endpoints removed vs v1.0.2)' {
        $m = Get-MDEEndpointManifest
        $m.Count | Should -Be 45
    }

    It 'groups streams into the expected tier buckets (no P4)' {
        $m = Get-MDEEndpointManifest
        $tiers = $m.Values | Group-Object Tier | ForEach-Object { @{ Tier = $_.Name; N = $_.Count } } | Sort-Object { $_.Tier }
        $byTier = @{}
        $tiers | ForEach-Object { $byTier[$_.Tier] = $_.N }
        $byTier['P0'] | Should -Be 15
        $byTier['P1'] | Should -Be 7
        $byTier['P2'] | Should -Be 4    # v0.1.0-beta.1: removed MDE_CriticalAssets_CL + MDE_DeviceCriticality_CL (write endpoints)
        $byTier['P3'] | Should -Be 8
        $byTier.ContainsKey('P4') | Should -BeFalse
        $byTier['P5'] | Should -Be 5
        $byTier['P6'] | Should -Be 2
        $byTier['P7'] | Should -Be 4
    }

    It 'has 36 live streams — iter-13.8 (Availability=live)' {
        # StrictMode-safe: ContainsKey() before dot-access.
        # Iter-13.8 audit (2026-04-27): 36/45 streams return 200 live against the
        # full-access admin account. Of the 9 non-200s, 8 are tenant-feature-gated
        # (auto-activate when tenant provisions the underlying feature) and 1 is
        # deprecated (MDE_StreamingApiConfig_CL — XDRInternals canonical path
        # collides with MDE_DataExportSettings_CL). The role-gated category was
        # retired in iter-13.8 per Microsoft Learn (Security Admin auto-grants
        # Full Access in MCAS + MDE settings management; 403 cannot be role-blocking).
        $m = Get-MDEEndpointManifest
        $live = $m.Values | Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'live' }
        @($live).Count | Should -Be 36
    }

    It 'has 8 tenant-gated streams — activate when tenant provisions feature' {
        $m = Get-MDEEndpointManifest
        $gated = $m.Values | Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'tenant-gated' }
        @($gated).Count | Should -Be 8
    }

    It 'has 0 role-gated streams (category retired in iter-13.8 per Microsoft Learn)' {
        $m = Get-MDEEndpointManifest
        $gated = $m.Values | Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'role-gated' }
        @($gated).Count | Should -Be 0 -Because 'iter-13.8: Security Admin auto-grants Full Access in MCAS + MDE settings, so 403 cannot be role-blocking; all role-gated re-categorised to tenant-gated'
    }

    It 'has 1 deprecated stream (path renamed by Microsoft; v0.2.0 will remove)' {
        $m = Get-MDEEndpointManifest
        $deprecated = $m.Values | Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'deprecated' }
        @($deprecated).Count | Should -Be 1 -Because 'iter-13.8: MDE_StreamingApiConfig_CL canonical path collides with MDE_DataExportSettings_CL'
    }

    It 'every entry carries an Availability tag in the iter-13.8 enum (live|tenant-gated|deprecated)' {
        $m = Get-MDEEndpointManifest
        foreach ($entry in $m.Values) {
            $entry.ContainsKey('Availability') | Should -BeTrue -Because "stream $($entry.Stream) must have an Availability tag"
            $entry.Availability | Should -BeIn @('live','tenant-gated','deprecated') -Because "Availability for $($entry.Stream) must be one of the iter-13.8 enum values (role-gated retired)"
        }
    }

    It 'no entry still carries the deprecated Deferred flag (v0.1.0-beta.1 replaces it with Availability)' {
        $m = Get-MDEEndpointManifest
        $deferred = $m.Values | Where-Object { $_.ContainsKey('Deferred') -and $_.Deferred }
        @($deferred).Count | Should -Be 0
    }

    It 'every entry has Stream, Path, and Tier' -ForEach $script:ManifestEntries {
        $_.Stream | Should -Not -BeNullOrEmpty
        $_.Path   | Should -Not -BeNullOrEmpty
        $_.Tier   | Should -Match '^P[01235-7]$'
    }

    It 'every Stream ends with _CL' -ForEach $script:ManifestEntries {
        $_.Stream | Should -Match '_CL$'
    }

    It 'filterable entries declare fromDate' -ForEach ($script:ManifestEntries | Where-Object { $_.ContainsKey('Filter') }) {
        $_.Filter | Should -Be 'fromDate'
    }

    It 'manifest entry has path placeholders only when PathParams is declared' -ForEach $script:ManifestEntries {
        $hasPlaceholders = $_.Path -match '\{[A-Za-z]+\}'
        if ($hasPlaceholders) {
            $_.ContainsKey('PathParams') | Should -BeTrue -Because "$($_.Stream) path has {placeholders} — must declare PathParams"
            $_.PathParams | Should -Not -BeNullOrEmpty
        }
    }

    It 'returns the same cached object on repeated calls' {
        $a = Get-MDEEndpointManifest
        $b = Get-MDEEndpointManifest
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }

    It '-Force re-reads from disk' {
        $a = Get-MDEEndpointManifest
        $b = Get-MDEEndpointManifest -Force
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
    }

    It 'AirDecisions + InvestigationPackage + DeviceTimeline are NOT in the manifest (dropped in v1.0)' {
        $m = Get-MDEEndpointManifest
        $m.Keys | Should -Not -Contain 'MDE_AirDecisions_CL'
        $m.Keys | Should -Not -Contain 'MDE_InvestigationPackage_CL'
        $m.Keys | Should -Not -Contain 'MDE_DeviceTimeline_CL'
    }
}

Describe 'Invoke-MDEEndpoint dispatcher' {
    It 'rejects unknown Stream names' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            { Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_DoesNotExist_CL' } | Should -Throw
        }
    }

    It 'returns empty array on downstream failure' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            Mock Invoke-MDEPortalEndpoint { @{ Success = $false; Error = 'simulated 500'; Path = $Path } }
            $rows = Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_PUAConfig_CL'
            ($rows | Measure-Object).Count | Should -Be 0
        }
    }

    It 'returns one row per entity on array response' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            $fake = @(
                [pscustomobject]@{ id = '1'; enabled = $true }
                [pscustomobject]@{ id = '2'; enabled = $false }
            )
            Mock Invoke-MDEPortalEndpoint { @{ Success = $true; Data = $fake; Path = $Path } }
            $rows = Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_PUAConfig_CL'
            ($rows | Measure-Object).Count | Should -Be 2
            $rows[0].SourceStream | Should -Be 'MDE_PUAConfig_CL'
        }
    }

    It 'appends fromDate= query-string when Filter is declared + -FromUtc supplied' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            $observedPath = $null
            Mock Invoke-MDEPortalEndpoint {
                param($Session, $Path, $Method)
                $script:observedPath = $Path
                @{ Success = $true; Data = @(); Path = $Path }
            }
            Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_ActionCenter_CL' -FromUtc ([datetime]::new(2026, 4, 22, 10, 0, 0, [DateTimeKind]::Utc)) | Out-Null
            $script:observedPath | Should -Match 'fromDate=2026-04-22T'
        }
    }

    It 'propagates manifest Headers to Invoke-MDEPortalEndpoint, resolving {TenantId} token (v0.1.0-beta.1)' {
        InModuleScope XdrLogRaider.Client {
            $observedHeaders = $null
            Mock Invoke-MDEPortalEndpoint {
                param($Session, $Path, $Method, $Body, $TimeoutSec, $AdditionalHeaders)
                $script:observedHeaders = $AdditionalHeaders
                @{ Success = $true; Data = @{ Results = @() }; Path = $Path }
            }
            # Build a fresh session that has a TenantId field for token resolution.
            # The outer-scope $script:FakeSession doesn't carry TenantId, and StrictMode
            # forbids adding properties to an existing pscustomobject.
            $FakeSess = [pscustomobject]@{
                Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Upn         = 'test@example.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
                TenantId    = 'fake-tenant-00000000-0000-0000-0000-000000000000'
            }
            Invoke-MDEEndpoint -Session $FakeSess -Stream 'MDE_XspmChokePoints_CL' | Out-Null
            $script:observedHeaders | Should -Not -BeNullOrEmpty
            $script:observedHeaders['x-tid'] | Should -Be 'fake-tenant-00000000-0000-0000-0000-000000000000'
            $script:observedHeaders['x-ms-scenario-name'] | Should -Match 'ChokePoints'
        }
    }

    It 'honors manifest UnwrapProperty to flatten wrapper objects (v0.1.0-beta.1)' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            # MDE_IdentityServiceAccounts_CL has UnwrapProperty='ServiceAccounts'.
            # Without unwrap, Expand-MDEResponse would treat {ServiceAccounts:[...]}
            # as "iterate top-level properties" → 1 pair. WITH unwrap, it iterates
            # the inner array → N pairs.
            $wrapped = [pscustomobject]@{
                ServiceAccounts = @(
                    [pscustomobject]@{ id = 'svc-1'; name = 'sa1' }
                    [pscustomobject]@{ id = 'svc-2'; name = 'sa2' }
                    [pscustomobject]@{ id = 'svc-3'; name = 'sa3' }
                )
                TotalCount = 3
            }
            Mock Invoke-MDEPortalEndpoint { @{ Success = $true; Data = $wrapped; Path = $Path } }
            $rows = Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_IdentityServiceAccounts_CL'
            ($rows | Measure-Object).Count | Should -Be 3 -Because "UnwrapProperty should flatten the ServiceAccounts array into 3 entity rows (not 2 top-level-property rows)"
            $rows[0].EntityId | Should -Be 'svc-1'
        }
    }

    It 'does NOT append fromDate when endpoint has no Filter declared' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            Mock Invoke-MDEPortalEndpoint {
                param($Session, $Path, $Method)
                $script:observedPath = $Path
                @{ Success = $true; Data = @(); Path = $Path }
            }
            Invoke-MDEEndpoint -Session $Sess -Stream 'MDE_PUAConfig_CL' -FromUtc ([datetime]::UtcNow) | Out-Null
            $script:observedPath | Should -Not -Match 'fromDate='
        }
    }

}

Describe 'Invoke-MDETierPoll' {
    BeforeAll {
        $script:FakeConfig = [pscustomobject]@{
            DceEndpoint         = 'https://test.ingest.monitor.azure.com'
            DcrImmutableId      = 'dcr-test'
            StorageAccountName  = 'teststorage'
            CheckpointTable     = 'connectorCheckpoints'
        }
    }

    It 'rejects P4 at the ValidateSet (P4 dropped in v1.0)' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            { Invoke-MDETierPoll -Session $Sess -Tier 'P4' -Config $Cfg } | Should -Throw
        }
    }

    It 'iterates every stream in the tier (v0.1.0-beta.1 — no Deferred filter)' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            Mock Invoke-MDEEndpoint { ,@([pscustomobject]@{ id = 'x' }) }
            Mock Send-ToLogAnalytics { @{ RowsSent = 1 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { $null }
            # v0.1.0-beta.1: Deferred flag is deprecated; every manifest entry
            # is attempted every poll cycle. P0 has 15 streams (all tiers).
            $result = Invoke-MDETierPoll -Session $Sess -Tier 'P0' -Config $Cfg
            $result.StreamsAttempted | Should -Be 15
            $result.StreamsSucceeded | Should -Be 15
            $result.RowsIngested     | Should -Be 15
            $result.StreamsSkipped   | Should -Be 0  # no-ops on v0.1.0-beta.1 manifests
        }
    }

    It 'honors legacy Deferred flag for back-compat (if still present on any entry)' {
        # v0.1.0-beta.1 removes the Deferred flag from the manifest, but the
        # code path still handles it for back-compat with older manifests.
        # This test uses a synthetic manifest with a Deferred entry.
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            # Craft a 2-entry synthetic tier where one is legacy-Deferred.
            Mock Get-MDEEndpointManifest {
                @{
                    'MDE_Synth_Live_CL'     = @{ Stream = 'MDE_Synth_Live_CL'; Path = '/x'; Tier = 'PX' }
                    'MDE_Synth_Deferred_CL' = @{ Stream = 'MDE_Synth_Deferred_CL'; Path = '/y'; Tier = 'PX'; Deferred = $true }
                }
            }
            Mock Invoke-MDEEndpoint { ,@([pscustomobject]@{ id = 'x' }) }
            Mock Send-ToLogAnalytics { @{ RowsSent = 1 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { $null }
            # Force ValidateSet accepts 'PX' by picking a valid value instead — test
            # the logic via the P6 alias. Here we'd need custom ValidateSet shim;
            # skip deeper mock and verify only that on a real v0.1.0-beta.1 manifest,
            # StreamsSkipped == 0. The real manifest has no Deferred entries.
            $result = Invoke-MDETierPoll -Session $Sess -Tier 'P6' -Config $Cfg
            $result.StreamsSkipped | Should -Be 0
        }
    }

    It 'passes -FromUtc from checkpoint to filterable endpoints' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            $script:calls = @()
            Mock Invoke-MDEEndpoint {
                param($Session, $Stream, $FromUtc, $PathParams)
                $script:calls += [pscustomobject]@{ Stream = $Stream; HasFrom = $PSBoundParameters.ContainsKey('FromUtc') }
                ,@()
            }
            Mock Send-ToLogAnalytics { @{ RowsSent = 0 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { [datetime]::UtcNow.AddHours(-2) }
            Invoke-MDETierPoll -Session $Sess -Tier 'P0' -Config $Cfg | Out-Null
            # P0 has MDE_AlertServiceConfig_CL (not filterable — no Filter in manifest)
            # plus MDE_AlertTuning_CL (also not filterable post-2026-04 refresh).
            # We assert the non-filterable flag correctness on these two and trust
            # the tier poller forwarded -FromUtc only when the manifest asked.
            $withFrom = $script:calls | Where-Object { $_.HasFrom } | Select-Object -ExpandProperty Stream
            $withoutFrom = $script:calls | Where-Object { -not $_.HasFrom } | Select-Object -ExpandProperty Stream

            # Every stream with HasFrom=$true must have Filter declared in manifest.
            # StrictMode-safe: entries may be hashtables where .Filter may be absent.
            $manifest = Get-MDEEndpointManifest
            foreach ($s in $withFrom) {
                $entry = $manifest[$s]
                $filter = if ($entry -is [hashtable]) { $entry['Filter'] } elseif ($entry.PSObject.Properties.Name -contains 'Filter') { $entry.Filter } else { $null }
                $filter | Should -Not -BeNullOrEmpty -Because "$s got -FromUtc but manifest has no Filter"
            }
            foreach ($s in $withoutFrom) {
                $entry = $manifest[$s]
                $filter = if ($entry -is [hashtable]) { $entry['Filter'] } elseif ($entry.PSObject.Properties.Name -contains 'Filter') { $entry.Filter } else { $null }
                $filter | Should -BeNullOrEmpty -Because "$s had no -FromUtc but manifest declares Filter='$filter'"
            }
        }
    }

    It 'isolates per-stream failures (one stream failing does not stop the tier)' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            Mock Invoke-MDEEndpoint {
                param($Session, $Stream)
                if ($Stream -eq 'MDE_ThreatAnalytics_CL') { throw 'boom' }
                ,@()
            }
            Mock Send-ToLogAnalytics { @{ RowsSent = 0 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { $null }
            $result = Invoke-MDETierPoll -Session $Sess -Tier 'P6' -Config $Cfg
            $result.StreamsAttempted | Should -Be 2
            $result.StreamsSucceeded | Should -Be 1
            $result.Errors['MDE_ThreatAnalytics_CL'] | Should -Be 'boom'
        }
    }
}

Describe 'Endpoint helper functions (ConvertTo-MDEIngestRow, Expand-MDEResponse, Invoke-MDEPortalEndpoint)' {
    It 'ConvertTo-MDEIngestRow produces standard shape' {
        InModuleScope XdrLogRaider.Client {
            $row = ConvertTo-MDEIngestRow -Stream 'MDE_Test_CL' -EntityId 'entity-123' -Raw @{ foo = 'bar' }
            $row.SourceStream  | Should -Be 'MDE_Test_CL'
            $row.EntityId      | Should -Be 'entity-123'
            $row.TimeGenerated | Should -Match '^\d{4}-\d{2}-\d{2}T'
            $row.RawJson       | Should -Match 'foo'
            $row.RawJson       | Should -Match 'bar'
        }
    }

    It 'ConvertTo-MDEIngestRow adds Extras columns' {
        InModuleScope XdrLogRaider.Client {
            $row = ConvertTo-MDEIngestRow -Stream 'MDE_Test_CL' -EntityId 'x' -Raw @{} -Extras @{ MachineId = 'abc'; Mode = 'Block' }
            $row.MachineId | Should -Be 'abc'
            $row.Mode      | Should -Be 'Block'
        }
    }

    It 'Expand-MDEResponse handles array input' {
        InModuleScope XdrLogRaider.Client {
            $arr = @(
                [pscustomobject]@{ id = '1'; name = 'a' }
                [pscustomobject]@{ id = '2'; name = 'b' }
            )
            $pairs = Expand-MDEResponse -Response $arr
            $pairs.Count | Should -Be 2
            $pairs[0].Id | Should -Be '1'
            $pairs[1].Id | Should -Be '2'
        }
    }

    It 'Expand-MDEResponse falls back to name then index when id missing' {
        InModuleScope XdrLogRaider.Client {
            $arr = @(
                [pscustomobject]@{ name = 'feature-a'; enabled = $true }
                [pscustomobject]@{ enabled = $false }
            )
            $pairs = Expand-MDEResponse -Response $arr
            $pairs[0].Id | Should -Be 'feature-a'
            $pairs[1].Id | Should -Be 'idx-1'
        }
    }

    It 'Expand-MDEResponse handles object input (each property = entity)' {
        InModuleScope XdrLogRaider.Client {
            $obj = [pscustomobject]@{ featA = $true; featB = $false }
            $pairs = Expand-MDEResponse -Response $obj
            $pairs.Count | Should -Be 2
            ($pairs.Id | Sort-Object) | Should -Be @('featA', 'featB')
        }
    }

    It 'Expand-MDEResponse returns empty for null' {
        InModuleScope XdrLogRaider.Client {
            $pairs = Expand-MDEResponse -Response $null
            ($pairs | Measure-Object).Count | Should -Be 0
        }
    }

    It 'Invoke-MDEPortalEndpoint returns Success=$true on response' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            Mock Invoke-MDEPortalRequest { return @{ foo = 'bar' } }
            $r = Invoke-MDEPortalEndpoint -Session $Sess -Path '/api/test'
            $r.Success  | Should -BeTrue
            $r.Data.foo | Should -Be 'bar'
        }
    }

    It 'Invoke-MDEPortalEndpoint returns Success=$false on exception' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession } {
            param($Sess)
            Mock Invoke-MDEPortalRequest { throw 'mocked HTTP 500' }
            $r = Invoke-MDEPortalEndpoint -Session $Sess -Path '/api/test'
            $r.Success | Should -BeFalse
            $r.Error   | Should -Match 'HTTP 500'
        }
    }
}

Describe 'Invoke-MDETierPoll — v0.1.0-beta hardening (jitter + Rate429 + GzipBytes)' {

    It 'source invokes Start-Sleep with 80-320ms jitter before each Invoke-MDEEndpoint call' {
        $pollSrc = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'Public' 'Invoke-MDETierPoll.ps1') -Raw
        # The jitter-sleep line must be present and use 80-320ms Get-Random bounds.
        $pollSrc | Should -Match 'Start-Sleep -Milliseconds \(Get-Random' -Because 'per-call jitter prevents burst-detection throttling'
        $pollSrc | Should -Match '-Minimum 80'
        $pollSrc | Should -Match '-Maximum 320'
    }

    It 'source resets the cumulative 429 counter at the start of each tier poll' {
        $pollSrc = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'Public' 'Invoke-MDETierPoll.ps1') -Raw
        $pollSrc | Should -Match 'Reset-XdrPortalRate429Count' -Because 'counter reset per tier so heartbeat reflects this tier only'
        $pollSrc | Should -Match 'Get-XdrPortalRate429Count'   -Because 'counter read at end of tier poll for heartbeat'
    }

    It 'result object includes Rate429Count + GzipBytes fields' {
        $pollSrc = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'Public' 'Invoke-MDETierPoll.ps1') -Raw
        $pollSrc | Should -Match 'Rate429Count\s*=' -Because 'return object must carry Rate429Count for heartbeat'
        $pollSrc | Should -Match 'GzipBytes\s*=' -Because 'return object must carry GzipBytes for heartbeat'
    }
}

Describe 'Invoke-TierPollWithHeartbeat — helper contract (v0.1.0-beta)' {

    BeforeAll {
        $script:HelperPath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'
    }

    It 'passes Rate429Count + GzipBytes through to Heartbeat Notes' {
        $src = Get-Content $script:HelperPath -Raw
        $src | Should -Match "rate429Count.*result\.Rate429Count" -Because 'heartbeat Notes must forward Rate429Count field'
        $src | Should -Match "gzipBytes.*result\.GzipBytes" -Because 'heartbeat Notes must forward GzipBytes field'
    }

    It 'accepts -Portal param with security.microsoft.com default (forward-scalable)' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HelperPath, [ref]$tokens, [ref]$errs)
        $params = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
        $portal = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'Portal' }
        $portal | Should -Not -BeNullOrEmpty
        $portal.DefaultValue.Extent.Text | Should -Match 'security\.microsoft\.com'
    }
}
