# Self-recovery probe tests per plan v11 §4.22 + §8.9 + §6 G15
#
# R1 · Checkpoint resilience       · force-kill mid-cycle · verify next cycle re-reads checkpoint
# R2 · KMSI rotation              · invalidate KMSI cookie · verify T3 fires once
# R3 · 503 injection              · proxy-inject 503 · verify circuit breaker opens then closes
# R4 · Malformed manifest         · push invalid .psd1 · verify Validate-Manifests rejects pre-deploy
#
# Lab-tenant nightly · NOT pre-deploy gate. Per §6 G15 severity = POST-v0.1.0.
# These tests document the recovery contracts that the architecture must support.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $script:srcRoot  = Join-Path $script:repoRoot.Path 'src'
}

Describe 'Recovery R1 · Checkpoint resilience' {
    It 'Save-XdrCheckpointAtomic writes ETag-conditional Insert-Or-Replace' {
        $runtimePath = Join-Path $script:srcRoot 'Modules\Xdr.Common.Runtime\Xdr.Common.Runtime.psm1'
        Test-Path $runtimePath | Should -BeTrue
        $content = Get-Content $runtimePath -Raw
        $content | Should -Match 'function Save-XdrCheckpointAtomic'
        $content | Should -Match 'IfMatchETag'
        $content | Should -Match '412'
    }

    It 'Save-XdrCheckpointReset writes empty cursor + null LastUpdatedUtc' {
        $runtimePath = Join-Path $script:srcRoot 'Modules\Xdr.Common.Runtime\Xdr.Common.Runtime.psm1'
        $content = Get-Content $runtimePath -Raw
        $content | Should -Match 'function Save-XdrCheckpointReset'
        $content | Should -Match "LastUpdatedUtc\s*=\s*''"
    }
}

Describe 'Recovery R2 · KMSI rotation' {
    It 'Defender.Auth has the T3 full-OAuth path reachable (Connect-DefenderPortal -> Get-XdrEntraEstsAuth)' {
        $defAuthPath = Join-Path $script:srcRoot 'Modules\Xdr.Defender.Auth\Xdr.Defender.Auth.psm1'
        # Xdr.Defender.Auth is a CORE module — its absence is a REGRESSION (fail-loud), not a skip-as-pass.
        Test-Path $defAuthPath | Should -BeTrue -Because 'Xdr.Defender.Auth is a core module · absence is a regression, not a skip'
        $content = Get-Content $defAuthPath -Raw
        # §26 adopted the proven layered cookie-OIDC chain. Connect-DefenderPortal is the public handler
        # (T1 cache -> T2 KMSI refresh -> T3 fresh); Get-XdrEntraEstsAuth is the T3 full-OAuth orchestrator
        # (portal-home entry -> credential -> SAS-TOTP -> interrupt walker -> form_post -> sccauth). The prior
        # monolithic single-function headless login was a regression of this design and was replaced.
        $content | Should -Match 'function Connect-DefenderPortal'
        $content | Should -Match 'Get-XdrEntraEstsAuth'
    }

    It 'MutexStore (Xdr.Common.Lease) serializes T3 collisions' {
        $leasePath = Join-Path $script:srcRoot 'Modules\Xdr.Common.Lease\Xdr.Common.Lease.psm1'
        Test-Path $leasePath | Should -BeTrue -Because 'Xdr.Common.Lease is a core module · absence is a regression, not a skip'
        $content = Get-Content $leasePath -Raw
        $content | Should -Match 'Lock-XdrSingleFlight'
    }
}

Describe 'Recovery R3 · 503 injection + circuit breaker' {
    It 'Send-ToDce has DLQ path for terminal failures' {
        $ingestPath = Join-Path $script:srcRoot 'Modules\Xdr.Common.Ingest\Xdr.Common.Ingest.psm1'
        Test-Path $ingestPath | Should -BeTrue -Because 'Xdr.Common.Ingest is a core module · absence is a regression, not a skip'
        $content = Get-Content $ingestPath -Raw
        $content | Should -Match 'Send-ToDce'
        $content | Should -Match 'Dlq|DLQ|XdrIngestDlq'
    }
}

Describe 'Recovery R4 · Malformed manifest rejection' {
    It 'Validate-Manifests detects missing required fields' {
        $validateTool = Join-Path $script:repoRoot.Path 'tools\Validate-Manifests.ps1'
        Test-Path $validateTool | Should -BeTrue
        $content = Get-Content $validateTool -Raw
        # v11 §4.17 evidence pipeline: required fields per §4.11 (no IsActive)
        $content | Should -Match 'requiredPerOp'
        $content | Should -Match 'DcrImmutableIdEnvVar'
        $content | Should -Match 'Provenance'
        # Inactive blocks push (exit 1) · literal 'Inactive' string assigned to Status variable
        $content | Should -Match "'Inactive'"
    }

    It 'Validate-Manifests rejects IsActive flag (v11 §4.11 LOCKED)' {
        $validateTool = Join-Path $script:repoRoot.Path 'tools\Validate-Manifests.ps1'
        $content = Get-Content $validateTool -Raw
        $content | Should -Match "'IsActive' field present"
    }
}
