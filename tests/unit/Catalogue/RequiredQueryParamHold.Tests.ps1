#Requires -Version 7.4
# Required-query-param pollability HOLD (audit 2026-06-15). The cataloguer modelled PATH params (EntityResolution) but
# NOT required QUERY params -> an op needing a query param the autonomous runtime cannot supply (GetIndicatorReputation's
# 'query' indicator · the File-Investigation pivots' 'entityId' · GetActivityLocationsByUser's 'username') was SHIPPED yet
# 400'd EVERY cycle. Build-Catalogue now records RequiredQueryParams (in:query AND required, minus the runtime-supplied
# time/pagination params + curation querySupplied) and HOLDS such ops at BOTH ship-gate twins (in-loop + Stage-5).
# These tests pin the INVARIANT over the committed Defender catalogue and prove the proven pilot is untouched (no false hold).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $cat = Get-Content (Join-Path $script:repo 'references/inventory/nodoc-defender-xdr/catalogue.json') -Raw | ConvertFrom-Json -Depth 40
    $script:ops = @(if ($cat -is [array]) { $cat } elseif ($cat.PSObject.Properties['operations']) { $cat.operations } else { $cat.catalogue })
    $script:shipped = @($script:ops | Where-Object { $_.Shipped })
    $script:byOp = @{}; foreach ($o in $script:ops) { $script:byOp["$($o.Category)|$($o.Operation)"] = $o }
}

Describe 'Required-query-param pollability HOLD · invariant over the committed catalogue' {
    It 'NO Shipped op carries an unsatisfied RequiredQueryParams (the hold holds at the ship-gate)' {
        $bad = @($script:shipped | Where-Object { $_.PSObject.Properties['RequiredQueryParams'] -and @($_.RequiredQueryParams).Count -gt 0 })
        $names = ($bad | ForEach-Object { "$($_.Category)|$($_.Operation)" } | Sort-Object -Unique) -join ', '
        $bad.Count | Should -Be 0 -Because "a shipped op with an unsupplied required query param 400s every cycle: $names"
    }
    It 'records RequiredQueryParams on the known un-pollable ops + HOLDS them (modelled, not silently shipped)' {
        foreach ($k in @('Analytics & Data|GetIndicatorReputation', 'Cloud Apps|GetActivityLocationsByUser', 'File Investigation|ListDomainEmails')) {
            $o = $script:byOp[$k]
            $o | Should -Not -BeNullOrEmpty -Because "$k must be present in the catalogue"
            @($o.RequiredQueryParams).Count | Should -BeGreaterThan 0 -Because "$k needs a required query param the runtime cannot supply"
            $o.Shipped | Should -BeFalse -Because "$k is un-pollable-now -> must be HELD (not Shipped)"
        }
    }
    It 'does NOT hold an op whose only query params are runtime-supplied (time/pagination are not held)' {
        # GetHistory (pilot · Shipped) is time-windowed: its time-filter query params are auto-supplied, so it must NOT
        # be recorded as having an unsatisfied RequiredQueryParams.
        $gh = $script:byOp['Operations|GetHistory']
        $gh | Should -Not -BeNullOrEmpty
        $gh.Shipped | Should -BeTrue
        ($gh.PSObject.Properties['RequiredQueryParams'] -and @($gh.RequiredQueryParams).Count -gt 0) | Should -BeFalse -Because 'time-filter query params are runtime-supplied, never a hold'
    }
    It 'the proven pilot (Operations) still ships exactly its 9 ops (no false hold from the new gate)' {
        $opsShipped = @($script:ops | Where-Object { $_.Category -eq 'Operations' -and $_.Shipped })
        $opsShipped.Count | Should -Be 9
        @($opsShipped | Where-Object { $_.PSObject.Properties['RequiredQueryParams'] }).Count | Should -Be 0
    }
}
