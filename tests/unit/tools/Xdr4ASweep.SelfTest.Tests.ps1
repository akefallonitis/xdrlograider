#Requires -Version 7.4
# SelfTest for the §4.A offline cataloguing sweep — the pure per-op A1-A10 flagging (Get-XdrShippedOpFlags) +
# the aggregator (Invoke-XdrShipSetSweep) + the live invariant that the DEPLOYED ship-set sweeps CLEAN (so prepush
# CONFIRMS, never DISCOVERS). RED-provable: hand a defective op fixture → the matching axis flags; hand a clean op
# → 0 flags. Includes the if/else-@()-collapse REGRESSION (a false '' columnType flag · caught live 2026-06-23).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:lib  = Join-Path $script:repo 'tools/lib/Xdr.PostDeployAudit.ps1'
    $script:tool = Join-Path $script:repo 'tools/Invoke-Xdr4ASweep.ps1'
    . $script:lib

    # A minimal CLEAN shipped op (PSCustomObject · the catalogue shape): live-captured, data-grade, projects a col,
    # SNAPSHOT keyless-by-design, no official-overlap, not a fan-out.
    $script:cleanOp = [pscustomobject]@{
        OperationId      = 'Test.CleanOp'
        Operation        = 'CleanOp'
        Category         = 'TestCat'
        IngestionMode    = 'SNAPSHOT'
        EntityResolution = 'NotEntity'
        DependsOn        = $null
        OfficialApiOverlap = 'None'
        EvidenceTier     = 'live-captured'
        EffectiveValueClass = 'CoreTelemetry'
        CursorField      = $null
        NaturalKey       = @()
        TimeFilter       = [pscustomobject]@{ Mode = 'None' }
        ProjectionMap    = [pscustomobject]@{ Id = '$.id'; Name = '$.name' }
    }
}

Describe '§4.A sweep · lib + tool parse' {
    It 'the tool parses with no errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'a CLEAN live-captured data-grade op produces 0 flags' {
        @(Get-XdrShippedOpFlags -Op $script:cleanOp -OverlapVerdict '' -IsDeployed $false).Count | Should -Be 0
    }
}

Describe '§4.A · A1 ZERO-PROJ' {
    It 'flags a data-grade op with an EMPTY ProjectionMap (un-deployed)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.ProjectionMap = [pscustomobject]@{}
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Match 'A1 ZERO-PROJ'
    }
    It 'does NOT flag a Reference/UiHelper op with an empty ProjectionMap (RawJson-only is legit)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.ProjectionMap = [pscustomobject]@{}; $op.EffectiveValueClass = 'Reference'
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Not -Match 'A1 ZERO-PROJ'
    }
    It 'SUPPRESSED for a DEPLOYED op (shipped knowingly · §4.B is its gate)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.ProjectionMap = [pscustomobject]@{}
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $true) | Should -Not -Match 'A1 ZERO-PROJ'
    }
}

Describe '§4.A · A4 NO-KEY (mode-aware · WINDOW contract)' {
    It 'flags a CURSOR op with NO key AND no CursorField' {
        $op = $script:cleanOp.PSObject.Copy(); $op.IngestionMode = 'CURSOR'; $op.NaturalKey = @(); $op.CursorField = $null
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Match 'A4 NO-KEY'
    }
    It 'does NOT flag a CURSOR op WITH a CursorField (keyless-cursor exactly-once via the content-hash boundary)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.IngestionMode = 'CURSOR'; $op.NaturalKey = @(); $op.CursorField = 'createdDate'
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Not -Match 'A4 NO-KEY'
    }
    It 'does NOT flag a keyless WINDOW op WITH a complete From/To window contract (exactly-once via the window boundary · A5)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.IngestionMode = 'WINDOW'; $op.NaturalKey = @()
        $op.TimeFilter = [pscustomobject]@{ Mode = 'ServerFromDate'; FromDateParam = 'fromDate'; ToDateParam = 'toDate' }
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Not -Match 'A4 NO-KEY'
    }
    It 'flags a WINDOW op with NO key AND NO window contract (Mode=None · dup-accumulation)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.IngestionMode = 'WINDOW'; $op.NaturalKey = @()
        $op.TimeFilter = [pscustomobject]@{ Mode = 'None' }
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Match 'A4 NO-KEY'
    }
    It 'A4 still applies to a DEPLOYED op (correctness defect at any tier · NOT suppressed)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.IngestionMode = 'CURSOR'; $op.NaturalKey = @(); $op.CursorField = $null
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $true) | Should -Match 'A4 NO-KEY'
    }
}

