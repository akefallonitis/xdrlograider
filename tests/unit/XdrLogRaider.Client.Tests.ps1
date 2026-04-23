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
    It 'exports exactly the 6 public functions: dispatcher, tier-poller, manifest, + 3 helpers' {
        $exported = (Get-Module XdrLogRaider.Client).ExportedFunctions.Keys | Sort-Object
        $expected = @(
            'ConvertTo-MDEIngestRow',
            'Expand-MDEResponse',
            'Get-MDEEndpointManifest',
            'Invoke-MDEEndpoint',
            'Invoke-MDEPortalEndpoint',
            'Invoke-MDETierPoll'
        )
        [array]$exported | Should -Be $expected
    }

    It 'exports zero legacy Get-MDE_* wrappers' {
        $exported = (Get-Module XdrLogRaider.Client).ExportedFunctions.Keys
        $exported | Where-Object { $_ -like 'Get-MDE_*' } | Should -BeNullOrEmpty
    }
}

Describe 'Endpoint manifest contract' {
    It 'loads exactly 52 endpoints' {
        $m = Get-MDEEndpointManifest
        $m.Count | Should -Be 52
    }

    It 'groups streams into the expected tier buckets (no P4)' {
        $m = Get-MDEEndpointManifest
        $tiers = $m.Values | Group-Object Tier | ForEach-Object { @{ Tier = $_.Name; N = $_.Count } } | Sort-Object { $_.Tier }
        $byTier = @{}
        $tiers | ForEach-Object { $byTier[$_.Tier] = $_.N }
        $byTier['P0'] | Should -Be 19
        $byTier['P1'] | Should -Be 7
        $byTier['P2'] | Should -Be 7
        $byTier['P3'] | Should -Be 8
        $byTier.ContainsKey('P4') | Should -BeFalse
        $byTier['P5'] | Should -Be 5
        $byTier['P6'] | Should -Be 2
        $byTier['P7'] | Should -Be 4
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

    It 'no manifest entry has path placeholders ({...}) — all paths are fully resolved' -ForEach $script:ManifestEntries {
        $_.Path | Should -Not -Match '\{[A-Za-z]+\}'
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

    It 'iterates every snapshot endpoint in the tier' {
        InModuleScope XdrLogRaider.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            Mock Invoke-MDEEndpoint { ,@([pscustomobject]@{ id = 'x' }) }
            Mock Send-ToLogAnalytics { @{ RowsSent = 1 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { $null }
            $result = Invoke-MDETierPoll -Session $Sess -Tier 'P0' -Config $Cfg
            $result.StreamsAttempted | Should -Be 19
            $result.StreamsSucceeded | Should -Be 19
            $result.RowsIngested     | Should -Be 19
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
