#Requires -Version 7.4
<#
.SYNOPSIS
  Φ4.A · roll the ARM deployment back to a KNOWN-GOOD committed template — safely, never destructively.
.DESCRIPTION
  git IS the snapshot store (NO-FORK · no extra snapshot files): the rollback target is deploy/mainTemplate.json
  AS COMMITTED at a known-good git ref (-GoodRef · e.g. the last green tag/SHA). The tool:
    1. REFUSES without a valid -GoodRef that actually carries deploy/mainTemplate.json (never a blind redeploy);
    2. extracts that exact template from git to a temp file;
    3. runs `az deployment group what-if` ALWAYS (shows the delta · never blind);
    4. applies via `az deployment group create --mode Incremental` ONLY on explicit -Execute (additive · never
       Complete-mode · never removes the resource group · never a fire-and-forget detached run · never touches Key Vault).
  Default (no -Execute) = what-if dry-run only. Read-mostly; the only mutation is an additive incremental redeploy
  of a previously-good template, gated behind -Execute. SP creds from .env.local for headless operation.
.EXAMPLE
  ./Rollback-ArmDeployment.ps1 -GoodRef v0.1.0-pre -ResourceGroup xdrlograider              # dry-run (what-if)
  ./Rollback-ArmDeployment.ps1 -GoodRef v0.1.0-pre -ResourceGroup xdrlograider -Execute      # apply
#>
[CmdletBinding()]
param(
    [string] $GoodRef,                                    # known-good git commit/tag carrying deploy/mainTemplate.json
    [Parameter(Mandatory)][string] $ResourceGroup,
    [string] $ParametersFile,                             # optional ARM parameters file
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch] $Execute                                     # default = what-if only (dry-run)
)
$ErrorActionPreference = 'Stop'

# ── PURE request validator (git-only · no Azure · unit-tested) ──────────────────────────────────
# Safe ONLY when GoodRef is a real commit that actually carries deploy/mainTemplate.json. A blind rollback
# (no ref / bad ref / ref without the template) is REFUSED — never redeploy something we cannot pin.
function Test-XdrRollbackRequest {
    [CmdletBinding()]
    param([string] $GoodRef, [string] $RepoRoot)
    if ([string]::IsNullOrWhiteSpace($GoodRef)) {
        return @{ Safe = $false; Reason = 'no -GoodRef supplied (a known-good git commit/tag to roll back to · NEVER a blind redeploy)' }
    }
    Push-Location $RepoRoot
    try {
        $null = git rev-parse --verify "$GoodRef^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { return @{ Safe = $false; Reason = "GoodRef '$GoodRef' is not a valid git commit/tag" } }
        git cat-file -e "${GoodRef}:deploy/mainTemplate.json" 2>$null
        if ($LASTEXITCODE -ne 0) { return @{ Safe = $false; Reason = "GoodRef '$GoodRef' has no deploy/mainTemplate.json (not a deployable snapshot)" } }
    } finally { Pop-Location }
    return @{ Safe = $true; Reason = "GoodRef '$GoodRef' valid + carries deploy/mainTemplate.json" }
}

# Dot-sourced for unit tests → expose the pure function only, skip the live rollback.
if ($MyInvocation.InvocationName -eq '.') { return }

# ── validate the request (REFUSE a blind/unsafe rollback) ───────────────────────────────────────
$req = Test-XdrRollbackRequest -GoodRef $GoodRef -RepoRoot $RepoRoot
if (-not $req.Safe) { Write-Error "[Rollback] REFUSED · $($req.Reason)"; exit 1 }
Write-Host "[Rollback] target = deploy/mainTemplate.json @ $GoodRef · RG=$ResourceGroup · $($req.Reason)"

# ── extract the known-good template from git (git = the snapshot store) ─────────────────────────
$tmpl = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-rollback-" + ($GoodRef -replace '[^0-9A-Za-z]', '_') + ".json")
Push-Location $RepoRoot
try { git show "${GoodRef}:deploy/mainTemplate.json" 2>&1 | Set-Content -Path $tmpl -Encoding utf8 } finally { Pop-Location }
if (-not (Test-Path $tmpl) -or (Get-Item $tmpl).Length -lt 100) { Write-Error '[Rollback] failed to extract the known-good template from git'; exit 1 }

# ── az SP login from .env.local (headless · mirror Verify-DeployedConnector / Verify-DeployedVersion) ──
if (-not (az account show 2>$null)) {
    $envLocal = Join-Path $RepoRoot '.env.local'
    if (Test-Path $envLocal) {
        $kv = @{}; Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)\s*$') { $kv[$Matches[1]] = $Matches[2].Trim('"') } }
        if ($kv['AZURE_TENANT_ID'] -and $kv['AZURE_CLIENT_ID'] -and $kv['AZURE_CLIENT_SECRET']) {
            az login --service-principal -u $kv['AZURE_CLIENT_ID'] -p $kv['AZURE_CLIENT_SECRET'] --tenant $kv['AZURE_TENANT_ID'] --only-show-errors 2>&1 | Out-Null
        }
    }
    if (-not (az account show 2>$null)) { Write-Error '[Rollback] az not authenticated · run az login or populate .env.local'; exit 1 }
}

# ── WHAT-IF ALWAYS (never a blind rollback) ─────────────────────────────────────────────────────
$common = @('--resource-group', $ResourceGroup, '--template-file', $tmpl, '--mode', 'Incremental')
if ($ParametersFile) { $common += @('--parameters', "@$ParametersFile") }
Write-Host "[Rollback] what-if (Incremental · additive · the RG is NEVER deleted) ..."
az deployment group what-if @common
if ($LASTEXITCODE -ne 0) { Write-Error '[Rollback] what-if failed · NOT applying'; exit 1 }

if (-not $Execute) {
    Write-Host '[Rollback] DRY-RUN complete · review the what-if delta above, then re-run with -Execute to apply' -ForegroundColor Yellow
    exit 0
}

# ── EXECUTE · incremental (additive) redeploy of the known-good template ────────────────────────
Write-Host "[Rollback] EXECUTE · az deployment group create (Incremental) from $GoodRef" -ForegroundColor Cyan
az deployment group create @common
$code = $LASTEXITCODE
if ($code -ne 0) { Write-Error "[Rollback] deployment failed · exit=$code"; exit $code }
Write-Host '[Rollback] DONE · rolled back to the known-good template (Incremental · run Verify-DeployedVersion to confirm)' -ForegroundColor Green
exit 0
