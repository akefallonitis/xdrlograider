#Requires -Version 7.4
# P1 · the postdeploy driver's PURE stage plan (no Azure). B4 pins: (1) the driver chains EXACTLY the four
# existing tools in order version→estate→content→connector and adds NO new assertions (content precedes
# connector so the G1 prove-empty wire's direct-source verdict file exists when the connector's 0-row gate
# reads it); (2) the estate stage
# is report-only (NEVER -Apply) and parity is NOT double-called (Sync-LiveEstate already carries the BLOCKING
# Assert-LiveSchemaParity gate — a separate parity stage is the drift class); (3) operator inputs pass through
# verbatim to their owning stage.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $script:repo 'tools\Run-PostDeployVerify.ps1')   # dot-source · InvocationName '.' skips the live driver
}

Describe 'P1 · Get-XdrPostDeployStagePlan (pure wiring · B4)' {
    BeforeAll {
        $script:plan = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'ws-guid' `
            -WorkspaceResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/w' `
            -Window 'Hour' -OperationKey 'GetHistory' -FunctionApp 'fa'
    }
    It 'chains EXACTLY the four existing tools in order: version → estate → content → connector (content writes the direct-source verdicts the connector 0-row gate consumes)' {
        @($script:plan).Count | Should -Be 4
        ($script:plan.Name -join '>') | Should -Be 'version>estate>content>connector'
        $script:plan.File | Should -Be @('Verify-DeployedVersion.ps1', 'Sync-LiveEstate.ps1', 'Verify-XdrLiveContent.ps1', 'Verify-DeployedConnector.ps1')
    }
    It 'estate stage is report-only (no -Apply) and parity is NOT double-called as a fifth stage' {
        ($script:plan | Where-Object Name -eq 'estate').Args | Should -Not -Contain '-Apply'
        $script:plan.File | Should -Not -Contain 'Assert-LiveSchemaParity.ps1'
    }
    It 'passes -Window and -OperationKey through to the connector stage verbatim' {
        $c = @(($script:plan | Where-Object Name -eq 'connector').Args)
        $c[[array]::IndexOf($c, '-Window') + 1] | Should -Be 'Hour'
        $c[[array]::IndexOf($c, '-OperationKey') + 1] | Should -Be 'GetHistory'
    }
    It '-AllOps reaches BOTH the content AND the connector stages (else the connector silently loops a single empty-op → only Operations[0] gated + empty-op-key short-circuits the G1 LEGIT-NO-DATA probe → 0-row Operations[0] hard-fails MinRows)' {
        $pAll = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -AllOps $true
        @(($pAll | Where-Object Name -eq 'content').Args)   | Should -Contain '-AllOps'
        @(($pAll | Where-Object Name -eq 'connector').Args) | Should -Contain '-AllOps'   # REGRESSION: connector was silently single-op while content was AllOps
        # without -AllOps the connector targets the GIVEN op (-OperationKey), not a bare/empty fallback
        $cArgs = @(($script:plan | Where-Object Name -eq 'content').Args)
        $cArgs[[array]::IndexOf($cArgs, '-OperationKey') + 1] | Should -Be 'GetHistory'
        $connArgs = @(($script:plan | Where-Object Name -eq 'connector').Args)
        $connArgs | Should -Not -Contain '-AllOps'
        $connArgs[[array]::IndexOf($connArgs, '-OperationKey') + 1] | Should -Be 'GetHistory'
    }
    It 'G1 prove-empty wire (with -AllOps + -VerdictDir + -Category): content writes a PER-CAT -VerdictOut, connector reads the SAME -LiveSourceVerdicts, content first' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -AllOps $true -Category @('ExposureManagement') -VerdictDir 'T:\vd'
        $cont = @(($p | Where-Object Name -eq 'content-ExposureManagement').Args)
        $conn = @(($p | Where-Object Name -eq 'connector-ExposureManagement').Args)
        $expected = [System.IO.Path]::Combine('T:\vd', 'verdicts-ExposureManagement.json')
        $cont | Should -Contain '-VerdictOut'
        $cont[[array]::IndexOf($cont, '-VerdictOut') + 1] | Should -Be $expected
        $conn | Should -Contain '-LiveSourceVerdicts'
        $conn[[array]::IndexOf($conn, '-LiveSourceVerdicts') + 1] | Should -Be $expected
        # content MUST precede its connector so the verdict file exists when the connector's 0-row gate reads it
        ([array]::IndexOf($p.Name, 'content-ExposureManagement')) | Should -BeLessThan ([array]::IndexOf($p.Name, 'connector-ExposureManagement'))
    }
    It 'per-category: content+connector run ONCE PER -Category (version+estate global), each connector carries its -Category' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -AllOps $true -Category @('ExposureManagement','Operations')
        ($p.Name -join '>') | Should -Be 'version>estate>content-ExposureManagement>connector-ExposureManagement>content-Operations>connector-Operations'
        @(($p | Where-Object Name -eq 'version')).Count | Should -Be 1   # global, not per-cat
        @(($p | Where-Object Name -eq 'connector-Operations').Args)[[array]::IndexOf(@(($p | Where-Object Name -eq 'connector-Operations').Args), '-Category') + 1] | Should -Be 'Operations'
    }
    It 'NO verdict wire without -VerdictDir (no shared file → connector stays INCONCLUSIVE on unproven 0-rows)' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -AllOps $true
        @(($p | Where-Object Name -eq 'content').Args) | Should -Not -Contain '-VerdictOut'
        @(($p | Where-Object Name -eq 'connector').Args) | Should -Not -Contain '-LiveSourceVerdicts'
    }
    It 'forwards -DeployedSinceUtc to the connector stage (deploy-aware window floor)' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -DeployedSinceUtc '2026-06-11T22:11:37Z'
        $c = @(($p | Where-Object Name -eq 'connector').Args)
        $c | Should -Contain '-DeployedSinceUtc'
        $c[[array]::IndexOf($c, '-DeployedSinceUtc') + 1] | Should -Be '2026-06-11T22:11:37Z'
    }
    It '§4.B · forwards -StorageAccount to the connector stage (durable checkpoint-row ResetUtc source for D3/D7 reset-awareness)' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -StorageAccount 'mystorageacct'
        $c = @(($p | Where-Object Name -eq 'connector').Args)
        $c | Should -Contain '-StorageAccount'
        $c[[array]::IndexOf($c, '-StorageAccount') + 1] | Should -Be 'mystorageacct'
    }
    It '§4.B · NO -StorageAccount on the connector when none supplied (D3/D7 then use the Checkpoint.Reset telemetry fallback)' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y'
        @(($p | Where-Object Name -eq 'connector').Args) | Should -Not -Contain '-StorageAccount'
    }
    It 'forwards -WaitMinutes to the VERSION stage only (App-Insights→LA ingestion-lag tolerance · no false INCONCLUSIVE on a too-soon run)' {
        $p = Get-XdrPostDeployStagePlan -ResourceGroup 'rg' -WorkspaceId 'w' -WorkspaceResourceId '/x/y' -WaitMinutes 15
        $v = @(($p | Where-Object Name -eq 'version').Args)
        $v | Should -Contain '-WaitMinutes'
        $v[[array]::IndexOf($v, '-WaitMinutes') + 1] | Should -Be 15
        # it is a version-stage concern only — the connector/content stages must NOT carry it
        @(($p | Where-Object Name -eq 'connector').Args) | Should -Not -Contain '-WaitMinutes'
    }
    It 'omits -WaitMinutes when 0 (backward-compatible default · single query)' {
        $v = @(($script:plan | Where-Object Name -eq 'version').Args)   # $script:plan built with no -WaitMinutes
        $v | Should -Not -Contain '-WaitMinutes'
    }
    It 'every chained tool file exists in tools/ (wiring never points at a ghost)' {
        foreach ($f in $script:plan.File) {
            Test-Path (Join-Path $script:repo "tools\$f") | Should -BeTrue
        }
    }
    It 'run without required params REFUSES with exit 2 (a verify driver that cannot run must never pass)' {
        & pwsh -NoProfile -NonInteractive -File (Join-Path $script:repo 'tools\Run-PostDeployVerify.ps1') *> $null
        $LASTEXITCODE | Should -Be 2
    }
}

