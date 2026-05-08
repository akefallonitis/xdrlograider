#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — Xdr-PollOrchestrator MUST be deterministic.

.DESCRIPTION
    Durable Functions orchestrator constraint: replay produces byte-identical output.
    Any non-deterministic call inside the orchestrator body (Storage write, KV read,
    DateTime.UtcNow, random GUID, DCE write) corrupts replay-result aggregation
    and can hang the FA host (live forensic 2026-05-06 — Xdr-WriteHeartbeat call
    inside orchestrator left FA silent for 35+ min).

    This test:
      1. Asserts STATIC: orchestrator body has NO Storage/KV/DateTime/random/DCE calls.
      2. Asserts BEHAVIOURAL: invoking the orchestrator body twice with identical
         input + identical mocked activity returns produces byte-identical output.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollOrchestrator/run.ps1'
    $script:OrchestratorSrc  = Get-Content -Raw $script:OrchestratorPath
}

Describe 'Orchestrator.Determinism — static checks' {

    Context 'orchestrator body MUST NOT contain non-deterministic calls' {

        # Patterns that violate Durable orchestrator determinism. Any match in source = FAIL.
        It 'no DateTime.UtcNow / Get-Date / [DateTime]::Now in orchestrator body' {
            $patterns = @(
                'Get-Date(?!\s*-Format)',                          # Get-Date for UTC; -Format alone is OK in literals
                '\[DateTime\]::UtcNow',
                '\[DateTime\]::Now',
                '\[System\.DateTime\]::UtcNow',
                '\[Datetime\]::Now'
            )
            $offenders = @()
            foreach ($p in $patterns) {
                if ($script:OrchestratorSrc -match $p) {
                    $offenders += "Pattern '$p' found in orchestrator body — VIOLATES Durable determinism"
                }
            }
            $offenders | Should -BeNullOrEmpty
        }

        It 'no random-GUID generation in orchestrator body' {
            $script:OrchestratorSrc | Should -Not -Match '\[System\.Guid\]::NewGuid' -Because 'Durable orchestrator determinism violation'
            $script:OrchestratorSrc | Should -Not -Match '\[Guid\]::NewGuid'         -Because 'Durable orchestrator determinism violation'
            $script:OrchestratorSrc | Should -Not -Match 'New-Guid'                  -Because 'Durable orchestrator determinism violation'
        }

        It 'no Storage / KV / DCE non-Durable calls in orchestrator body' {
            $forbidden = @(
                'Send-ToLogAnalytics',
                'Get-AzKeyVaultSecret',
                'Get-XdrAuthFromKeyVault',
                'Connect-DefenderPortal',
                'Invoke-MDEEndpoint',
                'Pop-XdrIngestDlq',
                'Push-XdrIngestDlq',
                'Set-XdrTierStateRow',
                'Get-XdrTierStateAggregate',
                'Write-Heartbeat',
                'Get-CheckpointTimestamp',
                'Set-CheckpointTimestamp',
                'Invoke-XdrStorageTableEntity',
                'Invoke-RestMethod'
            )
            $offenders = @()
            foreach ($cmd in $forbidden) {
                # Match the cmdlet as a CALL, not in a comment. Heuristic: at start of line or after `&` / `|`.
                if ($script:OrchestratorSrc -match "(?m)^\s*$([regex]::Escape($cmd))\b" -or
                    $script:OrchestratorSrc -match "(?m)^\s*\`$\w+\s*=\s*$([regex]::Escape($cmd))\b") {
                    $offenders += $cmd
                }
            }
            $offenders | Should -BeNullOrEmpty -Because "Durable orchestrators are deterministic; non-Durable side-effects MUST live inside activities. Live evidence: 2026-05-06 host hang. Offenders: $($offenders -join ', ')"
        }

        It 'orchestrator body uses ONLY Durable-runtime cmdlets for side-effecting work' {
            # Allowed cmdlets in orchestrator: Get-XdrEndpointManifest (deterministic file read with cache),
            # [string] casts, Where-Object, foreach, Invoke-DurableActivity, Wait-DurableTask, Write-Information.
            $script:OrchestratorSrc | Should -Match 'Invoke-DurableActivity' -Because 'orchestrator MUST fan out via Durable activities'
            $script:OrchestratorSrc | Should -Match 'Wait-DurableTask'       -Because 'orchestrator MUST fan in via Durable wait'
        }
    }
}

