#Requires -Modules Pester
<#
.SYNOPSIS
    Lock the 4 cadence-tier drift parsers as parameterized KQL functions.

.DESCRIPTION
    Each parser is a KQL function:

        let MDE_Drift_<Tier> = (lookback:timespan = 7d, window:timespan = 1h) {
            ... body ...
        };
        MDE_Drift_<Tier>

    The function form lets workbooks pass `{TimeRange:value}` from the time-
    picker without forking the parser. The defaults preserve sensible behavior
    so call sites (workbooks, hunting queries, analytic rules) work unchanged.

    This test file locks three invariants per parser (4 parsers x 3 = 12
    tests, plus a small set of cross-cutting checks):

      1. The parser declares both `lookback:timespan` and `window:timespan`
         parameters at the top of the file.
      2. The parser body uses the parameters, not hardcoded literals — every
         `ago(...)` references the parameter identifier, never a raw literal.
      3. Every workbook call site passes either 0 args (defaults) or 2
         timespan-shaped arguments.

    Tier coverage:
        MDE_Drift_Exposure       → exposure
        MDE_Drift_Configuration  → config
        MDE_Drift_Inventory      → inventory
        MDE_Drift_Maintenance    → maintenance
    The 'ActionCenter' tier has no parser (events vs snapshots).

.NOTES
    Pair test with Parsers.Tests.ps1 (which locks the looser shape — declares
    the parameter pair at all). This file enforces the *body uses the params*
    semantic.
#>

BeforeDiscovery {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ParsersDir   = Join-Path $script:RepoRoot 'sentinel' 'parsers'
    $script:WorkbooksDir = Join-Path $script:RepoRoot 'sentinel' 'workbooks'

    # One discovery case per parser — the test cases below are -ForEach'd over this.
    $script:ParserCases = @()
    foreach ($p in Get-ChildItem -Path $script:ParsersDir -Filter 'MDE_Drift_*.kql' -ErrorAction SilentlyContinue) {
        $script:ParserCases += @{
            Name     = $p.BaseName
            FullPath = $p.FullName
            Content  = (Get-Content -Raw -Path $p.FullName)
        }
    }
}

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ParsersDir   = Join-Path $script:RepoRoot 'sentinel' 'parsers'
    $script:WorkbooksDir = Join-Path $script:RepoRoot 'sentinel' 'workbooks'

    # Every drift parser is expected to be a function with this exact signature
    # shape (whitespace-flexible). Defaults differ by tier but the type is fixed.
    $script:SignatureRegex = '\(\s*lookback\s*:\s*timespan(\s*=\s*\d+[dhms])?\s*,\s*window\s*:\s*timespan(\s*=\s*\d+[dhms])?\s*\)'

    # Strip KQL line comments so regex scans don't false-positive on examples
    # in the SYNOPSIS header (e.g. "// MDE_Drift_Inventory(7d, 1d)").
    function script:Strip-KqlComments {
        param([string] $Text)
        ($Text -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    }
}

Describe 'parser declares lookback + window as typed parameters' -ForEach $script:ParserCases {

    # ASSERTION 1 (per parser): function signature with typed timespan params.
    It '<Name> declares (lookback:timespan, window:timespan) function signature near the top' {
        $stripped = Strip-KqlComments -Text $_.Content
        $stripped | Should -Match $script:SignatureRegex `
            -Because "parser '$($_.Name)' must be a KQL function with typed timespan params (workbook time-picker plumbing)"
    }

    # ASSERTION 2 (per parser): body uses the parameter, not hardcoded literals.
    # Every `ago(...)` call must reference `lookback` or `window`, NOT a raw
    # timespan literal like `ago(7d)` / `ago(1h)`.
    It '<Name> body uses the parameters in ago(...) — no hardcoded timespan literals' {
        $stripped = Strip-KqlComments -Text $_.Content

        # Find every ago(...) call inside the parser body.
        $agoMatches = [regex]::Matches($stripped, 'ago\(\s*([^)]+?)\s*\)')

        # Each ago(...) argument must be the literal token "lookback" or "window"
        # (no digits — that would be a raw literal like 7d, 1h, etc.).
        foreach ($m in $agoMatches) {
            $arg = $m.Groups[1].Value.Trim()
            $arg | Should -Match '^(lookback|window)$' `
                -Because "parser '$($_.Name)' has ago($arg) — must be ago(lookback) or ago(window) so workbook time-picker can override"
        }

        # Sanity: the parser must actually CALL ago() at least once (otherwise
        # the time filter regressed away).
        $agoMatches.Count | Should -BeGreaterThan 0 `
            -Because "parser must filter by TimeGenerated > ago(lookback) at minimum"
    }

    # ASSERTION 3 (per parser): the function body IS the function (not just a
    # `let` declaration with no application). The very last non-comment, non-
    # whitespace token of the file must be the function name itself.
    It '<Name> applies its function (last non-comment line invokes the parser name)' {
        $stripped = Strip-KqlComments -Text $_.Content
        $tail = ($stripped -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1).Trim()

        # The parser is "applied" if the trailing line is the function name itself
        # (KQL convention: the last expression is the query result).
        $tail | Should -Match ('^' + [regex]::Escape($_.Name) + '(\(\s*\))?$') `
            -Because "parser '$($_.Name)' must end with the function name (or a no-arg invocation) so KQL returns the function as the parser body"
    }
}

