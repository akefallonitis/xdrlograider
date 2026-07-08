#Requires -Version 7.4
# Φ4.G2a · tools/Save-XdrCheckpointReset.ps1 contract — the operator-side LIVE checkpoint reset (the Φ4.E clean-baseline
# + Φ4.F exactly-once predecessor that previously had NO runnable entrypoint). MUST: parse · be DryRun-default
# (mutate only on -Apply) · write the EXACT runtime reset shape to XdrCheckpoint (Cursor=''+LastUpdatedUtc='' rewind ·
# Insert-Or-Replace) · use AAD (--auth-mode login) NOT the shared-key Az.Storage SDK (live shared-key is OFF) · carry
# ZERO destructive ops. RED pre-creation (tool absent).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Save-XdrCheckpointReset.ps1'
    $script:exists = Test-Path $script:tool
    $script:src = if ($script:exists) { Get-Content $script:tool -Raw } else { '' }
}

Describe 'Φ4.G2a · Save-XdrCheckpointReset live-reset CLI contract' {
    It 'exists and parses with no errors' {
        $script:exists | Should -BeTrue
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'is DRY-RUN by default — the REST insert-or-replace mutation is gated behind -Apply' {
        $script:src | Should -Match '\[switch\]\s*\$Apply'
        $script:src | Should -Match 'if\s*\(\s*-not\s+\$Apply\s*\)|if\s*\(\s*\$Apply\s*\)'
    }
    It 'writes the reset via AAD (--auth-mode login), never a shared key / Az.Storage SDK (live shared-key is OFF)' {
        $script:src | Should -Match '--auth-mode login'
        # Detect actual USAGE (SDK cmdlets · shared-key CLI flags), not prose mentions in the rationale docstring.
        $script:src | Should -Not -Match 'Get-AzStorageAccount|Add-AzTableRow|Get-AzStorageTable|New-AzStorageTable|--account-key|--connection-string'
    }
    It 'targets XdrCheckpoint with the rewind invariant (Cursor + LastUpdatedUtc cleared · Insert-Or-Replace)' {
        $script:src | Should -Match 'XdrCheckpoint'
        $script:src | Should -Match 'Cursor='
        $script:src | Should -Match 'LastUpdatedUtc='
        $script:src | Should -Match '-Method Put'      # Table REST insert-or-replace (PUT on the entity address) -- replaced az `--if-exists replace` so a pipe in a fanout-child RowKey cannot leak to cmd.exe (2026-06-19)
        $script:src | Should -Match 'PartitionKey='   # writes the partition key (literal — avoid `$` regex-anchor trap)
    }
    It 'carries NO destructive operation (no delete/purge/group/--no-wait)' {
        $script:src | Should -Not -Match 'entity delete|table delete|group delete|keyvault (purge|delete)|--no-wait|az group delete'
    }
}
