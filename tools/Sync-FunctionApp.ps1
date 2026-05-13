<#
.SYNOPSIS
    Operator-side helper: forces the deployed Function App to pull the latest
    GitHub release of function-app.zip.

.DESCRIPTION
    Background: the ARM template sets WEBSITE_RUN_FROM_PACKAGE to the GitHub
    release URL (default `https://github.com/<owner>/<repo>/releases/<releaseTag>/download/function-app.zip`,
    where `releaseTag=latest` resolves to a 302 redirect to the most-recent
    release).

    The Function App fetches the zip on cold-start and caches it. A running
    FA does NOT automatically detect that a new release was published — the
    underlying URL is stable. To pick up a new release, the FA needs to
    restart (which forces a fresh fetch).

    This script: queries the GitHub Releases API for the latest tag, checks
    if it differs from the FA's currently-deployed CONNECTOR_VERSION app
    setting, and triggers `az functionapp restart` only when there's a real
    new release. Idempotent — safe to run repeatedly or on a schedule (Azure
    Automation runbook, cron, Logic App, etc.).

.PARAMETER ResourceGroup
    Resource group of the deployed Function App.

.PARAMETER GithubRepo
    Owner/repo for the connector source. Default: akefallonitis/xdrlograider.

.PARAMETER Force
    Restart the FA even if the GitHub latest tag matches the deployed
    CONNECTOR_BUILD_ID. Useful for cache-bust if the FA is stuck on a
    corrupt download.

.EXAMPLE
    # On-demand operator sync
    pwsh ./tools/Sync-FunctionApp.ps1 -ResourceGroup xdrlr-prod-rg

.EXAMPLE
    # Schedule via Azure Automation runbook (every 6h) — recurring auto-update
    Schedule-AzAutomationRunbook -Name 'XdrLogRaider-Sync' -ResourceGroupName <auto-rg> ...

.OUTPUTS
    Object with Tag (latest GitHub release), Deployed (FA's current
    CONNECTOR_BUILD_ID), Action ('restart' | 'skip').
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $GithubRepo = 'akefallonitis/xdrlograider',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# az CLI session check
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { Write-Error "Run 'az login' first."; exit 1 }

# Locate the FA in the RG (assumes 1 FA per RG, matching the ARM template's pattern)
$fa = az resource list -g $ResourceGroup --resource-type Microsoft.Web/sites --query "[0].name" -o tsv 2>$null
if (-not $fa) {
    Write-Error "No Microsoft.Web/sites resource in resource group '$ResourceGroup'. Has the connector been deployed?"
    exit 1
}
Write-Host "Function App: $fa" -ForegroundColor Cyan

# Query GitHub Releases API for the latest tag
$latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$GithubRepo/releases/latest" -Headers @{ 'User-Agent' = 'XdrLogRaider-Sync' }
$latestTag = [string]$latest.tag_name
if ([string]::IsNullOrWhiteSpace($latestTag)) {
    Write-Error "GitHub did not return a tag for the latest release. Repo: $GithubRepo"
    exit 1
}
Write-Host "Latest release tag on GitHub: $latestTag" -ForegroundColor Cyan

# Read the FA's current CONNECTOR_BUILD_ID (set by the ARM template at deploy time)
$deployed = az functionapp config appsettings list -g $ResourceGroup -n $fa --query "[?name=='CONNECTOR_BUILD_ID'].value" -o tsv 2>$null
Write-Host "Deployed CONNECTOR_BUILD_ID: $deployed" -ForegroundColor Cyan

if (-not $Force -and $deployed -eq $latestTag) {
    Write-Host "Already on latest — no action." -ForegroundColor Green
    return [pscustomobject]@{ Tag = $latestTag; Deployed = $deployed; Action = 'skip' }
}

Write-Host "Restarting Function App to pick up release $latestTag..." -ForegroundColor Yellow
az functionapp restart -g $ResourceGroup -n $fa | Out-Null

# After restart the FA fetches function-app.zip from `releases/<releaseTag>/download/...`.
# If the operator deployed with releaseTag='latest', the URL itself is stable but
# GitHub now redirects it at the new release's content. If the operator pinned a
# specific releaseTag, they need to redeploy the ARM template with the new tag
# instead — restart alone won't change the URL.
Write-Host "Restart issued. The Function App will fetch the new package on its next cold-start." -ForegroundColor Green
Write-Host "Note: if you deployed with a pinned releaseTag (not 'latest'), restart alone won't switch versions." -ForegroundColor DarkYellow
Write-Host "      Either redeploy the ARM template with the new tag, or update the WEBSITE_RUN_FROM_PACKAGE app setting." -ForegroundColor DarkYellow

return [pscustomobject]@{ Tag = $latestTag; Deployed = $deployed; Action = 'restart' }
