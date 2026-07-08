#Requires -Version 7.4
# F7 · the cadence gate reads a category's checkpoint partition ONCE (Get-XdrCheckpointsForPartition) instead of an
# O(N) per-op point-read at cold start (the timeout class). The batched read is FAIL-OPEN: it feeds the overdue/cadence
# gate, NOT the poll's EO1-strict checkpoint read — a storage error → @{} → every op treated as due (correct: it can
# only OVER-include an op as due, never duplicate, because Invoke-XdrEntryPoll still does its own Get-XdrCheckpoint).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Storage    -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'F7 · Get-XdrCheckpointsForPartition (batched · fail-open · cadence-gate input)' {
    It 'maps every partition row by OperationKey (RowKey) → its checkpoint entity in ONE read' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntities {
            @{ Found = $true; Entities = @(
                @{ RowKey = 'GetHistory'; LastUpdatedUtc = '2026-06-11T05:00:00Z' },
                @{ RowKey = 'GetPending'; LastUpdatedUtc = '2026-06-11T04:00:00Z' }
            ) }
        }
        $map = Get-XdrCheckpointsForPartition -PartitionKey 'Defender_Operations'
        @($map.Keys).Count | Should -Be 2
        $map['GetHistory'].LastUpdatedUtc | Should -Be '2026-06-11T05:00:00Z'
        $map['GetPending'].LastUpdatedUtc | Should -Be '2026-06-11T04:00:00Z'
        Should -Invoke -ModuleName Xdr.Common.Runtime Get-XdrTableEntities -Times 1 -Exactly   # ONE batched read, not N
    }
    It 'a read ERROR is FAIL-OPEN → @{} (the cadence gate then treats every op as due · NEVER throws)' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntities { throw 'storage 500 · transient' }
        $map = Get-XdrCheckpointsForPartition -PartitionKey 'Defender_Operations'   # fail-open · must NOT throw (else the It errors)
        @($map.Keys).Count | Should -Be 0
    }
    It 'an ABSENT table (Found=false) → @{} (cold start · every op due · correct)' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntities { @{ Found = $false; Entities = @() } }
        @((Get-XdrCheckpointsForPartition -PartitionKey 'Defender_Operations').Keys).Count | Should -Be 0
    }
}

Describe 'F7 · Get-XdrTableEntities (partition query · parses value[] · 404 → not-found)' {
    BeforeAll { $script:prevSa = $env:XDRLR_STORAGE_ACCOUNT; $env:XDRLR_STORAGE_ACCOUNT = 'fakeacct' }
    AfterAll  { $env:XDRLR_STORAGE_ACCOUNT = $script:prevSa }
    It 'parses the Tables value[] body into entities (single page · no continuation)' {
        Mock -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest {
            @{ Success = $true; StatusCode = 200; Headers = @{}; Content = '{"value":[{"RowKey":"a","LastUpdatedUtc":"t1"},{"RowKey":"b","LastUpdatedUtc":"t2"}]}' }
        }
        $res = Get-XdrTableEntities -TableName 'XdrCheckpoint' -PartitionKey 'Defender_Operations'
        $res.Found | Should -BeTrue
        @($res.Entities).Count | Should -Be 2
        @($res.Entities)[0]['RowKey'] | Should -Be 'a'
    }
    It 'a 404 (table absent) → Found=false, Entities empty (no throw)' {
        Mock -ModuleName Xdr.Common.Storage Invoke-XdrStorageRest { @{ Success = $false; StatusCode = 404 } }
        $res = Get-XdrTableEntities -TableName 'XdrCheckpoint' -PartitionKey 'P'
        $res.Found | Should -BeFalse
        @($res.Entities).Count | Should -Be 0
    }
}
