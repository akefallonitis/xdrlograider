#Requires -Version 7.4
<#
.SYNOPSIS
    Refresh SHA pins for third-party GitHub Actions in .github/workflows/release.yml.

.DESCRIPTION
    Pinning third-party actions to immutable commit SHAs (instead of floating major tags
    like @v4 / @v3 / @v2) is a supply-chain hardening best practice — the upstream
    maintainer cannot silently change the action by re-tagging.

    Trade-off: SHAs go stale. New action releases require manual refresh.

    This tool reads .github/workflows/release.yml, finds every `uses: <owner>/<repo>@<sha>`
    line, looks up the LATEST commit SHA for the action's tracked major version, and
    optionally updates the workflow.

.PARAMETER WhatIf
    Show what would change without writing.

.PARAMETER WorkflowPath
    Path to release.yml. Default: .github/workflows/release.yml from repo root.

.EXAMPLE
    pwsh tools/Update-PinnedSHAs.ps1 -WhatIf

.EXAMPLE
    pwsh tools/Update-PinnedSHAs.ps1

.NOTES
    Internal spec: Part XI (Π11.5f) supply-chain hardening.
    Run monthly OR after security advisory on any pinned action.
    Requires `gh` CLI authenticated.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkflowPath = (Join-Path $PSScriptRoot '..' '.github' 'workflows' 'release.yml')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "Update-PinnedSHAs requires the GitHub CLI (gh) installed and authenticated."
}

$workflowAbs = (Resolve-Path $WorkflowPath).Path
Write-Host "Reading workflow: $workflowAbs" -ForegroundColor Cyan

$content = Get-Content -Raw -LiteralPath $workflowAbs

# Track which (owner/repo, intended-major-tag, current-sha) tuples are pinned.
# Workflow format we manage:  uses: <owner>/<repo>@<40-char-sha>  # <intent-tag>
$rx = '(?m)^(\s*uses:\s*)([^/\s]+/[^@\s]+)@([0-9a-f]{40})(\s*#\s*([^\r\n]+))?'
$matches = [regex]::Matches($content, $rx)

if ($matches.Count -eq 0) {
    Write-Warning "No pinned actions found in $workflowAbs. Expected format: 'uses: owner/repo@<40-char-sha>  # vN'"
    return
}

$updates = @()
foreach ($m in $matches) {
    $repo       = $m.Groups[2].Value
    $currentSha = $m.Groups[3].Value
    $intentTag  = if ($m.Groups[5].Success) { $m.Groups[5].Value.Trim() } else { $null }

    if (-not $intentTag) {
        Write-Warning "$repo pinned to $currentSha but no '# vN' intent comment · skipping (cannot resolve intended major version)"
        continue
    }

    Write-Host ("`nChecking {0} @{1}..." -f $repo, $intentTag) -ForegroundColor DarkCyan
    try {
        $latestSha = (gh api "repos/$repo/git/refs/tags/$intentTag" --jq '.object.sha' 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($latestSha) -or $latestSha.Length -ne 40) {
            Write-Warning "  Could not resolve $repo@$intentTag (gh returned: '$latestSha')"
            continue
        }
    } catch {
        Write-Warning "  Lookup failed for $repo@$intentTag · $($_.Exception.Message)"
        continue
    }

    if ($latestSha -eq $currentSha) {
        Write-Host "  $repo @$intentTag is up to date: $currentSha" -ForegroundColor Green
        continue
    }

    Write-Host ("  UPDATE: {0} @{1}" -f $repo, $intentTag) -ForegroundColor Yellow
    Write-Host ("    old: {0}" -f $currentSha)
    Write-Host ("    new: {0}" -f $latestSha)
    $updates += [pscustomobject]@{
        Repo      = $repo
        IntentTag = $intentTag
        OldSha    = $currentSha
        NewSha    = $latestSha
    }
}

if ($updates.Count -eq 0) {
    Write-Host "`nAll pinned actions are up to date. No changes needed." -ForegroundColor Green
    return
}

Write-Host ("`n{0} action(s) need updating" -f $updates.Count) -ForegroundColor Yellow

if (-not $PSCmdlet.ShouldProcess($workflowAbs, "Apply $($updates.Count) SHA-pin updates")) {
    Write-Host "Dry-run · workflow NOT modified." -ForegroundColor Yellow
    return
}

# Apply substitutions
foreach ($u in $updates) {
    # Replace the SHA but preserve indentation and the # comment
    $needle = "$($u.Repo)@$($u.OldSha)"
    $replacement = "$($u.Repo)@$($u.NewSha)"
    $content = $content.Replace($needle, $replacement)
}

Set-Content -LiteralPath $workflowAbs -Value $content -Encoding utf8 -NoNewline
Write-Host "`nWorkflow updated. Review the diff and commit." -ForegroundColor Green
Write-Host "  git diff $workflowAbs" -ForegroundColor DarkGray
