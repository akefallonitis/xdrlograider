#Requires -Version 7.4
<#
.SYNOPSIS
LOCAL, operator-run live-CONTENT verifier for the Defender connector — the loop-breaker gate.
Proves, against the REAL portal, that a shipped op returns CONTENT-CORRECT typed rows (shape vs the
manifest ProjectionMap · NOT just "rows exist"). Mode A = local data-plane content proof. Mode B (KQL
workspace landing) is the next increment.

.DESCRIPTION
HARD LOCAL-ONLY: refuses to run under CI ($CI / $GITHUB_ACTIONS) — the service account must never auth in
GitHub. Mode A bypasses the FA storage-coordination layer (single-flight blob lease + XdrTierState cache are
SAMI-only; a local SP gets 401 there) by calling the per-portal handler Connect-DefenderPortal DIRECTLY with
__ForceFresh (cache-miss tolerated), exactly as Probe-FullChain-Local.ps1 -AllPortals does. Then it issues a
direct /apiproxy GET with the minted sccauth+XSRF, parses via the SAME ConvertTo-XdrRows the runtime uses, and
asserts the row's content-shape against references/the manifest ProjectionMap.

Operator-run only. .env.local SP for KV/LogAnalytics tokens. NOT a steady-state tool.
#>
[CmdletBinding()]
param(
    [ValidateSet('A','B','Both')] [string] $Mode = 'A',
    [string] $OperationKey = 'GetTenantContext',
    [switch] $AllOps,
    [ValidateSet('Defender','Entra','Intune','Purview','SecurityCopilot')] [string] $Portal = 'Defender',
    [string] $Category = 'Operations',
    [string] $FunctionApp,  # C-1: resolved from .env.local (XDRLR_FUNCTION_APP) below if not passed
    [string] $VerdictOut    # G1 (prove-empty wire): with -AllOps, write {OperationKey -> Verdict} JSON here so
                            # Verify-DeployedConnector can gate its 0-row decision on the DIRECT-SOURCE verdict
                            # (EMPTY/CAP-ABSENT = legit no-data; PASS/RED-shape on 0 workspace rows = FA not landing = RED).
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── 0. HARD CI REFUSAL (security lock · creds never run in CI) ──────────────────
if ($env:CI -or $env:GITHUB_ACTIONS) {
    # Write-Warning (NOT Write-Error): $ErrorActionPreference='Stop' would make Write-Error terminate (exit 1)
    # before `exit 2` runs. The exit-2 contract is what the gauntlet asserts.
    Write-Warning 'Verify-XdrLiveContent is LOCAL-ONLY: the service account must never authenticate in CI. Refusing.'
    exit 2
}

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

# ── 1. .env.local (SP creds + connector RG) ─────────────────────────────────────
$envLocal = Join-Path $repoRoot '.env.local'
if (-not (Test-Path $envLocal)) { throw ".env.local not found at $envLocal" }
$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') { $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$rg = $envVars['XDRLR_CONNECTOR_RG']
if (-not $rg) { throw 'XDRLR_CONNECTOR_RG missing from .env.local' }
# C-1 (2026-06-18): resolve the Function App from .env.local (the established estate source) rather than a hardcoded
# maintainer default — a public tool must not bake in a specific deployment. Pass -FunctionApp to override.
if (-not $FunctionApp) { $FunctionApp = $envVars['XDRLR_FUNCTION_APP'] }
if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionApp)' }

# ── 2. dual auth context: az CLI + Az PowerShell (the local Get-AzAccessToken paths need Az PS) ──
Write-Host '[verify] az login (SP) + Connect-AzAccount (SP) ...' -ForegroundColor Cyan
az login --service-principal -u $envVars['AZURE_CLIENT_ID'] -p $envVars['AZURE_CLIENT_SECRET'] --tenant $envVars['AZURE_TENANT_ID'] --only-show-errors *> $null
az account set --subscription $envVars['XDRLR_SUBSCRIPTION_ID'] --only-show-errors
try {
    $sec  = ConvertTo-SecureString $envVars['AZURE_CLIENT_SECRET'] -AsPlainText -Force
    $cred = [PSCredential]::new($envVars['AZURE_CLIENT_ID'], $sec)
    Connect-AzAccount -ServicePrincipal -Tenant $envVars['AZURE_TENANT_ID'] -Credential $cred -Subscription $envVars['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
} catch { Write-Warning "[verify] Connect-AzAccount failed (Mode B KQL may not work): $($_.Exception.Message)" }

# ── 3. self-configure from the deployed FA app settings (same XDRLR_* config as production) ──
$rawSettings = az functionapp config appsettings list --name $FunctionApp --resource-group $rg --only-show-errors | ConvertFrom-Json
$faSettings = @{}
foreach ($s in $rawSettings) { $faSettings[$s.name] = $s.value }
foreach ($k in @('XDRLR_SERVICE_ACCOUNT_UPN','XDRLR_AUTH_METHOD','XDRLR_KEYVAULT_NAME','XDRLR_KEYVAULT_URL','XDRLR_TENANT_ID','XDRLR_WORKSPACE_ID')) {
    if ($faSettings.ContainsKey($k)) { Set-Item "env:$k" $faSettings[$k] }
}
Remove-Item env:IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
Remove-Item env:IDENTITY_HEADER   -ErrorAction SilentlyContinue

# ── 4. import the bundled modules ───────────────────────────────────────────────
$modRoot = Join-Path $repoRoot 'src/Modules'
$env:PSModulePath = $modRoot + [IO.Path]::PathSeparator + $env:PSModulePath
foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*' | Sort-Object Name)) {
    $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
    if (Test-Path $psd1) { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop }
}