Describe 'P1 · Test-XdrInconclusiveTolerable (pure · OPT-IN tolerance · M1 cure preserved)' {
    It 'empty tolerate set → never tolerable (default callers stay strict · M1 cure)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('Reauth · x · y'); Advisories = @() }) -Tolerate @()) | Should -BeFalse
    }
    It 'null report → false' {
        (Test-XdrInconclusiveTolerable -Report $null -Tolerate @('Reauth')) | Should -BeFalse
    }
    It 'any blocker → false (never tolerate a data-integrity blocker · exit-2 class)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @('Boot · x'); Inconclusives = @('Reauth · x · y'); Advisories = @() }) -Tolerate @('Reauth')) | Should -BeFalse
    }
    It 'only the named inconclusive (Reauth) → tolerable' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('Reauth · self-heal · triggered=0'); Advisories = @() }) -Tolerate @('Reauth')) | Should -BeTrue
    }
    It 'a DATA inconclusive alongside Reauth → NOT tolerable (data must be proven)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('Reauth · x · y', 'SnapshotNoDupAccum[GetAppsSecureScoreMetric] · cross-cycle · z'); Advisories = @() }) -Tolerate @('Reauth')) | Should -BeFalse
    }
    It 'base-name strip: a per-op [opTag] gate matches its base name in the tolerate set' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('SnapshotNoDupAccum[GetX] · cross-cycle · z'); Advisories = @() }) -Tolerate @('SnapshotNoDupAccum')) | Should -BeTrue
    }
    It 'an ADVISORY outside the set alongside tolerated inconclusives → TOLERABLE (advisories are non-blocking · flag-for-review · surfaced for the manual audit · 2026-07-01 · live: AttackSimulation CapabilityRegression)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('D7 · cadence · reset-churn', 'Reauth · x'); Advisories = @('CapabilityRegression[GetRecommendations] · went 403/404') }) -Tolerate @('Reauth','D7')) | Should -BeTrue
    }
    It 'an ADVISORY-ONLY exit-1 (no inconclusives) → TOLERABLE (GREEN-WITH-ADVISORIES continues · an advisory never gates the finalize)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @(); Advisories = @('CapabilityRegression[GetX] · went 403/404') }) -Tolerate @('Reauth')) | Should -BeTrue
    }
    It 'an advisory does NOT rescue an UNtolerated inconclusive (M1 intact · the inconclusive still gates RED)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @(); Inconclusives = @('SnapshotNoDupAccum[GetX] · cross-cycle · z'); Advisories = @('CapabilityRegression[GetX] · w') }) -Tolerate @('Reauth')) | Should -BeFalse
    }
    It 'a blocker is never rescued by the advisory-decoupling (exit-2 data-integrity class stays fatal)' {
        (Test-XdrInconclusiveTolerable -Report ([pscustomobject]@{ Blockers = @('D8f[GetX] · typed col null'); Inconclusives = @(); Advisories = @('CapabilityRegression[GetX] · w') }) -Tolerate @('Reauth','D7')) | Should -BeFalse
    }
}
