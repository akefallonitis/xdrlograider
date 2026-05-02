#Requires -Modules Pester
<#
.SYNOPSIS
    Locks the iter-14.0 Phase 0.5 commit-msg hook: blocks AI-attribution
    trailer leaks (Co-Authored-By: Claude, noreply@anthropic.com,
    "Generated with Claude") at the commit-msg stage.

.DESCRIPTION
    The hook lives at tools/git-hooks/commit-msg (versioned). The local
    install at .git/hooks/commit-msg is created by tools/Install-GitHooks.ps1.

    These tests:
    1. Assert the versioned hook exists and contains the three block patterns.
    2. Assert the local hook (when present) matches the versioned content.
    3. Run the actual hook script against crafted commit messages to prove
       it rejects the bad shapes and accepts the clean shape. Bash-dependent;
       skipped on hosts without bash.
#>

# Pester 5 has separate Discovery + Run scopes. Skip-condition values must be
# set BeforeDiscovery (so -Skip:(...) sees them); the same values must be re-set
# in BeforeAll for use inside It blocks at Run time.

# Pester 5 has separate Discovery + Run scopes; the bash-path resolution
# logic is inlined into both BeforeDiscovery and BeforeAll because top-level
# functions don't reliably cross the scope boundary.

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    $bashPath = if ($cmd) { $cmd.Source } else {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $candidate = Join-Path (Split-Path $git.Source -Parent) '..\bin\bash.exe'
            $resolved = try { (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { $null }
            if ($resolved -and (Test-Path -LiteralPath $resolved)) { $resolved } else { $null }
        } else { $null }
    }
    $script:BashPath     = $bashPath
    $script:HasBash      = [bool]$bashPath
    $script:HasLocalHook = Test-Path -LiteralPath (Join-Path $repoRoot '.git' 'hooks' 'commit-msg')
}

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:VersionedHook = Join-Path $script:RepoRoot 'tools' 'git-hooks' 'commit-msg'
    $script:LocalHook     = Join-Path $script:RepoRoot '.git' 'hooks' 'commit-msg'
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    $script:BashPath = if ($cmd) { $cmd.Source } else {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $candidate = Join-Path (Split-Path $git.Source -Parent) '..\bin\bash.exe'
            $resolved = try { (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { $null }
            if ($resolved -and (Test-Path -LiteralPath $resolved)) { $resolved } else { $null }
        } else { $null }
    }
    $script:TempDir = New-Item -Path (Join-Path ([System.IO.Path]::GetTempPath()) "xdrlr-hookgate-$(Get-Random)") -ItemType Directory -Force
}

AfterAll {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Commit-message hygiene hook (iter-14.0 Phase 0.5)' {

    Context 'Versioned hook source' {

        It 'Versioned hook exists at tools/git-hooks/commit-msg' {
            Test-Path -LiteralPath $script:VersionedHook | Should -BeTrue -Because 'tools/Install-GitHooks.ps1 expects this source-of-truth file'
        }

        It 'Versioned hook contains the Co-Authored-By: Claude block pattern' {
            $content = Get-Content -LiteralPath $script:VersionedHook -Raw
            $content | Should -Match 'co-authored-by:.*claude' -Because 'block 1 must catch Co-Authored-By: Claude trailers'
        }

        It 'Versioned hook contains the noreply@anthropic.com block pattern' {
            $content = Get-Content -LiteralPath $script:VersionedHook -Raw
            $content | Should -Match 'noreply@anthropic\\\.com' -Because 'block 2 must catch Anthropic email signature leaks'
        }

        It 'Versioned hook contains the "Generated with Claude" block pattern' {
            $content = Get-Content -LiteralPath $script:VersionedHook -Raw
            $content | Should -Match 'generated.+claude' -Because 'block 3 must catch bare Generated with Claude markers'
        }

        It 'Versioned hook is a POSIX shell script (uses /bin/sh shebang)' {
            $firstLine = (Get-Content -LiteralPath $script:VersionedHook -TotalCount 1)
            $firstLine | Should -Be '#!/bin/sh' -Because 'POSIX sh keeps it portable across linux + git-bash on windows'
        }
    }

    Context 'Local hook installation' {

        It 'Local hook (.git/hooks/commit-msg) exists' -Skip:(-not $script:HasLocalHook) {
            Test-Path -LiteralPath $script:LocalHook | Should -BeTrue
        }

        It 'Local hook content matches the versioned source exactly' -Skip:(-not $script:HasLocalHook) {
            $local     = Get-Content -LiteralPath $script:LocalHook -Raw
            $versioned = Get-Content -LiteralPath $script:VersionedHook -Raw
            $local | Should -BeExactly $versioned -Because 'tools/Install-GitHooks.ps1 should keep local copy in sync; re-run if mismatched'
        }
    }

    Context 'Hook execution against crafted commit messages' -Tag 'requires-bash' {

        It 'Rejects "Co-Authored-By: Claude Opus 4.7" (mixed case)' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            "feat: thing`n`nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 1 -Because 'block 1 must reject Co-Authored-By: Claude'
        }

        It 'Rejects "co-authored-by: claude sonnet" (lowercase)' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            "fix: thing`n`nco-authored-by: claude sonnet" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 1 -Because 'case-insensitive match required'
        }

        It 'Rejects "noreply@anthropic.com" anywhere in the message' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            "fix: thing`n`nReported-by: bot <noreply@anthropic.com>" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 1 -Because 'block 2 must reject Anthropic email leak even without Co-Authored-By trailer'
        }

        It 'Rejects "Generated with Claude Code"' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            "feat: feature`n`nGenerated with Claude Code" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 1 -Because 'block 3 must reject Generated with Claude markers'
        }

        It 'Accepts a clean commit message (no AI trailers)' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            "feat(iter-14.0): clean message`n`nDescription with no AI attribution." | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 0 -Because 'clean messages must pass'
        }

        It 'Accepts a commit that mentions "claude" in subject narrative (not a trailer)' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            # 'Claude' as a product name in narrative text without a Co-Authored-By trailer
            # is allowed (the connector itself may have legitimate references).
            "feat: add Claude SDK example to docs" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 0 -Because 'narrative mentions of Claude must not be blocked; only trailers + emails + Generated-with markers'
        }

        It 'Skips comment lines (lines starting with #) when scanning' -Skip:(-not $script:HasBash) {
            $msgFile = Join-Path $script:TempDir "msg-$(Get-Random).txt"
            # Git auto-adds # comment lines. Hook must skip them.
            "feat: thing`n`n# This commit was originally Co-Authored-By: Claude (now removed)`n# noreply@anthropic.com appears in this comment but is scrubbed" | Set-Content -LiteralPath $msgFile -Encoding ascii
            & $script:BashPath $script:VersionedHook $msgFile *> $null
            $LASTEXITCODE | Should -Be 0 -Because 'comment lines must be ignored (git appends them automatically and they are not part of the commit message)'
        }
    }
}
