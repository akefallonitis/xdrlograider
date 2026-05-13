#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Xdr.Sentinel.Ingest — mocked DCE + Storage Table HTTP paths.

Describe 'Get-XdrTierCadenceMap — production cadence floor (Rule 18 / Phase A0.1)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'returns the 5 canonical cadence tiers' {
        $map = Get-XdrTierCadenceMap
        $map.Keys | Sort-Object | Should -Be (@('ActionCenter','Configuration','Inventory','Maintenance','XspmGraph'))
    }

    It 'no cadence is shorter than 10 minutes (prevents AMEND-2 audit-window regression)' {
        $map = Get-XdrTierCadenceMap
        foreach ($k in $map.Keys) {
            $map[$k].TotalSeconds | Should -BeGreaterOrEqual 600 -Because "$k cadence must be >= 10 minutes in production (AMEND-2 5-min compression must not regress)"
        }
    }

    It 'ActionCenter=10m, XspmGraph=1h, Configuration=6h, Inventory=1d, Maintenance=7d (production values locked)' {
        $map = Get-XdrTierCadenceMap
        $map['ActionCenter'].TotalMinutes | Should -Be 10
        $map['XspmGraph'].TotalHours    | Should -Be 1
        $map['Configuration'].TotalHours | Should -Be 6
        $map['Inventory'].TotalDays      | Should -Be 1
        $map['Maintenance'].TotalDays    | Should -Be 7
    }
}

Describe 'Send-ToLogAnalytics — DCE ingest' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'short-circuits on empty Rows and returns RowsSent=0' {
        Mock Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest { throw 'should not be called' }
        $r = Send-ToLogAnalytics `
            -DceEndpoint 'https://dce.eastus2-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-abc' `
            -StreamName 'Custom-Defender_ActionCenter_CL' `
            -Rows @()
        $r.RowsSent | Should -Be 0
        $r.BatchesSent | Should -Be 0
        Should -Invoke Invoke-WebRequest -ModuleName Xdr.Sentinel.Ingest -Times 0
    }

    It 'rejects malformed DcrImmutableId (must start with dcr-)' {
        $rows = @([pscustomobject]@{ TimeGenerated = [DateTime]::UtcNow.ToString('o'); EntityId = 'a' })
        { Send-ToLogAnalytics `
            -DceEndpoint 'https://dce.eastus2-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'malformed-id' `
            -StreamName 'Custom-Defender_ActionCenter_CL' `
            -Rows $rows } | Should -Throw '*invalid DcrImmutableId*'
    }
}

Describe 'Write-Heartbeat — populated Notes (Rule 12)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'accepts Notes pscustomobject and forwards to Send-ToLogAnalytics' {
        $script:Captured = $null
        Mock Send-ToLogAnalytics -ModuleName Xdr.Sentinel.Ingest {
            param($DceEndpoint, $DcrImmutableId, $StreamName, $Rows)
            $script:Captured = $Rows
            @{ RowsSent = 1; BatchesSent = 1; LatencyMs = 10; GzipBytes = 100; StreamName = $StreamName; DlqEnqueued = 0 }
        }
        Write-Heartbeat `
            -DceEndpoint    'https://dce.eastus2-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-ops-fake' `
            -FunctionName   'ConnectorHeartbeat' `
            -Tier           'Heartbeat' `
            -StreamsAttempted 18 `
            -StreamsSucceeded 17 `
            -RowsIngested 12345 `
            -LatencyMs 234 `
            -Notes ([pscustomobject]@{ cardState = 'Connected'; perStream = @{}; errors = 0; circuitState = 'closed' }) `
            -Portal 'Defender'
        $script:Captured | Should -Not -BeNullOrEmpty
        $row = $script:Captured[0]
        $row.FunctionName | Should -Be 'ConnectorHeartbeat'
        $row.Tier | Should -Be 'Heartbeat'
        $row.Portal | Should -Be 'Defender'
        $row.StreamsAttempted | Should -Be 18
        $row.RowsIngested | Should -Be 12345
        # Notes — pilot line-107 fix invariant
        $row.Notes | Should -Not -BeNullOrEmpty
    }

    It 'rejects invalid Tier value (ValidateSet enforced)' {
        Mock Send-ToLogAnalytics -ModuleName Xdr.Sentinel.Ingest {}
        { Write-Heartbeat `
            -DceEndpoint    'https://dce.eastus2-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-ops-fake' `
            -FunctionName   'ConnectorHeartbeat' `
            -Tier 'NotARealTier' } | Should -Throw '*ValidateSet*'
    }
}

Describe 'Set-XdrTierStateRow — ByProperties (Phase 1 sub-area pattern)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'ByProperties: upserts row with PartitionKey/RowKey + arbitrary Properties' {
        $script:Captured = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
            $script:Captured = @{ pk = $PartitionKey; rk = $RowKey; op = $Operation; entity = $Entity }
        }
        Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -PartitionKey 'Defender' `
            -RowKey 'action_center' `
            -Properties @{
                Tier = 'ActionCenter'
                StreamsAttempted = 5
                CircuitState = 'closed'
                ConsecutiveErrors = 0
            }
        $script:Captured.pk | Should -Be 'Defender'
        $script:Captured.rk | Should -Be 'action_center'
        $script:Captured.op | Should -Be 'Upsert'
        $script:Captured.entity.Tier | Should -Be 'ActionCenter'
        $script:Captured.entity.CircuitState | Should -Be 'closed'
        $script:Captured.entity.TimestampUtc | Should -Match '\d{4}-\d{2}-\d{2}T'
    }

    It 'BySchema (pilot compat): -Reason rejects retired tenant-gated' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {}
        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal 'Defender' `
            -Tier 'ActionCenter' `
            -Stream 'Defender_ActionCenter_CL' `
            -Reason 'tenant-gated' } | Should -Throw '*tenant-gated*'
    }

    It 'BySchema (pilot compat): -Reason accepts rate-limited (Rule 6)' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {}
        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal 'Defender' `
            -Tier 'ActionCenter' `
            -Stream 'Defender_ActionCenter_CL' `
            -Reason 'rate-limited' } | Should -Not -Throw
    }

    It 'BySchema (pilot compat): -Reason accepts all 4 Rule-6 values' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {}
        foreach ($r in @('live','live-empty','rate-limited','error')) {
            { Set-XdrTierStateRow `
                -StorageAccountName 'xdrlrst' `
                -Portal 'Defender' `
                -Tier 'ActionCenter' `
                -Stream 'Defender_ActionCenter_CL' `
                -Reason $r } | Should -Not -Throw -Because "Reason='$r'"
        }
    }
}

