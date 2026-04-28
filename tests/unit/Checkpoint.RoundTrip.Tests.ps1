#Requires -Modules Pester

# Round-trip tests for Get-CheckpointTimestamp / Set-CheckpointTimestamp.
#
# Iter 13.15: implementation switched from AzTable / Az.Storage cmdlets to the
# unified Invoke-XdrStorageTableEntity helper (System.Net.Http.HttpClient + MI
# token via Get-AzAccessToken). Because the helper is now MODULE-OWNED (it
# lives in XdrLogRaider.Ingest), bare `function global:` overrides do NOT
# intercept it — module-internal function lookups resolve to the module's own
# definition first. We use Pester's `Mock -ModuleName XdrLogRaider.Ingest`
# pattern to inject a fake helper at the module-internal call seam.
#
# Notes on the public function contract (preserved across the refactor):
#   - Get returns [datetime]::MinValue on any read failure or when no row exists.
#   - Set swallows exceptions as warnings (no retry, no throw to caller).
#   - Param names are -StreamName (not -Stream) and -TableName (not -Table).

BeforeAll {
    $script:IngestModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'
    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Checkpoint round-trip' {

    BeforeEach {
        # Pester 5 evaluates the Mock body in the test script scope, so
        # $script:* in the mock body and in BeforeEach/It bodies refer to the
        # SAME script scope (this file).
        $script:FakeTable          = @{}
        $script:FailUpsertCount    = 0
        $script:UpsertCallsSoFar   = 0
        $script:LastSeenTableName  = $null

        Mock -ModuleName XdrLogRaider.Ingest Invoke-XdrStorageTableEntity {
            param(
                [string]$StorageAccountName,
                [string]$TableName,
                [string]$PartitionKey,
                [string]$RowKey,
                [string]$Operation,
                [hashtable]$Entity
            )
            $script:LastSeenTableName = $TableName
            switch ($Operation) {
                'Get' {
                    $key = "$PartitionKey|$RowKey"
                    if ($script:FakeTable.ContainsKey($key)) {
                        return [pscustomobject]$script:FakeTable[$key]
                    }
                    return $null
                }
                'Upsert' {
                    $script:UpsertCallsSoFar++
                    if ($script:FailUpsertCount -gt 0) {
                        $script:FailUpsertCount--
                        throw [System.Net.WebException]::new('Simulated Azure 503 transient')
                    }
                    $row = @{}
                    if ($Entity -is [System.Collections.IDictionary]) {
                        foreach ($k in $Entity.Keys) { $row[$k] = $Entity[$k] }
                    }
                    $row['PartitionKey'] = $PartitionKey
                    $row['RowKey']       = $RowKey
                    $script:FakeTable["$PartitionKey|$RowKey"] = $row
                    return $null
                }
                'Delete' {
                    $script:FakeTable.Remove("$PartitionKey|$RowKey") | Out-Null
                    return $null
                }
            }
        }
    }

    It 'first-run Get (no row) returns MinValue' {
        $result = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $result | Should -Be ([datetime]::MinValue)
    }

    It 'Set then Get returns the timestamp that was written' {
        $when = [datetime]::SpecifyKind((Get-Date '2026-04-23T10:11:12.345'), [DateTimeKind]::Utc)
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $when -WarningAction SilentlyContinue

        $roundTripped = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue

        $roundTripped | Should -Be $when
        $roundTripped.Kind | Should -Be ([DateTimeKind]::Utc)
    }

    It 'preserves millisecond precision across the round-trip' {
        $precise = [datetime]::SpecifyKind((Get-Date '2026-04-23T10:11:12.987'), [DateTimeKind]::Utc)
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $precise -WarningAction SilentlyContinue

        $r = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $r.Millisecond | Should -Be 987
    }

    It 'second Set overwrites the first (latest-wins)' {
        $early = [datetime]::SpecifyKind((Get-Date '2026-01-01T00:00:00'), [DateTimeKind]::Utc)
        $late  = [datetime]::SpecifyKind((Get-Date '2026-04-23T12:00:00'), [DateTimeKind]::Utc)
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $early -WarningAction SilentlyContinue
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $late  -WarningAction SilentlyContinue

        $r = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $r | Should -Be $late
    }

    It 'isolates streams (write to one does not affect another)' {
        $t = [datetime]::SpecifyKind((Get-Date '2026-04-23T09:00:00'), [DateTimeKind]::Utc)
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $t -WarningAction SilentlyContinue

        $other = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_ActionCenter_CL' -WarningAction SilentlyContinue
        $other | Should -Be ([datetime]::MinValue)
    }

    It 'returns MinValue when the helper throws (table missing / permissions / transient)' {
        # Override the mock just for this test to always throw on Get.
        Mock -ModuleName XdrLogRaider.Ingest Invoke-XdrStorageTableEntity {
            throw "simulated table missing"
        }
        $r = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $r | Should -Be ([datetime]::MinValue)
    }

    It 'null StreamName is rejected (mandatory parameter)' {
        # Mandatory + [string] rejects $null but permits '' — mirror that exactly.
        { Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName $null -WarningAction SilentlyContinue } |
            Should -Throw
        { Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName $null -Timestamp (Get-Date) -WarningAction SilentlyContinue } |
            Should -Throw
    }

    It 'null StorageAccountName is rejected (mandatory parameter)' {
        { Get-CheckpointTimestamp -StorageAccountName $null -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue } |
            Should -Throw
    }

    It 'transient Set failure surfaces as a Write-Warning (no throw, no retry)' {
        # Documents current contract: Set-CheckpointTimestamp swallows exceptions
        # as warnings. If retry logic is added later this test should be updated.
        $script:FailUpsertCount = 1
        { Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp (Get-Date) -WarningAction SilentlyContinue } |
            Should -Not -Throw

        # Because Set swallowed the fault, nothing was written, so Get returns MinValue.
        $r = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $r | Should -Be ([datetime]::MinValue)
        $script:UpsertCallsSoFar | Should -Be 1
    }

    It 'default TableName resolves to connectorCheckpoints' {
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_X_CL' -Timestamp (Get-Date) -WarningAction SilentlyContinue
        $script:LastSeenTableName | Should -Be 'connectorCheckpoints'
    }
}
