#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0 GA Phase A.4 internal/external separation gate (per directive 27).

.DESCRIPTION
    Verifies that `git archive HEAD` (used by GitHub Releases for source-zip
    downloads + by some operators for offline mirroring) does NOT include any
    internal-dev artifacts. Defense-in-depth on top of:
      - .gitignore excluding .internal/ + .claude/ from version control
      - .gitattributes export-ignore on the same paths

    Without this gate, a maintainer could accidentally `git add` something
    under .internal/ and the leak would only be caught at release time.

    What MUST NOT appear in `git archive HEAD`:
      - .internal/                — design notes, dev tools, test fixtures
      - .claude/                   — agent plans + working notes
      - tests/.env.local           — local SP credentials (per directive 35)
      - *.passkey.json             — passkey JSON files
      - *.secret / *.key / *.pem   — any secret material
      - NOTES.local.md / TODO.local.md / .scratch/  — local working state

    Test runs `git archive HEAD --format=tar` + parses the file list.
    Skipped if not in a git repo or if git is unavailable.
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Set-Location -LiteralPath $script:RepoRoot
    $script:GitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $script:InGitRepo = $false
    if ($script:GitAvailable) {
        $null = git rev-parse --git-dir 2>$null
        $script:InGitRepo = ($LASTEXITCODE -eq 0)
    }
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

Describe 'Phase A.4: Internal/external separation — .gitattributes export-ignore' -Skip:(-not $script:InGitRepo) {
    BeforeAll {
        # Capture the file list that would ship via `git archive HEAD`.
        # Cross-platform: use --format=zip + System.IO.Compression to enumerate
        # entries (avoids tar incompatibility between Windows tar.exe and Git
        # Bash tar that interprets C: as a host).
        Push-Location -LiteralPath $script:RepoRoot
        try {
            $tempZip = [System.IO.Path]::GetTempFileName() + '.zip'
            try {
                # --worktree-attributes uses the WORKING TREE .gitattributes (not the HEAD-committed one)
                # so this test passes even when .gitattributes has been updated but not yet committed.
                # Production release.yml MUST also use --worktree-attributes OR ensure .gitattributes
                # is committed before release.
                $null = git archive HEAD --format=zip --worktree-attributes -o $tempZip 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git archive HEAD --format=zip failed"
                }
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zipFile = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
                try {
                    # ZIP entries use forward slashes; that's what we want.
                    $script:ArchivePaths = @($zipFile.Entries | Select-Object -ExpandProperty FullName)
                } finally {
                    $zipFile.Dispose()
                }
            } finally {
                if (Test-Path -LiteralPath $tempZip) {
                    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
                }
            }
        } finally {
            Pop-Location
        }
    }

    It '.gitattributes file exists at repo root' {
        $gaPath = Join-Path $script:RepoRoot '.gitattributes'
        Test-Path -LiteralPath $gaPath | Should -BeTrue -Because 'Phase A.1 created .gitattributes for export-ignore defense-in-depth'
    }

    It '.gitattributes declares .internal/ as export-ignore' {
        $gaPath = Join-Path $script:RepoRoot '.gitattributes'
        $content = Get-Content -Raw -Path $gaPath
        $content | Should -Match '(?m)^\.internal/\s+export-ignore' -Because 'must exclude internal-dev artifacts from git archive'
    }

    It '.gitattributes declares .claude/ as export-ignore' {
        $gaPath = Join-Path $script:RepoRoot '.gitattributes'
        $content = Get-Content -Raw -Path $gaPath
        $content | Should -Match '(?m)^\.claude/\s+export-ignore' -Because 'must exclude agent plans from git archive'
    }
}

Describe 'Phase A.4: git archive HEAD excludes internal-dev artifacts' -Skip:(-not $script:InGitRepo) {
    It 'No path under .internal/ in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object { $_ -match '^\.internal/' }
        $leaks | Should -BeNullOrEmpty -Because 'Phase A.4 separation: .internal/ MUST NOT ship in releases'
    }

    It 'No path under .claude/ in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object { $_ -match '^\.claude/' }
        $leaks | Should -BeNullOrEmpty -Because 'Phase A.4 separation: .claude/ MUST NOT ship in releases'
    }

    It 'No tests/.env.local file in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object { $_ -eq 'tests/.env.local' -or $_ -match '^tests/\.env\.[^/]+\.local$' }
        $leaks | Should -BeNullOrEmpty -Because 'local SP credentials MUST NOT ship'
    }

    It 'No *.passkey.json files in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object { $_ -match '\.passkey\.json$' }
        $leaks | Should -BeNullOrEmpty -Because 'passkey JSON files MUST NOT ship'
    }

    It 'No *.secret / *.key / *.pem / *.pfx files in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object { $_ -match '\.(secret|key|pem|pfx)$' }
        $leaks | Should -BeNullOrEmpty -Because 'secret material MUST NOT ship'
    }

    It 'No local working-state files in git archive output' {
        $leaks = $script:ArchivePaths | Where-Object {
            $_ -eq 'NOTES.local.md' -or
            $_ -eq 'TODO.local.md' -or
            $_ -match '^\.scratch/' -or
            $_ -eq '.protection-restore.json'
        }
        $leaks | Should -BeNullOrEmpty -Because 'local maintainer working-state MUST NOT ship'
    }
}

Describe 'Phase A.4: git archive HEAD INCLUDES required operator-facing artifacts' -Skip:(-not $script:InGitRepo) {
    It 'README.md is included' {
        $script:ArchivePaths | Should -Contain 'README.md'
    }

    It 'LICENSE is included' {
        $script:ArchivePaths | Should -Contain 'LICENSE'
    }

    It 'Top-level docs/ directory is included' {
        $hasDocs = @($script:ArchivePaths | Where-Object { $_ -match '^docs/[^/]+\.md$' }).Count -gt 0
        $hasDocs | Should -BeTrue -Because 'operator-facing docs MUST ship'
    }

    It 'src/ directory is included' {
        $hasSrc = @($script:ArchivePaths | Where-Object { $_ -match '^src/' }).Count -gt 0
        $hasSrc | Should -BeTrue -Because 'Function App source MUST ship'
    }

    It 'tools/ directory is included (operator-facing tools only)' {
        $hasTools = @($script:ArchivePaths | Where-Object { $_ -match '^tools/[^/]+\.ps1$' }).Count -gt 0
        $hasTools | Should -BeTrue -Because 'operator-facing tools MUST ship; .internal/tools/ stays excluded'
    }

    It 'sentinel/ directory is included' {
        $hasSentinel = @($script:ArchivePaths | Where-Object { $_ -match '^sentinel/' }).Count -gt 0
        $hasSentinel | Should -BeTrue -Because 'Sentinel content (workbooks/rules/parsers) MUST ship'
    }

    It 'deploy/ directory is included' {
        $hasDeploy = @($script:ArchivePaths | Where-Object { $_ -match '^deploy/' }).Count -gt 0
        $hasDeploy | Should -BeTrue -Because 'ARM template + Solution Gallery package MUST ship'
    }
}