Describe '§4.A · A6 FANOUT-NO-PARENT' {
    It 'flags a Resolved fan-out op with an EMPTY DependsOn' {
        $op = $script:cleanOp.PSObject.Copy(); $op.EntityResolution = 'Resolved'; $op.DependsOn = $null
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Match 'A6 FANOUT-NO-PARENT'
    }
    It 'does NOT flag a Resolved fan-out op WITH a DependsOn parent' {
        $op = $script:cleanOp.PSObject.Copy(); $op.EntityResolution = 'Resolved'; $op.DependsOn = 'GetMachinesWdatp'
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Not -Match 'A6 FANOUT-NO-PARENT'
    }
}

Describe '§4.A · A9/P11 OVERLAP hard gate (the SSOT P11 HARD GATE)' {
    It 'flags an OfficialApiOverlap=Likely op with NO overlapVerdict' {
        $op = $script:cleanOp.PSObject.Copy(); $op.OfficialApiOverlap = 'Likely'
        @(Get-XdrShippedOpFlags -Op $op -OverlapVerdict '' -IsDeployed $false) | Should -Match 'A9/P11 OVERLAP-NO-VERDICT'
    }
    It 'does NOT flag an overlap=Likely op WITH a ship verdict' {
        $op = $script:cleanOp.PSObject.Copy(); $op.OfficialApiOverlap = 'Likely'
        @(Get-XdrShippedOpFlags -Op $op -OverlapVerdict 'ship' -IsDeployed $false) | Should -Not -Match 'A9/P11'
    }
    It 'flags an overlap=Likely op whose verdict is HOLD but it is shipped (contradiction)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.OfficialApiOverlap = 'Exact'
        @(Get-XdrShippedOpFlags -Op $op -OverlapVerdict 'hold' -IsDeployed $false) | Should -Match 'A9/P11 OVERLAP-HOLD-SHIPPED'
    }
    It 'A9/P11 still applies to a DEPLOYED op (suppression is A8/A1-only · the hard gate holds)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.OfficialApiOverlap = 'Likely'
        @(Get-XdrShippedOpFlags -Op $op -OverlapVerdict '' -IsDeployed $true) | Should -Match 'A9/P11 OVERLAP-NO-VERDICT'
    }
}

Describe '§4.A · A8 NEEDS-LIVE-PROBE (pre-ship · suppressed when deployed)' {
    It 'flags a postman-example op that is NOT yet deployed' {
        $op = $script:cleanOp.PSObject.Copy(); $op.EvidenceTier = 'postman-example'
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $false) | Should -Match 'A8 NEEDS-LIVE-PROBE'
    }
    It 'SUPPRESSED for a DEPLOYED postman-example op (it passed the onboard live-path probe · ROUND-6)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.EvidenceTier = 'postman-example'
        @(Get-XdrShippedOpFlags -Op $op -IsDeployed $true) | Should -Not -Match 'A8 NEEDS-LIVE-PROBE'
    }
}

