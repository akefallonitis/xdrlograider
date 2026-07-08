#Requires -Version 7.4
<#
.SYNOPSIS
LOCAL full-chain auth + poll probe (real T3 against the lab tenant). Surfaces the entire remaining
runtime cluster (StrictMode property/shape bugs, auth tier behaviour, parser, ingest) in ONE local
pass with FULL PowerShell script stack traces — instead of one-bug-per-FA-deploy (plan §21 pivot).

.DESCRIPTION
Self-configures from the deployed Function App's app settings (so the chain runs with the SAME
XDRLR_* config as production), imports the bundled modules, then executes:
  Connect-XdrPortal -Portal Defender  (real T1/T2/T3 — reads creds from KV, may burn one TOTP on T3)
  → Invoke-XdrEntryPoll on the ActionCenter manifest entry (real Defender poll + parse + DCE ingest)

Every failure is caught and printed with $_.ScriptStackTrace (the real file:line the FA's generic
interpreter frames hide). Uses the SP from .env.local for KV/Storage data-plane tokens (the code's
Get-AzAccessToken local-dev fallback, since there is no IDENTITY_ENDPOINT off-Functions).

NOT a steady-state tool. Operator-run, lab-tenant only. Cites plan §21 local-first pivot.
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $FunctionApp,   # C-1: ← .env.local XDRLR_FUNCTION_APP (or pass)
    [switch] $SkipPoll,
    # -AllPortals: the all-5-portal AUTH verification artifact (plan §32 R2 A3 · §30.1 A-AUTH).
    # Drives Connect-XdrPortal -Force for EACH of the 5 portals, classifies the seated session
    # (cookie family = Defender/Purview: Sccauth+XSRF · bearer family = Entra/Intune/SecurityCopilot:
    # AccessToken), prints a per-portal pass/fail summary, and exits 0 only if all 5 authenticate.
    # Cookie portals may each burn a TOTP (operator: TOTP-burn is a NON-issue · §25). v0.1.0 polls
    # Defender only — this proves auth for all 5 (the deliverable bar), not polling for all 5.
    [switch] $AllPortals,
    # Optional subset for -AllPortals (e.g. -Portals Entra,Intune,SecurityCopilot to re-test just the
    # bearer trio without re-burning the cookie portals' TOTP). Default = all 5.
    [ValidateSet('Defender','Purview','Entra','Intune','SecurityCopilot')] [string[]] $Portals
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

# ── 1. Load .env.local (SP creds + connector RG) ────────────────────────────────
$envLocal = Join-Path $repoRoot '.env.local'
if (-not (Test-Path $envLocal)) { throw ".env.local not found at $envLocal" }
$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') { $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$rg = $envVars['XDRLR_CONNECTOR_RG']
if (-not $rg) { throw "XDRLR_CONNECTOR_RG missing from .env.local" }
# C-1 (2026-06-18): resolve FA from .env.local (the established source) rather than a hardcoded maintainer default.
if (-not $FunctionApp) { $FunctionApp = $envVars['XDRLR_FUNCTION_APP'] }
if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionApp)' }

# ── 2. SP login (KV/Storage data-plane tokens use the Get-AzAccessToken fallback locally) ──
Write-Host "[probe] az login (SP) ..." -ForegroundColor Cyan
az login --service-principal -u $envVars['AZURE_CLIENT_ID'] -p $envVars['AZURE_CLIENT_SECRET'] --tenant $envVars['AZURE_TENANT_ID'] --only-show-errors *> $null
az account set --subscription $envVars['XDRLR_SUBSCRIPTION_ID'] --only-show-errors

# ── 3. Self-configure from the deployed FA app settings (same config as production) ──
Write-Host "[probe] pulling FA app settings from $FunctionApp ..." -ForegroundColor Cyan
$rawSettings = az functionapp config appsettings list --name $FunctionApp --resource-group $rg --only-show-errors | ConvertFrom-Json
$faSettings = @{}
foreach ($s in $rawSettings) { $faSettings[$s.name] = $s.value }

