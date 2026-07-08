#Requires -Version 7.4
# WS4.4 · the reconcile driver's PURE planning core (no Azure). Pins: (1) repo↔live diff classifies missing
# vs stale correctly and NEVER lists Sysmon_CL or role assignments for deletion; (2) the R-DEPLOY-IDEMPOTENT
# frontier seed plan fires EXACTLY in the checkpoint-loss-with-live-rows state and never overwrites an existing
# checkpoint nor seeds SNAPSHOT/WINDOW ops.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $repo 'tools\Sync-LiveEstate.ps1')   # dot-source · InvocationName '.' skips the live driver
}

Describe 'WS4.4 · Get-XdrEstateDiffPlan (repo intent vs live)' {
    It 'a fully-present category is neither missing nor stale' {
        $p = Get-XdrEstateDiffPlan -RepoCategories @('Operations') `
            -LiveTables @('Defender_Operations_CL') -LiveDcrs @('xdrlr-dcr-operations-zocqir') `
            -LiveAppSettings @('XDRLR_DCR_DEFENDER_OPERATIONS')
        $p.MissingLive | Should -BeNullOrEmpty
        $p.Stale | Should -BeNullOrEmpty
    }
    It 'a repo category with no live table/DCR/appsetting is MISSING with a surgical fix command' {
        $p = Get-XdrEstateDiffPlan -RepoCategories @('ActionCenter') -LiveTables @() -LiveDcrs @() -LiveAppSettings @()
        @($p.MissingLive).Count | Should -Be 1
        $p.MissingLive[0].Category | Should -Be 'ActionCenter'
        $p.MissingLive[0].Fix | Should -Match 'Onboard-CategorySurgical.*-Category ActionCenter -Apply'
    }
    It 'a live Defender_*_CL / xdrlr-dcr-* / XDRLR_DCR_* with no repo counterpart is STALE (operator-delete only)' {
        $p = Get-XdrEstateDiffPlan -RepoCategories @('Operations') `
            -LiveTables @('Defender_Operations_CL','Defender_ActionCenter_CL') `
            -LiveDcrs @('xdrlr-dcr-operations-zocqir','xdrlr-dcr-actioncenter-zocqir') `
            -LiveAppSettings @('XDRLR_DCR_DEFENDER_OPERATIONS','XDRLR_DCR_DEFENDER_ACTIONCENTER')
        @($p.Stale | Where-Object { $_.Name -eq 'Defender_ActionCenter_CL' }).Count | Should -Be 1
        @($p.Stale | Where-Object { $_.Name -eq 'xdrlr-dcr-actioncenter-zocqir' }).Count | Should -Be 1
        @($p.Stale | Where-Object { $_.Name -eq 'XDRLR_DCR_DEFENDER_ACTIONCENTER' }).Count | Should -Be 1
        foreach ($s in $p.Stale) { $s.OperatorDelete | Should -Not -BeNullOrEmpty }
    }
    It 'flags legacy Xdr*_CL orphans (e.g. XdrConnectorHealth_CL) as stale, but never customer tables' {
        $p = Get-XdrEstateDiffPlan -RepoCategories @('Operations') `
            -LiveTables @('Defender_Operations_CL','XdrConnectorHealth_CL','SomeCustomerTable_CL') `
            -LiveDcrs @('xdrlr-dcr-operations-zocqir') -LiveAppSettings @('XDRLR_DCR_DEFENDER_OPERATIONS')
        @($p.Stale | Where-Object { $_.Name -eq 'XdrConnectorHealth_CL' }).Count | Should -Be 1
        @($p.Stale | Where-Object { $_.Name -eq 'SomeCustomerTable_CL' }) | Should -BeNullOrEmpty
    }
    It 'NEVER lists Sysmon_CL (protected) nor any role assignment' {
        $p = Get-XdrEstateDiffPlan -RepoCategories @('Operations') `
            -LiveTables @('Defender_Operations_CL','Sysmon_CL') -LiveDcrs @('xdrlr-dcr-operations-zocqir') `
            -LiveAppSettings @('XDRLR_DCR_DEFENDER_OPERATIONS')
        $p.Protected | Should -Contain 'Sysmon_CL'
        @($p.Stale | Where-Object { $_.Name -eq 'Sysmon_CL' }) | Should -BeNullOrEmpty
        @($p.Stale | Where-Object { $_.Kind -eq 'roleAssignment' }) | Should -BeNullOrEmpty
    }
}

Describe 'WS4.4 · Get-XdrFrontierSeedPlan (R-DEPLOY-IDEMPOTENT)' {
    BeforeAll {
        $script:ops = @(
            [pscustomobject]@{ OperationKey='GetHistory'; IngestionMode='CURSOR'; CursorField='EventTime'; Category='Operations' },
            [pscustomobject]@{ OperationKey='GetPending';  IngestionMode='SNAPSHOT'; CursorField=$null;     Category='Operations' }
        )
    }
    It 'seeds a CURSOR op when checkpoint ABSENT and live rows exist (the redeploy/checkpoint-loss state)' {
        $plan = Get-XdrFrontierSeedPlan -Ops $script:ops -ExistingCheckpointKeys @() `
            -LiveMax @{ GetHistory = @{ MaxCursor = '2026-06-11T05:00:00Z'; BoundaryKeys = 'a1,a2' } }
        @($plan).Count | Should -Be 1
        $plan[0].OperationKey | Should -Be 'GetHistory'
        $plan[0].Cursor | Should -Be '2026-06-11T05:00:00Z'
        $plan[0].BoundaryKeys | Should -Be 'a1,a2'
    }
    It 'NEVER overwrites an existing checkpoint' {
        $plan = Get-XdrFrontierSeedPlan -Ops $script:ops -ExistingCheckpointKeys @('Defender_Operations|GetHistory') `
            -LiveMax @{ GetHistory = @{ MaxCursor = '2026-06-11T05:00:00Z'; BoundaryKeys = 'a1' } }
        @($plan) | Should -BeNullOrEmpty
    }
    It 'NEVER seeds a SNAPSHOT op, and skips a CURSOR op with no live rows (true cold start is correct)' {
        $plan = Get-XdrFrontierSeedPlan -Ops $script:ops -ExistingCheckpointKeys @() -LiveMax @{}
        @($plan) | Should -BeNullOrEmpty
    }
}
