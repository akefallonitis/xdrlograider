#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — Get-XdrTierStateAggregate MUST be strict-mode
    safe AND MUST exclude the dispatcher's __schedule__ control rows.

.DESCRIPTION
    LIVE FORENSIC 2026-05-06: Connector-Heartbeat aggregator crashed under
    Azure Functions PowerShell StrictMode v3 because:

      1. The dispatcher (Xdr-Refresh) writes __schedule__ rows to XdrTierState
         that lack TimestampUtc / Portal / Tier / Success columns.
      2. The aggregator did `$_.TimestampUtc -gt $sinceCutoff` on those rows,
         throwing "PropertyNotFoundException: TimestampUtc not found on object."
      3. Crash aborted the per-(Portal, Tier) aggregate emit → no
         StreamsSucceeded > 0 row landed in XdrConnectorHealth_CL → connector
         card stayed Disconnected indefinitely.

    Fix (commit pending — this test):
      a. Server-side filter "RowKey ne '__schedule__'" eliminates the strict-mode
         risk at the source.
      b. Defensive null-guards using PSObject.Properties.Name -contains check
         on every property access.

    This test mocks Invoke-XdrStorageTableEntity to return a mixed row set
    (one __schedule__ row WITHOUT TimestampUtc + one per-stream row WITH it)
    and asserts the function:
      - Does NOT throw under StrictMode v3
      - Returns exactly the per-(Portal, Tier) aggregate for the live row only
      - Includes correct StreamsSucceeded / RowsIngested totals
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    # Import dep FIRST then the module-under-test (so RequiredModules resolves).
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force -ErrorAction Stop
}

Describe 'TierStateAggregate.StrictModeSafety — defensive null-guards + __schedule__ exclusion' {

    BeforeEach {
        # Section R+ NOTE 2026-05-06T22:00: deployed Connector-Heartbeat run.ps1
        # uses `Set-StrictMode -Version Latest` (NOT Version 3). Version Latest
        # is stricter on variable-name interpolation -- caught a real bug where
        # `$base?` inside a string was parsed as one variable token.
        # Use Latest in tests to match deployed runtime exactly.
        Set-StrictMode -Version Latest
    }

    AfterEach {
        Set-StrictMode -Off
    }

    It 'does NOT throw when the table contains a __schedule__ row missing TimestampUtc' {
        # Arrange: mock returns a mixed row set. The __schedule__ row LACKS
        # TimestampUtc + Portal + Tier + Success — exactly the live shape.
        # The Filter parameter would normally exclude it, but the defensive
        # null-guards ensure even an unfiltered row set won't crash.
        Mock -CommandName Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest -MockWith {
            @(
                # __schedule__ row (control row written by Xdr-Refresh dispatcher)
                [pscustomobject]@{
                    PartitionKey = 'Defender|ActionCenter'
                    RowKey       = '__schedule__'
                    NextRunUtc   = (Get-Date).AddMinutes(10).ToString('o')
                }
                # Per-stream success row (real activity result)
                [pscustomobject]@{
                    PartitionKey = 'Defender|ActionCenter'
                    RowKey       = 'MDE_ActionCenter_CL'
                    Portal       = 'Defender'
                    Tier         = 'ActionCenter'
                    Stream       = 'MDE_ActionCenter_CL'
                    TimestampUtc = (Get-Date).ToString('o')
                    Success      = $true
                    RowsIngested = 5
                    ErrorText    = ''
                    OperationId  = 'op-test'
                }
            )
        }

        { Get-XdrTierStateAggregate -StorageAccountName 'fake-sa' -ErrorAction Stop } | Should -Not -Throw
    }

    It 'returns aggregate covering ONLY the per-stream rows (excluding __schedule__)' {
        Mock -CommandName Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest -MockWith {
            # Mock the SERVER-SIDE filter: when -Filter is set, return only matching rows.
            # Real Storage Table OData would apply the filter; the test asserts the
            # aggregator passed the right filter AND handled the result correctly.
            if ($Filter -match "RowKey ne '__schedule__'") {
                @(
                    [pscustomobject]@{
                        PartitionKey = 'Defender|ActionCenter'
                        RowKey       = 'MDE_ActionCenter_CL'
                        Portal       = 'Defender'
                        Tier         = 'ActionCenter'
                        Stream       = 'MDE_ActionCenter_CL'
                        TimestampUtc = (Get-Date).ToString('o')
                        Success      = $true
                        RowsIngested = 7
                        ErrorText    = ''
                        OperationId  = 'op-1'
                    }
                    [pscustomobject]@{
                        PartitionKey = 'Defender|Inventory'
                        RowKey       = 'MDE_DeviceTimeline_CL'
                        Portal       = 'Defender'
                        Tier         = 'Inventory'
                        Stream       = 'MDE_DeviceTimeline_CL'
                        TimestampUtc = (Get-Date).ToString('o')
                        Success      = $true
                        RowsIngested = 13
                        ErrorText    = ''
                        OperationId  = 'op-2'
                    }
                )
            } else {
                # If aggregator failed to pass the filter, return the broken mixed
                # set so the test asserts non-zero diff.
                throw "Aggregator did not pass server-side __schedule__ filter — got Filter='$Filter'"
            }
        }

        $result = Get-XdrTierStateAggregate -StorageAccountName 'fake-sa'
        $result.Count | Should -Be 2 -Because 'Two distinct (Portal, Tier) groups'
        ($result | Where-Object Tier -eq 'ActionCenter').StreamsSucceeded | Should -Be 1
        ($result | Where-Object Tier -eq 'ActionCenter').RowsIngested     | Should -Be 7
        ($result | Where-Object Tier -eq 'Inventory').StreamsSucceeded    | Should -Be 1
        ($result | Where-Object Tier -eq 'Inventory').RowsIngested        | Should -Be 13
    }

    It 'passes -Filter "RowKey ne ''__schedule__''" to Invoke-XdrStorageTableEntity' {
        $script:CapturedFilter = $null
        Mock -CommandName Invoke-XdrStorageTableEntity -ModuleName Xdr.Sentinel.Ingest -MockWith {
            $script:CapturedFilter = $Filter
            @()
        }
        $null = Get-XdrTierStateAggregate -StorageAccountName 'fake-sa'
        $script:CapturedFilter | Should -Be "RowKey ne '__schedule__'" -Because 'Server-side filter eliminates strict-mode crash risk on dispatcher control rows'
    }
}
