#Requires -Version 7.4
<#
.SYNOPSIS
  #20 F-POSTDISCOVERY · read-POST op live-discovery probe (local, out-of-band, ONE round).

  The read-POST MECHANISM already exists end-to-end (catalogue BodyTemplates · ship-formula allows
  ReadViaPost · engine New-XdrRequestUrl/New-XdrRequestBody/Invoke-XdrAuthenticated build+send the body).
  The ONLY gap closing here: read-POST ops have NO LIVE FIXTURE yet (the OpenAPI response schema is a
  stub) → the cataloguer can't derive a typed ProjectionMap → Shipped=false.

  This probe AUTHs exactly like Probe-FullChain-Local (.env.local SP → self-config from the deployed FA →
  Connect-XdrPortal -Defender), then for each candidate read-POST op it builds the REAL engine URL
  (New-XdrRequestUrl) + a clean minimal first-page body (the catalogue BodyTemplate with paging forced to
  page 1 / size 100) and POSTs via the REAL transport (Invoke-XdrAuthenticated). A 200-with-rows response
  is CAPTURED to references/live/<source>/discovery/<OperationId>.json — the honest live fixture the
  cataloguer then types + ships. A 400/empty op is reported as a documented hold (NOT shipped).

  HONESTY: this captures REAL portal responses through the REAL engine body/transport path — it is the
  automated equivalent of a manual HAR, not a fabricated fixture. An op only becomes shippable if it
  actually returns tenant data here.

