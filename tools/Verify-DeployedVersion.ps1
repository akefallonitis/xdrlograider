#Requires -Version 7.4
<#
.SYNOPSIS
  Φ4.D gate — verify the DEPLOYED Function App is running git HEAD (BUILD_SHA == HEAD).
.DESCRIPTION
  Reads the latest Boot.VersionProbe.GitCommit from the deployed FA's Log Analytics workspace
  (App* telemetry · same surface as Verify-DeployedConnector) and compares it to `git rev-parse
  HEAD`. This PROVES the live version IS HEAD before any postdeploy KQL data-quality check can
  mean anything (plan §5 Φ4.D). Exit: 0 = match · 2 = DRIFT (blocking) · 1 = inconclusive
  (no Boot.VersionProbe in window / unstamped commit).
.NOTES
  Read-only · NEVER mutates Azure. SP creds from .env.local for headless operation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorkspaceId,          # ARM resource id OR customerId GUID
    [int]    $SinceMinutes = 120,
    [int]    $WaitMinutes  = 0,                            # >0 = poll for the probe (App-Insights→LA ingestion lag tolerance)
    [string] $ExpectedSha,                                # default = git HEAD
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)
$ErrorActionPreference = 'Stop'

# ── PURE comparison core (unit-tested · no Azure) ───────────────────────────────────────────────
# Tolerates short-vs-full SHA (the stamp may be a 7- or 40-char commit). Returns {Match;Inconclusive;Detail}.
function Compare-XdrDeployedSha {
    [CmdletBinding()]
    param([string] $DeployedSha, [string] $ExpectedSha)
    $d = ([string]$DeployedSha).Trim().ToLowerInvariant()
    $e = ([string]$ExpectedSha).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($d) -or $d -eq 'unknown') {
        return @{ Match = $false; Inconclusive = $true; Detail = "deployed commit '$DeployedSha' (no Boot.VersionProbe in window / unstamped) · cannot verify BUILD_SHA==HEAD" }
    }
    if ([string]::IsNullOrWhiteSpace($e)) {
        return @{ Match = $false; Inconclusive = $true; Detail = 'expected (HEAD) commit is empty · cannot verify' }
    }
    $minLen = [Math]::Min($d.Length, $e.Length)
    if ($minLen -lt 7) {
        return @{ Match = $false; Inconclusive = $true; Detail = "commit too short to compare (deployed='$d' expected='$e')" }
    }
    if ($d.Substring(0, $minLen) -eq $e.Substring(0, $minLen)) {
        return @{ Match = $true; Inconclusive = $false; Detail = "BUILD_SHA==HEAD · deployed=$d HEAD=$e" }
    }
    return @{ Match = $false; Inconclusive = $false; Detail = "DRIFT · deployed=$d != HEAD=$e · the live FA is NOT running HEAD (cache-bust redeploy via tools/Deploy-FaPackageLocal.ps1)" }
}

function Get-XdrFaPackagePathspec {
    # PURE · the FA package that ships to the Function App (run-from-package) = the engine + manifests. Operator
    # tooling (tools/, tests/) is NOT in the package, so a tooling-only commit does not change the deployed FA.
    return @('src', 'manifests')
}

function Test-XdrFaPackageUnchanged {
    # TRUE iff git shows NO diff in the FA package paths (Get-XdrFaPackagePathspec) between the deployed commit and the
    # expected (HEAD) commit → a BUILD_SHA mismatch is then a TOOLING-ONLY advance (tools/tests moved HEAD without
    # touching what ships) and the live FA IS current. FALSE on any package diff, empty SHAs, or a git failure
    # (fail-safe: an unverifiable compare is drift, never a silent green). 2026-06-23: a verify-tooling commit
    # (4eddf92) false-blocked the round re-prove though src/manifests == the deployed d8a2dd2.
    param([string]$DeployedSha, [string]$ExpectedSha, [string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($DeployedSha) -or [string]::IsNullOrWhiteSpace($ExpectedSha)) { return $false }
    Push-Location $RepoRoot
    try {
        git diff --quiet $DeployedSha $ExpectedSha -- (Get-XdrFaPackagePathspec) 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false } finally { Pop-Location }
}

# Dot-sourced for unit tests → expose the pure function only, skip the live query.
if ($MyInvocation.InvocationName -eq '.') { return }

# ── resolve expected = git HEAD ─────────────────────────────────────────────────────────────────
if (-not $ExpectedSha) {
    Push-Location $RepoRoot
    try { $ExpectedSha = ([string](git rev-parse HEAD 2>&1)).Trim() } finally { Pop-Location }
}
if (-not $ExpectedSha) { Write-Error 'Could not resolve HEAD (git rev-parse HEAD)'; exit 1 }

# ── az SP login from .env.local (headless · mirror Verify-DeployedConnector) ────────────────────
if (-not (az account show 2>$null)) {
    $envLocal = Join-Path $RepoRoot '.env.local'
    if (Test-Path $envLocal) {
        $kv = @{}; Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Z_]+)\s*=\s*(.+)\s*$') { $kv[$Matches[1]] = $Matches[2].Trim('"') } }
        if ($kv['AZURE_TENANT_ID'] -and $kv['AZURE_CLIENT_ID'] -and $kv['AZURE_CLIENT_SECRET']) {
            az login --service-principal -u $kv['AZURE_CLIENT_ID'] -p $kv['AZURE_CLIENT_SECRET'] --tenant $kv['AZURE_TENANT_ID'] --only-show-errors 2>&1 | Out-Null
        }
    }
    if (-not (az account show 2>$null)) { Write-Error 'az not authenticated · run az login or populate .env.local with AZURE_TENANT_ID/CLIENT_ID/CLIENT_SECRET'; exit 1 }
}

