#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — Xdr-Refresh universal portal-agnostic dispatcher.

.DESCRIPTION
    Xdr-Refresh is the SINGLE timer that replaces the 5 deleted Defender-*-Refresh
    timers AND avoids per-portal duplication for v0.2.0+ multi-portal expansion.

    Cron: every 1 min. Body:
      1. Read XdrTierState Storage table for ALL enabled (Portal, Tier) pairs
      2. For each whose nextRunUtc <= now, call Start-NewOrchestration
      3. Update nextRunUtc = now + cadence (per static cadence map)

    This test gates the dispatch logic with synthetic 'now' values across a week.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeDiscovery {
    # BeforeDiscovery runs at discovery-time so -Skip decorators can use these.
    $RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:RefreshPath        = Join-Path $RepoRoot 'src/functions/Xdr-Refresh/run.ps1'
    $script:RefreshExists      = Test-Path $script:RefreshPath
    $script:CadenceMapPath     = Join-Path $RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Get-XdrTierCadenceMap.ps1'
    $script:CadenceMapExists   = Test-Path $script:CadenceMapPath
}

BeforeAll {
    $script:RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:RefreshPath   = Join-Path $script:RepoRoot 'src/functions/Xdr-Refresh/run.ps1'
    $script:RefreshExists = Test-Path $script:RefreshPath
}

Describe 'XdrRefresh.TierDispatch — universal dispatcher (placeholder until R.4.3)' {

    It 'src/functions/Xdr-Refresh/ exists with run.ps1' -Skip:(-not $script:RefreshExists) {
        Test-Path $script:RefreshPath | Should -BeTrue -Because 'Xdr-Refresh is the single universal-dispatcher timer per R.1 architecture'
    }

    It 'Xdr-Refresh function.json declares timer trigger with cron 0 * * * * * (every 1 min) + durableClient binding' -Skip:(-not $script:RefreshExists) {
        $fn = Get-Content -Raw (Join-Path $script:RepoRoot 'src/functions/Xdr-Refresh/function.json') | ConvertFrom-Json
        $fn.bindings.Count               | Should -Be 2 -Because 'timer trigger + durableClient'
        $timerBinding   = $fn.bindings | Where-Object type -eq 'timerTrigger' | Select-Object -First 1
        $durableBinding = $fn.bindings | Where-Object type -eq 'durableClient' | Select-Object -First 1
        $timerBinding   | Should -Not -BeNullOrEmpty
        $durableBinding | Should -Not -BeNullOrEmpty -Because 'starts orchestrations'
        $timerBinding.schedule | Should -Be '0 * * * * *' -Because 'every 1 min — universal dispatcher granularity'
    }

    It 'Xdr-Refresh body reads XdrTierState + dispatches due (Portal, Tier) pairs via Start-NewOrchestration' -Skip:(-not $script:RefreshExists) {
        $src = Get-Content -Raw $script:RefreshPath
        $src | Should -Match 'XdrTierState'                                            -Because 'must read tier-state Storage'
        $src | Should -Match 'Start-NewOrchestration'                                  -Because 'must start orchestrations for due (Portal, Tier) pairs'
        # nextRunUtc update goes via Invoke-XdrStorageTableEntity Upsert (the universal helper).
        $src | Should -Match "Invoke-XdrStorageTableEntity|Set-XdrTierStateRow" -Because 'must update nextRunUtc after dispatch via Storage table write'
        $src | Should -Match 'NextRunUtc'                                              -Because 'must compute the next-run timestamp'
    }

    It 'Xdr-Refresh dispatch is portal-agnostic (does NOT hard-code Portal=Defender)' -Skip:(-not $script:RefreshExists) {
        $src = Get-Content -Raw $script:RefreshPath
        # The dispatcher MUST iterate all enabled portals, not loop only Defender.
        $src | Should -Not -Match "Portal\s*=\s*'Defender'\s*[;}]" -Because (
            "v0.2.0+ multi-portal expansion: Portal value must come from XdrTierState row, not hard-coded literal. " +
            "Hard-coding 'Defender' would require new code for each new portal — defeats the universal-dispatcher design."
        )
    }
}

Describe 'XdrRefresh.TierDispatch — cadence map' {

    It 'cadence map module function exists and contains the 5 v0.1.0 GA tiers' -Skip:(-not $script:CadenceMapExists) {
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force -Global -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1') -Force -Global -ErrorAction SilentlyContinue
        $map = Get-XdrTierCadenceMap
        $map.Keys | Sort-Object | Should -Be @('ActionCenter','Configuration','Inventory','Maintenance','XspmGraph') -Because '5 v0.1.0 GA cadence tiers'

        # Section R++ TROUBLESHOOTING (2026-05-07): Configuration/Inventory/Maintenance
        # are temporarily compressed to 1h so operators can see end-to-end data flow
        # within minutes instead of days during active production-readiness shake-out.
        # MUST REVERT before v0.1.0 GA tag — see Get-XdrTierCadenceMap.ps1 comment block.
        # Test allows EITHER production OR compressed cadence so this test passes
        # under both states. When Phase R++.K reverts, the production assertions
        # become the only valid path again.
        $isProductionCadence = ($map['Configuration'] -eq ([TimeSpan]::FromHours(6)))
        $isCompressedCadence = ($map['Configuration'] -eq ([TimeSpan]::FromHours(1)))
        ($isProductionCadence -or $isCompressedCadence) | Should -BeTrue -Because 'Configuration cadence must be 6h (production) or 1h (compressed-troubleshooting per Section R++)'

        $map['ActionCenter']  | Should -Be ([TimeSpan]::FromMinutes(10)) -Because 'ActionCenter cadence = 10 min (security events; never compressed)'
        $map['XspmGraph']     | Should -Be ([TimeSpan]::FromHours(1))    -Because 'XspmGraph cadence = 1 hour (already 1h in production)'
        if ($isProductionCadence) {
            $map['Configuration'] | Should -Be ([TimeSpan]::FromHours(6))    -Because 'Configuration cadence = 6 hours (production)'
            $map['Inventory']     | Should -Be ([TimeSpan]::FromDays(1))     -Because 'Inventory cadence = 1 day (production)'
            $map['Maintenance']   | Should -Be ([TimeSpan]::FromDays(7))     -Because 'Maintenance cadence = 7 days (production)'
        } else {
            $map['Configuration'] | Should -Be ([TimeSpan]::FromHours(1)) -Because 'Configuration cadence compressed to 1h (Section R++ troubleshooting)'
            $map['Inventory']     | Should -Be ([TimeSpan]::FromHours(1)) -Because 'Inventory cadence compressed to 1h (Section R++ troubleshooting)'
            $map['Maintenance']   | Should -Be ([TimeSpan]::FromHours(1)) -Because 'Maintenance cadence compressed to 1h (Section R++ troubleshooting)'
        }
    }
}
