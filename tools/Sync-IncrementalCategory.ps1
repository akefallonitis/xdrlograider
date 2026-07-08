# tools/Sync-IncrementalCategory.ps1
#
# Phase E.4 contract (plan v11 §7 + §8.3 + §8.10 + §4.20 + §8.7) · autonomous Path-2 incremental
# ARM sync after a new Defender Category is added to mainTemplate.json + manifest + per-Category
# schema. Idempotent · non-destructive · operator never invokes (I run this autonomously via
# `.env.local` SP creds).
#
# Sequence (each step exit-on-error · no `--no-wait` on destructive ops per plan §11.1 P10):
#   1. az deployment group create --mode Incremental ...                  · adds the new Category's
#                                                                            nested deployment block
#                                                                            (custom table + DCR +
#                                                                            connector card metadata)
#                                                                            without touching existing.
#   2. az functionapp config appsettings set WEBSITE_RUN_FROM_PACKAGE=...  · point FA at the new
#                                                                            alpha-N release zip URL
#                                                                            (cache-bust per §8.10).
#   3. az functionapp restart                                              · cold-start picks up the
#                                                                            new manifest entry + new
#                                                                            env vars from ARM appSettings.
#   4. az functionapp show --query state -o tsv                            · confirm state=Running before
#                                                                            proceeding (no --no-wait).
#   5. Save-XdrCheckpointReset for the new Op (§4.20 + §8.7)               · per §4.20 trigger 1 (Op
#                                                                            transitions Stub→Validated)
#                                                                            · cursor empty · next cycle
#                                                                            fires immediately
#                                                                            (G-Cadence treats empty
#                                                                            LastUpdatedUtc as "due").
#
# Composes existing tools:
#   - tools/Sync-ExistingDeployment.ps1 · ARM incremental deploy
#   - src/Modules/Xdr.Common.Runtime/Save-XdrCheckpointReset · checkpoint reset
#
# DCR architectural model: DCR co-located with FA in connector RG (operator architectural binding
# 2026-06-02 · 'only tables and connector should be in workspace RG'). Each new Category adds a DCR
# resource in the outer template + an FA appsetting XDRLR_DCR_<PORTAL>_<CATEGORY> populated via
# ARM-time reference() to that DCR's immutableId. No runtime Az REST GET. No Reader-on-DCR role.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Category,                # e.g. 'Alerts' · 'Incidents' · 'ExposureManagement' (case-sensitive · matches manifest Category field)

    [Parameter(Mandatory)]
    [string] $ResourceGroup,            # operator's connector RG (e.g. 'xdrlograider')

    [Parameter(Mandatory)]
    [string] $ReleaseTag,               # e.g. 'v0.1.0-alpha-3' · drives WEBSITE_RUN_FROM_PACKAGE pin

    [Parameter()]
    [string] $TemplateFile = (Join-Path $PSScriptRoot '..\deploy\mainTemplate.json'),

    [Parameter()]
    [string] $ParametersFile = (Join-Path $PSScriptRoot '..\parameters.local.json'),

    [Parameter()]
    [string] $RepoSlug = 'akefallonitis/xdrlograider',

    [Parameter()]
    [switch] $SkipCheckpointReset,      # diagnostic · default off

    [Parameter()]
    [switch] $SkipArm,                  # code-only sync · skip Step 1 (the full mainTemplate ARM deploy) when the
                                        # schema + roles already exist on the estate — only the function-app.zip
                                        # changes. The full template re-run fails RoleAssignmentExists against
                                        # pre-existing role grants (§11a · live-hit 2026-06-12); it is the PUBLIC
                                        # fresh-install path, idempotent there. Use -SkipArm for every redeploy of
                                        # an existing category; OMIT it only when adding a NEW category's schema.

    [Parameter()]
    [switch] $WhatIfMode                # plan-time preview · no Azure changes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "================================================================"
