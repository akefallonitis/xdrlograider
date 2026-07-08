#Requires -Version 7.4
# D25 · CADENCE-TIER contract (Stage 5.5 · content-value cadence as curation DATA, decoupled from IngestionMode).
# Pins the derivation OUTPUT on the committed catalogue so the mode-coupled regression (79/81 shipped ops at a flat
# 00:15:00, config endpoints re-polled every 15 minutes) can never silently return: revert the Stage-5.5 pass and
# regen → these go RED.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:cat = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 40
    $script:cur = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\curation.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    $script:shipped = @($script:cat['Operations'] | Where-Object { $_['Shipped'] })
    $script:tiers = $script:cur['cadence']['tierDefaults']
}

Describe 'D25 · cadence tiers (curation DATA · single Stage-5.5 derivation point)' {
    It 'curation carries the five operator-locked tier defaults' {
        $script:tiers['events']      | Should -Be '00:10:00'
        $script:tiers['frequent']    | Should -Be '01:00:00'
        $script:tiers['config']      | Should -Be '06:00:00'
        $script:tiers['inventory']   | Should -Be '1.00:00:00'
        $script:tiers['maintenance'] | Should -Be '7.00:00:00'
    }
    It 'every Shipped op carries a CadenceTier from tierDefaults (provenance · no fabrication)' {
        $script:shipped.Count | Should -BeGreaterThan 0
        foreach ($op in $script:shipped) {
            $op.ContainsKey('CadenceTier') | Should -BeTrue -Because "$($op['OperationId']) must record its tier"
            $script:tiers.ContainsKey([string]$op['CadenceTier']) | Should -BeTrue -Because "$($op['OperationId']) tier '$($op['CadenceTier'])' must be a defined tier"
        }
    }
    It 'every Shipped op cadence equals its tier default (tier is authoritative, not IngestionMode)' {
        foreach ($op in $script:shipped) {
            [string]$op['Cadence'] | Should -Be ([string]$script:tiers[[string]$op['CadenceTier']]) -Because "$($op['OperationId'])"
        }
    }
    It 'NO Shipped op polls at the legacy flat 00:15:00 (the mode-coupled regression)' {
        @($script:shipped | Where-Object { [string]$_['Cadence'] -eq '00:15:00' }) | Should -BeNullOrEmpty
    }
    It 'Action Center ops sit in the events tier (D25: ~10m), not the old 5m/15m mode values' {
        $ac = @($script:shipped | Where-Object { [string]$_['Subcategory'] -eq 'Action Center' })
        $ac.Count | Should -BeGreaterOrEqual 3
        foreach ($op in $ac) { [string]$op['CadenceTier'] | Should -Be 'events'; [string]$op['Cadence'] | Should -Be '00:10:00' }
    }
    It 'config-state endpoints poll at hours, not minutes (the operator directive: GetTenantContext class)' {
        $tc = @($script:shipped | Where-Object { [string]$_['OperationId'] -eq 'MultiTenant.GetTenantContext' }) | Select-Object -First 1
        $tc | Should -Not -BeNullOrEmpty
        [string]$tc['CadenceTier'] | Should -Be 'config'
        [string]$tc['Cadence']     | Should -Be '06:00:00'
    }
    It 'derived fallback is honest: CURSOR ops without curation land in events; ConfigState in config' {
        foreach ($op in $script:shipped) {
            $opId = [string]$op['OperationId']; $sub = [string]$op['Subcategory']
            $curOp  = $script:cur['cadence']['operationTiers'].ContainsKey($opId)
            $curSub = $script:cur['cadence']['subcategoryTiers'].ContainsKey($sub)
            if (-not $curOp -and -not $curSub) {
                $expect = if ([string]$op['IngestionMode'] -eq 'CURSOR') { 'events' }
                          elseif ([string]$op['EffectiveValueClass'] -eq 'ConfigState') { 'config' }
                          else { 'frequent' }
                [string]$op['CadenceTier'] | Should -Be $expect -Because $opId
            }
        }
    }
}
