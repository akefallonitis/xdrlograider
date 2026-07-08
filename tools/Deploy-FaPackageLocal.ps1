#requires -Version 7.0
<#
.SYNOPSIS
  Path-① LOOP code deploy (plan §23): publish a locally-built function-app.zip to the live
  Function App WITHOUT the GA/marketplace release pipeline (no tag, no release.yml, no GitHub
  release). Release-independent. Standing-authorized as a live-FA cache-bust (plan §12/§23.1).

.DESCRIPTION
  The live FA is Linux Consumption (Dynamic) → it MUST run-from-package; ZipDeploy/config-zip are
  not viable. Storage shared-key is OFF (identity-based). So this tool:
    1. Builds function-app.zip locally (tools/Build-FunctionAppZip.ps1).
    2. Captures the CURRENT WEBSITE_RUN_FROM_PACKAGE (emits the exact revert command FIRST).
    3. Ensures the running principal has Storage Blob Data Contributor on the FA's storage account
       (self-grant via its User Access Administrator role if missing — additive leaf assignment).
    4. Uploads the zip to a self-hosted blob (OAuth --auth-mode login; shared-key-off-safe).
    5. Mints a user-delegation READ SAS (OAuth; no account key needed) for that blob.
    6. Sets WEBSITE_RUN_FROM_PACKAGE = <blob SAS URL> + XDRLR_GIT_COMMIT_SHA = <sha>.
    7. Restarts the FA (synchronous, NO --no-wait) and confirms state=Running.

  HARD CONSTRAINTS (plan §12/§23): touches ONLY a self-hosted blob + the FA appSetting + restart.
  It NEVER touches Microsoft.KeyVault/* or runs any ARM deployment. The SAS value is never echoed.

.PARAMETER GitSha
  Short SHA of HEAD being deployed (stamps XDRLR_GIT_COMMIT_SHA + names the blob for cache-bust).

.PARAMETER Execute
  Without it the tool is DRY-RUN: it prints every planned step + commands and mutates nothing.
  With it, the mutating steps run.

.NOTES
  Plan §23.2. KNOWN LIMITATION: user-delegation SAS max 7 days → re-deploy refreshes it (fine for
  the iteration loop; GA uses path ② release URL). Pester contract: 0-KV/0-ARM + dry-run path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{7,40}$')]
    [string] $GitSha,

    [Parameter()]
    [string] $ResourceGroup,                   # C-1: ← .env.local XDRLR_CONNECTOR_RG (or pass)

    [Parameter()]
    [string] $FunctionAppName,                 # C-1: ← .env.local XDRLR_FUNCTION_APP (or pass)

    [Parameter()]
    [string] $StorageAccount,                 # auto-discovered from the FA if omitted

    [Parameter()]
    [string] $Container = 'fa-releases',

    [Parameter()]
    [int] $SasDays = 6,                        # < 7 (user-delegation SAS hard cap)

    [Parameter()]
    [string] $ZipPath,                         # default: build it

    [switch] $Execute
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# C-1 (2026-06-18): resolve estate from .env.local (the established source) when not passed — no hardcoded maintainer default.
if (-not $ResourceGroup -or -not $FunctionAppName) {
    $envLocal = Join-Path $repoRoot '.env.local'
    if (Test-Path $envLocal) {
        $ev = @{}; Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $ev[$Matches[1]] = $Matches[2].Trim().Trim('"') } }
        if (-not $ResourceGroup)   { $ResourceGroup   = $ev['XDRLR_CONNECTOR_RG'] }
        if (-not $FunctionAppName) { $FunctionAppName = $ev['XDRLR_FUNCTION_APP'] }
    }
}
if (-not $FunctionAppName) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionAppName)' }
if (-not $ResourceGroup)   { throw 'XDRLR_CONNECTOR_RG missing from .env.local (or pass -ResourceGroup)' }

$mode = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }

function Write-Step  { param([string]$m) Write-Host "`n[Deploy-FaPackageLocal][$mode] $m" -ForegroundColor Cyan }
function Write-Plan  { param([string]$m) Write-Host "    would run: $m" -ForegroundColor DarkGray }
function Invoke-Az {
    param([string[]]$Args, [switch]$AllowFail)
    Write-Plan ("az " + ($Args -join ' '))
    if (-not $Execute) { return $null }
    $out = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "az $($Args -join ' ') failed (exit $LASTEXITCODE): $out"
    }
    return $out
}

# ── HARD GUARD: this tool must never touch KeyVault or run ARM ──────────────────
$selfText = Get-Content -LiteralPath $PSCommandPath -Raw
if ($selfText -match 'deployment\s+group\s+create' -or $selfText -match 'keyvault\s+(set|delete|purge)') {
    throw 'GUARD: Deploy-FaPackageLocal must not perform ARM deploys or KeyVault writes (plan §23.1).'
}

Write-Step "Path-① loop code deploy of $GitSha to $FunctionAppName (RG=$ResourceGroup). NO release/tag/GA."

# ── Step 0 · identity + subscription context ───────────────────────────────────
$acct = az account show -o json | ConvertFrom-Json
$subId = $acct.id
$principalId = $acct.user.name      # SP appId when logged in as the .env.local SP
Write-Host "    subscription=$($acct.name) ($subId)  principal=$principalId ($($acct.user.type))"

# ── Step 1 · build the package ─────────────────────────────────────────────────
Write-Step 'Step 1/7 · build function-app.zip'
if (-not $ZipPath) {
    $builder = Join-Path $repoRoot 'tools/Build-FunctionAppZip.ps1'
    if (-not (Test-Path $builder)) { throw "Builder missing: $builder" }
    Push-Location $repoRoot
    try { & pwsh -NoProfile -File $builder } finally { Pop-Location }
    $ZipPath = Join-Path $repoRoot 'function-app.zip'
}
if (-not (Test-Path $ZipPath)) { throw "function-app.zip not produced at $ZipPath" }
$zipInfo = Get-Item $ZipPath
$zipHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash
$sizeMb = [math]::Round($zipInfo.Length / 1MB, 2)
Write-Host "    zip: $ZipPath  size=${sizeMb}MB  sha256=$zipHash"
if ($sizeMb -gt 50) { throw "zip ${sizeMb}MB exceeds sanity cap (50MB)" }

# ── Step 2 · discover storage + CAPTURE current package (revert FIRST) ──────────
Write-Step 'Step 2/7 · capture current WEBSITE_RUN_FROM_PACKAGE (revert anchor)'
if (-not $StorageAccount) {
    $StorageAccount = (az functionapp config appsettings list -g $ResourceGroup -n $FunctionAppName `
        --query "[?name=='AzureWebJobsStorage__accountName'].value | [0]" -o tsv)
    if (-not $StorageAccount) { throw 'Could not discover AzureWebJobsStorage__accountName from the FA' }
}
$oldPkg = az functionapp config appsettings list -g $ResourceGroup -n $FunctionAppName `
    --query "[?name=='WEBSITE_RUN_FROM_PACKAGE'].value | [0]" -o tsv
$oldSha = az functionapp config appsettings list -g $ResourceGroup -n $FunctionAppName `
    --query "[?name=='XDRLR_GIT_COMMIT_SHA'].value | [0]" -o tsv
Write-Host "    storage=$StorageAccount  current XDRLR_GIT_COMMIT_SHA=$oldSha"
$oldPkgRedacted = if ($oldPkg -match '\?') { ($oldPkg -replace '\?.*$','?<token-redacted>') } else { $oldPkg }
Write-Host "    current WEBSITE_RUN_FROM_PACKAGE=$oldPkgRedacted"
Write-Host "`n    >>> REVERT (if needed): az functionapp config appsettings set -g $ResourceGroup -n $FunctionAppName --settings 'WEBSITE_RUN_FROM_PACKAGE=$oldPkg' 'XDRLR_GIT_COMMIT_SHA=$oldSha' --output none ; az functionapp restart -g $ResourceGroup -n $FunctionAppName" -ForegroundColor Yellow

# ── Step 3 · REQUIRE Storage Blob Data Contributor on the SA (least-privilege · NO self-escalation) ─
Write-Step 'Step 3/7 · verify Storage Blob Data Contributor on the storage account (tool never self-grants RBAC)'
$saScope = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccount"
$hasWrite = az role assignment list --assignee $principalId --all `
    --query "[?(roleDefinitionName=='Storage Blob Data Contributor' || roleDefinitionName=='Storage Blob Data Owner') && (scope=='$saScope' || contains(scope,'resourceGroups/$ResourceGroup'))].roleDefinitionName | [0]" -o tsv 2>$null
if ($hasWrite) {
    Write-Host "    OK · principal holds '$hasWrite' (blob-write present)"
} else {
    throw @"
BLOCKED (least-privilege · plan §23): the deploy principal $principalId lacks blob-write on $StorageAccount.
This tool does NOT self-escalate RBAC. Grant it ONCE (operator) then re-run:
  az role assignment create --assignee $principalId --role 'Storage Blob Data Contributor' --scope $saScope
"@
}

# ── Step 4 · upload the package to a self-hosted blob (OAuth) ───────────────────
Write-Step 'Step 4/7 · upload package blob (OAuth · shared-key-off-safe)'
$blobName = "function-app-$GitSha.zip"
Invoke-Az @('storage','container','create','--auth-mode','login','--account-name',$StorageAccount,'--name',$Container,'--output','none') -AllowFail
Invoke-Az @('storage','blob','upload','--auth-mode','login','--account-name',$StorageAccount,'--container-name',$Container,'--name',$blobName,'--file',$ZipPath,'--overwrite','--output','none')

# ── Step 5 · mint a user-delegation READ SAS (no account key) ───────────────────
Write-Step 'Step 5/7 · user-delegation READ SAS for the blob'
$start  = (Get-Date).ToUniversalTime().AddMinutes(-15).ToString('yyyy-MM-ddTHH:mm:ssZ')
$expiry = (Get-Date).ToUniversalTime().AddDays($SasDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
$pkgUrl = $null
if ($Execute) {
    $sas = az storage blob generate-sas --auth-mode login --as-user `
        --account-name $StorageAccount --container-name $Container --name $blobName `
        --permissions r --start $start --expiry $expiry --https-only -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $sas) { throw 'user-delegation SAS generation failed' }
    $pkgUrl = "https://$StorageAccount.blob.core.windows.net/$Container/$blobName`?$sas"
    Write-Host "    SAS minted (expiry=$expiry) · URL=https://$StorageAccount.blob.core.windows.net/$Container/$blobName`?<sas-redacted>"
} else {
    Write-Plan "storage blob generate-sas --auth-mode login --as-user --account-name $StorageAccount --container-name $Container --name $blobName --permissions r --expiry $expiry --https-only"
    Write-Host "    (dry-run) package URL = https://$StorageAccount.blob.core.windows.net/$Container/$blobName?<sas>"
}

# ── Step 6 · repoint WEBSITE_RUN_FROM_PACKAGE + stamp the SHA ───────────────────
Write-Step 'Step 6/7 · set WEBSITE_RUN_FROM_PACKAGE (self-hosted) + XDRLR_GIT_COMMIT_SHA'
if ($Execute) {
    # pass the SAS-bearing URL without echoing it
    az functionapp config appsettings set -g $ResourceGroup -n $FunctionAppName `
        --settings "WEBSITE_RUN_FROM_PACKAGE=$pkgUrl" "XDRLR_GIT_COMMIT_SHA=$GitSha" --output none
    if ($LASTEXITCODE -ne 0) { throw "appsettings set failed (exit $LASTEXITCODE)" }
    Write-Host '    appsettings updated (package URL set · SAS not echoed)'
} else {
    Write-Plan "functionapp config appsettings set -g $ResourceGroup -n $FunctionAppName --settings WEBSITE_RUN_FROM_PACKAGE=<blob-sas-url> XDRLR_GIT_COMMIT_SHA=$GitSha"
}

# ── Step 7 · restart (sync) + confirm Running ──────────────────────────────────
Write-Step 'Step 7/7 · restart (synchronous · NO --no-wait) + confirm state=Running'
Invoke-Az @('functionapp','restart','-g',$ResourceGroup,'-n',$FunctionAppName,'--output','none')
if ($Execute) {
    $state = ''; $waited = 0
    while ($waited -lt 180) {
        $state = az functionapp show -g $ResourceGroup -n $FunctionAppName --query state -o tsv 2>$null
        if ($state -eq 'Running') { break }
        Start-Sleep -Seconds 10; $waited += 10
    }
    if ($state -ne 'Running') { throw "FA did not reach Running within ${waited}s (last=$state)" }
    Write-Host "    state=Running after ${waited}s"
}

Write-Host "`n[Deploy-FaPackageLocal][$mode] DONE. FA $FunctionAppName now pinned to $GitSha via self-hosted package." -ForegroundColor Green
if (-not $Execute) { Write-Host '    (DRY-RUN — nothing was changed. Re-run with -Execute to apply.)' -ForegroundColor Yellow }
Write-Host '    NEXT: Verify-DeployedConnector (Cycle.Completed>0 · 0 AppExceptions · reauth self-heals) before schema sync.' -ForegroundColor Green
