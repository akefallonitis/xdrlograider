#Requires -Version 7.4
<#
.SYNOPSIS
Git PRE-PUSH hook (structural gate G8) · runs Run-PrePushGauntlet and BLOCKS the push on ANY failure.

.DESCRIPTION
The gauntlet is the offline-provable RED-able gate (parse · analyzer · Pester · manifest/schema regen→diff ·
exactly-once replay · ARM validate · …). Before this hook it was OPT-IN — nothing ran it automatically, so an
offline-red change could be pushed (the M1 disease). This hook makes it MANDATORY at `git push`: non-zero gauntlet
exit aborts the push.

Install via tools/hooks/Install-GitHooks.ps1 (writes a `.git/hooks/pre-push` sh shim that execs this script).
Bypassing the hook (`git push --no-verify`) is a BANNED operator action (plan §H locks).

Exit: 0 → gauntlet GREEN, push proceeds. Non-zero → BLOCK (fix the failing axis + re-run; never --no-verify).
#>
[CmdletBinding()]
param(
    # git invokes the pre-push hook with positional args `<remote-name> <remote-url>` (and ref updates on stdin).
    # Accept + ignore them so `pwsh -File Hook-PrePush.ps1 origin <url>` binds cleanly — the hook's only job is to run
    # the gauntlet. Without this catch-all, bare param() rejected 'origin' and ABORTED every push (NOT a --no-verify).
    [Parameter(ValueFromRemainingArguments = $true)] $GitPushArgs
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$gauntlet = Join-Path $repo 'tools/Run-PrePushGauntlet.ps1'
if (-not (Test-Path $gauntlet)) {
    Write-Host "[Hook-PrePush] BLOCK · gauntlet not found: $gauntlet" -ForegroundColor Red
    exit 1
}
Write-Host "[Hook-PrePush] running Run-PrePushGauntlet · the push BLOCKS on any failure ..."
& pwsh -NoProfile -File $gauntlet
$code = $LASTEXITCODE
if ($code -ne 0) {
    Write-Host "[Hook-PrePush] BLOCK · gauntlet exit=$code · push aborted. Fix the failing axis and re-run — NEVER bypass with --no-verify." -ForegroundColor Red
    exit $code
}
Write-Host "[Hook-PrePush] gauntlet GREEN · push allowed." -ForegroundColor Green
exit 0