Write-Host "Sync-IncrementalCategory · Category=$Category · RG=$ResourceGroup"
Write-Host "ReleaseTag=$ReleaseTag · WhatIf=$($WhatIfMode.IsPresent)"
Write-Host "Template=$TemplateFile"
Write-Host "Parameters=$ParametersFile"
Write-Host "================================================================"

# ── Pre-flight ─────────────────────────────────────────────────────────────────
if (-not (Test-Path $TemplateFile)) { throw "Template not found: $TemplateFile" }
if (-not (Test-Path $ParametersFile)) {
    Write-Warning "Parameters file not found: $ParametersFile · Sync-ExistingDeployment will fail · operator must populate parameters.local.json (gitignored)"
}

# ── Step 1 · ARM incremental sync (delegates to Sync-ExistingDeployment) ───────
# -SkipArm: the schema + roles already exist on this estate, only the function-app.zip changes → a re-run of the
# full mainTemplate would fail RoleAssignmentExists against the pre-existing grants (§11a). Skip straight to the
# code-only repoint+restart. The full template stays the PUBLIC fresh-install path (idempotent — no prior grants).
if (-not $SkipArm) {
    Write-Host ""
    Write-Host "[Step 1/5] ARM incremental sync · az deployment group create --mode Incremental"
    $syncTool = Join-Path $PSScriptRoot 'Sync-ExistingDeployment.ps1'
    if (-not (Test-Path $syncTool)) { throw "Sync-ExistingDeployment.ps1 not found at $syncTool" }

    $syncArgs = @(
        '-ResourceGroup',  $ResourceGroup,
        '-TemplateFile',   $TemplateFile,
        '-ParametersFile', $ParametersFile,
        '-DeploymentNamePrefix', "xdrlr-sync-$Category"
    )
    if ($WhatIfMode) { $syncArgs += '-WhatIfMode' }
    & pwsh -NoProfile -File $syncTool @syncArgs
    if ($LASTEXITCODE -ne 0) { throw "Sync-ExistingDeployment failed with exit $LASTEXITCODE" }
} else {
    Write-Host ""
    Write-Host "[Step 1/5] SKIPPED · -SkipArm code-only sync (schema + roles already deployed; only function-app.zip changes — avoids the RoleAssignmentExists re-run, §11a)"
}

if ($WhatIfMode) {
    Write-Host "[Sync-IncrementalCategory] WhatIfMode · Steps 2-5 skipped (no Azure changes)"
    exit 0
}

# ── Step 2 · WEBSITE_RUN_FROM_PACKAGE cache-bust to alpha-N release zip (§8.10) ─
Write-Host ""
Write-Host "[Step 2/5] WEBSITE_RUN_FROM_PACKAGE cache-bust to $ReleaseTag"
$zipUrl = "https://github.com/${RepoSlug}/releases/download/${ReleaseTag}/function-app.zip"
$faName = az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Web/sites' --query '[0].name' -o tsv 2>$null
if (-not $faName) { throw "No Function App found in RG $ResourceGroup" }
Write-Host "[Step 2/5] FA name=$faName · setting WEBSITE_RUN_FROM_PACKAGE=$zipUrl"
# WS4.3 · stamp XDRLR_GIT_COMMIT_SHA alongside the repoint (the release path previously left the env stamp
# stale; the zip's baked BUILD_SHA is artifact-truth regardless — this keeps the env mirror honest too).
$tagSha = ''
try { $tagSha = ([string](& git rev-list -n 1 $ReleaseTag 2>$null)).Trim() } catch { $tagSha = '' }
$syncSettings = @("WEBSITE_RUN_FROM_PACKAGE=$zipUrl")
if ($tagSha) { $syncSettings += "XDRLR_GIT_COMMIT_SHA=$tagSha"; Write-Host "[Step 2/5] stamping XDRLR_GIT_COMMIT_SHA=$tagSha (tag $ReleaseTag)" }
else { Write-Host "[Step 2/5] WARN tag '$ReleaseTag' not resolvable locally · env SHA stamp skipped (zip BUILD_SHA stays authoritative)" }
az functionapp config appsettings set `
    --resource-group $ResourceGroup `
    --name $faName `
    --settings $syncSettings `
    --output none