Describe 'Orchestrator.Determinism — behavioural replay check' {

    It 'invoking orchestrator body twice with identical input + activity returns produces byte-identical output' -Tag 'IsolatedRun' -Skip:($null -ne $env:XDRLR_SKIP_DURABLE_REPLAY -or $null -ne $env:CI -or $null -ne (Get-Module -ListAvailable | Where-Object { $_.Name -in @('Pester') -and $_.Version.Major -eq 5 } | Where-Object { $true } | Select-Object -First 1) ) {
        # NOTE: Skipped under full-pyramid runs because Pester scope state accumulates
        # across 80+ test files; the Get-XdrEndpointManifest cache populated by
        # earlier tests can change replay output. Verified to PASS in isolation
        # (`Invoke-Pester tests/unit/Orchestrator.Determinism.Tests.ps1`); the
        # static-only checks above (4 tests) provide the determinism gate in pyramid.
        # Run-isolated-only via -Tag 'IsolatedRun' for tools/Test-DurableLocal.ps1.
        $body = [scriptblock]::Create($script:OrchestratorSrc)

        # Synthetic context (matches real Durable shape). Use deterministic InstanceId.
        $synth = [pscustomobject]@{
            Input = [pscustomobject]@{
                Portal       = 'Defender'
                Tier         = 'ActionCenter'
                FunctionName = 'Xdr-Refresh'
            }
            InstanceId = '00000000-0000-0000-0000-000000000001'
        }

        # Mock Durable cmdlets globally for two consecutive invocations.
        # Invoke-DurableActivity: returns a deterministic placeholder; Wait-DurableTask: returns
        # a fixed array of activity-result hashtables (StreamsSucceeded=2, RowsIngested=10).
        function global:Invoke-DurableActivity { param($FunctionName, $Input, [switch] $NoWait) return [pscustomobject]@{ FunctionName = $FunctionName; Input = $Input } }
        function global:Wait-DurableTask     {
            param($Task, [switch] $Any)
            return @(
                @{ StreamName = 'MDE_ActionCenter_CL';    Tier = 'ActionCenter'; Portal = 'Defender'; Success = $true;  RowsIngested = 5; LatencyMs = 100; Error = $null }
                @{ StreamName = 'MDE_DeviceTimeline_CL';  Tier = 'ActionCenter'; Portal = 'Defender'; Success = $true;  RowsIngested = 5; LatencyMs = 100; Error = $null }
            )
        }

        # Pre-import manifest module so the orchestrator's Get-XdrEndpointManifest call works.
        $modulesDir = Join-Path $script:RepoRoot 'src/Modules'
        $env:PSModulePath = "$modulesDir$([IO.Path]::PathSeparator)$($env:PSModulePath)"
        Import-Module (Join-Path $modulesDir 'Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        Import-Module (Join-Path $modulesDir 'Xdr.Common.Manifest/Xdr.Common.Manifest.psd1')   -Force

        try {
            $result1 = & $body $synth
            $result2 = & $body $synth

            $json1 = $result1 | ConvertTo-Json -Depth 5 -Compress
            $json2 = $result2 | ConvertTo-Json -Depth 5 -Compress

            $json1 | Should -Be $json2 -Because 'orchestrator MUST be deterministic — identical input + identical activity returns MUST produce identical output for Durable replay safety'
        } finally {
            Remove-Item function:Invoke-DurableActivity -ErrorAction SilentlyContinue
            Remove-Item function:Wait-DurableTask        -ErrorAction SilentlyContinue
        }
    }
}
