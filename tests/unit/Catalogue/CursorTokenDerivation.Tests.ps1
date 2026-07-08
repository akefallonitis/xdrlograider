#Requires -Version 7.4
# T3c (audit 2026-06-12 · operator directive "all pagination generic across all cases" · expansion=data-only bar) ·
# RESPONSE-token pagination derivation. Build-Catalogue derived pagination from REQUEST params only, but a
# continuation token lives in the RESPONSE (body) — so every nextLink/skipToken API in the corpus catalogued as
# Mode='none' (0 of 1941 ops carried CursorPath) and would silently single-page. The runtime token path was fully
# built yet INERT: the generator could not emit its contract = the #1 expansion blocker (Graph/Entra/Purview/
# Sentinel all use nextLink). These pin the generator fix: token detection (tier: live fixture > captured RAW >
# OpenAPI 200-schema properties) -> Pagination Mode='cursor' + CursorPath (+CursorQuery for opaque tokens), with the
# pilot's ops UNCHANGED (regen byte-stability).

Describe 'T3c · catalogue · response-token pagination derivation (Mode=cursor)' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:cat  = Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:ops  = $script:cat.Operations
    }

    It 'AttackSimulator.ListSimulations (live capture carries odata.nextLink="?$skiptoken=") derives Mode=cursor + bracket CursorPath' {
        $o = $script:ops | Where-Object { $_.OperationId -eq 'AttackSimulator.ListSimulations' }
        $o | Should -Not -BeNullOrEmpty
        $o.Pagination.Mode       | Should -Be 'cursor' -Because 'the captured RAW body carries the odata.nextLink continuation key — Mode=none would silently single-page'
        $o.Pagination.CursorMode | Should -Be 'nextLink'
        $o.Pagination.CursorPath | Should -Be "`$['odata.nextLink']" -Because 'the literal response key contains a dot — bracket notation keeps it ONE JSONPath segment'
        $o.Pagination.LoopGuard  | Should -BeGreaterThan 0
    }

    It 'every Mode=cursor op carries the COMPLETE runtime contract (CursorPath always · CursorQuery for opaque cursorToken)' {
        $cursorOps = @($script:ops | Where-Object { $_.Pagination -and $_.Pagination.Mode -eq 'cursor' })
        $cursorOps.Count | Should -BeGreaterThan 0
        foreach ($o in $cursorOps) {
            $o.Pagination.CursorPath | Should -Not -BeNullOrEmpty -Because "cursor op $($o.OperationId) needs the token JSONPath"
            $o.Pagination.CursorMode | Should -BeIn @('nextLink','cursorToken') -Because $o.OperationId
            if ($o.Pagination.CursorMode -eq 'cursorToken') {
                $o.Pagination.CursorQuery | Should -Not -BeNullOrEmpty -Because "opaque-token op $($o.OperationId) must re-send the token as a request param"
            }
        }
    }

    It 'PILOT STABILITY · GetHistory keeps its proven pageIndex contract (token detection must not touch it)' {
        $o = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetHistory' }
        $o.Pagination.Mode       | Should -Be 'pageSize'
        $o.Pagination.CursorMode | Should -Be 'pageIndexIncrement'
        ($o.Pagination.PSObject.Properties.Name -contains 'CursorPath') | Should -BeFalse
    }

    It 'PILOT STABILITY · no Operations-category shipped op switches to cursor mode (the 9 pilot ops are pageIndex/none)' {
        $pilot = @($script:ops | Where-Object { $_.Category -eq 'Operations' -and $_.Shipped })
        $pilot.Count | Should -Be 9 -Because 'the v0.1.0 pilot ships exactly 9 Operations ops'
        foreach ($o in $pilot) {
            $o.Pagination.Mode | Should -Not -Be 'cursor' -Because "pilot op $($o.OperationId) must stay regen-byte-stable"
        }
    }
}