# ── 5. load the manifest entry for -OperationKey (Operations category) ──────────
$opManifest = Join-Path $repoRoot "manifests/$Portal/$Category.psd1"
$data = Import-PowerShellDataFile $opManifest
$entries = if ($data -is [System.Collections.IDictionary]) {
    $arr = @(); foreach ($v in $data.Values) { if ($v -is [System.Array]) { $arr += $v } }; if ($arr.Count) { $arr } else { @($data) }
} else { @($data) }
# -AllOps loops EVERY op in the category (below); the single -OperationKey is then irrelevant, so don't resolve/
# throw on it (the default 'GetTenantContext' is Operations-only and would wrongly fail -AllOps for other cats).
$entry = $entries | Where-Object { $_['OperationKey'] -eq $OperationKey } | Select-Object -First 1
if (-not $AllOps) {
    if (-not $entry) { throw "OperationKey '$OperationKey' not found in $opManifest" }
    Write-Host "[verify] op=$OperationKey · Path=$($entry['Path']) · Mode=$($entry['IngestionMode']) · Shape=$($entry['ResponseShape'])" -ForegroundColor Green
}

# ── PURE content-shape gate · extracted to a dot-sourceable lib so the offline gauntlet can RED-prove it ──
. (Join-Path $PSScriptRoot 'lib/Xdr.ContentShapeGate.ps1')

if ($Mode -eq 'B') { Write-Warning '[verify] Mode B (KQL landing) is the next increment — running Mode A.'; $Mode = 'A' }

# ── MODE A · LOCAL data-plane content proof ─────────────────────────────────────
Write-Host "`n=== MODE A · LOCAL data-plane content proof · $OperationKey ===" -ForegroundColor Cyan

# 5a. direct auth (bypass storage-coordination · cache-miss tolerated). Creds from .env.local lab values
# (XDRLR_TEST_*) — the PROVEN local source (Probe-FullChain-Local.ps1 -AllPortals §26.3). Avoids the KV-REST
# fetch in Get-XdrCredentials, which 401s for the local SP (KV is SAMI-only locally · not a connector bug).
$creds = @{
    UPN          = if ($envVars['XDRLR_TEST_UPN']) { $envVars['XDRLR_TEST_UPN'] } else { $env:XDRLR_SERVICE_ACCOUNT_UPN }
    Password     = $envVars['XDRLR_TEST_PASSWORD']
    AuthMethod   = if ($envVars['XDRLR_TEST_AUTH_METHOD']) { $envVars['XDRLR_TEST_AUTH_METHOD'] } elseif ($env:XDRLR_AUTH_METHOD) { $env:XDRLR_AUTH_METHOD } else { 'CredentialsTotp' }
    TenantId     = if ($envVars['XDRLR_TENANT_ID']) { $envVars['XDRLR_TENANT_ID'] } else { $env:XDRLR_TENANT_ID }
    TotpSeed     = if ($envVars['XDRLR_TEST_TOTP_SECRET']) { $envVars['XDRLR_TEST_TOTP_SECRET'] } else { $envVars['XDRLR_TEST_TOTP_SEED'] }
    __ForceFresh = $true
}
if (-not $creds['UPN'] -or -not $creds['Password']) { throw 'Mode A needs XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD (+ XDRLR_TEST_TOTP_SECRET) in .env.local' }
$session = Connect-DefenderPortal -Credentials $creds
$sccauth = [string]$session['Sccauth']
Write-Host "[verify] auth OK · sccauthLen=$($sccauth.Length) · ExpiresUtc=$($session['ExpiresUtc']) · ExpirySource=$($session['EarliestExpirySource'])" -ForegroundColor Green

