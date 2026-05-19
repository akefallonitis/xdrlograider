#Requires -Module Pester
# φ.E · run.ps1 runtime enhancements · helpers + structural invariants
# Locks the contract that:
#   1. Pagination loop is wired (do-while with continuation lookup)
#   2. Checkpoint table read/write happens around the pagination loop
#   3. Cadence-skip via XdrCheckpoint.LastPolledUtc + entry.Cadence
#   4. Time-filter URL injection via entry.TimeFilter + entry.TimeFilterParam
#   5. Per-sub-area circuit-breaker (XdrTierState · 3-error/30min · D-18)
#   6. Stream router via DCR_IMMUTABLE_ID_MAP app setting (per-sub-area DCR + stream)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RunPs1   = Join-Path $script:RepoRoot 'src/functions/Xdr-Poll/run.ps1'
    $script:RunSrc   = Get-Content -Raw -LiteralPath $script:RunPs1
}

Describe 'φ.E · runtime helpers · in-file invariants' -Tag 'phase-e' {

    It 'ConvertTo-XdrCadenceTimespan covers all 6 cadence buckets (10m/30m/1h/6h/24h/weekly)' {
        $script:RunSrc | Should -Match 'function ConvertTo-XdrCadenceTimespan'
        foreach ($bucket in '10m','30m','1h','6h','24h','weekly') {
            ($script:RunSrc.Contains("'$bucket'")) | Should -BeTrue -Because "switch case for '$bucket' must be present"
        }
    }

    It 'ConvertFrom-XdrDcrImmutableIdMap parses app setting JSON into hashtable' {
        $script:RunSrc | Should -Match 'function ConvertFrom-XdrDcrImmutableIdMap'
        $script:RunSrc | Should -Match "DCR_IMMUTABLE_ID_MAP"
    }

    It 'Get-XdrPaginationContinuation switches on entry.Pagination strategy (5 valid values)' {
        $script:RunSrc | Should -Match 'function Get-XdrPaginationContinuation'
        foreach ($strat in 'nextlink','odata-link','skip-token','continuation') {
            ($script:RunSrc.Contains("'$strat'")) | Should -BeTrue -Because "switch case for '$strat' must be present"
        }
    }

    It 'Add-XdrUrlQueryParam handles existing ? vs & separator' {
        $script:RunSrc | Should -Match 'function Add-XdrUrlQueryParam'
        $script:RunSrc.Contains("if (`$Url -match '\?')") | Should -BeTrue
    }
}

Describe 'φ.E · per-entry loop · core behavior wired' -Tag 'phase-e' {

    It 'Cadence-skip via XdrCheckpoint.LastPolledUtc + entry.Cadence' {
        $script:RunSrc | Should -Match 'cadenceSkipped\+\+'
        $script:RunSrc | Should -Match 'ConvertTo-XdrCadenceTimespan'
        $script:RunSrc | Should -Match 'Runtime\.CadenceSkip'
    }

    It 'Per-sub-area circuit-breaker · open at 3 failures · 30min cooldown · half-open recovery' {
        $script:RunSrc.Contains('$cb.Failures -ge 3') | Should -BeTrue
        $script:RunSrc.Contains('1800') | Should -BeTrue
        $script:RunSrc.Contains('HalfOpen') | Should -BeTrue
        $script:RunSrc.Contains('Runtime.CircuitTripped') | Should -BeTrue
        $script:RunSrc.Contains('Runtime.CircuitOpenSkip') | Should -BeTrue
    }

    It 'Pagination loop · do-while with continuation lookup (multiline)' {
        $script:RunSrc.Contains('Get-XdrPaginationContinuation') | Should -BeTrue
        $script:RunSrc.Contains('} while ($continuation)') | Should -BeTrue
    }

    It 'Time-filter URL injection · uses entry.TimeFilter + entry.TimeFilterParam · subtracts 5min overlap' {
        $script:RunSrc | Should -Match "TimeFilterParam"
        $script:RunSrc | Should -Match "AddMinutes\(-5\)"
    }

    It 'Stream router · DCR_IMMUTABLE_ID_MAP lookup per entry.SubArea' {
        $script:RunSrc | Should -Match '\$dcrMap\.ContainsKey\(\$e\.SubArea\)'
        $script:RunSrc | Should -Match 'Runtime\.DcrLookupMiss'
    }

    It 'Checkpoint read/write · XdrCheckpoint table · LastPolledUtc + LastCompletedPage + ContinuationToken' {
        $script:RunSrc.Contains("'XdrCheckpoint'") | Should -BeTrue
        $script:RunSrc.Contains('LastPolledUtc') | Should -BeTrue
        $script:RunSrc.Contains('LastCompletedPage') | Should -BeTrue
        $script:RunSrc.Contains('ContinuationToken') | Should -BeTrue
    }

    It 'XdrTierState durability · writes circuit state on trip' {
        $script:RunSrc.Contains("'XdrTierState'") | Should -BeTrue
    }
}

Describe 'φ.E · cycle-end heartbeat surfaces new counters' -Tag 'phase-e' {

    It 'cycle-end heartbeat Note includes cadenceSkipped + circuitSkipped + pages' {
        $script:RunSrc | Should -Match 'cadenceSkipped=\$cadenceSkipped'
        $script:RunSrc | Should -Match 'circuitSkipped=\$circuitSkipped'
        $script:RunSrc | Should -Match 'pages=\$pagesProcessed'
    }

    It 'cycle-end heartbeat sets CircuitOpen=$anyCircuitOpen' {
        $script:RunSrc | Should -Match '-CircuitOpen\s+\$anyCircuitOpen'
    }
}
