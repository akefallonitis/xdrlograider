#Requires -Version 7.4
<#
.SYNOPSIS
FH-6 · postdeploy ENFORCEMENT — runs the full postdeploy verify chain LOCALLY and, ONLY on a green result, records a
per-SHA pass by posting a GitHub commit status (default context: postdeploy/verified = success). release.yml refuses to
build / sign / publish a SHA that has no green postdeploy/verified status, so a LIVE-only defect (cross-cycle duplicate ·
DCR-403 0-rows · cadence / auth / version regression) can NEVER reach a published release. The cutover tools CALL this on
success so the chain cannot be skipped — the status is posted ONLY by an actual passing verify run, never by hand.

.DESCRIPTION
HARD LOCAL-ONLY (security lock · identical to Verify-XdrLiveContent): the chain runs the service-account content verify,
so the service account must NEVER authenticate in CI. Refuses under $CI / $GITHUB_ACTIONS (exit 2). The release-side CHECK
(merely READING the status) is the only CI-safe half and lives in release.yml + post-deploy-gate.yml.

Chain (fail-fast · each a child process · exit = the failing stage's own code):
  1. Run-PostDeployVerify  — version(==HEAD) -> estate/parity -> connector(per-op pop/exactly-once/cadence/health/D12) -> content
  2. Test-GaReadiness      — GA-readiness gate over the deployed manifest
On green: POST repos/<owner>/<repo>/statuses/<sha>  state=success context=<Context>.
On any non-green: exit the stage's code and post NOTHING (absence == not-verified == release stays blocked for that SHA).

.EXAMPLE
pwsh tools/Confirm-PostDeploy.ps1 -ResourceGroup xdrlograider -WorkspaceId <customerId-guid> `
  -WorkspaceResourceId /subscriptions/.../workspaces/<ws> -Window Sustain -AllOps
#>
[CmdletBinding()]
param(
    # NOT Mandatory: the file is dot-sourced by Pester for the PURE planners (Mandatory would PROMPT and hang); the live
    # driver validates presence and refuses loudly (exit 2) instead.
    [string] $ResourceGroup,           # ← .env.local XDRLR_CONNECTOR_RG if omitted
    [string] $WorkspaceId,             # customerId GUID or ARM id · ← .env.local XDRLR_WORKSPACE_ID if omitted (forwarded to the verify chain)
    [string] $WorkspaceResourceId,     # ARM full resource id · ← .env.local XDRLR_WORKSPACE_RESOURCE_ID if omitted
    [ValidateSet('Boot','Cold','Hour','Sustain','FirstIteration','ConsecutiveSustain')] [string] $Window = 'Sustain',
    [switch] $AllOps,
    [string] $FunctionApp,   # C-1: ← .env.local XDRLR_FUNCTION_APP (or pass)
    [string] $Sha,                     # default = git HEAD
    [string] $Repo,                    # owner/repo · default = derived from `git remote get-url origin`
    [string] $DeployedSinceUtc,
    [string] $Context = 'postdeploy/verified',
    [switch] $WhatIf                   # build + print the chain plan + the status record · run NOTHING · post NOTHING
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── PURE planners (Pester-driven · no Azure · no gh · no git) ─────────────────────────────────────
function Get-XdrConfirmChainPlan {
    <#
    .SYNOPSIS
    PURE · the ordered postdeploy ENFORCEMENT chain (each entry a child-process verify step). Run-PostDeployVerify
    already chains version->estate->connector->content; Test-GaReadiness adds the GA-readiness gate. EXTEND here (e.g.
    across-restart / cache-bust / sync-override) — the live driver just runs the plan fail-fast.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [Parameter(Mandatory)][string] $WorkspaceResourceId,
        [string] $Window = 'Sustain',
        [bool]   $AllOps = $false,
        [string] $FunctionApp = '',   # C-1: production passes the resolved FA (below); '' neutral standalone/Pester default
        [string] $DeployedSinceUtc = ''
    )
    $pdvArgs = @('-ResourceGroup', $ResourceGroup, '-WorkspaceId', $WorkspaceId, '-WorkspaceResourceId', $WorkspaceResourceId, '-Window', $Window, '-FunctionApp', $FunctionApp)
    if ($AllOps)          { $pdvArgs += '-AllOps' }
    if ($DeployedSinceUtc) { $pdvArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }
    $gaArgs = @('-ResourceGroup', $ResourceGroup, '-WorkspaceId', $WorkspaceId, '-WorkspaceResourceId', $WorkspaceResourceId)
    if ($AllOps)          { $gaArgs += '-AllOps' }
    if ($DeployedSinceUtc) { $gaArgs += @('-DeployedSinceUtc', $DeployedSinceUtc) }   # scope the live GA gates to THIS deploy's lineage
    return , @(
        @{ Name = 'postdeploy-verify'; File = 'Run-PostDeployVerify.ps1'; Args = $pdvArgs }
        @{ Name = 'ga-readiness';      File = 'Test-GaReadiness.ps1';     Args = $gaArgs }
    )
}

function Get-XdrPostDeployStatusRecord {
    <#
    .SYNOPSIS
    PURE · the GitHub commit-status payload recording a per-SHA postdeploy verdict. GitHub caps `description` at 140
    chars; `context` is the required-status NAME that release.yml checks. ASCII-only (safe over the gh api transport).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Sha,
        [Parameter(Mandatory)][ValidateSet('success','failure','pending','error')][string] $State,
        [Parameter(Mandatory)][string] $WorkspaceId,
        [string] $Window = 'Sustain',
        [string] $Utc = '',
        [string] $Context = 'postdeploy/verified'
    )
    $wsShort = if ($WorkspaceId.Length -ge 8) { $WorkspaceId.Substring(0, 8) } else { $WorkspaceId }
    $verb = switch ($State) { 'success' { 'verified' } 'failure' { 'FAILED' } default { $State } }
    $desc = "postdeploy $verb | ws=$wsShort | window=$Window"
    if ($Utc) { $desc += " | $Utc" }
    if ($desc.Length -gt 140) { $desc = $desc.Substring(0, 140) }
    return [ordered]@{ sha = $Sha; context = $Context; state = $State; description = $desc }
}

# ─── Live driver (LOCAL-ONLY · child processes · posts the status on green) ─────────────────────────
if ($MyInvocation.InvocationName -ne '.') {
    # HARD CI REFUSAL (security lock · the chain runs the service-account content verify · creds NEVER in CI · exit 2
    # is the same blocker contract Verify-XdrLiveContent uses and the gauntlet asserts).
    if ($env:CI -or $env:GITHUB_ACTIONS) {
        Write-Warning 'Confirm-PostDeploy is LOCAL-ONLY: the chain runs the service-account content verify · the service account must never authenticate in CI. Refusing.'
        exit 2
    }
    # C-1 (2026-06-18) + §4.B FIX-4 (2026-06-24): resolve the estate from .env.local (gitignored · the established source ·
    # no hardcoded maintainer default) BEFORE the required-args check, so the chain self-resolves with NO manual flag —
    # same XDRLR_* convention as Run-PostDeployAudit/Verify (WorkspaceResourceId was the B6 INCONCLUSIVE cause).
    $envLocalC = Join-Path (Resolve-Path "$PSScriptRoot\..").Path '.env.local'; $evC = @{}
    if (Test-Path $envLocalC) { Get-Content $envLocalC | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $evC[$Matches[1]] = $Matches[2].Trim().Trim('"') } } }
    if (-not $ResourceGroup)       { $ResourceGroup       = $evC['XDRLR_CONNECTOR_RG'] }
    if (-not $WorkspaceResourceId) { $WorkspaceResourceId = $evC['XDRLR_WORKSPACE_RESOURCE_ID'] }
    if (-not $WorkspaceId)         { $WorkspaceId         = $evC['XDRLR_WORKSPACE_ID'] }
    if (-not $ResourceGroup -or -not $WorkspaceId -or -not $WorkspaceResourceId) {
        Write-Host '[Confirm-PostDeploy] -ResourceGroup + -WorkspaceId + -WorkspaceResourceId are required (set XDRLR_CONNECTOR_RG / XDRLR_WORKSPACE_ID / XDRLR_WORKSPACE_RESOURCE_ID in .env.local, or pass them · the pure planners are dot-sourceable for tests).'
        exit 2
    }
    $sha = if ($Sha) { $Sha } else { (git rev-parse HEAD 2>$null) }
    if ($sha) { $sha = "$sha".Trim() }
    if (-not $sha) { Write-Error '[Confirm-PostDeploy] cannot resolve the commit SHA (pass -Sha or run inside the repo).'; exit 2 }
    $repo = if ($Repo) { $Repo } else {
        $u = (git remote get-url origin 2>$null)
        if ($u -match 'github\.com[:/]+([^/]+/[^/.]+)') { $Matches[1] } else { '' }
    }
    if (-not $repo) { Write-Error '[Confirm-PostDeploy] cannot resolve owner/repo (pass -Repo or set an origin remote).'; exit 2 }

    # C-1 (2026-06-18): resolve FA from .env.local (the established source) when not passed — no hardcoded maintainer default.
    if (-not $FunctionApp) {
        $envLocal = Join-Path (Resolve-Path "$PSScriptRoot\..").Path '.env.local'
        if (Test-Path $envLocal) { Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*XDRLR_FUNCTION_APP\s*=\s*(.+)$') { $FunctionApp = $Matches[1].Trim().Trim('"') } } }
    }
    if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionApp)' }
    $plan = Get-XdrConfirmChainPlan -ResourceGroup $ResourceGroup -WorkspaceId $WorkspaceId `
        -WorkspaceResourceId $WorkspaceResourceId -Window $Window -AllOps $AllOps.IsPresent `
        -FunctionApp $FunctionApp -DeployedSinceUtc $DeployedSinceUtc

    if ($WhatIf) {
        Write-Host "[Confirm-PostDeploy] -WhatIf · sha=$sha · repo=$repo · NO verify run · NO status posted"
        foreach ($s in $plan) { Write-Host "  stage '$($s.Name)' · tools/$($s.File) $($s.Args -join ' ')" }
        (Get-XdrPostDeployStatusRecord -Sha $sha -State success -WorkspaceId $WorkspaceId -Window $Window -Context $Context) | Format-List | Out-String | Write-Host
        exit 0
    }

    foreach ($s in $plan) {
        Write-Host "[Confirm-PostDeploy] -- stage '$($s.Name)' · tools/$($s.File) --"
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot $s.File) @($s.Args)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[Confirm-PostDeploy] FAIL at stage '$($s.Name)' · exit $LASTEXITCODE · recording NOTHING (release stays blocked for $sha)"
            exit $LASTEXITCODE
        }
    }

    # All green · record the per-SHA pass as a GitHub commit status (the release precondition reads this).
    $utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $rec = Get-XdrPostDeployStatusRecord -Sha $sha -State success -WorkspaceId $WorkspaceId -Window $Window -Utc $utc -Context $Context
    Write-Host "[Confirm-PostDeploy] ALL STAGES GREEN · posting $($rec.context)=success for $sha"
    gh api -X POST "repos/$repo/statuses/$sha" -f "state=$($rec.state)" -f "context=$($rec.context)" -f "description=$($rec.description)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "[Confirm-PostDeploy] failed to POST the commit status (gh exit $LASTEXITCODE) · the release gate will stay blocked for $sha"; exit 1 }
    Write-Host "[Confirm-PostDeploy] recorded postdeploy pass · release.yml precondition satisfied for $sha"
    exit 0
}