$passThru = @(
    'XDRLR_SERVICE_ACCOUNT_UPN','XDRLR_AUTH_METHOD','XDRLR_KEYVAULT_NAME','XDRLR_KEYVAULT_URL',
    'XDRLR_STORAGE_ACCOUNT','XDRLR_DCE_ENDPOINT','XDRLR_WORKSPACE_ID','XDRLR_TENANT_ID',
    'XDRLR_DCR_DEFENDER_ACTIONCENTER','APPLICATIONINSIGHTS_CONNECTION_STRING'
)
foreach ($k in $passThru) {
    if ($faSettings.ContainsKey($k)) { Set-Item "env:$k" $faSettings[$k] }
}
# NOTE: locally there is NO IDENTITY_ENDPOINT, so the Cache/Storage/Ingest token paths use the
# Get-AzAccessToken fallback (works because we az-logged-in the SP above).
Remove-Item env:IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
Remove-Item env:IDENTITY_HEADER   -ErrorAction SilentlyContinue
Write-Host "[probe] UPN=$($env:XDRLR_SERVICE_ACCOUNT_UPN) AuthMethod=$($env:XDRLR_AUTH_METHOD) KV=$($env:XDRLR_KEYVAULT_NAME) SA=$($env:XDRLR_STORAGE_ACCOUNT)"

# ── 4. Import bundled modules (system path kept so Az is available for the local token fallback) ──
$modRoot = Join-Path $repoRoot 'src/Modules'
$env:PSModulePath = $modRoot + [IO.Path]::PathSeparator + $env:PSModulePath
$loaded = 0
foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*' | Sort-Object Name)) {
    $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
    if (Test-Path $psd1) { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop; $loaded++ }
}
Write-Host "[probe] imported $loaded Xdr modules" -ForegroundColor Green

function Show-XdrFailure {
    param([System.Management.Automation.ErrorRecord]$Err, [string]$Stage)
    Write-Host "===== $Stage FAILED =====" -ForegroundColor Red
    Write-Host "Type    : $($Err.Exception.GetType().FullName)"
    Write-Host "Message : $($Err.Exception.Message)"
    Write-Host "----- ScriptStackTrace (real file:line) -----" -ForegroundColor Yellow
    Write-Host $Err.ScriptStackTrace
    if ($Err.Exception.InnerException) { Write-Host "Inner   : $($Err.Exception.InnerException.Message)" }
}

# ── 4b. -AllPortals · the all-5-portal AUTH verification artifact (plan §32 R2 A3) ──
# Runs the REAL Connect-XdrPortal -Force chain for each of the 5 portals and classifies the seated
# session by family (cookie vs bearer). StrictMode-safe indexer reads throughout (sessions are the
# normalized [hashtable] from ConvertTo-XdrSessionHashtable). Per-portal pass/fail + summary table.
function Test-XdrPortalAuth {
    param(
        [Parameter(Mandatory)] [string] $P,
        [Parameter(Mandatory)] [hashtable] $Creds
    )
    $rec = [ordered]@{ Portal = $P; Family = '-'; Pass = $false; Evidence = ''; ErrText = '' }
    $script:XdrProbeLastErr = $null
    try {
        # Call the per-portal Connect handler DIRECTLY (not via Connect-XdrPortal). Rationale: Connect-XdrPortal
        # wraps the handler in a Blob-Lease single-flight + StateStore cache, both of which require the Storage
        # DATA-plane roles the FA MANAGED IDENTITY has but the local SP does NOT (Acquire-XdrBlobLease → 401 →
        # 'Single-flight contention' BEFORE auth is ever attempted · plan §22.1/§23.0 local-SP artifact). The
        # all-5-AUTH deliverable is the auth FLOW per portal; the lease/cache is FA-MSI infra verified separately.
        # This mirrors the §26.3 PROVEN local Defender gate (direct Connect-DefenderPortal · cache-miss tolerated).
        # ConvertTo-XdrSessionHashtable normalizes the handler return exactly as Connect-XdrPortal would.
        $raw = switch ($P) {
            'Defender'        { Connect-DefenderPortal        -Credentials $Creds }
            'Purview'         { Connect-PurviewPortal         -Credentials $Creds }
            'Entra'           { Connect-EntraPortal           -Credentials $Creds }
            'Intune'          { Connect-IntunePortal          -Credentials $Creds }
            'SecurityCopilot' { Connect-SecurityCopilotPortal -Credentials $Creds }
            default           { throw "no direct handler for portal '$P'" }
        }
        $s = ConvertTo-XdrSessionHashtable -InputObject $raw
        if ($null -eq $s) { $rec.ErrText = 'null session'; return [pscustomobject]$rec }
        $sh   = if ($s -is [hashtable]) { $s } else { $null }
        $scc  = if ($sh) { [string]$sh['Sccauth'] }     else { '' }
        $tok  = if ($sh) { [string]$sh['AccessToken'] } else { '' }
        $exp  = if ($sh) { [string]$sh['ExpiresUtc'] }  else { '' }
        if ($scc) {
            # Cookie family (Defender · Purview): sccauth + XSRF + dynamic expiry + tenant
            $xsrf = if ($sh) { [string]$sh['XsrfToken'] } else { '' }
            $ten  = if ($sh) { [string]$sh['TenantId'] }  else { '' }
            $rec.Family   = 'cookie'
            $rec.Pass     = ($scc.Length -gt 0)
            $rec.Evidence = "sccauthLen=$($scc.Length) xsrfLen=$($xsrf.Length) tenant=$ten exp=$exp"
        } elseif ($tok) {
            # Bearer family (Entra · Intune · SecurityCopilot): access token + expiry + audience
            $aud = if ($sh) { [string]$sh['Audience'] }  else { '' }
            $sub = if ($sh) { [string]$sh['SubPortal'] } else { '' }
            $rec.Family   = 'bearer'
            $rec.Pass     = ($tok.Length -gt 0)
            $rec.Evidence = "tokenLen=$($tok.Length) exp=$exp aud=$aud subPortal=$sub"
        } else {
            $keys = if ($sh) { ($sh.Keys -join ',') } else { $s.GetType().FullName }
            $rec.ErrText = "session has neither Sccauth nor AccessToken (shape: $keys)"
        }
    } catch {
        $rec.ErrText = $_.Exception.Message
        $script:XdrProbeLastErr = $_
    }
    return [pscustomobject]$rec
}

