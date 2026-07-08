#Requires -Version 7.4
<#
.SYNOPSIS
  LOCAL TVM (Threat & Vulnerability Management) portal-internal endpoint surface capture (GET-only, read-only).

  Replicates the §26.3-PROVEN local auth chain (Probe-AsrSurface-Local / Probe-FullChain-Local):
    .env.local SP -> az login -> self-config from the deployed FA app settings -> import Xdr.* modules ->
    DIRECT Connect-DefenderPortal (lease-bypassed) -> ConvertTo-XdrSessionHashtable -> $session.
  Then GETs the TVM /apiproxy/mtp/tvm/analytics/* surface via cookie+XSRF (+ the discovered api-version header).

  PURPOSE: the TVM asset-list ops' postman shapes are STUBS (empty ProjectionMap) -> the cataloguer can't
  derive a typed projection / an asset-id field to seed the {assetId} fan-out (GetAsset / ListAssetInstallations,
  which EntityDependsOn.Tests.ps1 requires be seeded from a SAME-CATEGORY parent). This probe captures the REAL
  response SHAPE of each TVM list op so a follow-on cataloguing round can type them born-correct, and CRITICALLY
  detects whether ListTopVulnerableAssets (or any asset-list op) projects a per-asset id (machineId/assetId/
  deviceId/id). If it does, it substitutes a REAL captured id into GetAsset + ListAssetInstallations and captures
  their shapes too.

  Records RESPONSE SHAPE ONLY (top-level keys + array-item field names+types). NEVER prints a secret; NEVER
  writes a raw tenant value (no device names / IPs / GUIDs-from-rows) into the report OR the fixtures. GET-only.

.NOTES
  Does NOT touch curation.json / catalogue.json / manifests. No commit/deploy. The captured asset id used to
  drive the fan-out is held only in-memory and never logged/written.
#>
param(
    [string] $FunctionApp,
    [string] $Source = 'nodoc-defender-xdr',
    [switch] $WhatIfNoWrite   # probe + report, but do NOT write shape fixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent

# == 1. Load .env.local (SP creds + connector RG + lab test creds) ==
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

# == 2. SP login (data-plane token fallback for the FA-settings read) ==
Write-Host "[tvm] az login (SP) ..." -ForegroundColor Cyan
az login --service-principal -u $envVars['AZURE_CLIENT_ID'] -p $envVars['AZURE_CLIENT_SECRET'] --tenant $envVars['AZURE_TENANT_ID'] --only-show-errors *> $null
az account set --subscription $envVars['XDRLR_SUBSCRIPTION_ID'] --only-show-errors

# == 3. Self-configure from the deployed FA app settings (same config as production) ==
Write-Host "[tvm] pulling FA app settings from $FunctionApp ..." -ForegroundColor Cyan
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
Write-Host "[tvm] UPN=$($env:XDRLR_SERVICE_ACCOUNT_UPN) AuthMethod=$($env:XDRLR_AUTH_METHOD)"

# == 4. Import bundled modules ==
$modRoot = Join-Path $repoRoot 'src/Modules'
$env:PSModulePath = $modRoot + [IO.Path]::PathSeparator + $env:PSModulePath
$loaded = 0
foreach ($d in (Get-ChildItem $modRoot -Directory -Filter 'Xdr.*' | Sort-Object Name)) {
    $psd1 = Join-Path $d.FullName "$($d.Name).psd1"
    if (Test-Path $psd1) { Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop; $loaded++ }
}
Write-Host "[tvm] imported $loaded Xdr modules" -ForegroundColor Green

# == 4b. Direct auth (lease-bypassed · the §26.3 PROVEN local Defender gate) ==
$probeCreds = @{
    UPN        = if ($envVars['XDRLR_TEST_UPN'])         { $envVars['XDRLR_TEST_UPN'] }         else { $env:XDRLR_SERVICE_ACCOUNT_UPN }
    Password   = $envVars['XDRLR_TEST_PASSWORD']
    AuthMethod = if ($envVars['XDRLR_TEST_AUTH_METHOD']) { $envVars['XDRLR_TEST_AUTH_METHOD'] } elseif ($env:XDRLR_AUTH_METHOD) { $env:XDRLR_AUTH_METHOD } else { 'CredentialsTotp' }
    TenantId   = if ($envVars['XDRLR_TENANT_ID'])        { $envVars['XDRLR_TENANT_ID'] }        else { $env:XDRLR_TENANT_ID }
    TotpSeed   = if ($envVars['XDRLR_TEST_TOTP_SECRET']) { $envVars['XDRLR_TEST_TOTP_SECRET'] } else { $envVars['XDRLR_TEST_TOTP_SEED'] }
}
if (-not $probeCreds.UPN -or -not $probeCreds.Password) {
    throw "[tvm] needs XDRLR_TEST_UPN + XDRLR_TEST_PASSWORD (+ XDRLR_TEST_TOTP_SECRET) in .env.local"
}
# Transient-TOTP retry: a concurrent login can consume the current RFC6238 window. Wait ~35s for the next
# window and retry ONCE (per the task's auth note). Never prints any secret.
$rawSession = $null
for ($authTry = 1; $authTry -le 2; $authTry++) {
    try {
        Write-Host "[tvm] Connect-DefenderPortal (direct · lease-bypassed) UPN=$($probeCreds.UPN) AuthMethod=$($probeCreds.AuthMethod) [try $authTry] ..." -ForegroundColor Cyan
        $rawSession = Connect-DefenderPortal -Credentials $probeCreds
        break
    } catch {
        $am = ([string]$_.Exception.Message) -replace '\s+', ' '
        if ($authTry -lt 2) {
            Write-Host "[tvm] auth attempt 1 failed (likely a TOTP-window collision) — waiting 35s for the next window, retrying once ..." -ForegroundColor Yellow
            Start-Sleep -Seconds 35
        } else {
            throw "[tvm] auth failed after 2 attempts: $($am.Substring(0,[Math]::Min(180,$am.Length)))"
        }
    }
}
$session = ConvertTo-XdrSessionHashtable -InputObject $rawSession
if (-not $session) { throw "[tvm] Connect-DefenderPortal returned a null session" }
Write-Host "[tvm] session seated (sccauthLen=$(([string]$session['Sccauth']).Length))" -ForegroundColor Green

# Defender apiproxy base = {BaseUrl}/apiproxy (ApiProxy UrlGrammar). BaseUrl from the EXPORTED Get-XdrPortalConfig
# SoT; '/apiproxy' is the stable grammar constant (the private append-helper is not exported).
$defCfg  = Get-XdrPortalConfig -Portal 'Defender'
$apiBase = "$([string]$defCfg['BaseUrl'])/apiproxy"   # -> https://security.microsoft.com/apiproxy
$mtpBase = "$apiBase/mtp"

# == RAW GET helper == cookie+XSRF + an api-version header. Returns @{Code;Body;BodyClip}. Never throws on
# 4xx/5xx; never logs secrets. (Same shape as the ASR probe's Invoke-RawGet.)
# DISCOVERED (2026-06-25 matrix): the tvm/analytics backend REQUIRES an `api-version` HEADER (query form -> 400
# "expected header missing"), and the version DIFFERS by sub-route: the asset/inventory ops (topVulnerable,
# products, certificates, advisories, ...) want '1.0'; the changeEvents/* ops want '2.0'. So Invoke-TvmGet below
# NEGOTIATES: try the candidate versions in order, take the first non-(UnsupportedApiVersion/expected-header) reply.
$tvmVersions = @('1.0','2.0')
function Invoke-RawGet {
    param([hashtable]$Sess, [string]$Url, [hashtable]$Extra = @{})
    $h = @{ Accept = 'application/json' }
    $cookie = if ($Sess['Cookie']) { [string]$Sess['Cookie'] } elseif ($Sess['Sccauth']) { "sccauth=$($Sess['Sccauth'])" } else { '' }
    if ($cookie) { $h['Cookie'] = $cookie }
    if ($Sess['XsrfToken']) { $h['X-XSRF-TOKEN'] = [string]$Sess['XsrfToken'] }
    foreach ($k in $Extra.Keys) { $h[$k] = [string]$Extra[$k] }
    try {
        $r = Invoke-WebRequest -Method GET -Uri $Url -Headers $h -TimeoutSec 60 -SkipHttpErrorCheck -SslProtocol 'Tls12, Tls13' -ErrorAction Stop
        $raw = $r.Content
        $bt = if ($raw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
        return @{ Code = [int]$r.StatusCode; Body = $bt; BodyClip = $(if ($bt.Length -gt 220) { $bt.Substring(0,220) } else { $bt }) }
    } catch {
        return @{ Code = 0; Body = ''; BodyClip = ("transport: " + (([string]$_.Exception.Message) -replace '\s+',' ')) }
    }
}

# == api-version NEGOTIATING GET == tries $tvmVersions until one is NOT rejected for the version/header reason.
# Returns @{ Code; Body; BodyClip; ApiVersion } where ApiVersion is the version that "stuck" (got past the
# version gate, whatever the final status). A 200 short-circuits immediately.
function Invoke-TvmGetNegotiated {
    param([hashtable]$Sess, [string]$Url)
    $last = $null
    foreach ($v in $tvmVersions) {
        $r = Invoke-RawGet -Sess $Sess -Url $Url -Extra @{ 'api-version' = $v }
        $r['ApiVersion'] = $v
        $versionRejected = ($r.Code -eq 400 -or $r.Code -eq 405) -and ($r.Body -match '(?i)UnsupportedApiVersion|expected header')
        if (-not $versionRejected) { return $r }   # this version was accepted by the gate (200, or a real app-level status)
        $last = $r
    }
    return $last   # all versions rejected — return the last attempt for reporting
}

# == TRANSPORT SANITY-CHECK (verify-don't-assume) == ListProducts is a Shipped asset-inventory TVM op on the
# SAME service. 200 (api-version negotiated) = session/transport good (so a TVM op's 0/4xx is about THAT op, not
# our session). NOTE: a 400 'TvmPremium license required' here would be a LICENSE signal, not a transport fault.
$sanity = Invoke-TvmGetNegotiated -Sess $session -Url "$mtpBase/tvm/analytics/products"
$sanCol = if ($sanity.Code -eq 200) { 'Green' } else { 'Yellow' }
Write-Host "[tvm] transport sanity (tvm/analytics/products · Shipped op · api-version=$($sanity.ApiVersion)): HTTP $($sanity.Code)" -ForegroundColor $sanCol
if ($sanity.Code -ne 200) { Write-Host "[tvm]   sanity body: $($sanity.BodyClip)" -ForegroundColor DarkYellow }

# == SHAPE-ONLY summarizer == top-level keys + (first array row) field name->CLR type. NEVER emits a raw value.
function Get-ShapeOnly {
    param([object]$Node, [int]$Depth = 0, [int]$MaxDepth = 8)
    if ($null -eq $Node) { return '<null>' }
    if ($Depth -ge $MaxDepth) { return '...' }
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Node.Keys)) { $o["$k"] = Get-ShapeOnly -Node $Node[$k] -Depth ($Depth + 1) -MaxDepth $MaxDepth }
        return $o
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $arr = @($Node)
        $first = if ($arr.Count -gt 0) { Get-ShapeOnly -Node $arr[0] -Depth ($Depth + 1) -MaxDepth $MaxDepth } else { '<empty>' }
        return [ordered]@{ '<array>' = "count=$($arr.Count)"; '<itemShape>' = $first }
    }
    return "<$($Node.GetType().Name)>"   # scalar -> CLR type only, never the value
}

$discoDir = Join-Path $repoRoot "references/live/$Source/discovery"
if (-not $WhatIfNoWrite -and -not (Test-Path $discoDir)) { New-Item -ItemType Directory -Path $discoDir -Force | Out-Null }

# == Probe one GET endpoint == returns a record + (on 200) the PARSED payload (for id-extraction) + writes a
# shape fixture <OperationId>.json. The payload is returned to the caller IN-MEMORY only (never logged).
function Probe-TvmGet {
    # -RedactInUrl: a raw tenant value (e.g. a captured asset id) substituted into the path. It is replaced with
    # -RedactMask in the RECORDED endpoint (fixture + report) so no raw tenant identifier is ever written. The
    # live GET still uses the real $Url; only the persisted/printed form is masked.
    param([string]$Label, [string]$Url, [string]$OperationId, [hashtable]$Sess, [string]$RedactInUrl = '', [string]$RedactMask = '{assetId}')
    $recUrl = ($Url -replace '^https://security\.microsoft\.com', '')
    if ($RedactInUrl) { $recUrl = $recUrl.Replace($RedactInUrl, $RedactMask) }
    $rec = [ordered]@{ Label = $Label; OperationId = $OperationId; Url = $recUrl; Http = ''; ApiVersion = ''; Status = ''; Rows = 0; Shape = $null; Note = ''; Payload = $null }
    try {
        $raw = $null
        for ($try = 1; $try -le 3; $try++) {
            $raw = Invoke-TvmGetNegotiated -Sess $Sess -Url $Url
            if ($raw.Code -ge 500 -and $try -lt 3) { Start-Sleep -Seconds 3; continue }
            break
        }
        $rec.Http = [string]$raw.Code
        $rec.ApiVersion = [string]$raw.ApiVersion
        if ($raw.Code -ne 200) {
            $rec.Status = switch ($raw.Code) { 404 { 'NOT_FOUND' } 403 { 'FORBIDDEN' } 400 { 'BAD_REQUEST' } 0 { 'TRANSPORT_ERR' } default { "HTTP_$($raw.Code)" } }
            $rec.Note   = $raw.BodyClip
            return [pscustomobject]$rec
        }
        $payload = $null
        if ($raw.Body) { try { $payload = $raw.Body | ConvertFrom-Json -AsHashtable -Depth 30 } catch { $payload = $raw.Body } }
        $rec.Payload = $payload
        # row count: prefer a top-level array, else a common container, else 1 object
        $rows = $null
        if ($payload -is [System.Collections.IEnumerable] -and $payload -isnot [string] -and $payload -isnot [System.Collections.IDictionary]) { $rows = $payload }
        elseif ($payload -is [System.Collections.IDictionary]) {
            foreach ($c in @('value','data','Records','items','results','Results','assets','products','certificates','extensions','advisories','changeEvents','installations')) {
                if ($payload.Contains($c) -and ($payload[$c] -is [System.Collections.IEnumerable]) -and ($payload[$c] -isnot [string])) { $rows = $payload[$c]; break }
            }
        }
        $count = if ($null -eq $rows) { if ($payload) { 1 } else { 0 } } else { @($rows).Count }
        $rec.Rows  = $count
        $rec.Shape = Get-ShapeOnly -Node $payload
        $rec.Status = if ($count -ge 1) { 'CONFIRMED' } else { 'CONFIRMED_EMPTY' }
        if (-not $WhatIfNoWrite -and $OperationId) {
            $fx = [ordered]@{
                capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
                operationId = $OperationId
                endpoint    = $recUrl
                method      = 'GET'
                apiVersion  = [string]$raw.ApiVersion
                httpStatus  = 200
                rowCount    = $count
                shape       = $rec.Shape
                note        = 'SHAPE-ONLY capture (no raw tenant values). Live data = postdeploy verify only. api-version is the portal-internal apiproxy header value, not an MS-documented API version.'
            }
            $fxPath = Join-Path $discoDir "$OperationId.json"
            $fx | ConvertTo-Json -Depth 32 | Set-Content -Path $fxPath -Encoding UTF8
            $rec.Note = "shape fixture -> $($OperationId).json"
        }
    } catch {
        $msg = ([string]$_.Exception.Message) -replace '\s+', ' '
        if ($msg -match '\bHTTP\s+(\d{3})\b') { $rec.Http = $Matches[1] } elseif ($msg -match '\b([45]\d\d)\b') { $rec.Http = $Matches[1] }
        $rec.Status = switch ($rec.Http) { '404' { 'NOT_FOUND' } '403' { 'FORBIDDEN' } '400' { 'BAD_REQUEST' } default { 'ERROR' } }
        $rec.Note   = $msg.Substring(0, [Math]::Min(220, $msg.Length))
    }
    return [pscustomobject]$rec
}

# == ASSET-ID DETECTOR == scans a parsed list payload for a per-asset id field that can seed the {assetId}
# fan-out. Returns @{ Field = '<name>'; Value = '<id>' } or $null. The VALUE is for in-memory fan-out only and
# is NEVER printed/written; only the FIELD NAME is reported (that is the load-bearing fact for the catalogue).
# Candidate field names in priority order (the {assetId} path is documented as a machine id in the OpenAPI).
function Find-AssetIdField {
    param([object]$Payload)
    if ($null -eq $Payload) { return $null }
    # locate the items array (asset rows)
    $items = $null
    if ($Payload -is [System.Collections.IEnumerable] -and $Payload -isnot [string] -and $Payload -isnot [System.Collections.IDictionary]) { $items = @($Payload) }
    elseif ($Payload -is [System.Collections.IDictionary]) {
        foreach ($c in @('value','data','Records','items','results','Results','assets')) {
            if ($Payload.Contains($c) -and ($Payload[$c] -is [System.Collections.IEnumerable]) -and ($Payload[$c] -isnot [string])) { $items = @($Payload[$c]); break }
        }
        if ($null -eq $items) { $items = @($Payload) }   # single-object payload: inspect it directly
    }
    if (-not $items -or $items.Count -eq 0) { return $null }
    $first = $items[0]
    if ($first -isnot [System.Collections.IDictionary]) { return $null }
    # priority: an explicit machine/asset/device id, then a bare 'id'
    $candidates = @('machineId','assetId','deviceId','assetGuid','machineGuid','id','Id')
    foreach ($cand in $candidates) {
        foreach ($k in @($first.Keys)) {
            if ("$k" -ieq $cand) {
                $v = $first[$k]
                if ($v -is [string] -and $v.Length -gt 0) { return @{ Field = "$k"; Value = $v } }
            }
        }
    }
    return $null
}

$svc = "$mtpBase/tvm/analytics"
$all = @()

Write-Host "`n========== TVM ASSET-LIST OPS (CRITICAL: asset-id detection) ==========" -ForegroundColor Magenta
# (1) CRITICAL FIRST — ListTopVulnerableAssets: does it project a per-asset id to seed the fan-out?
$topVuln = Probe-TvmGet -Label 'ListTopVulnerableAssets' -OperationId 'VulnerabilityManagement.ListTopVulnerableAssets' -Url "$svc/assets/topVulnerable" -Sess $session
$all += $topVuln

# (2) the rest of the asset/inventory list ops
$listOps = @(
    @{ L = 'GetVulnerableDevicesReport';        Op = 'VulnerabilityManagement.GetVulnerableDevicesReport';        P = '/vulnerableDevicesReport' }
    @{ L = 'ListProducts';                      Op = 'VulnerabilityManagement.ListProducts';                      P = '/products' }
    @{ L = 'ListCertificates';                  Op = 'VulnerabilityManagement.ListCertificates';                  P = '/certificates' }
    @{ L = 'ListExtensions';                    Op = 'VulnerabilityManagement.ListExtensions';                    P = '/extensions' }
    @{ L = 'ListAdvisories';                    Op = 'VulnerabilityManagement.ListAdvisories';                    P = '/advisories' }
    @{ L = 'ListChangeEvents';                  Op = 'VulnerabilityManagement.ListChangeEvents';                  P = '/changeEvents/' }
    @{ L = 'GetTopSoftwareChangeEventsPerDay';  Op = 'VulnerabilityManagement.GetTopSoftwareChangeEventsPerDay';  P = '/changeEvents/sca/topPerDay' }
    @{ L = 'GetTopVaChangeEventsPerDay';        Op = 'VulnerabilityManagement.GetTopVaChangeEventsPerDay';        P = '/changeEvents/va/topPerDay' }
)
foreach ($o in $listOps) {
    $r = Probe-TvmGet -Label $o.L -OperationId $o.Op -Url "$svc$($o.P)" -Sess $session
    $all += $r
    $col = if ($r.Status -like 'CONFIRMED*') { 'Green' } elseif ($r.Status -eq 'NOT_FOUND') { 'DarkGray' } else { 'Yellow' }
    Write-Host ("[tvm]   {0,-32} -> Http={1} {2} rows={3}" -f $o.L, $r.Http, $r.Status, $r.Rows) -ForegroundColor $col
}

# == ASSET-ID SEED DETECTION (the load-bearing finding) ==
# Scan ListTopVulnerableAssets first (the documented fan-out parent), then fall back to any other asset-list op
# that returned rows, to find a per-asset id field. The FIELD NAME is the catalogue-unblocking fact.
Write-Host "`n========== ASSET-ID FAN-OUT SEED DETECTION ==========" -ForegroundColor Magenta
$assetSeed = $null; $seedFromOp = ''
$seedOrder = @($topVuln) + @($all | Where-Object { $_.OperationId -in @('VulnerabilityManagement.GetVulnerableDevicesReport') -and $_.Status -like 'CONFIRMED*' })
foreach ($cand in $seedOrder) {
    if ($cand -and $cand.Status -like 'CONFIRMED*' -and $cand.Payload) {
        $found = Find-AssetIdField -Payload $cand.Payload
        if ($found) { $assetSeed = $found; $seedFromOp = $cand.OperationId; break }
    }
}
if ($assetSeed) {
    Write-Host "[tvm] ASSET-ID FIELD FOUND: '$($assetSeed.Field)' (projected by $seedFromOp) — this field can seed the {assetId} fan-out." -ForegroundColor Green
    Write-Host "[tvm]   (the id VALUE is held in-memory only for the GetAsset/ListAssetInstallations capture; never printed/written)" -ForegroundColor DarkGreen
} else {
    Write-Host "[tvm] NO per-asset id field detected in any confirmed TVM asset-list op (checked: machineId/assetId/deviceId/id). Fan-out remains un-seedable from a same-category op." -ForegroundColor Yellow
}

# == FAN-OUT CAPTURE (only if a real asset id was found) ==
Write-Host "`n========== {assetId} FAN-OUT OPS (GetAsset · ListAssetInstallations) ==========" -ForegroundColor Magenta
if ($assetSeed) {
    $aid = $assetSeed.Value
    $aidEnc = [uri]::EscapeDataString($aid)
    $fanOps = @(
        @{ L = 'GetAsset';               Op = 'VulnerabilityManagement.GetAsset';               P = "/assets/$aidEnc" }
        @{ L = 'ListAssetInstallations'; Op = 'VulnerabilityManagement.ListAssetInstallations'; P = "/assets/$aidEnc/installations" }
    )
    foreach ($o in $fanOps) {
        # RedactInUrl=$aidEnc so the recorded endpoint shows {assetId}, never the raw captured machine id.
        $r = Probe-TvmGet -Label $o.L -OperationId $o.Op -Url "$svc$($o.P)" -Sess $session -RedactInUrl $aidEnc -RedactMask '{assetId}'
        $all += $r
        $col = if ($r.Status -like 'CONFIRMED*') { 'Green' } elseif ($r.Status -eq 'NOT_FOUND') { 'DarkGray' } else { 'Yellow' }
        Write-Host ("[tvm]   {0,-32} -> Http={1} {2} rows={3}" -f $o.L, $r.Http, $r.Status, $r.Rows) -ForegroundColor $col
    }
} else {
    Write-Host "[tvm] (skipped GetAsset/ListAssetInstallations — no asset id was captured to substitute into {assetId}; reported, not fabricated)" -ForegroundColor DarkYellow
}

# == Final report ==
Write-Host "`n===== TVM SURFACE — RESULT TABLE =====" -ForegroundColor Cyan
$all | Format-Table Label, Http, ApiVersion, Status, Rows, Note -AutoSize | Out-String -Width 200 | Write-Host

Write-Host "`n===== CONFIRMED-ENDPOINT SHAPES =====" -ForegroundColor Cyan
foreach ($r in ($all | Where-Object { $_.Status -like 'CONFIRMED*' })) {
    Write-Host "`n--- $($r.Label)  [$($r.Url)]  rows=$($r.Rows) ---" -ForegroundColor Green
    $r.Shape | ConvertTo-Json -Depth 12 | Write-Host
}

$confirmed = @($all | Where-Object { $_.Status -like 'CONFIRMED*' }).Count
$assetIdMsg = if ($assetSeed) { "asset-id field='$($assetSeed.Field)' (from $seedFromOp)" } else { 'asset-id field=NONE-DETECTED' }
Write-Host "`n[tvm] confirmed=$confirmed endpoints · $assetIdMsg" -ForegroundColor Cyan
exit 0
