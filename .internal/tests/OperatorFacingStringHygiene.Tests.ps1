#Requires -Modules Pester
<#
.SYNOPSIS
    Operator-facing string hygiene gate. Blocks internal-iteration jargon
    (iter-X.Y, Phase X) and test-count narratives from leaking into surfaces
    operators read.

.DESCRIPTION
    The connector targets a clean-OSS-project look (Microsoft Sentinel-Solutions
    style). Operators see version-language only — never iteration numbers,
    internal phase labels, retraction narratives, or test-count claims.

    What this gate covers (FAILS the build if regex matches appear):

      - README.md (entire file)
      - CHANGELOG.md `[Unreleased]` section ONLY (older versioned entries
        preserve their iter-X mentions as historical record)
      - All operator-facing docs in docs/
      - PowerShell function-level .SYNOPSIS / .DESCRIPTION blocks in
        src/Modules/**/*.ps1 (NOT inline `# iter-` comments — those document
        per-line provenance for developers and are deliberately preserved)
      - Module manifests src/Modules/**/*.psd1 — `Description` and
        `ReleaseNotes` fields (operator-visible via Get-Module / PSGallery)
      - deploy/main.bicep + deploy/modules/*.bicep — `@description(...)` lines
        (operators see these in the Deploy-to-Azure wizard)
      - deploy/compiled/*.json — compiled ARM artifacts (the actual surface
        operators deploy from)
      - src/functions/*/run.ps1 — `Write-Information` / `Write-Warning`
        user-visible strings
      - src/functions/*/function.json — `description` field shown in the
        Azure Functions UI
      - tools/*.ps1 (excluding tools/_*.ps1) — `Write-Host` strings,
        `.SYNOPSIS` / `.DESCRIPTION` help blocks
      - sentinel/parsers/*.kql — KQL parsers deployed to operator workspace

    What this gate INTENTIONALLY excludes:

      - ~/.claude/plans/** (internal — outside repo)
      - tools/_*.ps1 (gitignored internal scripts)
      - CHANGELOG.md outside the `[Unreleased]` section (history is preserved)
      - Inline `# iter-X.Y:` provenance comments inside source files
      - Test files themselves (`Describe 'Phase 14B'` is fine; tests need to
        reference the historical phase numbers they cover)
      - tests/integration/, tests/e2e/, tests/fixtures/, tests/results/
      - src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1 (manifest
        owner; finished but stays as-is — comment-only references)
#>

BeforeDiscovery {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # Patterns we forbid in operator-facing surfaces. Phase pattern is
    # case-sensitive (operators use lowercase "phase" generically; we only
    # forbid the title-case "Phase" + alphanumeric label form which is the
    # internal-iteration jargon shape — Phase A, Phase 14B, Phase 9).
    $script:JargonPatterns = @(
        '\biter-\d+\.\d+\b',          # iter-13.15, iter-14.0
        '(?-i)\bPhase [A-Z0-9]+\b'    # Phase A, Phase 14B, Phase 9 (case-sensitive)
    )

    # Test-count narrative patterns that leak internal velocity numbers.
    $script:TestCountPatterns = @(
        '\b1[3-9]\d\d\+? (offline\s+)?tests?\b',  # 1355 tests, 1574 offline tests
        '\b\d{3,4}\+? offline tests?\b'           # 800+ offline tests
    )

    # Combined for surfaces that should be free of BOTH.
    $script:AllForbiddenPatterns = @($script:JargonPatterns) + @($script:TestCountPatterns)

    # Helper: scan a file for any pattern in $patterns; return matched lines.
    function script:Find-OperatorFacingMatches {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [Parameter(Mandatory)] [string[]] $Patterns,
            [scriptblock] $LineFilter = $null
        )
        $found = [System.Collections.Generic.List[object]]::new()
        if (-not (Test-Path -LiteralPath $Path)) { return ,@($found.ToArray()) }
        $lines = Get-Content -LiteralPath $Path
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($LineFilter -and -not (& $LineFilter $line $i)) { continue }
            foreach ($p in $Patterns) {
                if ($line -match $p) {
                    [void]$found.Add([pscustomobject]@{
                        File = $Path.Replace($script:RepoRoot, '.').Replace('\', '/')
                        Line = $i + 1
                        Pattern = $p
                        Text = $line.Trim()
                    })
                    break
                }
            }
        }
        return ,@($found.ToArray())
    }

    # Format a list of matches as a readable failure message.
    function script:Format-MatchReport {
        param([object[]] $Matches)
        if (-not $Matches -or $Matches.Count -eq 0) { return '' }
        return ($Matches | ForEach-Object { "    $($_.File):L$($_.Line) [$($_.Pattern)] $($_.Text)" }) -join "`n"
    }

    # CHANGELOG.md helper: extract the [Unreleased] section as a list of
    # (line-number, line) pairs. Preserves history below the first versioned
    # `## [x.y.z]` heading.
    function script:Get-UnreleasedSection {
        param([string] $ChangelogPath)
        if (-not (Test-Path -LiteralPath $ChangelogPath)) { return @() }
        $lines = Get-Content -LiteralPath $ChangelogPath
        $inUnreleased = $false
        $startLine = -1
        $endLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## \[Unreleased\]') {
                # First [Unreleased] only — historical sections may contain
                # nested [Unreleased] headers under older releases.
                if (-not $inUnreleased) {
                    $inUnreleased = $true
                    $startLine = $i
                    continue
                }
            }
            if ($inUnreleased -and $lines[$i] -match '^## \[\d') {
                $endLine = $i - 1
                break
            }
        }
        if ($startLine -lt 0) { return @() }
        if ($endLine -lt 0) { $endLine = $lines.Count - 1 }
        $section = @()
        for ($i = $startLine; $i -le $endLine; $i++) {
            $section += [pscustomobject]@{ Line = ($i + 1); Text = $lines[$i] }
        }
        return $section
    }

    # SYNOPSIS/DESCRIPTION extractor. Returns an array of (line-number, text)
    # pairs covering ONLY content inside `<#  ... #>` comment-help blocks.
    # Inline `# iter-13.15:` provenance comments are skipped.
    function script:Get-CommentHelpBlocks {
        param([string] $Path)
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        $lines = Get-Content -LiteralPath $Path
        $inBlock = $false
        $out = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '<#') { $inBlock = $true }
            if ($inBlock) {
                $out += [pscustomobject]@{ Line = ($i + 1); Text = $line }
            }
            if ($line -match '#>') { $inBlock = $false }
        }
        return $out
    }
}

Describe 'Operator-facing string hygiene — no internal-iteration jargon leaks' {

    Context 'README.md (entire file)' {
        It 'README.md is free of iter-X / Phase Y / test-count narrative' {
            $hits = Find-OperatorFacingMatches `
                -Path (Join-Path $script:RepoRoot 'README.md') `
                -Patterns $script:AllForbiddenPatterns
            $report = Format-MatchReport -Matches $hits
            @($hits).Count | Should -Be 0 -Because "README.md is the front door — operators must see version-language only.`n$report"
        }
    }

    Context 'CHANGELOG.md [Unreleased] section' {
        It 'CHANGELOG.md [Unreleased] is free of iter-X / Phase Y / test-count narrative' {
            $section = Get-UnreleasedSection -ChangelogPath (Join-Path $script:RepoRoot 'CHANGELOG.md')
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $section) {
                foreach ($p in $script:AllForbiddenPatterns) {
                    if ($entry.Text -match $p) {
                        [void]$allMatches.Add([pscustomobject]@{
                            File = './CHANGELOG.md'
                            Line = $entry.Line
                            Pattern = $p
                            Text = $entry.Text.Trim()
                        })
                        break
                    }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "[Unreleased] uses operator-version-language; older versioned entries below it preserve their iter-X mentions as history.`n$report"
        }
    }

    Context 'docs/ — operator-facing documentation' {
        It 'every operator-facing doc is free of iter-X / Phase Y / test-count narrative' {
            $docFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'docs') -Filter '*.md' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $docFiles) {
                foreach ($m in (Find-OperatorFacingMatches -Path $file.FullName -Patterns $script:AllForbiddenPatterns)) {
                    [void]$allMatches.Add($m)
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "docs/ is the operator surface; replace iter-X mentions with operator-language behavior descriptions ('the L1/L2 split', 'the typed-column ingest', 'the boundary-marker pattern').`n$report"
        }
    }

    Context 'src/Modules/**/*.ps1 — function-level .SYNOPSIS / .DESCRIPTION blocks' {
        It 'function-level comment-help blocks are free of iter-X / Phase Y' {
            $psFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/Modules') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $psFiles) {
                $help = Get-CommentHelpBlocks -Path $file.FullName
                foreach ($entry in $help) {
                    foreach ($p in $script:JargonPatterns) {
                        if ($entry.Text -match $p) {
                            [void]$allMatches.Add([pscustomobject]@{
                                File = $file.FullName.Replace($script:RepoRoot, '.').Replace('\', '/')
                                Line = $entry.Line
                                Pattern = $p
                                Text = $entry.Text.Trim()
                            })
                            break
                        }
                    }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because ".SYNOPSIS / .DESCRIPTION are operator-visible via Get-Help. Inline '# iter-13.15:' provenance comments are still allowed and intentionally preserved.`n$report"
        }
    }

    Context 'src/Modules/**/*.psd1 — module manifests' {
        It 'module manifest Description / ReleaseNotes are free of iter-X / Phase Y' {
            $manifestFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/Modules') -Recurse -Filter '*.psd1' -ErrorAction SilentlyContinue
            # Skip endpoints.manifest.psd1 — that's an endpoint catalogue, not
            # a module manifest. The owner explicitly excludes it from this gate.
            $manifestFiles = $manifestFiles | Where-Object { $_.Name -notlike 'endpoints.manifest.*' }
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $manifestFiles) {
                $lines = Get-Content -LiteralPath $file.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    # Operator-visible manifest fields: Description = '...' and ReleaseNotes = '...'
                    if ($line -match '^\s*(Description|ReleaseNotes)\s*=') {
                        foreach ($p in $script:JargonPatterns) {
                            if ($line -match $p) {
                                [void]$allMatches.Add([pscustomobject]@{
                                    File = $file.FullName.Replace($script:RepoRoot, '.').Replace('\', '/')
                                    Line = $i + 1
                                    Pattern = $p
                                    Text = $line.Trim()
                                })
                                break
                            }
                        }
                    }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "Description + ReleaseNotes are operator-visible via Get-Module / PSGallery.`n$report"
        }
    }

    Context 'deploy/ — Bicep @description() and compiled ARM' {
        It 'Bicep @description() lines are free of iter-X / Phase Y' {
            $bicepFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'deploy') -Recurse -Filter '*.bicep' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $bicepFiles) {
                $lines = Get-Content -LiteralPath $file.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -match '^\s*@description\(') {
                        foreach ($p in $script:JargonPatterns) {
                            if ($line -match $p) {
                                [void]$allMatches.Add([pscustomobject]@{
                                    File = $file.FullName.Replace($script:RepoRoot, '.').Replace('\', '/')
                                    Line = $i + 1
                                    Pattern = $p
                                    Text = $line.Trim()
                                })
                                break
                            }
                        }
                    }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "@description() shows up in the Deploy-to-Azure wizard.`n$report"
        }

        It 'compiled ARM templates and createUiDefinition are free of iter-X / Phase Y' {
            $jsonFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'deploy/compiled') -Filter '*.json' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $jsonFiles) {
                foreach ($m in (Find-OperatorFacingMatches -Path $file.FullName -Patterns $script:JargonPatterns)) {
                    [void]$allMatches.Add($m)
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "deploy/compiled/*.json is what operators deploy.`n$report"
        }
    }

    Context 'src/functions/ — Azure Functions surfaces' {
        It 'function.json description fields are free of iter-X / Phase Y' {
            $fnFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/functions') -Recurse -Filter 'function.json' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $fnFiles) {
                foreach ($m in (Find-OperatorFacingMatches -Path $file.FullName -Patterns $script:JargonPatterns)) {
                    [void]$allMatches.Add($m)
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "function.json description shows in Azure Functions UI.`n$report"
        }

        It 'run.ps1 user-visible Write-Information / Write-Warning strings are free of iter-X / Phase Y' {
            $runFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src/functions') -Recurse -Filter 'run.ps1' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $runFiles) {
                $lines = Get-Content -LiteralPath $file.FullName
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    # Skip pure comment lines — # iter- inline comments are dev-facing.
                    if ($line -match '^\s*#') { continue }
                    if ($line -match 'Write-(Information|Warning|Error|Host)') {
                        foreach ($p in $script:JargonPatterns) {
                            if ($line -match $p) {
                                [void]$allMatches.Add([pscustomobject]@{
                                    File = $file.FullName.Replace($script:RepoRoot, '.').Replace('\', '/')
                                    Line = $i + 1
                                    Pattern = $p
                                    Text = $line.Trim()
                                })
                                break
                            }
                        }
                    }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "Write-Information / Write-Warning surface to App Insights traces.`n$report"
        }
    }

    Context 'tools/ — operator-runnable scripts' {
        It 'tools/*.ps1 (excluding tools/_*.ps1) help blocks and Write-Host strings are free of iter-X / Phase Y' {
            $toolFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'tools') -Filter '*.ps1' -ErrorAction SilentlyContinue
            # Exclude internal-only scripts (gitignored).
            $toolFiles = $toolFiles | Where-Object { $_.Name -notlike '_*.ps1' }
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $toolFiles) {
                $lines = Get-Content -LiteralPath $file.FullName
                $inHelpBlock = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -match '<#') { $inHelpBlock = $true }
                    $check = $false
                    if ($inHelpBlock) { $check = $true }
                    if ($line -match 'Write-(Host|Information|Warning|Error)') { $check = $true }
                    if ($check) {
                        foreach ($p in $script:JargonPatterns) {
                            if ($line -match $p) {
                                [void]$allMatches.Add([pscustomobject]@{
                                    File = $file.FullName.Replace($script:RepoRoot, '.').Replace('\', '/')
                                    Line = $i + 1
                                    Pattern = $p
                                    Text = $line.Trim()
                                })
                                break
                            }
                        }
                    }
                    if ($line -match '#>') { $inHelpBlock = $false }
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "tools/*.ps1 are operator-runnable; Get-Help and console output must be jargon-free.`n$report"
        }
    }

    Context 'sentinel/parsers/ — KQL parsers deployed to operator workspace' {
        It 'parser comments are free of iter-X / Phase Y' {
            $kqlFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'sentinel/parsers') -Filter '*.kql' -ErrorAction SilentlyContinue
            $allMatches = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $kqlFiles) {
                foreach ($m in (Find-OperatorFacingMatches -Path $file.FullName -Patterns $script:JargonPatterns)) {
                    [void]$allMatches.Add($m)
                }
            }
            $report = Format-MatchReport -Matches $allMatches.ToArray()
            $allMatches.Count | Should -Be 0 -Because "Parsers ship into the operator's workspace and operators read their headers when querying.`n$report"
        }
    }
}
