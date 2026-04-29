#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.9 (S1 lock): no parser may unconditionally union a stream that's
    flagged `Availability='deprecated'` in the manifest.

.DESCRIPTION
    A deprecated stream produces zero rows post-deploy (its underlying portal
    endpoint was renamed/retired by Microsoft). Including it in a parser's
    union is harmless but pointless — and it also misleads downstream rule
    authors who scan the parser's source-table list.

    This gate scans every KQL parser file for unconditional `union` references
    to any deprecated manifest stream. New deprecations + new parsers both get
    locked: if anyone marks a stream `deprecated` without removing it from
    parsers, the test fails with a precise file:line pointer.
#>

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ParsersDir    = Join-Path $script:RepoRoot 'sentinel' 'parsers'
    $script:ManifestPath  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:Manifest      = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:DeprecatedStreams = @($script:Manifest.Endpoints | Where-Object { $_.Availability -eq 'deprecated' }).Stream
}

Describe 'Sentinel parsers — no unconditional union of deprecated streams (iter 13.9 S1)' {

    It 'every deprecated manifest stream is absent from every parser union' {
        if (@($script:DeprecatedStreams).Count -eq 0) {
            Set-ItResult -Skipped -Because 'no deprecated streams in manifest — gate inert until one exists'
            return
        }
        $parsers = Get-ChildItem -Path $script:ParsersDir -Filter '*.kql' -File
        $offenders = @()

        foreach ($parser in $parsers) {
            $content = Get-Content $parser.FullName -Raw
            $lines = $content -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Skip comments
                if ($line -match '^\s*//') { continue }
                foreach ($dep in $script:DeprecatedStreams) {
                    # Match the stream name as a token (preceded by union/comma/whitespace,
                    # followed by comma/whitespace/end-of-line). Skip false-positives where
                    # the stream name appears only inside a string literal (e.g.
                    # where StreamName == "MDE_X_CL").
                    if ($line -match ('(?<![\w"])' + [regex]::Escape($dep) + '(?![\w"])') -and
                        $line -notmatch '"' -and
                        $line -notmatch "'") {
                        $offenders += "$($parser.Name):L$($i+1) :: $dep referenced — should be removed (deprecated in manifest)"
                    }
                }
            }
        }

        $offenders | Should -BeNullOrEmpty -Because (
            'iter-13.9 S1 lock: deprecated streams produce zero rows; remove from parser unions to keep source-table lists honest. Offenders:' +
            [Environment]::NewLine + ($offenders -join [Environment]::NewLine)
        )
    }

    It 'baseline parser count is at least 6 (drift detector)' {
        $parsers = @(Get-ChildItem -Path $script:ParsersDir -Filter '*.kql' -File)
        $parsers.Count | Should -BeGreaterOrEqual 6 -Because 'baseline parser count must not regress'
    }
}
