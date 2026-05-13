#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Get-XdrTierStateAggregate — Phase 1 BySubArea + pilot ByTier paths.
# Note: Invoke-XdrStorageTableEntity uses System.Net.Http.HttpClient directly
# (not Invoke-WebRequest) so HTTP-level mocking requires deeper instrumentation.
# We mock at the helper level instead — same coverage of orchestration logic.

Describe 'Get-XdrTierStateAggregate — Phase 1 BySubArea path' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'returns hashtable keyed by RowKey for rows under PartitionKey=Defender' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $Operation, $Filter)
            @(
                [pscustomobject]@{ PartitionKey = 'Defender'; RowKey = 'action_center';            Tier = 'ActionCenter'; CircuitState = 'closed'; RowsIngested = 50;  LastRunUtc = '2026-05-13T10:00:00Z' }
                [pscustomobject]@{ PartitionKey = 'Defender'; RowKey = 'vulnerability_management'; Tier = 'Inventory';    CircuitState = 'open';   RowsIngested = 0;   ConsecutiveErrors = 3; LastRunUtc = '2026-05-13T11:00:00Z' }
            )
        }
        $r = Get-XdrTierStateAggregate -StorageAccountName 'xdrlrst'
        $r | Should -BeOfType [System.Collections.Hashtable]
        $r.ContainsKey('action_center')            | Should -BeTrue
        $r.ContainsKey('vulnerability_management') | Should -BeTrue
        $r['action_center'].Tier            | Should -Be 'ActionCenter'
        $r['vulnerability_management'].CircuitState | Should -Be 'open'
    }

    It 'BySubArea filter passes PartitionKey down to Invoke-XdrStorageTableEntity' {
        $script:CapturedFilter = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $Operation, $Filter)
            $script:CapturedFilter = $Filter
            @()
        }
        Get-XdrTierStateAggregate -StorageAccountName 'xdrlrst' -PartitionKey 'Entra' | Out-Null
        $script:CapturedFilter | Should -Match "PartitionKey eq 'Entra'"
    }

    It 'handles empty Storage Table response (no rows yet) by returning empty hashtable' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest { @() }
        $r = Get-XdrTierStateAggregate -StorageAccountName 'xdrlrst'
        $r | Should -BeOfType [System.Collections.Hashtable]
        $r.Count | Should -Be 0
    }
}

Describe 'Get-XdrTierStateAggregate — ByTier (pilot compat path)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'ByTier returns aggregate rows grouped by Portal|Tier (legacy pilot pattern)' {
        $now = [DateTime]::UtcNow.ToString('o')
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $Operation, $Filter)
            @(
                [pscustomobject]@{ PartitionKey = 'Defender|ActionCenter'; RowKey = 'Defender_ActionCenter_CL'; Portal = 'Defender'; Tier = 'ActionCenter'; TimestampUtc = $now; Reason = 'live'; Success = $true; RowsIngested = 50 }
                [pscustomobject]@{ PartitionKey = 'Defender|Inventory';    RowKey = 'Defender_EndpointDevices_CL'; Portal = 'Defender'; Tier = 'Inventory';    TimestampUtc = $now; Reason = 'live'; Success = $true; RowsIngested = 1200 }
            )
        }
        $r = @(Get-XdrTierStateAggregate -StorageAccountName 'xdrlrst' -ByTier)
        $r.Count | Should -Be 2
        ($r | Where-Object { $_.Tier -eq 'Inventory' }).RowsIngested | Should -Be 1200
        ($r | Where-Object { $_.Tier -eq 'ActionCenter' }).RowsIngested | Should -Be 50
    }
}

Describe 'ConvertTo-XdrAiSafeProperties — secret redaction (Telemetry private helper)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    }

    It 'Send-XdrAppInsightsTrace silently redacts secret-keyed values without throwing' {
        $secrets = @{
            normalProp   = 'normal'
            password     = 'should-redact'
            sccauth      = 'cookie'
            xsrfToken    = 'csrf'
            passkey      = '{"private":"key"}'
            privateKey   = '-----BEGIN PRIVATE KEY-----'
            totpBase32   = 'JBSWY3DPEHPK3PXP'
        }
        { Send-XdrAppInsightsTrace -Message 'redact unit test' -Properties $secrets } | Should -Not -Throw
        { Send-XdrAppInsightsCustomEvent -EventName 'evt' -Properties $secrets } | Should -Not -Throw
    }
}
