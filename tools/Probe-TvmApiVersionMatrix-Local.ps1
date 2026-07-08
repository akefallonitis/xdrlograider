#Requires -Version 7.4
<#
.SYNOPSIS
  STEP-1 VERIFY (verify-don't-assume) for the GENERIC api-version task. Reuses the §26.3-PROVEN local auth chain
  (.env.local SP -> az login -> FA self-config -> Connect-DefenderPortal TOTP -> session), then probes the
  tvm/analytics routes with api-version sent EXPLICITLY (NO negotiation/fallback) so we can read the TRUE per-route
  per-version status. Records, per route, the HTTP code for api-version=1.0 AND api-version=2.0 separately.

  QUESTION (the design fork): does api-version=2.0 return 200 on the routes that negotiated 1.0
  (assets/topVulnerable, products, riskscore, ...)? If 2.0 is 200 for ALL -> a SINGLE default 2.0 for /tvm/analytics/.
  If any route REJECTS 2.0 -> the engine must NEGOTIATE generically. (sca/topPerDay is the known 2.0-only route;
  it is included as the inverse control — it should REJECT 1.0.)

  GET-only, read-only. NEVER prints a secret; NEVER writes a raw tenant value. Does NOT touch curation/catalogue/
  manifests. No commit/deploy. Temporary verify harness.
#>
param(
    [string] $FunctionApp,
    [string] $Source = 'nodoc-defender-xdr'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# == 1. Load .env.local ==
$envLocal = Join-Path $repoRoot '.env.local'
if (-not (Test-Path $envLocal)) { throw ".env.local not found at $envLocal" }
$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') { $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$rg = $envVars['XDRLR_CONNECTOR_RG']; if (-not $rg) { throw "XDRLR_CONNECTOR_RG missing" }
if (-not $FunctionApp) { $FunctionApp = $envVars['XDRLR_FUNCTION_APP'] }
if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing (or pass -FunctionApp)' }

# == 2. SP login ==
Write-Host "[apiv] az login (SP) ..." -ForegroundColor Cyan
az login --service-principal -u $envVars['AZURE_CLIENT_ID'] -p $envVars['AZURE_CLIENT_SECRET'] --tenant $envVars['AZURE_TENANT_ID'] --only-show-errors *> $null
az account set --subscription $envVars['XDRLR_SUBSCRIPTION_ID'] --only-show-errors

# == 3. Self-configure from the deployed FA app settings ==
Write-Host "[apiv] pulling FA app settings from $FunctionApp ..." -ForegroundColor Cyan
$rawSettings = az functionapp config appsettings list --name $FunctionApp --resource-group $rg --only-show-errors | ConvertFrom-Json
$faSettings = @{}
foreach ($s in $rawSettings) { $faSettings[$s.name] = $s.value }
$passThru = @('XDRLR_SERVICE_ACCOUNT_UPN','XDRLR_AUTH_METHOD','XDRLR_KEYVAULT_NAME','XDRLR_KEYVAULT_URL','XDRLR_STORAGE_ACCOUNT','XDRLR_TENANT_ID','APPLICATIONINSIGHTS_CONNECTION_STRING')
foreach ($k in $passThru) { if ($faSettings.ContainsKey($k)) { Set-Item "env:$k" $faSettings[$k] } }
Remove-Item env:IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
Remove-Item env:IDENTITY_HEADER   -ErrorAction SilentlyContinue

# == 4. Import modules ==
$modRoot = Join-Path $repoRoot 'src/Modules'
$env:PSModulePath = $modRoot + [IO.Path]::PathSeparator + $env:PSModulePath
foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*' | Sort-Object Name)) {
    $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
    if (Test-Path $psd1) { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop }
}

# == 4b. Direct auth (lease-bypassed) ==
$probeCreds = @{
    UPN        = if ($envVars['XDRLR_TEST_UPN'])         { $envVars['XDRLR_TEST_UPN'] }         else { $env:XDRLR_SERVICE_ACCOUNT_UPN }
    Password   = $envVars['XDRLR_TEST_PASSWORD']
    AuthMethod = if ($envVars['XDRLR_TEST_AUTH_METHOD']) { $envVars['XDRLR_TEST_AUTH_METHOD'] } elseif ($env:XDRLR_AUTH_METHOD) { $env:XDRLR_AUTH_METHOD } else { 'CredentialsTotp' }
    TenantId   = if ($envVars['XDRLR_TENANT_ID'])        { $envVars['XDRLR_TENANT_ID'] }        else { $env:XDRLR_TENANT_ID }
    TotpSeed   = if ($envVars['XDRLR_TEST_TOTP_SECRET']) { $envVars['XDRLR_TEST_TOTP_SECRET'] } else { $envVars['XDRLR_TEST_TOTP_SEED'] }
}
if (-not $probeCreds.UPN -or -not $probeCreds.Password) { throw "[apiv] needs XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD (+ XDRLR_TEST_TOTP_SECRET)" }
$rawSession = $null
for ($authTry = 1; $authTry -le 2; $authTry++) {
    try {
        Write-Host "[apiv] Connect-DefenderPortal (direct) UPN=$($probeCreds.UPN) [try $authTry] ..." -ForegroundColor Cyan
        $rawSession = Connect-DefenderPortal -Credentials $probeCreds; break
    } catch {
        if ($authTry -lt 2) { Write-Host "[apiv] auth try 1 failed (likely TOTP-window) — waiting 35s ..." -ForegroundColor Yellow; Start-Sleep -Seconds 35 }
        else { $am = ([string]$_.Exception.Message) -replace '\s+',' '; throw "[apiv] auth failed: $($am.Substring(0,[Math]::Min(180,$am.Length)))" }
    }
}
$session = ConvertTo-XdrSessionHashtable -InputObject $rawSession
if (-not $session) { throw "[apiv] null session" }
Write-Host "[apiv] session seated (sccauthLen=$(([string]$session['Sccauth']).Length))" -ForegroundColor Green

$defCfg  = Get-XdrPortalConfig -Portal 'Defender'
$svc = "$([string]$defCfg['BaseUrl'])/apiproxy/mtp/tvm/analytics"   # -> https://security.microsoft.com/apiproxy/mtp/tvm/analytics

# == EXPLICIT-version GET (NO negotiation) == sends exactly the one api-version asked; returns @{Code;Reject;Clip}.
function Invoke-RawGetVer {
    param([hashtable]$Sess, [string]$Url, [string]$Ver)
    $h = @{ Accept = 'application/json' }
    $cookie = if ($Sess['Cookie']) { [string]$Sess['Cookie'] } elseif ($Sess['Sccauth']) { "sccauth=$($Sess['Sccauth'])" } else { '' }
    if ($cookie) { $h['Cookie'] = $cookie }
    if ($Sess['XsrfToken']) { $h['X-XSRF-TOKEN'] = [string]$Sess['XsrfToken'] }
    if ($Ver) { $h['api-version'] = $Ver }
    try {
        $r = Invoke-WebRequest -Method GET -Uri $Url -Headers $h -TimeoutSec 60 -SkipHttpErrorCheck -SslProtocol 'Tls12, Tls13' -ErrorAction Stop
        $raw = $r.Content
        $bt = if ($raw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
        $code = [int]$r.StatusCode
        # version-reject = the SPECIFIC "wrong/absent api-version" signal (NOT a generic 4xx like 403/404/license)
        $reject = ($code -eq 400 -or $code -eq 405) -and ($bt -match '(?i)UnsupportedApiVersion|expected header|api-version')
        return @{ Code = $code; Reject = $reject; Clip = $(if ($bt.Length -gt 160) { $bt.Substring(0,160) } else { $bt }) }
    } catch {
        return @{ Code = 0; Reject = $false; Clip = ("transport: " + (([string]$_.Exception.Message) -replace '\s+',' ')) }
    }
}

# == The routes that negotiated 1.0 (per the captured discovery fixtures) — the ones the task names FIRST + the rest ==
# Plus the known 2.0-only inverse control (sca/topPerDay).
$routes = @(
    @{ Name = 'assets/topVulnerable (ListTopVulnerableAssets)'; Path = '/assets/topVulnerable';        Negotiated = '1.0' }
    @{ Name = 'products (ListProducts · CONTROL)';              Path = '/products';                    Negotiated = '1.0' }
    @{ Name = 'riskscore (GetTvmRiskScore)';                    Path = '/riskscore';                   Negotiated = '1.0' }
    @{ Name = 'advisories (ListAdvisories)';                    Path = '/advisories';                  Negotiated = '1.0' }
    @{ Name = 'certificates (ListCertificates)';                Path = '/certificates';                Negotiated = '1.0' }
    @{ Name = 'extensions (ListExtensions)';                    Path = '/extensions';                  Negotiated = '1.0' }
    @{ Name = 'changeEvents/ (ListChangeEvents)';               Path = '/changeEvents/';               Negotiated = '1.0' }
    @{ Name = 'changeEvents/va/topPerDay (GetTopVaChange...)';  Path = '/changeEvents/va/topPerDay';   Negotiated = '1.0' }
    @{ Name = 'vulnerableDevicesReport (GetVulnDevices...)';    Path = '/vulnerableDevicesReport';     Negotiated = '1.0' }
    @{ Name = 'changeEvents/sca/topPerDay (INVERSE CONTROL)';   Path = '/changeEvents/sca/topPerDay';  Negotiated = '2.0' }
)

# == CONTROL FIRST: prove the session/transport with the known-good negotiated version on /products ==
Write-Host "`n========== SESSION CONTROL (prove transport BEFORE the matrix) ==========" -ForegroundColor Magenta
$ctl10 = Invoke-RawGetVer -Sess $session -Url "$svc/products" -Ver '1.0'
$ctlCol = if ($ctl10.Code -eq 200) { 'Green' } else { 'Red' }
Write-Host ("[apiv] CONTROL /products api-version=1.0 -> HTTP {0}{1}" -f $ctl10.Code, $(if($ctl10.Code -ne 200){" · $($ctl10.Clip)"}else{''})) -ForegroundColor $ctlCol
if ($ctl10.Code -ne 200) { Write-Host "[apiv] *** CONTROL DID NOT RETURN 200 — session/transport NOT proven; matrix results below are UNRELIABLE ***" -ForegroundColor Red }

# == THE MATRIX: per route, 1.0 AND 2.0 explicitly ==
Write-Host "`n========== api-version MATRIX (explicit · no negotiation) ==========" -ForegroundColor Magenta
$rows = @()
foreach ($rt in $routes) {
    $url = "$svc$($rt.Path)"
    $r10 = Invoke-RawGetVer -Sess $session -Url $url -Ver '1.0'
    Start-Sleep -Milliseconds 250
    $r20 = Invoke-RawGetVer -Sess $session -Url $url -Ver '2.0'
    Start-Sleep -Milliseconds 250
    $v10 = if ($r10.Reject) { "$($r10.Code)/REJECT" } else { "$($r10.Code)" }
    $v20 = if ($r20.Reject) { "$($r20.Code)/REJECT" } else { "$($r20.Code)" }
    $twoOk = ($r20.Code -eq 200)
    $rows += [pscustomobject]@{
        Route        = $rt.Name
        Negotiated   = $rt.Negotiated
        'v1.0'       = $v10
        'v2.0'       = $v20
        '2.0==200?'  = $(if ($twoOk) { 'YES' } elseif ($r20.Reject) { 'NO-REJECT' } else { "NO($($r20.Code))" })
        Note20       = $(if ($r20.Code -ne 200) { $r20.Clip } else { '' })
    }
    $col = if ($twoOk) { 'Green' } elseif ($r20.Reject) { 'Yellow' } else { 'DarkYellow' }
    Write-Host ("[apiv]   {0,-46} neg={1}  1.0={2,-12} 2.0={3,-12} 2.0-is-200={4}" -f $rt.Name, $rt.Negotiated, $v10, $v20, $(if($twoOk){'YES'}else{'NO'})) -ForegroundColor $col
}

Write-Host "`n===== api-version MATRIX — RESULT TABLE =====" -ForegroundColor Cyan
$rows | Format-Table Route, Negotiated, 'v1.0', 'v2.0', '2.0==200?', Note20 -AutoSize | Out-String -Width 220 | Write-Host

# == VERDICT ==
$oneRoutes = @($rows | Where-Object { $_.Negotiated -eq '1.0' })
$twoOnAllOne = @($oneRoutes | Where-Object { $_.'2.0==200?' -eq 'YES' }).Count
$totalOne = $oneRoutes.Count
$scaRow = @($rows | Where-Object { $_.Route -like '*INVERSE*' })[0]
Write-Host "`n===== VERDICT =====" -ForegroundColor Cyan
Write-Host "[apiv] 1.0-negotiated routes where api-version=2.0 ALSO returns 200: $twoOnAllOne / $totalOne" -ForegroundColor $(if ($twoOnAllOne -eq $totalOne) { 'Green' } else { 'Yellow' })
if ($scaRow) { Write-Host "[apiv] inverse control sca/topPerDay: 1.0 -> $($scaRow.'v1.0') (expect REJECT) · 2.0 -> $($scaRow.'v2.0') (expect 200)" -ForegroundColor Cyan }
if ($twoOnAllOne -eq $totalOne) {
    Write-Host "[apiv] => DESIGN = SINGLE DEFAULT api-version: 2.0 for /tvm/analytics/ (2.0 is backward-compatible on every 1.0 route)" -ForegroundColor Green
} else {
    Write-Host "[apiv] => DESIGN = GENERIC NEGOTIATION (2.0 then 1.0 on version-reject · cache per route-prefix) — 2.0 is NOT universally accepted" -ForegroundColor Yellow
}
exit 0
