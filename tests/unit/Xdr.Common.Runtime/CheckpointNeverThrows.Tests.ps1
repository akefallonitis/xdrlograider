#Requires -Version 7.4
# FH-7 (audit 2026-06-15) · Save-XdrCheckpointAtomic NEVER-throws contract — the behavioral coverage that was MISSING
# (Recovery.Tests R1 only GREPS the function text for '412', it never exercises the path). Two storage-layer throw
# sites escaped un-wrapped: the table PUT (Set-XdrTableEntity throws on a network error / missing XDRLR_STORAGE_ACCOUNT,
# Storage.psm1:140/215) and the 412-retry re-read (Get-XdrCheckpoint throws after 3 failed reads · CheckpointReadFailLoud).
# Un-wrapped, the throw is MISCLASSIFIED by the caller as "save failed" AFTER rows were already pushed to DCE this cycle
# -> the cursor is NOT advanced -> those rows RE-INGEST next cycle = a silent CROSS-CYCLE DUPLICATE (+ spurious breaker
# trip). The contract is $false-on-any-failure, never throw. These tests pin BOTH sites behaviorally.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

Describe 'FH-7 · Save-XdrCheckpointAtomic honors the NEVER-throws contract on a storage-layer throw' {
    It 'returns $false (does NOT throw) when the table PUT throws (network / missing storage account)' {
        Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity { throw [System.Exception]::new('storage 500 - transient network blip') }
        $threw = $false; $result = $null
        try { $result = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Cursor '2026-05-06T01:51:53.7605698Z' -BoundaryKeys 'K1' } catch { $threw = $true }
        $threw  | Should -BeFalse -Because 'a storage PUT throw must be caught, not escape (the never-throws contract)'
        $result | Should -BeFalse -Because 'a caught storage throw returns $false -> caller leaves the cursor unadvanced (safe re-poll · no cross-cycle dup)'
    }
    It 'returns $false (does NOT throw) when the 412-retry re-read throws (CheckpointReadFailLoud)' {
        Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity { @{ Success = $false; StatusCode = 412 } }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrCheckpoint { throw [System.Exception]::new('checkpoint read failed after 3 attempts (transient)') }
        $threw = $false; $result = $null
        try { $result = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Cursor '2026-05-06T01:51:53.7605698Z' -BoundaryKeys 'K1' -ExistingETag 'e1' } catch { $threw = $true }
        $threw  | Should -BeFalse -Because 'the loud 412 re-read throw must be caught, never fault the Durable Activity'
        $result | Should -BeFalse -Because 'a caught 412-reread throw returns $false (safe re-poll · no silent duplicate)'
    }
}