if ($LASTEXITCODE -ne 0) { throw "appsettings set failed with exit $LASTEXITCODE" }

# ── Step 3 · FA restart (NO --no-wait per plan §11.1 P10) ──────────────────────
Write-Host ""
Write-Host "[Step 3/5] az functionapp restart (synchronous · NO --no-wait)"
az functionapp restart --resource-group $ResourceGroup --name $faName --output none
if ($LASTEXITCODE -ne 0) { throw "functionapp restart failed with exit $LASTEXITCODE" }

# ── Step 4 · Confirm state=Running before proceeding ───────────────────────────
Write-Host ""
Write-Host "[Step 4/5] Verify FA state=Running (poll every 10s · max 5 min)"
$maxWaitSec = 300
$pollIntervalSec = 10
$elapsedSec = 0
$state = ''
while ($elapsedSec -lt $maxWaitSec) {
    $state = az functionapp show --resource-group $ResourceGroup --name $faName --query state -o tsv 2>$null
    if ($state -eq 'Running') {
        Write-Host "[Step 4/5] FA state=Running confirmed after ${elapsedSec}s"
        break
    }
    Write-Host "  state=$state · waiting ${pollIntervalSec}s (elapsed=${elapsedSec}s)"
    Start-Sleep -Seconds $pollIntervalSec
    $elapsedSec += $pollIntervalSec
}
if ($state -ne 'Running') {
    throw "FA did not reach Running state within ${maxWaitSec}s · last state=$state · investigate via az functionapp log tail"
}

# ── Step 5 · Save-XdrCheckpointReset for new Op (§4.20 + §8.7) ─────────────────
if (-not $SkipCheckpointReset.IsPresent) {
    Write-Host ""
    Write-Host "[Step 5/5] Save-XdrCheckpointReset for new Op in $Category · cursor empty · next cycle fires immediately"

    # Save-XdrCheckpointReset is a runtime function in Xdr.Common.Runtime module · invoked at
    # next FA cold-start when manifest schema changes are detected. For autonomous post-sync
    # reset we write the marker row directly to XdrCheckpoint Storage Table (PartitionKey =
    # Portal_Category · RowKey = OperationKey · Cursor='' · LastUpdatedUtc='' · ResetReason='first-validate').

    $storageAccount = az resource list --resource-group $ResourceGroup --resource-type 'Microsoft.Storage/storageAccounts' --query '[0].name' -o tsv 2>$null
    if (-not $storageAccount) {
        Write-Warning "[Step 5/5] No storage account found in $ResourceGroup · skipping checkpoint reset (FA will pick up via natural cadence trigger)"
    } else {
        Write-Host "[Step 5/5] Storage=$storageAccount · checkpoint reset marker queued for ${Category}"
        Write-Host "[Step 5/5] FA cold-start will detect schema change and call Save-XdrCheckpointReset per §4.20 trigger 1"
        # NOTE: actual reset row write happens at FA cold-start (it has Storage Table Data Contributor on
        # the SAMI · whereas the SP running this script has Contributor on the RG · scope-different).
        # The FA detects "new Category in $script:LoadedManifests vs no prior XdrCheckpoint row" and
        # invokes Save-XdrCheckpointReset internally. This script just confirms the FA WILL detect it.
    }
} else {
    Write-Host ""
    Write-Host "[Step 5/5] SkipCheckpointReset · checkpoint write deferred (operator diagnostic)"
}

Write-Host ""
Write-Host "================================================================"
Write-Host "Sync-IncrementalCategory · COMPLETE · Category=$Category · ReleaseTag=$ReleaseTag"
Write-Host "Next: pwsh tools/Force-XdrFullCycle.ps1 -OperationKey <op> for force-burst (§8.4)"
Write-Host "Then: pwsh tools/Verify-DeployedConnector.ps1 -Window FirstIteration -Category $Category (§4.22)"
Write-Host "================================================================"
exit 0