# 5b. sccauth decode-test (finalizes D-AUTH: is it a readable JWT with exp?)
$segs = $sccauth.Split('.')
$isJwt = $false; $sccExp = $null
if ($segs.Count -eq 3) {
    try {
        $p = $segs[1].Replace('-','+').Replace('_','/'); switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
        $isJwt = $true; if ($claims.PSObject.Properties.Name -contains 'exp') { $sccExp = $claims.exp }
    } catch { $isJwt = $false }
}
Write-Host "[verify] sccauth decode: segments=$($segs.Count) · isReadableJwt=$isJwt · exp=$sccExp  (=> D-AUTH design: $(if($isJwt -and $sccExp){'token-exp readable'}else{'OPAQUE → reactive 440-reauth + verified floor'}))" -ForegroundColor Yellow

# 5c. per-op content proof (direct /apiproxy GET + parse + assert · reused by single-op AND -AllOps)
function Invoke-XdrOpProof {
    param([hashtable] $Entry, [hashtable] $Session)
    $opKey = [string]$Entry['OperationKey']
    $base  = 'https://security.microsoft.com/apiproxy'
    $sub   = [string]$Entry['SubPortal']
    # {TenantId} path-token substitution from the session — faithful to the runtime's New-XdrRequestUrl (:1860),
    # so this LOCAL probe sends the EXACT URL the FA would (else a false RED on {TenantId} ops like ListAutomationRules).
    $path  = [string]$Entry['Path']
    if ($path -match '\{TenantId\}' -and $Session['TenantId']) { $path = $path -replace '\{TenantId\}', [string]$Session['TenantId'] }
    # A Resolved entity (fan-out) op carries a non-{TenantId} {param} the RUNTIME substitutes from the PARENT op's
    # recently-seen ids. This LOCAL direct-source probe has no parent cache, so it would send the literal
    # {MachineId}/{DeviceId} and the API rejects it (400 'Invalid machineId' / 'Machine id must be provided', or 404) —
    # a verify-tool artifact, NOT a content failure. The direct-source probe is N/A for fan-out ops: their data is
    # validated by the engine's PER-ENTITY emission (the deployed-connector workspace-row check + Entry.Fanout
    # telemetry), and the prepush EntityDependsOn guard already proved the parent SHIPS and PROJECTS the id field.
    # Verdict 'FANOUT' (acceptable · the connector 0-row gate treats it as legit-empty-capable). Generic across cats.
    if ($path -match '\{(?!TenantId\})[A-Za-z0-9]+\}') {
        return [pscustomobject]@{ OperationKey = $opKey; Status = 0; RowCount = 0; EnvelopeOk = $false; Projected = 'n/a'; Verdict = 'FANOUT'; Sample = 'direct-source probe N/A · fan-out {param} op validated via engine per-entity emission + Entry.Fanout telemetry' }
    }
    $url   = if ($sub) { "$base/$sub$path" } else { "$base$path" }
    $headers = @{ Accept = 'application/json' }
    $headers['Cookie'] = if ($Session['Cookie']) { [string]$Session['Cookie'] } else { "sccauth=$($Session['Sccauth'])" }
    if ($Session['XsrfToken']) { $headers['X-XSRF-TOKEN'] = [string]$Session['XsrfToken'] }
    # TimeoutSec 180 (was 60): large list responses (e.g. ListCriticalAssetClassifications · 151 rows) exceed 60s and
    # ERR ("the request was canceled due to the configured HttpTimeout"), which is a verify-tool artifact, not a
    # content defect — a too-short probe timeout false-flags a healthy op. Generic (any large-response op).
    # F-APIVERSION probe parity (2026-07-01): the /tvm/analytics/ backend REQUIRES an api-version REQUEST header whose
    # working value VARIES BY ROUTE (1.0 for most · 2.0 for sca/topPerDay · live-matrix). The FA's Invoke-XdrPortalHttp
    # NEGOTIATES it (Xdr.Common.Runtime $XdrTvmApiVersionCandidates); this raw probe MUST too, else every tvm/analytics op
    # 400s "An expected header was missing" — a PROBE artifact (the FA polls these ops fine + lands rows · live-confirmed
    # GetTvmRiskScore=14 / MachineSecurityStates=9). SAME version-reject condition as the engine (:1822): 405 is a
    # structural version/method reject → retry unconditionally; a 400 is a version reject ONLY when the body proves it
    # (UnsupportedApiVersion / 'expected header') — a non-version 400 (e.g. 'Wrong pagination parameters') SURFACES as the
    # real error, never mis-retried. Non-tvm/analytics URLs make ONE pass with no api-version header (byte-identical).
    $isTvmAnalytics = $url -match '(?i)/tvm/analytics/'
    $verCandidates  = if ($isTvmAnalytics) { @('1.0','2.0') } else { @($null) }
    $verCandidates  = @($verCandidates)   # FORCE array (defeat single-element unwrap under StrictMode)
    $resp = $null
    for ($vi = 0; $vi -lt $verCandidates.Count; $vi++) {
        $ver = [string]$verCandidates[$vi]
        if ($ver) { $headers['api-version'] = $ver }
        $resp = Invoke-WebRequest -Method GET -Uri $url -Headers $headers -TimeoutSec 180 -SkipHttpErrorCheck -SslProtocol 'Tls12, Tls13' -ErrorAction Stop
        $sc = [int]$resp.StatusCode
        if ($isTvmAnalytics -and ($vi -lt ($verCandidates.Count - 1)) -and (($sc -eq 405) -or ($sc -eq 400 -and ([string]$resp.Content -match '(?i)unsupported.?api.?version|expected[ -]?header')))) {
            Write-Host "[verify] api-version '$ver' version-rejected (HTTP $sc) for $opKey · negotiating next candidate" -ForegroundColor DarkYellow
            continue
        }
        break
    }
    $status = [int]$resp.StatusCode
    $bodyText = [string]$resp.Content
    $rec = [ordered]@{ OperationKey = $opKey; Status = $status; RowCount = 0; EnvelopeOk = $false; Projected = '0/0'; Verdict = 'RED'; Sample = '' }
    if ($status -lt 200 -or $status -ge 300) {
        $rec.Sample = ([string]$bodyText).Substring(0, [Math]::Min(240, ([string]$bodyText).Length))  # capture body → capability-absent vs contract-error discriminator
        # Mirror the runtime's Test-XdrIsCapabilityAbsent (license-independence · Xdr.Common.Runtime :2863): 403/404, OR a
        # 400 whose body is the apiproxy "InvalidProxyPrefix" (e.g. /mtoapi MTO ops not routable for a non-MTO tenant), OR a
        # 400 naming a missing LICENSE/product ("The following licenses are required to be on: TvmPremium" · live-caught
        # ListExtensions/ListCertificates on the unlicensed lab tvm surface) = capability-absent → ACCEPTABLE (the connector
        # postures it · the op SHIPS + auto-lights-up on a licensed tenant · F18). The SAME license marker as the engine
        # (:2886 · licen[sc]es near required) so a real contract 400 still stays RED — zero-masking holds. Else a real RED.
        $capAbsent = ($status -eq 403 -or $status -eq 404 -or ($status -eq 400 -and ($rec.Sample -match 'InvalidProxyPrefix' -or $rec.Sample -match '(?i)\blicen[sc]es?\b[^.;]{0,60}\brequired\b|\brequire[sd]?\b[^.;]{0,40}\blicen[sc]es?\b')))
        $rec.Verdict = if ($capAbsent) { 'CAP-ABSENT' } else { "RED-HTTP$status" }
        return [pscustomobject]$rec
    }
    $obj  = $bodyText | ConvertFrom-Json -AsHashtable -Depth 25
    $pm   = if ($Entry['ProjectionMap'] -is [hashtable]) { $Entry['ProjectionMap'] } else { @{} }
    $rows = ConvertTo-XdrRows -ResponseBody $obj -OperationKey $opKey -Portal $Portal -Category $Category `
        -Subcategory ([string]$Entry['Subcategory']) -ResponseShape ([string]$Entry['ResponseShape']) `
        -ItemsContainer ([string]$Entry['ItemsContainer']) -ProjectionMap $pm
    $v = Test-XdrContentShape -Rows $rows -ProjectionMap $pm
    $rec.RowCount = $v.RowCount; $rec.EnvelopeOk = $v.EnvelopeOk; $rec.Projected = "$($v.ProjectionResolved)/$($v.ProjectionTotal)"
    # PASS = content-correct rows · EMPTY = 2xx but 0 rows (capability/config-empty · not a failure) · RED-shape = rows but wrong content
    $rec.Verdict = if ($v.Pass) { 'PASS' } elseif ($v.RowCount -eq 0) { 'EMPTY' } else { 'RED-shape' }
    if ($v.RowCount -ge 1) { $r0 = @($rows)[0]; $rec.Sample = ([string]$r0['RawJson']).Substring(0, [Math]::Min(140, ([string]$r0['RawJson']).Length)) }
    return [pscustomobject]$rec
}