Describe 'Set-CheckpointTimestamp pagination resume (Phase A0.3)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'persists LastCompletedPage when caller passes it' {
        $script:Captured = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
            $script:Captured = $Entity
        }
        Set-CheckpointTimestamp `
            -StorageAccountName 'xdrlrst' `
            -StreamName 'Custom-Defender_VulnerabilityManagement_CL' `
            -LastCompletedPage 47 -PaginationToken 'tok-abc'
        $script:Captured.LastCompletedPage | Should -Be 47
        $script:Captured.PaginationToken | Should -Be 'tok-abc'
        $script:Captured.LastPolledUtc | Should -Match '\d{4}-\d{2}-\d{2}T'
    }

    It '-ClearPagination resets LastCompletedPage=0 + PaginationToken empty' {
        $script:Captured = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
            $script:Captured = $Entity
        }
        Set-CheckpointTimestamp `
            -StorageAccountName 'xdrlrst' `
            -StreamName 'Custom-Defender_VulnerabilityManagement_CL' `
            -ClearPagination
        $script:Captured.LastCompletedPage | Should -Be 0
        $script:Captured.PaginationToken | Should -Be ''
    }
}

Describe 'Get-CheckpointState (Phase A0.3) returns full checkpoint state' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'returns hashtable with LastPolledUtc + LastCompletedPage + PaginationToken' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            [pscustomobject]@{
                LastPolledUtc     = '2026-05-13T10:30:00Z'
                LastCompletedPage = 7
                PaginationToken   = 'opaque-tok'
            }
        }
        $s = Get-CheckpointState -StorageAccountName 'xdrlrst' -StreamName 'Custom-X_CL'
        $s | Should -BeOfType [System.Collections.Hashtable]
        $s.LastCompletedPage | Should -Be 7
        $s.PaginationToken | Should -Be 'opaque-tok'
        $s.LastPolledUtc | Should -BeOfType [datetime]
    }

    It 'returns defaults when row absent (no prior checkpoint)' {
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest { $null }
        $s = Get-CheckpointState -StorageAccountName 'xdrlrst' -StreamName 'never-polled'
        $s.LastPolledUtc | Should -Be ([datetime]::MinValue)
        $s.LastCompletedPage | Should -Be 0
        $s.PaginationToken | Should -Be ''
    }
}