if ($AllPortals) {
    # Build creds from .env.local lab values (the §26.3 PROVEN local source · avoids the KV dependency of
    # Get-XdrCredentials). TotpSeed key matches Get-XdrCredentials' output shape that the auth flow consumes.
    $probeCreds = @{
        UPN        = if ($envVars['XDRLR_TEST_UPN'])         { $envVars['XDRLR_TEST_UPN'] }         else { $env:XDRLR_SERVICE_ACCOUNT_UPN }
        Password   = $envVars['XDRLR_TEST_PASSWORD']
        AuthMethod = if ($envVars['XDRLR_TEST_AUTH_METHOD']) { $envVars['XDRLR_TEST_AUTH_METHOD'] } elseif ($env:XDRLR_AUTH_METHOD) { $env:XDRLR_AUTH_METHOD } else { 'CredentialsTotp' }
        TenantId   = if ($envVars['XDRLR_TENANT_ID'])        { $envVars['XDRLR_TENANT_ID'] }        else { $env:XDRLR_TENANT_ID }
        TotpSeed   = if ($envVars['XDRLR_TEST_TOTP_SECRET']) { $envVars['XDRLR_TEST_TOTP_SECRET'] } else { $envVars['XDRLR_TEST_TOTP_SEED'] }
    }
    if (-not $probeCreds.UPN -or -not $probeCreds.Password) {
        throw "[probe] -AllPortals needs XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD (+ XDRLR_TEST_TOTP_SECRET) in .env.local"
    }
    Write-Host "[probe] -AllPortals creds: UPN=$($probeCreds.UPN) AuthMethod=$($probeCreds.AuthMethod) TotpSeed=$(if($probeCreds.TotpSeed){'set'}else{'MISSING'})" -ForegroundColor DarkCyan
    $portalList = if ($Portals -and $Portals.Count) { $Portals } else { @('Defender','Purview','Entra','Intune','SecurityCopilot') }
    $results = foreach ($p in $portalList) {
        Write-Host "`n[probe] === $p · direct Connect-${p}Portal (REAL auth · lease bypassed) ===" -ForegroundColor Cyan
        $res = Test-XdrPortalAuth -P $p -Creds $probeCreds
        if ($res.Pass) {
            Write-Host "[probe] $p PASS · family=$($res.Family) · $($res.Evidence)" -ForegroundColor Green
        } else {
            Write-Host "[probe] $p FAIL · $($res.ErrText)" -ForegroundColor Red
            if ($script:XdrProbeLastErr) { Show-XdrFailure -Err $script:XdrProbeLastErr -Stage "$p auth" }
        }
        $res
    }
    Write-Host "`n===== 5-PORTAL AUTH SUMMARY =====" -ForegroundColor Cyan
    $results | Format-Table Portal, Family, Pass, Evidence, ErrText -AutoSize | Out-Host
    $passCount = @($results | Where-Object { $_.Pass }).Count
    $total     = $portalList.Count
    $color     = if ($passCount -eq $total) { 'Green' } else { 'Yellow' }
    Write-Host "[probe] $passCount/$total portals authenticated" -ForegroundColor $color
    Write-Host "`n[probe] done (-AllPortals)" -ForegroundColor Cyan
    exit $(if ($passCount -eq $total) { 0 } else { 2 })
}

