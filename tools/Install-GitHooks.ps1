<#
.SYNOPSIS
    Installs the versioned git hooks from tools/git-hooks/ into .git/hooks/.

.DESCRIPTION
    The .git/hooks/ directory is local to each clone (not versioned by git).
    Versioned hook scripts live under tools/git-hooks/. This helper copies
    those scripts into .git/hooks/ so they take effect for the local clone.

    Re-run after cloning the repo or after pulling repo changes that update
    the hooks under tools/git-hooks/.

    Currently installs:
      - commit-msg (blocks AI-attribution trailer leaks before they reach git history)

.PARAMETER Force
    Overwrite existing hooks even if their content already matches the
    versioned copy.

.EXAMPLE
    PS> ./tools/Install-GitHooks.ps1
    [install] commit-msg

.EXAMPLE
    PS> ./tools/Install-GitHooks.ps1 -Force
    [update]  commit-msg
#>
[CmdletBinding()]
param(
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..')
$versionedDir = Join-Path $repoRoot 'tools' 'git-hooks'
$localDir     = Join-Path $repoRoot '.git' 'hooks'

if (-not (Test-Path -LiteralPath $localDir)) {
    throw "Not a git repository (no .git/hooks/ at $localDir). Run from a clone of the repo."
}

if (-not (Test-Path -LiteralPath $versionedDir)) {
    throw "No versioned hooks directory at $versionedDir."
}

$hooks = Get-ChildItem -LiteralPath $versionedDir -File -ErrorAction Stop
if ($hooks.Count -eq 0) {
    Write-Warning "No hook scripts found in $versionedDir."
    return
}

foreach ($hook in $hooks) {
    $target = Join-Path $localDir $hook.Name
    if ((Test-Path -LiteralPath $target) -and -not $Force.IsPresent) {
        $existing = Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue
        $new      = Get-Content -LiteralPath $hook.FullName -Raw
        if ($existing -eq $new) {
            Write-Host "[skip]    $($hook.Name) (already up-to-date)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "[update]  $($hook.Name)" -ForegroundColor Yellow
    } else {
        Write-Host "[install] $($hook.Name)" -ForegroundColor Green
    }

    Copy-Item -LiteralPath $hook.FullName -Destination $target -Force

    # On Unix-like hosts, ensure +x. Windows git uses .gitattributes for the bit.
    if ($IsLinux -or $IsMacOS) {
        & chmod '+x' $target | Out-Null
    }
}

Write-Host ""
Write-Host "Git hooks installed under .git/hooks/." -ForegroundColor Cyan
Write-Host "Verify: .git/hooks/commit-msg should exist and be executable." -ForegroundColor Cyan