Describe 'Write-Heartbeat lean Notes (Decision 15 / H14)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'Notes is NEVER null/empty even when caller did not pass -Notes (Rule 12)' {
        $script:Captured = $null
        Mock Send-ToLogAnalytics -ModuleName Xdr.Sentinel.Ingest {
            param($DceEndpoint, $DcrImmutableId, $StreamName, $Rows)
            $script:Captured = $Rows
            @{ RowsSent = 1; BatchesSent = 1; LatencyMs = 10; GzipBytes = 100; StreamName = $StreamName; DlqEnqueued = 0 }
        }
        Write-Heartbeat `
            -DceEndpoint    'https://dce' `
            -DcrImmutableId 'dcr-ops-fake' `
            -FunctionName   'ConnectorHeartbeat' `
            -Tier           'Heartbeat'
        $row = $script:Captured[0]
        $row.Notes | Should -Not -BeNullOrEmpty
        $row.Notes | Should -Not -Be '{}'
        # Default lean form must contain cardState + dlqDepth + openCircuits + fatalError keys
        $row.Notes | Should -Match 'cardState'
        $row.Notes | Should -Match 'dlqDepth'
    }

    It 'persists ConnectorVersion + ConnectorBuildId typed cols (H13)' {
        $script:Captured = $null
        Mock Send-ToLogAnalytics -ModuleName Xdr.Sentinel.Ingest {
            param($DceEndpoint, $DcrImmutableId, $StreamName, $Rows)
            $script:Captured = $Rows
            @{ RowsSent = 1; BatchesSent = 1; LatencyMs = 10; GzipBytes = 100; StreamName = $StreamName; DlqEnqueued = 0 }
        }
        Write-Heartbeat `
            -DceEndpoint    'https://dce' `
            -DcrImmutableId 'dcr-ops-fake' `
            -FunctionName   'ConnectorHeartbeat' `
            -Tier           'Heartbeat' `
            -ConnectorVersion '0.1.0' `
            -ConnectorBuildId 'v0.1.0-rc.1'
        $row = $script:Captured[0]
        $row.ConnectorVersion | Should -Be '0.1.0'
        $row.ConnectorBuildId | Should -Be 'v0.1.0-rc.1'
    }
}

Describe 'Set-CheckpointTimestamp / Push-XdrIngestDlq — basic Storage Table writes' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force
    }

    It 'Set-CheckpointTimestamp writes PartitionKey=<StreamName> RowKey=latest' {
        $script:Captured = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
            $script:Captured = @{ pk = $PartitionKey; rk = $RowKey; op = $Operation }
        }
        Set-CheckpointTimestamp `
            -StorageAccountName 'xdrlrst' `
            -TableName 'connectorCheckpoints' `
            -StreamName 'Custom-Defender_ActionCenter_CL' `
            -Timestamp ([DateTime]::UtcNow)
        $script:Captured.pk | Should -Be 'Custom-Defender_ActionCenter_CL'
        $script:Captured.rk | Should -Be 'latest'
        $script:Captured.op | Should -Be 'Upsert'
    }

    It 'Push-XdrIngestDlq enqueues failed batch with PartitionKey=<StreamName>' {
        $script:Captured = $null
        Mock Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest {
            param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
            $script:Captured = @{ pk = $PartitionKey; entity = $Entity }
        }
        Push-XdrIngestDlq `
            -StorageAccountName 'xdrlrst' `
            -TableName 'xdrIngestDlq' `
            -StreamName 'Custom-Defender_ActionCenter_CL' `
            -Rows @([pscustomobject]@{ id = 'a' }) `
            -Reason 'HTTP 413 payload too large'
        $script:Captured.pk | Should -Be 'Custom-Defender_ActionCenter_CL'
        $script:Captured.entity.Reason | Should -Match '413'
    }
}
