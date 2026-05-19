#Requires -Module Pester
# Locks the post-hoc AXIS-section audit · S-5 of v0.1.0 P0 v2 RESET.
#
# Complements S-1 (pre-commit hook · gates at commit time) by VERIFYING every commit
# since the hook-installed baseline (3809bf5) carries the AXIS/PRIOR-GATES/VERIFY/LOCK
# template. Catches:
#   - Commits made with `git commit --no-verify` (bypass)
#   - Commits from environments where the hook is uninstalled
#   - Methodology drift over time
#
# Uses the same Test-CommitMessageHasRequiredSections helper as the hook, so the
# pre-commit gate AND the post-hoc audit share one source of truth.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:libPath  = Join-Path $script:repoRoot 'tools\lib\Hook-PreCommit.lib.ps1'
    . $script:libPath

    # AXIS-gate baseline — first commit after S-1 hook landed.
    # Commits BEFORE this baseline are exempt (the gate didn't exist yet).
    $script:axisGateBaseline = '3809bf5'

    function Get-CommitsSinceBaseline {
        param([string]$Baseline, [int]$MaxCommits = 200)
        # git log <baseline>..HEAD returns commits AFTER the baseline (exclusive)
        # We want commits INCLUDING and AFTER S-1 hook lands, but S-1 IS the baseline
        # and S-1's commit message was written BEFORE the hook existed in `.git/hooks/`
        # so we audit commits AFTER S-1.
        $range = "$Baseline..HEAD"
        $hashes = & git -C $script:repoRoot log $range --format='%H' 2>$null
        if (-not $hashes) { return @() }
        return @($hashes) | Select-Object -First $MaxCommits
    }

    function Get-CommitFullMessage {
        param([string]$Sha)
        return (& git -C $script:repoRoot log -1 $Sha --format='%B' 2>$null) -join "`n"
    }
}

Describe 'CommitMsg.AxisSection · post-hoc audit of commits since S-1 hook baseline' -Tag 'commit-msg' {

    It 'baseline commit 3809bf5 is reachable in git log' {
        $sha = & git -C $script:repoRoot rev-parse $script:axisGateBaseline 2>$null
        $sha | Should -Not -BeNullOrEmpty
    }

    It 'every commit since S-1 baseline contains all 4 required sections' {
        $shas = @(Get-CommitsSinceBaseline -Baseline $script:axisGateBaseline)
        if ($shas.Count -eq 0) {
            Set-ItResult -Skipped -Because 'no commits yet after S-1 baseline (squash orphan branch or CI shallow-clone with baseline unreachable)'
            return
        }
        # Also skip if baseline ref isn't in our local git history (orphan branch · CI shallow clone)
        $baselineExists = & git -C $script:repoRoot rev-parse --verify --quiet $script:axisGateBaseline 2>$null
        if (-not $baselineExists) {
            Set-ItResult -Skipped -Because 'S-1 baseline commit not reachable in git history (post-squash orphan branch · expected)'
            return
        }

        $violations = @()
        foreach ($sha in $shas) {
            $msg = Get-CommitFullMessage -Sha $sha
            $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
            if ($issues.Count -gt 0) {
                $shortSha = $sha.Substring(0, [Math]::Min(7, $sha.Length))
                $subject = (& git -C $script:repoRoot log -1 $sha --format='%s' 2>$null) -join ''
                $violations += "  $shortSha '$subject' · $($issues -join ' / ')"
            }
        }

        if ($violations.Count -gt 0) {
            $msg = "AXIS-section gate violated in $($violations.Count) commit(s) since $script:axisGateBaseline:`n" + ($violations -join "`n")
            throw $msg
        }
    }

    It 'no commit since baseline has multiple AXIS: sections (one-axis-per-commit)' {
        $shas = @(Get-CommitsSinceBaseline -Baseline $script:axisGateBaseline)
        if ($shas.Count -eq 0) {
            Set-ItResult -Skipped -Because 'no commits yet after S-1 baseline (squash orphan branch or shallow clone)'
            return
        }
        $baselineExists = & git -C $script:repoRoot rev-parse --verify --quiet $script:axisGateBaseline 2>$null
        if (-not $baselineExists) {
            Set-ItResult -Skipped -Because 'S-1 baseline commit not reachable (post-squash orphan branch · expected)'
            return
        }

        $multiAxis = @()
        foreach ($sha in $shas) {
            $msg = Get-CommitFullMessage -Sha $sha
            $count = ([regex]::Matches($msg, '(?m)^AXIS:')).Count
            if ($count -gt 1) {
                $shortSha = $sha.Substring(0, [Math]::Min(7, $sha.Length))
                $subject = (& git -C $script:repoRoot log -1 $sha --format='%s' 2>$null) -join ''
                $multiAxis += "  $shortSha '$subject' · $count AXIS sections"
            }
        }

        if ($multiAxis.Count -gt 0) {
            $msg = "Multi-axis commits since $script:axisGateBaseline (one-axis-per-commit rule G5 violation):`n" + ($multiAxis -join "`n")
            throw $msg
        }
    }
}

Describe 'CommitMsg.AxisSection · S-1 baseline commit itself' -Tag 'commit-msg' {

    It 'baseline commit 3809bf5 message carries the full AXIS/PRIOR-GATES/VERIFY/LOCK template (set the precedent)' {
        $sha = & git -C $script:repoRoot rev-parse --verify --quiet $script:axisGateBaseline 2>$null
        if (-not $sha) {
            Set-ItResult -Skipped -Because 'baseline commit not in git history (post-squash orphan branch · CI shallow clone · expected)'
            return
        }
        $msg = (& git -C $script:repoRoot log -1 $sha --format='%B' 2>$null) -join "`n"
        $issues = @(Test-CommitMessageHasRequiredSections -Message $msg)
        $issues.Count | Should -Be 0 -Because "S-1 baseline commit must demonstrate the methodology it enforces"
    }
}
