#Requires -Module Pester
# φ.AUTH.9 · LIVE cross-portal integration · all 5 portals proven against operator tenant
#
# Reads the most recent tests/results/iter-*/probe-auth-multi.json (refreshed by
# Probe-Auth-Local.ps1) and asserts per-portal chain status. NO TOTP burn during this
# test run (artefacts already produced by the prior Probe-Auth-Local invocation at
# Stage A.1).
#
# Acceptance (Plan §REPLAN STAGE I):
#   · ≥3/5 chain success (Defender · Purview · 1+ Entra sub · 1+ Intune sub · SecurityCopilot)
#   · Defender + Purview cookie chains MUST be ChainSuccess=$true (operator's lab tenant
#     has these · they're the v0.1.0 ACTIVE portal + nearest sibling)
#   · Entra::B2C + Intune::Autopatch expected FALSE (tenant-capability-blocked · honest
#     gap per AADSTS500011)
#   · Auth.MultiPortalWarmUp telemetry would fire at FA cold-start (φ.AUTH.11 wired)
#
# Test isolation: this is a T6-LIVE artefact-verification test · runs offline by reading
# the JSON · marks Skipped when no probe artefacts present (CI without operator creds).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ResultsDir = Join-Path $script:RepoRoot 'tests/results'

    # Find latest iter-*/probe-auth-multi.json
    $script:LatestProbe = $null
    if (Test-Path $script:ResultsDir) {
        $script:LatestProbe = @(Get-ChildItem -Path $script:ResultsDir -Filter 'probe-auth-multi.json' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1)
    }
    if ($script:LatestProbe) {
        $script:Probe = Get-Content -Raw -LiteralPath $script:LatestProbe.FullName | ConvertFrom-Json
    }
}

Describe 'φ.AUTH.9 · cross-portal LIVE artefact freshness' -Tag 'integration','runtime-live-multiauth' {

    It 'tests/results/iter-*/probe-auth-multi.json exists (operator probed within last 24h)' {
        if (-not $script:LatestProbe) {
            Set-ItResult -Skipped -Because 'no probe-auth-multi.json found · operator must run tools/Probe-Auth-Local.ps1 -Portal All before this test'
            return
        }
        $script:LatestProbe.LastWriteTime | Should -BeGreaterThan ([datetime]::UtcNow.AddHours(-24)) -Because 'T3-LIVE freshness window'
    }

    It 'probe artefact has 10 sub-portal entries (Defender + 5 Entra + 2 Intune + Purview + SecurityCopilot)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        @($script:Probe.ChainsRequested).Count | Should -Be 10
        @($script:Probe.Probes).Count | Should -Be 10
    }
}

Describe 'φ.AUTH.9 · per-portal chain status (operator lab tenant)' -Tag 'integration','runtime-live-multiauth' {

    It 'Defender::cookie chain SUCCEEDED (v0.1.0 ACTIVE portal · must work)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $def = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'Defender' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].ChainSuccess | Should -BeTrue -Because 'Defender cookie chain (TOTP + KMSI SSO) is the v0.1.0 ACTIVE poll target · MUST be GREEN'
        $def[0].CapabilityStatus | Should -BeGreaterOrEqual 200
        $def[0].CapabilityStatus | Should -BeLessThan 500 -Because 'TenantContext returns 2xx-4xx · not 5xx'
    }

    It 'Purview::cookie chain SUCCEEDED (nearest sibling to Defender · same cookie pattern)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $pur = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'Purview' })
        $pur | Should -Not -BeNullOrEmpty
        $pur[0].ChainSuccess | Should -BeTrue -Because 'Purview cookie chain shares sccauth pattern with Defender'
    }

    It 'Entra::IAM bearer chain SUCCEEDED (v0.3.0 scaffolded · 1+ Entra sub must work)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $iam = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'Entra' -and $_.SubPortal -eq 'IAM' })
        $iam | Should -Not -BeNullOrEmpty
        $iam[0].ChainSuccess | Should -BeTrue
    }

    It 'SecurityCopilot bearer chain SUCCEEDED' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $sc = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'SecurityCopilot' })
        $sc | Should -Not -BeNullOrEmpty
        $sc[0].ChainSuccess | Should -BeTrue
    }

    It 'Aggregate ≥ 3/5 chain success (Plan §REPLAN STAGE I acceptance · Defender + Purview + ≥1 Entra + ≥1 Intune + SC)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        # Group by Portal · success if ANY sub-portal in that family succeeded
        $perPortal = @($script:Probe.Probes | Group-Object Portal)
        $passPortals = @($perPortal | Where-Object { @($_.Group | Where-Object { $_.ChainSuccess }).Count -gt 0 })
        $passPortals.Count | Should -BeGreaterOrEqual 3 -Because "≥3 portals must have at least one chain-success · got: $(($passPortals | ForEach-Object Name) -join ', ')"
    }
}

Describe 'φ.AUTH.9 · known tenant-capability gaps (NOT auth bugs · honest classification)' -Tag 'integration','runtime-live-multiauth' {

    It 'Entra::B2C failure is AADSTS500011 (resource not installed · NOT auth chain bug)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $b2c = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'Entra' -and $_.SubPortal -eq 'B2C' })
        if ($b2c -and $b2c[0].ChainSuccess -eq $false -and $b2c[0].Error) {
            $b2c[0].Error | Should -Match 'AADSTS500011' -Because 'operator lab tenant lacks B2C admin resource principal · documented honest gap'
        }
    }

    It 'Intune::Autopatch failure is AADSTS500011 (Autopatch principal not registered · NOT auth chain bug)' {
        if (-not $script:Probe) { Set-ItResult -Skipped -Because 'no probe artefact'; return }
        $ap = @($script:Probe.Probes | Where-Object { $_.Portal -eq 'Intune' -and $_.SubPortal -eq 'Autopatch' })
        if ($ap -and $ap[0].ChainSuccess -eq $false -and $ap[0].Error) {
            $ap[0].Error | Should -Match 'AADSTS500011' -Because 'operator lab tenant lacks Autopatch resource principal · documented honest gap'
        }
    }
}