.NOTES
  Default -Operations = the 4 XSPM attack-surface streams (the #20 SHIP candidates · MDE · distinct).
  Curation (exclude QueryAttackSurface/RunHuntingQuery/Sentinel-TI/etc) lives in curation.json, NOT here.
#>
param(
    [string]   $FunctionApp,
    [string]   $Source = 'nodoc-defender-xdr',
    [string[]] $Operations = @(
        'ExposureManagement.GetTopEntryPoints',
        'ExposureManagement.GetTopTargets',
        'ExposureManagement.GetAttackPaths',
        'ExposureManagement.GetChokePoints'
    ),
    [int]      $PageSize = 100,
    [switch]   $WhatIfNoWrite   # build + POST + report, but do NOT write fixtures (dry capture)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# ── 1. Load .env.local (SP creds + connector RG) ── (mirrors Probe-FullChain-Local) ──
$envLocal = Join-Path $repoRoot '.env.local'
if (-not (Test-Path $envLocal)) { throw ".env.local not found at $envLocal" }
$envVars = @{}
Get-Content $envLocal | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$') { $envVars[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$rg = $envVars['XDRLR_CONNECTOR_RG']
if (-not $rg) { throw "XDRLR_CONNECTOR_RG missing from .env.local" }
if (-not $FunctionApp) { $FunctionApp = $envVars['XDRLR_FUNCTION_APP'] }
if (-not $FunctionApp) { throw 'XDRLR_FUNCTION_APP missing from .env.local (or pass -FunctionApp)' }

# ── 2. SP login (local data-plane token fallback) ──
Write-Host "[disco] az login (SP) ..." -ForegroundColor Cyan
az login --service-principal -u $envVars['AZURE_CLIENT_ID'] -p $envVars['AZURE_CLIENT_SECRET'] --tenant $envVars['AZURE_TENANT_ID'] --only-show-errors *> $null
az account set --subscription $envVars['XDRLR_SUBSCRIPTION_ID'] --only-show-errors

# ── 3. Self-configure from the deployed FA app settings (same config as production) ──
Write-Host "[disco] pulling FA app settings from $FunctionApp ..." -ForegroundColor Cyan
$rawSettings = az functionapp config appsettings list --name $FunctionApp --resource-group $rg --only-show-errors | ConvertFrom-Json
$faSettings = @{}
foreach ($s in $rawSettings) { $faSettings[$s.name] = $s.value }
$passThru = @(
    'XDRLR_SERVICE_ACCOUNT_UPN','XDRLR_AUTH_METHOD','XDRLR_KEYVAULT_NAME','XDRLR_KEYVAULT_URL',
    'XDRLR_STORAGE_ACCOUNT','XDRLR_TENANT_ID','APPLICATIONINSIGHTS_CONNECTION_STRING'
)
foreach ($k in $passThru) { if ($faSettings.ContainsKey($k)) { Set-Item "env:$k" $faSettings[$k] } }
Remove-Item env:IDENTITY_ENDPOINT -ErrorAction SilentlyContinue
Remove-Item env:IDENTITY_HEADER   -ErrorAction SilentlyContinue
Write-Host "[disco] UPN=$($env:XDRLR_SERVICE_ACCOUNT_UPN) AuthMethod=$($env:XDRLR_AUTH_METHOD) KV=$($env:XDRLR_KEYVAULT_NAME)"

# ── 4. Import bundled modules ──
$modRoot = Join-Path $repoRoot 'src/Modules'
$env:PSModulePath = $modRoot + [IO.Path]::PathSeparator + $env:PSModulePath
$loaded = 0
foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*' | Sort-Object Name)) {
    $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
    if (Test-Path $psd1) { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop; $loaded++ }
}
Write-Host "[disco] imported $loaded Xdr modules" -ForegroundColor Green

# ── 4b. Direct auth (local-SP-safe) ── Connect-XdrPortal wraps a Blob-Lease + StateStore that need the
# Storage data-plane roles the FA MANAGED IDENTITY has but the local SP does NOT (→ 401 'Single-flight
# contention' BEFORE auth). So we auth via the DIRECT handler (the §26.3-PROVEN local path, same as
# Probe-FullChain-Local's Test-XdrPortalAuth) and drive the per-op POSTs with Invoke-XdrPortalHttp -Session
# (which does NOT re-enter Connect-XdrPortal's lease/cache).
$probeCreds = @{
    UPN        = if ($envVars['XDRLR_TEST_UPN'])         { $envVars['XDRLR_TEST_UPN'] }         else { $env:XDRLR_SERVICE_ACCOUNT_UPN }
    Password   = $envVars['XDRLR_TEST_PASSWORD']
    AuthMethod = if ($envVars['XDRLR_TEST_AUTH_METHOD']) { $envVars['XDRLR_TEST_AUTH_METHOD'] } elseif ($env:XDRLR_AUTH_METHOD) { $env:XDRLR_AUTH_METHOD } else { 'CredentialsTotp' }
    TenantId   = if ($envVars['XDRLR_TENANT_ID'])        { $envVars['XDRLR_TENANT_ID'] }        else { $env:XDRLR_TENANT_ID }
    TotpSeed   = if ($envVars['XDRLR_TEST_TOTP_SECRET']) { $envVars['XDRLR_TEST_TOTP_SECRET'] } else { $envVars['XDRLR_TEST_TOTP_SEED'] }
}
if (-not $probeCreds.UPN -or -not $probeCreds.Password) {
    throw "[disco] needs XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD (+ XDRLR_TEST_TOTP_SECRET) in .env.local (the Probe-FullChain-Local -AllPortals creds)"
}
Write-Host "[disco] Connect-DefenderPortal (direct · lease-bypassed) UPN=$($probeCreds.UPN) AuthMethod=$($probeCreds.AuthMethod) ..." -ForegroundColor Cyan
$rawSession = Connect-DefenderPortal -Credentials $probeCreds
$session = ConvertTo-XdrSessionHashtable -InputObject $rawSession
if (-not $session) { throw "[disco] Connect-DefenderPortal returned a null session" }
Write-Host "[disco] session seated (sccauthLen=$(([string]$session['Sccauth']).Length))" -ForegroundColor Green

# ── 5. Load the catalogue (source of OperationId · Path · Method · BodyTemplate · SubPortal · Category) ──
$catPath = Join-Path $repoRoot "references/inventory/$Source/catalogue.json"
if (-not (Test-Path $catPath)) { throw "catalogue not found at $catPath" }
$catalogue = (Get-Content $catPath -Raw | ConvertFrom-Json).operations

# Force a clean first-page body from the catalogue BodyTemplate: keep the op's shape (filters, etc) but
# overwrite ANY paging field to page-1 / $PageSize so we never request a garbage page (the template carries
# random example values like pageIndex:6110). Generic: only touches keys that look like paging.
function ConvertTo-XdrFirstPageBody {
    param([string]$BodyTemplateJson, [int]$Size)
    if ([string]::IsNullOrWhiteSpace($BodyTemplateJson)) { return @{} }
    $obj = $BodyTemplateJson | ConvertFrom-Json -AsHashtable -Depth 64
    if ($obj -isnot [System.Collections.IDictionary]) { return $obj }
    foreach ($k in @($obj.Keys)) {
        switch -Regex ($k) {
            '^(pageIndex|skip|Skip|offset|page)$' { $obj[$k] = if ($k -match 'index|page') { 1 } else { 0 } }
            '^(pageSize|PageSize|maxPageSize|minPageSize|top|Top|limit)$' { $obj[$k] = $Size }
        }
    }
    return $obj
}

$discoDir = Join-Path $repoRoot "references/live/$Source/discovery"
if (-not $WhatIfNoWrite -and -not (Test-Path $discoDir)) { New-Item -ItemType Directory -Path $discoDir -Force | Out-Null }

# ── 6. Probe each candidate op via the REAL engine path ──
$results = @()
foreach ($opId in $Operations) {
    $op = @($catalogue | Where-Object { $_.OperationId -eq $opId } | Select-Object -First 1)
    $rec = [ordered]@{ OperationId = $opId; Status = ''; Http = ''; Rows = 0; Note = '' }
    if (-not $op) { $rec.Status = 'NOT_IN_CATALOGUE'; $results += [pscustomobject]$rec; continue }
    $op = $op[0]
    try {
        $entry = @{
            OperationKey = $op.OperationId
            Portal       = if ($op.PSObject.Properties['Portal'] -and $op.Portal) { [string]$op.Portal } else { 'Defender' }
            SubPortal    = if ($op.PSObject.Properties['SubPortal'] -and $op.SubPortal) { [string]$op.SubPortal } else { 'mtp' }
            Path         = [string]$op.Path
            Method       = if ($op.PSObject.Properties['Method'] -and $op.Method) { [string]$op.Method } else { 'POST' }
        }
        $method = [string]$entry['Method']
        $url  = New-XdrRequestUrl -Entry $entry -Page 1
        $body = if ($method -in @('POST','PUT','PATCH')) { ConvertTo-XdrFirstPageBody -BodyTemplateJson ([string]$op.BodyTemplate) -Size $PageSize } else { $null }
        Write-Host "[disco] $method $opId → $url" -ForegroundColor Cyan
        # Retry on 5xx (the apiproxy returns a transient "try again later" 500 for some upstreams).
        $resp = $null; $lastErr = $null
        for ($try = 1; $try -le 3; $try++) {
            try { $resp = Invoke-XdrPortalHttp -Session $session -Method $method -Url $url -Body $body; $lastErr = $null; break }
            catch {
                $lastErr = $_
                if ($_.Exception.Message -match '\b5\d\d\b' -and $try -lt 3) { Write-Host "[disco]   5xx · retry $try/2 ..." -ForegroundColor DarkYellow; Start-Sleep -Seconds 3; continue }
                throw
            }
        }
        if ($lastErr) { throw $lastErr }
        $rec.Http = '200'
        # Invoke-XdrPortalHttp returns a transport WRAPPER {StatusCode,RawBody,Headers,Body}; the real API
        # payload is .Body. Unwrap before counting/capturing — else we count the wrapper (always 1) and
        # mis-read a genuinely-empty response (e.g. {Records:[],TotalRecords:0}) as "has data".
        if ($resp -and $resp.PSObject.Properties['Body']) { $resp = $resp.Body }
        if ($resp -is [string]) { try { $resp = $resp | ConvertFrom-Json } catch {} }
        # Count rows generically: prefer the catalogue ItemsContainer, else any top-level array, else 1 object.
        $rows = $null
        $container = if ($op.PSObject.Properties['ItemsContainer']) { [string]$op.ItemsContainer } else { '' }
        if ($container -and $resp.PSObject.Properties[$container]) { $rows = $resp.$container }
        elseif ($resp.PSObject.Properties['data'])  { $rows = $resp.data }
        elseif ($resp.PSObject.Properties['value']) { $rows = $resp.value }
        elseif ($resp -is [System.Collections.IEnumerable] -and $resp -isnot [string]) { $rows = $resp }
        $count = if ($null -eq $rows) { if ($resp) { 1 } else { 0 } } elseif ($rows -is [System.Collections.IEnumerable] -and $rows -isnot [string]) { @($rows).Count } else { 1 }
        $rec.Rows = $count
        if ($count -ge 1) {
            $rec.Status = 'CAPTURED'
            if (-not $WhatIfNoWrite) {
                $fixturePath = Join-Path $discoDir "$opId.json"
                $resp | ConvertTo-Json -Depth 64 | Set-Content -Path $fixturePath -Encoding UTF8
                $rec.Note = "fixture → $fixturePath"
            } else { $rec.Note = '(dry: no fixture written)' }
        } else {
            $rec.Status = 'EMPTY_HOLD'; $rec.Note = '200 but 0 rows — tenant-empty or needs a specific filter (documented hold)'
        }
    } catch {
        $msg = [string]$_.Exception.Message
        $clean = ($msg -replace '\s+', ' ')
        if ($clean -match '\b[45]\d\d\b') { $rec.Http = $Matches[0] }
        $rec.Status = 'FAILED_HOLD'
        $rec.Note = $clean.Substring(0, [Math]::Min(180, $clean.Length))
    }
    $results += [pscustomobject]$rec
}

Write-Host "`n===== F-POSTDISCOVERY RESULTS =====" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
$captured = @($results | Where-Object Status -eq 'CAPTURED').Count
Write-Host "[disco] captured=$captured / $($Operations.Count) candidate read-POST ops" -ForegroundColor $(if ($captured -gt 0) { 'Green' } else { 'DarkYellow' })
# A discovery run is informational — exit 0 if it ran cleanly (per-op verdicts are in the table); exit 2
# only if a hard error prevented probing at all (handled by the throws above).
exit 0
