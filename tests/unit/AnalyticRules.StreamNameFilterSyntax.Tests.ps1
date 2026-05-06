#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — every analytic-rule + hunting-query KQL string
    that filters on `StreamName == "<value>"` MUST use a bare MDE_*_CL stream
    name on the right-hand side, NOT a multi-clause expression embedded inside
    the string literal.

.DESCRIPTION
    LIVE FORENSIC 2026-05-06: 17 yaml files (12 analytic rules + 5 hunting
    queries) shipped with the malformed pattern:

      where StreamName == "Defender_X_CL | where SourceName == 'MDE_Y_CL'"

    KQL parses this as a literal string compare (`StreamName` == 60-char
    literal) — the row's StreamName never matches that text → all 17 rules
    silently return zero rows. Security detections were dead.

    Root cause: drift parsers project `StreamName = SourceName` (bare
    MDE_*_CL), so callers must compare to the bare name, not the workspace
    table query that produced the parser's input.

    This test AST/regex-walks every yaml file in sentinel/ and FAILS if any
    quoted operand of a `StreamName ==` clause contains a `|` character.
    The check is also extended to `SourceStream ==` and `SourceName ==`
    (related fields prone to the same misuse).
#>

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:SentinelDir = Join-Path $script:RepoRoot 'sentinel'
}

Describe 'AnalyticRules.StreamNameFilterSyntax — no pipe-inside-string-literal in StreamName/SourceStream/SourceName comparisons' {

    It 'no analytic-rule or hunting-query yaml contains pipe-inside-string-literal in stream-id comparison' {
        $yamlFiles = @(
            Get-ChildItem -Path (Join-Path $script:SentinelDir 'analytic-rules') -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem -Path (Join-Path $script:SentinelDir 'hunting-queries') -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
        )

        $offenders = @()
        foreach ($f in $yamlFiles) {
            $content = Get-Content -Raw $f.FullName
            # Bug pattern: any of the three stream-id fields followed by == followed by a
            # quoted string that contains a pipe character.
            $pattern = '(StreamName|SourceStream|SourceName)\s*==\s*"[^"]*\|[^"]*"'
            if ($content -match $pattern) {
                $offenders += ('{0}: {1}' -f $f.FullName.Substring($script:RepoRoot.Length + 1), $matches[0])
            }
        }

        $reason = "StreamName/SourceStream/SourceName comparisons must NOT embed a pipe inside the quoted operand (KQL would treat the entire quoted text as one literal that never matches a row value). Live evidence: 17 yaml files broken in commit a4ef2f8 - every rule silently dead. Offenders:`n" + ($offenders -join "`n")
        $offenders | Should -BeNullOrEmpty -Because $reason
    }

    It 'every StreamName ==/SourceStream ==/SourceName == compares against an MDE_*_CL bare name' {
        $yamlFiles = @(
            Get-ChildItem -Path (Join-Path $script:SentinelDir 'analytic-rules') -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
            Get-ChildItem -Path (Join-Path $script:SentinelDir 'hunting-queries') -Filter '*.yaml' -Recurse -ErrorAction SilentlyContinue
        )

        $offenders = @()
        foreach ($f in $yamlFiles) {
            $content = Get-Content -Raw $f.FullName
            # Look for `<field> == "..."` where the literal isn't a bare MDE_*_CL.
            # Allow Defender_*_CL on the LHS (workspace table query) — that's a
            # separate `where SourceName == 'MDE_X_CL'` filter, NOT inside a string.
            $matches = [regex]::Matches($content, '(?<field>StreamName|SourceStream)\s*==\s*"(?<val>[^"]+)"')
            foreach ($m in $matches) {
                $val = $m.Groups['val'].Value
                if ($val -notmatch '^MDE_[A-Za-z]+_CL$') {
                    $offenders += "{0}: {1} == `"{2}`" (expected bare MDE_<Stream>_CL)" -f $f.Name, $m.Groups['field'].Value, $val
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because (
            "Drift parsers project `StreamName = SourceName` so the compare value MUST be a bare MDE_<Stream>_CL identifier. Anything else (workspace table name, multi-clause expression) cannot match. Offenders:`n" + ($offenders -join "`n")
        )
    }
}
