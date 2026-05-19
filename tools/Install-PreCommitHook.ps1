#Requires -Version 7.4
<#
.SYNOPSIS
    One-time installer · writes .git/hooks/pre-commit shim invoking Hook-PreCommit.ps1.

.DESCRIPTION
    .git/hooks/ is local-only (NOT version-controlled). Operators run this script
    once after cloning to enable the methodology pre-commit gate (S-1 from the
    v0.1.0 P0 v2 RESET plan).

    The installed shim is a POSIX shell script that invokes pwsh to run
    tools/Hook-PreCommit.ps1 with the staged commit message path. Works on
    Linux/macOS (chmod +x) and Windows (Git for Windows ships a POSIX shell).

.PARAMETER Force
    Overwrite an existing .git/hooks/pre-commit without prompting.

.EXAMPLE
    pwsh tools/Install-PreCommitHook.ps1

.EXAMPLE
    pwsh tools/Install-PreCommitHook.ps1 -Force

.NOTES
    Idempotent: re-running detects an already-installed Xdr shim and exits with
    a notice. Use -Force to refresh.

    Internal spec: Part VIII (S-1) · pre-commit hook installer spec.
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gitDir   = Join-Path $repoRoot '.git'
$hookDir  = Join-Path $gitDir 'hooks'
$hookPath = Join-Path $hookDir 'pre-commit'

if (-not (Test-Path $gitDir)) {
    throw "Install-PreCommitHook: '$gitDir' not found — must run from inside a git working tree."
}
if (-not (Test-Path $hookDir)) {
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
}

# Idempotency: detect existing Xdr shim
$xdrSignature = '# Xdr Hook-PreCommit shim · v0.1.0 P0 v2 RESET'
if ((Test-Path $hookPath) -and -not $Force) {
    $existing = Get-Content -Raw -Path $hookPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Contains($xdrSignature)) {
        Write-Host "Install-PreCommitHook: Xdr shim already installed at '$hookPath' (use -Force to refresh)" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "Install-PreCommitHook: non-Xdr pre-commit hook exists at '$hookPath'" -ForegroundColor Yellow
    Write-Host "  Re-run with -Force to overwrite, or back it up first." -ForegroundColor Yellow
    exit 1
}

# Build POSIX shell shim — repo-relative pwsh invocation
$shimContent = @'
#!/bin/sh
# Xdr Hook-PreCommit shim · v0.1.0 P0 v2 RESET
# Installed by: pwsh tools/Install-PreCommitHook.ps1
# Invokes: pwsh tools/Hook-PreCommit.ps1 -CommitMsgPath .git/COMMIT_EDITMSG
#
# Bypass (METHODOLOGY VIOLATION · operator approval required):
#   git commit --no-verify
#
# Configuration via env vars:
#   XDR_HOOK_SKIP_T1=1   skip T1 unit tests (recovery scenarios only)
#   XDR_HOOK_T3_HOURS=N  override default 24h T3-LIVE freshness window

set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_SCRIPT="$REPO_ROOT/tools/Hook-PreCommit.ps1"

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "Xdr Hook-PreCommit shim: '$HOOK_SCRIPT' not found"
    echo "Re-install with: pwsh tools/Install-PreCommitHook.ps1 -Force"
    exit 1
fi

EXTRA_ARGS=""
if [ -n "$XDR_HOOK_SKIP_T1" ] && [ "$XDR_HOOK_SKIP_T1" != "0" ]; then
    EXTRA_ARGS="$EXTRA_ARGS -SkipT1"
fi
if [ -n "$XDR_HOOK_T3_HOURS" ]; then
    EXTRA_ARGS="$EXTRA_ARGS -MaxT3AgeHours $XDR_HOOK_T3_HOURS"
fi

# shellcheck disable=SC2086
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOOK_SCRIPT" -CommitMsgPath "$REPO_ROOT/.git/COMMIT_EDITMSG" $EXTRA_ARGS
'@

Set-Content -Path $hookPath -Value $shimContent -NoNewline -Encoding ascii

# chmod +x on Unix-ish hosts (Windows: Git for Windows handles execute bit via .gitattributes / core.filemode)
if ($IsLinux -or $IsMacOS) {
    & chmod +x $hookPath 2>$null
}

Write-Host "Install-PreCommitHook: shim installed at '$hookPath'" -ForegroundColor Green
Write-Host ""
Write-Host "Next: try a commit — the hook will run pwsh tools/Hook-PreCommit.ps1 automatically." -ForegroundColor Cyan
Write-Host "Bypass (METHODOLOGY VIOLATION):  git commit --no-verify" -ForegroundColor Yellow