# ── 5. Real auth chain (T1/T2/T3) ───────────────────────────────────────────────
Write-Host "`n[probe] Connect-XdrPortal -Portal $Portal -Force (REAL auth) ..." -ForegroundColor Cyan
$session = $null
try {
    $session = Connect-XdrPortal -Portal $Portal -Force
    $shape = if ($session -is [hashtable]) { 'hashtable' } elseif ($null -eq $session) { 'NULL' } else { $session.GetType().FullName }
    $keys  = if ($session -is [hashtable]) { ($session.Keys -join ',') } else { '' }
    Write-Host "[probe] Connect-XdrPortal OK · shape=$shape · keys=[$keys]" -ForegroundColor Green
} catch {
    Show-XdrFailure -Err $_ -Stage 'Connect-XdrPortal'
}

# ── 6. Real poll (only if auth seated a session) ────────────────────────────────
$pollOk = $false
if ($session -and -not $SkipPoll) {
    # Categorization = nodoc x-tagGroups (operator-locked 2026-06-11): the Action Center ops live in the
    # Operations GROUP manifest (Subcategory='Action Center') — there is no ActionCenter.psd1. Probe GetHistory
    # BY KEY (the live-proven CURSOR op), never by index.
    $defMan = Import-PowerShellDataFile (Join-Path $repoRoot 'manifests/Defender/Operations.psd1')
    $block  = if ($defMan.ContainsKey('Defender')) { $defMan['Defender'] } else { $defMan }
    $op     = @($block['Operations'] | Where-Object { $_.OperationKey -eq 'GetHistory' } | Select-Object -First 1)
    if (-not $op) { $op = @($block['Operations'])[0] }
    $entry  = @{}
    foreach ($k in $op.Keys) { $entry[$k] = $op[$k] }
    $entry['DcrImmutableId'] = $env:XDRLR_DCR_DEFENDER_OPERATIONS
    Write-Host "`n[probe] Invoke-XdrEntryPoll OperationKey=$($entry.OperationKey) (REAL poll) ..." -ForegroundColor Cyan
    try {
        $r = Invoke-XdrEntryPoll -Entry $entry -CorrelationId ([Guid]::NewGuid().ToString())
        Write-Host "[probe] Poll result: Success=$($r.Success) Items=$($r.ItemCount) ErrorClass=$($r.ErrorClass) ErrorMessage=$($r.ErrorMessage)" -ForegroundColor Green
        $pollOk = ($r.Success -eq $true)
    } catch {
        Show-XdrFailure -Err $_ -Stage 'Invoke-XdrEntryPoll'
    }
} elseif (-not $session) {
    Write-Host "[probe] no session · skipping poll" -ForegroundColor DarkYellow
}

# A chain probe must NEVER exit 0 on a broken chain (the green-but-broken class — same M1 cure as
# Verify-DeployedConnector strict-by-default). -SkipPoll scopes the verdict to auth only.
$chainOk = if ($SkipPoll) { [bool]$session } else { ([bool]$session) -and $pollOk }
Write-Host "`n[probe] done · chain=$(if ($chainOk) { 'OK' } else { 'BROKEN' })" -ForegroundColor $(if ($chainOk) { 'Cyan' } else { 'Red' })
exit $(if ($chainOk) { 0 } else { 2 })