if ($AllOps) {
    Write-Host "`n[verify] -AllOps · proving content for $($entries.Count) Operations ops (ONE auth) ..." -ForegroundColor Cyan
    $results = foreach ($e in $entries) {
        Write-Host "[verify]  GET $($e['OperationKey']) ..." -ForegroundColor DarkCyan
        try { Invoke-XdrOpProof -Entry $e -Session $session }
        catch { $m = $_.Exception.Message; [pscustomobject]@{ OperationKey = [string]$e['OperationKey']; Status = -1; RowCount = 0; EnvelopeOk = $false; Projected = '0/0'; Verdict = "ERR:$($m.Substring(0,[Math]::Min(50,$m.Length)))"; Sample = '' } }
    }
    Write-Host ($results | Format-Table OperationKey, Status, RowCount, EnvelopeOk, Projected, Verdict -AutoSize | Out-String)
    $pass    = @($results | Where-Object { $_.Verdict -eq 'PASS' }).Count
    $emptyN  = @($results | Where-Object { $_.Verdict -eq 'EMPTY' }).Count
    $capAbsN = @($results | Where-Object { $_.Verdict -eq 'CAP-ABSENT' }).Count
    $fanoutN = @($results | Where-Object { $_.Verdict -eq 'FANOUT' }).Count
    $problem = @($results | Where-Object { $_.Verdict -notin @('PASS','EMPTY','CAP-ABSENT','FANOUT') }).Count
    Write-Host "[verify] -AllOps summary: PASS=$pass · EMPTY=$emptyN · CAP-ABSENT=$capAbsN · FANOUT=$fanoutN · PROBLEM=$problem of $($results.Count)" -ForegroundColor $(if ($problem -eq 0) { 'Green' } else { 'Yellow' })
    if ($VerdictOut) {
        # G1 prove-empty wire: emit {OperationKey -> direct-source Verdict} for Verify-DeployedConnector's 0-row gate.
        $vmap = [ordered]@{}; foreach ($r in ($results | Sort-Object OperationKey)) { $vmap[[string]$r.OperationKey] = [string]$r.Verdict }
        ($vmap | ConvertTo-Json -Depth 5) | Set-Content -Path $VerdictOut -Encoding UTF8
        Write-Host "[verify] -AllOps direct-source verdicts → $VerdictOut ($($results.Count) ops)" -ForegroundColor DarkCyan
    }
    # dump bodies for every non-PASS/EMPTY op (CAP-ABSENT + RED) so the capability-absent classification is MANUALLY reviewable
    foreach ($r in @($results | Where-Object { $_.Verdict -notin @('PASS','EMPTY') })) {
        Write-Host "[verify]   $($r.OperationKey) [$($r.Verdict)] body: $($r.Sample)" -ForegroundColor DarkYellow
    }
    if ($problem -eq 0) { Write-Host "`n=== MODE A -AllOps: 0 content-shape failures (engine content-correct for all reachable ops) ===" -ForegroundColor Green; exit 0 }
    exit 1
}

