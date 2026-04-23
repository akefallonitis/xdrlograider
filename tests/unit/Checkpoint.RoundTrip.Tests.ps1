#Requires -Modules Pester

# Round-trip tests for Get-CheckpointTimestamp / Set-CheckpointTimestamp.
#
# The implementation uses Az.Storage (New-AzStorageContext + Get-AzStorageTable)
# and AzTable (Get-AzTableRow / Add-AzTableRow). We stub all four at module
# scope so a fully offline table is simulated in-memory across the Set -> Get path.
#
# Notes on behaviour observed in the implementation (src/Modules/XdrLogRaider.Ingest/Public):
#   - Both functions CATCH exceptions and emit Write-Warning; Get returns
#     [datetime]::MinValue on failure, Set silently succeeds.
#   - Param names are -StreamName (not -Stream) and -TableName (not -Table).
#   - No retry logic inside Set; transient faults bubble out as warnings.

BeforeAll {
    $script:IngestModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'

    # -------- In-memory table simulator ----------------------------------------
    # Keyed by "$PartitionKey|$RowKey" → hashtable of properties. Lives on script scope
    # so each It can reset between runs.
    $script:FakeTable = @{}

    # Fail-injection knobs flipped per-It.
    $script:FailGetTableOnce = $false      # simulate Get-AzStorageTable returning $null (table absent)
    $script:FailAddRowCount  = 0           # > 0: throw that many times then succeed (retry simulation)
    $script:AddRowCallsSoFar = 0

    # Stubs — scoped to global so InModuleScope can see them. The real Ingest
    # module resolves these dynamically at runtime, so global stubs override.
    function global:New-AzStorageContext {
        param([string]$StorageAccountName, [switch]$UseConnectedAccount)
        [pscustomobject]@{ StorageAccountName = $StorageAccountName }
    }
    function global:Get-AzStorageTable {
        param([string]$Name, $Context, $ErrorAction)
        if ($script:FailGetTableOnce) {
            $script:FailGetTableOnce = $false
            return $null
        }
        [pscustomobject]@{
            Name       = $Name
            CloudTable = [pscustomobject]@{ Name = $Name }
        }
    }
    function global:New-AzStorageTable {
        param([string]$Name, $Context, $ErrorAction)
        [pscustomobject]@{
            Name       = $Name
            CloudTable = [pscustomobject]@{ Name = $Name }
        }
    }
    function global:Get-AzTableRow {
        param($Table, [string]$PartitionKey, [string]$RowKey, $ErrorAction)
        $key = "$PartitionKey|$RowKey"
        if ($script:FakeTable.ContainsKey($key)) {
            return [pscustomobject]$script:FakeTable[$key]
        }
        return $null
    }
    function global:Add-AzTableRow {
        param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting)

        $script:AddRowCallsSoFar++
        if ($script:FailAddRowCount -gt 0) {
            $script:FailAddRowCount--
            throw [System.Net.WebException]::new('Simulated Azure 503 transient')
        }

        $row = @{}
        if ($Property -is [System.Collections.IDictionary]) {
            foreach ($k in $Property.Keys) { $row[$k] = $Property[$k] }
        } else {
            $Property.PSObject.Properties | ForEach-Object { $row[$_.Name] = $_.Value }
        }
        $row['PartitionKey'] = $PartitionKey
        $row['RowKey']       = $RowKey
        $script:FakeTable["$PartitionKey|$RowKey"] = $row
    }

    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Item function:New-AzStorageContext -ErrorAction SilentlyContinue
    Remove-Item function:Get-AzStorageTable   -ErrorAction SilentlyContinue
    Remove-Item function:New-AzStorageTable   -ErrorAction SilentlyContinue
    Remove-Item function:Get-AzTableRow       -ErrorAction SilentlyContinue
    Remove-Item function:Add-AzTableRow       -ErrorAction SilentlyContinue
}

Describe 'Checkpoint round-trip' {

    BeforeEach {
        $script:FakeTable        = @{}
        $script:FailGetTableOnce = $false
        $script:FailAddRowCount  = 0
        $script:AddRowCallsSoFar = 0
    }

    It 'first-run Get (no row) returns MinValue' {
        $result = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $result | Should -Be ([datetime]::MinValue)
    }

    It 'Set then Get returns the timestamp that was written' {
        $when = [datetime]::SpecifyKind((Get-Date '2026-04-23T10:11:12.345'), [DateTimeKind]::Utc)
        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp $when -WarningAction SilentlyContinue

        $roundTripped = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue

        # Round-tripped value should equal the input (UTC preserved).
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

    It 'returns MinValue when the backing table does not exist yet' {
        $script:FailGetTableOnce = $true
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
        $script:FailAddRowCount = 1
        { Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -Timestamp (Get-Date) -WarningAction SilentlyContinue } |
            Should -Not -Throw

        # Because Set swallowed the fault, nothing was written, so Get returns MinValue.
        $r = Get-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_AlertTuning_CL' -WarningAction SilentlyContinue
        $r | Should -Be ([datetime]::MinValue)
        $script:AddRowCallsSoFar | Should -Be 1
    }

    It 'default TableName resolves to connectorCheckpoints' {
        # Capture the table name seen by the stub on a Set call.
        $seen = $null
        Mock -ModuleName XdrLogRaider.Ingest Get-AzStorageTable -MockWith {
            param([string]$Name, $Context, $ErrorAction)
            $script:seenName = $Name
            [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } }
        } -Verifiable

        Set-CheckpointTimestamp -StorageAccountName 'sta' -StreamName 'MDE_X_CL' -Timestamp (Get-Date) -WarningAction SilentlyContinue
        $script:seenName | Should -Be 'connectorCheckpoints'
    }
}