# ── resolve WorkspaceId → customerId GUID · accept a raw GUID OR an ARM resource id ──────────────
# (the prior `workspace show --ids <armid>` form failed for this workspace AND masked the error with 2>$null —
#  a rule §2 violation. The `-g <rg> -n <name>` form is empirically reliable; we parse it from the ARM id.)
$guidRe = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if ($WorkspaceId -match $guidRe) {
    # already a customerId GUID — pass through unchanged.
} elseif ($WorkspaceId -match '/resourceGroups/([^/]+)/.*/workspaces/([^/]+)$') {
    $wsRg = $Matches[1]; $wsName = $Matches[2]
    $res = az monitor log-analytics workspace show -g $wsRg -n $wsName --query customerId -o tsv 2>&1
    $guid = ([string]$res).Trim()
    if ($guid -notmatch $guidRe) { Write-Error "Failed to resolve WorkspaceId ARM id (g=$wsRg n=$wsName) to a customerId GUID · az: $res"; exit 1 }
    $WorkspaceId = $guid
} elseif ($WorkspaceId -match '/') {
    # Some other ARM resource id form — generic resource show (customerId lives under properties).
    $res = az resource show --ids $WorkspaceId --query properties.customerId -o tsv 2>&1
    $guid = ([string]$res).Trim()
    if ($guid -notmatch $guidRe) { Write-Error "Failed to resolve WorkspaceId ARM id to a customerId GUID · az: $res"; exit 1 }
    $WorkspaceId = $guid
}

# ── query the latest deployed Boot.VersionProbe GitCommit ───────────────────────────────────────
# App-Insights→LA ingestion lag (~5-20min) means a freshly-booted probe is STAMPED but not yet QUERYABLE. With
# -WaitMinutes > 0 we POLL (re-query every 30s) until the probe ingests or the budget elapses, so a postdeploy run
# right after a cutover tolerates the lag instead of a false INCONCLUSIVE. -WaitMinutes 0 (default) = single query
# (backward-compatible · unit-test / standalone). This is an INGESTION wait, not a window widen — $SinceMinutes is
# already wide; a row that has not landed yet cannot be surfaced by any window.
$kql = "AppEvents | where TimeGenerated > ago(${SinceMinutes}m) and Name == 'Boot.VersionProbe' | extend GitCommit = tostring(Properties.GitCommit) | top 1 by TimeGenerated desc | project GitCommit, TimeGenerated"
$flat = ($kql -replace '\s+', ' ').Trim()
$deadline = (Get-Date).AddMinutes([Math]::Max(0, $WaitMinutes))
$deployed = ''; $lastSeen = ''; $attempt = 0
do {
    $attempt++
    $raw = az monitor log-analytics query --workspace $WorkspaceId --analytics-query $flat --output json 2>&1
    try {
        $row = @($raw | ConvertFrom-Json)[0]
        if ($row) {
            foreach ($p in $row.PSObject.Properties) {
                if ($p.Name -match 'GitCommit') { $deployed = [string]$p.Value }
                if ($p.Name -match 'TimeGenerated') { $lastSeen = [string]$p.Value }
            }
        }
    } catch { <# non-JSON / empty result → $deployed stays '' → retry / INCONCLUSIVE · INTENTIONAL #> }
    if ($deployed -or (Get-Date) -ge $deadline) { break }
    Write-Host "[Verify-DeployedVersion] Boot.VersionProbe not yet ingested (attempt $attempt) · waiting 30s for App-Insights→LA lag (budget ${WaitMinutes}m)…"
    Start-Sleep -Seconds 30
} while ($true)

$verdict = Compare-XdrDeployedSha -DeployedSha $deployed -ExpectedSha $ExpectedSha
Write-Host "[Verify-DeployedVersion] window=${SinceMinutes}m lastSeen=$lastSeen"
Write-Host "[Verify-DeployedVersion] $($verdict.Detail)"
if ($verdict.Match) { Write-Host '[Verify-DeployedVersion] PASS · BUILD_SHA==HEAD' -ForegroundColor Green; exit 0 }
if ($verdict.Inconclusive) { Write-Warning '[Verify-DeployedVersion] INCONCLUSIVE · re-run after the next cold-start emits Boot.VersionProbe'; exit 1 }
# Raw-SHA DRIFT — but tolerate a TOOLING-ONLY advance: if the deployed commit's FA package (src/manifests) is
# byte-identical to HEAD's, the live FA reflects the current shippable code (a tools/tests commit moved HEAD). A real
# engine/manifest change differs here → stays DRIFT (must redeploy).
if (Test-XdrFaPackageUnchanged -DeployedSha $deployed -ExpectedSha $ExpectedSha -RepoRoot $RepoRoot) {
    Write-Host "[Verify-DeployedVersion] PASS · BUILD_SHA $deployed != HEAD $ExpectedSha BUT the FA package (src/manifests) is IDENTICAL — HEAD is ahead only by tooling-only commit(s); the live FA is current" -ForegroundColor Green
    exit 0
}
Write-Error "[Verify-DeployedVersion] DRIFT · deployed BUILD_SHA $deployed != HEAD $ExpectedSha AND the FA package (src/manifests) DIFFERS — a real engine/manifest change is not deployed · cache-bust redeploy"; exit 2