# single-op proof
Write-Host "[verify] GET $(if($entry['SubPortal']){"/$($entry['SubPortal'])"})$($entry['Path'])" -ForegroundColor Cyan
$rec = Invoke-XdrOpProof -Entry $entry -Session $session
$ok = $rec.Verdict -in @('PASS','EMPTY','CAP-ABSENT','FANOUT')   # CAP-ABSENT = tenant lacks the product (license-gate · acceptable) · FANOUT = fan-out {param} op (direct-probe N/A · validated via engine per-entity emission · acceptable)
Write-Host "`n[verify] CONTENT-SHAPE: op=$($rec.OperationKey) · HTTP=$($rec.Status) · rows=$($rec.RowCount) · envelope=$($rec.EnvelopeOk) · projected=$($rec.Projected) · verdict=$($rec.Verdict)" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
if ($rec.Sample) { Write-Host "[verify] MANUAL-REVIEW RawJson/body(140): $($rec.Sample)" -ForegroundColor DarkGray }
if ($rec.Verdict -eq 'PASS') { Write-Host "`n=== MODE A PASS · $($rec.OperationKey) content-correct live (manual+machine) ===" -ForegroundColor Green; exit 0 }
if ($ok) { Write-Host "`n=== MODE A $($rec.Verdict) · $($rec.OperationKey) (acceptable · tenant cannot serve this op) ===" -ForegroundColor Green; exit 0 }
Write-Host "`n=== MODE A $($rec.Verdict) · $($rec.OperationKey) ===" -ForegroundColor Red
exit 1
