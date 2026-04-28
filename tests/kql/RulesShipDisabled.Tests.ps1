#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.9 (S2 lock): every analytic rule must ship `enabled: false`.

.DESCRIPTION
    Solution-package design contract: customer-opt-in. A rule shipping with
    `enabled: true` would auto-fire on every workspace where the Solution is
    installed — likely producing false positives on day 1, eroding operator
    trust, and forcing the customer to disable + tune mid-flight.

    This gate locks the contract permanently. Any future rule contributor who
    forgets `enabled: false` (or sets it to true) gets a clean test failure
    pointing at the offending file:line.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RulesDir = Join-Path $script:RepoRoot 'sentinel' 'analytic-rules'
}

Describe 'Sentinel analytic rules — ship-disabled doctrine (iter 13.9 S2)' {

    It 'every rule yaml has `enabled: false` (customer opt-in)' {
        $offenders = @()
        $files = Get-ChildItem -Path $script:RulesDir -Filter '*.yaml' -File
        foreach ($f in $files) {
            $content = Get-Content $f.FullName -Raw
            # Match the YAML key at the start of a line. Tolerate inline comments.
            if ($content -notmatch '(?m)^\s*enabled:\s*false(\s|$|\s*#)') {
                $offenders += "$($f.Name) — missing or non-false `enabled:` directive"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            'iter-13.9 S2 lock: every analytic rule must ship enabled=false so customers ' +
            'opt in per-rule. Offenders: ' + [Environment]::NewLine + ($offenders -join [Environment]::NewLine)
        )
    }

    It 'every rule yaml has at least 14 rules in the directory (drift detector)' {
        $files = @(Get-ChildItem -Path $script:RulesDir -Filter '*.yaml' -File)
        $files.Count | Should -BeGreaterOrEqual 14 -Because 'baseline rule count must not regress'
    }
}