Describe '§4.A · A3 columnTypes CASE-SENSITIVE projection subset (cat-6 lesson)' {
    It 'flags a ColumnTypes key that is NOT a CASE-SENSITIVE member of the projection (casing drift)' {
        # projection has 'severity' (lower) but columnTypes declares 'Severity' (Pascal) → dead declaration
        @(Get-XdrShippedOpFlags -Op $script:cleanOp -ManifestProjectionColumns @('severity', 'Id') -ManifestColumnTypeKeys @('Severity')) |
            Should -Match 'A3 COLUMNTYPE-NOT-PROJECTED'
    }
    It 'does NOT flag a ColumnTypes key that IS a case-exact projection member' {
        @(Get-XdrShippedOpFlags -Op $script:cleanOp -ManifestProjectionColumns @('severity', 'Id') -ManifestColumnTypeKeys @('severity')) |
            Should -Not -Match 'A3 COLUMNTYPE-NOT-PROJECTED'
    }
    It 'REGRESSION · an EMPTY ColumnTypeKeys array does NOT produce a phantom '''' flag (the if/else-@()→null collapse trap)' {
        # The aggregator once built $ctKeys via `if(..){@(..)}else{@()}` — the else-@() collapsed to $null →
        # bound at the [string[]] param as @($null) → a phantom '' key → a FALSE A3 flag. Empty MUST be clean.
        @(Get-XdrShippedOpFlags -Op $script:cleanOp -ManifestProjectionColumns @('Id', 'Name') -ManifestColumnTypeKeys @()) |
            Should -Not -Match "COLUMNTYPE-NOT-PROJECTED"
    }
    It 'REGRESSION · a phantom @($null) ColumnTypeKeys is filtered (defensive empty-key filter)' {
        @(Get-XdrShippedOpFlags -Op $script:cleanOp -ManifestProjectionColumns @('Id') -ManifestColumnTypeKeys @($null)) |
            Should -Not -Match "ColumnTypes key ''"
    }
}

Describe '§4.A aggregator · Invoke-XdrShipSetSweep' {
    It 'aggregates flags across ops + counts swept ops' {
        $bad = $script:cleanOp.PSObject.Copy(); $bad.OperationId = 'Test.BadOp'; $bad.OfficialApiOverlap = 'Likely'
        $r = Invoke-XdrShipSetSweep -ShippedOps @($script:cleanOp, $bad) -OverlapVerdicts @{}
        $r.OpsSwept | Should -Be 2
        @($r.Flags) | Should -Match 'Test.BadOp'
        @($r.Flags) | Should -Not -Match 'Test.CleanOp'
    }
    It 'an op in DeployedOpIds gets A8/A1 suppressed (the deployed ship-set is clean)' {
        $op = $script:cleanOp.PSObject.Copy(); $op.OperationId = 'Test.Postman'; $op.EvidenceTier = 'postman-example'; $op.ProjectionMap = [pscustomobject]@{}
        $rUn  = Invoke-XdrShipSetSweep -ShippedOps @($op) -DeployedOpIds @{}
        $rDep = Invoke-XdrShipSetSweep -ShippedOps @($op) -DeployedOpIds @{ 'Test.Postman' = $true }
        @($rUn.Flags).Count  | Should -BeGreaterThan 0
        @($rDep.Flags).Count | Should -Be 0
    }
}

Describe '§4.A · LIVE INVARIANT · the DEPLOYED ship-set sweeps CLEAN (prepush CONFIRMS, never DISCOVERS)' {
    # The real catalogue/curation/manifests must keep the deployed ship-set at 0 flags — if a future cataloguer
    # change adds a debt to a deployed category, THIS test goes RED before prepush (the §4.A self-learning lock).
    It 'tools/Invoke-Xdr4ASweep.ps1 -Scope Deployed exits 0 (0 flags) against the committed catalogue' {
        & pwsh -NoProfile -File $script:tool -Scope Deployed *> $null
        $LASTEXITCODE | Should -Be 0 -Because 'a deployed-surface §4.A flag = a cataloguing miss the live re-prove would discover reactively · resolve via curation before commit'
    }
}