Describe 'workbook call sites match parser signatures (cross-cutting)' {

    # Cross-cutting: every workbook query that calls a drift parser must pass
    # 0 args (defaults) or exactly 2 timespan-shaped arguments.
    It 'every parser call in every workbook passes 0 or 2 timespan args' {
        $offenders = @()
        foreach ($wb in Get-ChildItem -Path $script:WorkbooksDir -Filter '*.json' -ErrorAction SilentlyContinue) {
            $content = Get-Content -Raw -Path $wb.FullName
            # Find MDE_Drift_<Tier>(args) — capture the args.
            $callMatches = [regex]::Matches($content, 'MDE_Drift_(?:Exposure|Configuration|Inventory|Maintenance)\s*\(([^)]*)\)')
            foreach ($cm in $callMatches) {
                $args = $cm.Groups[1].Value.Trim()
                if ([string]::IsNullOrEmpty($args)) {
                    continue  # 0 args — defaults apply.
                }
                $parts = ($args -split '\s*,\s*')
                if ($parts.Count -ne 2) {
                    $offenders += "$($wb.Name): call '$($cm.Value)' has $($parts.Count) args, expected 0 or 2"
                    continue
                }
                foreach ($part in $parts) {
                    if ($part -notmatch '^(\d+[dhms]|\{[^}]+\})$') {
                        $offenders += "$($wb.Name): call '$($cm.Value)' arg '$part' is not a timespan literal or workbook placeholder"
                    }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            'workbooks must call drift parsers with 2 timespan args (or 0 for defaults). Offenders:' +
            [Environment]::NewLine + ($offenders -join [Environment]::NewLine)
        )
    }

    # Sanity: confirm every parser is referenced from at least one workbook OR
    # analytic rule OR hunting query (otherwise it's dead code).
    It 'every drift parser is referenced from at least one workbook/rule/hunting query' {
        $sentinelDir = Join-Path $script:RepoRoot 'sentinel'
        foreach ($p in Get-ChildItem -Path $script:ParsersDir -Filter 'MDE_Drift_*.kql' -ErrorAction SilentlyContinue) {
            $name = $p.BaseName
            $found = $false
            foreach ($consumer in Get-ChildItem -Path $sentinelDir -Recurse -Include '*.json', '*.yaml' -ErrorAction SilentlyContinue) {
                if ((Get-Content -Raw -Path $consumer.FullName) -match ([regex]::Escape($name) + '\s*\(')) {
                    $found = $true
                    break
                }
            }
            $found | Should -BeTrue -Because "parser $name has zero callers — either remove it or wire it up"
        }
    }
}

Describe 'staging-package mirror is in sync' {
    # The staging package is the immutable copy that ships in the customer's
    # Sentinel solution ZIP. Phase 5 changes both copies; this gate locks them
    # byte-equal so a drift between source-of-truth and staging is caught.
    It 'every sentinel/parsers/*.kql matches deploy/solution-staging/XdrLogRaider/Parsers/*.kql' {
        $stagingDir = Join-Path $script:RepoRoot 'deploy' 'solution-staging' 'XdrLogRaider' 'Parsers'
        if (-not (Test-Path $stagingDir)) {
            Set-ItResult -Skipped -Because 'no staging dir present in this checkout'
            return
        }
        $mismatches = @()
        foreach ($p in Get-ChildItem -Path $script:ParsersDir -Filter '*.kql' -ErrorAction SilentlyContinue) {
            $stagingFile = Join-Path $stagingDir $p.Name
            if (-not (Test-Path $stagingFile)) {
                $mismatches += "$($p.Name): missing in staging"
                continue
            }
            $srcHash     = (Get-FileHash -Algorithm SHA256 -Path $p.FullName).Hash
            $stagingHash = (Get-FileHash -Algorithm SHA256 -Path $stagingFile).Hash
            if ($srcHash -ne $stagingHash) {
                $mismatches += "$($p.Name): SHA256 mismatch (src=$srcHash, staging=$stagingHash)"
            }
        }
        $mismatches | Should -BeNullOrEmpty -Because (
            'staging-package parsers must mirror source-of-truth. Mismatches:' +
            [Environment]::NewLine + ($mismatches -join [Environment]::NewLine)
        )
    }
}
