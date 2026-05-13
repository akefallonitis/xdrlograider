<#
.SYNOPSIS
    Operator-local online auth-chain validation (Defender XDR portal).

.DESCRIPTION
    Validates the full sccauth+XSRF auth chain end-to-end against
    security.microsoft.com BEFORE the operator deploys the connector.
    Also probes the NEW Phase 1 endpoints:
      - Get-DefenderTenantContext (Rule 21 dynamic regionality)
      - Get-XdrCustomCollectionRule (corrected path /mtp/mdeCustomCollection/rules)
      - One representative endpoint per Phase 1 sub-area (lightweight smoke)

    Run BEFORE deploy. Operators use a .env.local file for the test SA creds.

.PARAMETER EnvFile
    Path to .env.local (gitignored) with XDRLR_TEST_UPN / XDRLR_TEST_PASSWORD /
    XDRLR_TEST_TOTP_SECRET / AZURE_TENANT_ID. Default: ../tests/.env.local.

.OUTPUTS
    Exit 0 on auth-chain OK + TenantContext OK + Custom Collection OK.
    Exit 1 on any failure (full chain summary printed).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $EnvFile = (Join-Path $PSScriptRoot '..' 'tests' '.env.local')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not (Test-Path $EnvFile)) {
    Write-Host "Probe-Auth-Local: .env.local not found at $EnvFile" -ForegroundColor Red
    Write-Host "Create with: XDRLR_TEST_UPN=... / XDRLR_TEST_PASSWORD=... / XDRLR_TEST_TOTP_SECRET=... / AZURE_TENANT_ID=..."
    exit 1
}

Get-Content $EnvFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item -Path "env:$k" -Value $v
}

$tenant = $env:AZURE_TENANT_ID
$cred = @{
    upn        = $env:XDRLR_TEST_UPN
    password   = $env:XDRLR_TEST_PASSWORD
    totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
}

foreach ($k in @('AZURE_TENANT_ID','XDRLR_TEST_UPN','XDRLR_TEST_PASSWORD','XDRLR_TEST_TOTP_SECRET')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($k))) {
        Write-Host "Probe-Auth-Local: missing env var $k" -ForegroundColor Red
        exit 1
    }
}

# Import modules
$ordered = @('Xdr.Common.Auth','Xdr.Common.Manifest','Xdr.Common.Telemetry','Xdr.Defender.Auth','Xdr.Defender.Client','Xdr.Sentinel.Ingest','Xdr.Connector.Orchestrator')
foreach ($m in $ordered) {
    Import-Module (Join-Path $repoRoot "src/Modules/$m/$m.psd1") -Force
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Step, [string]$Status, [string]$Detail = '')
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host ("[{0,-4}] {1}" -f $Status, $Step) -ForegroundColor $color
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
    $results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
}

# ---- 1) Auth chain (sccauth+XSRF) ----
Write-Host "`n=== Auth chain ===" -ForegroundColor Cyan
$session = $null
try {
    $session = Connect-DefenderPortal -Method CredentialsTotp -Credential $cred -PortalHost 'security.microsoft.com' -TenantId $tenant -Force
    Add-Result -Step 'Connect-DefenderPortal' -Status 'OK' -Detail "Upn=$($session.Upn) Tenant=$($session.TenantId)"
} catch {
    Add-Result -Step 'Connect-DefenderPortal' -Status 'FAIL' -Detail $_.Exception.Message
    exit 1
}

# ---- 2) TenantContext (Rule 21) ----
Write-Host "`n=== TenantContext (Rule 21) ===" -ForegroundColor Cyan
try {
    $ctx = Get-DefenderTenantContext -Session $session.Session
    Add-Result -Step 'Get-DefenderTenantContext' -Status 'OK' -Detail "Region=$($ctx.Region) Datacenter=$($ctx.Datacenter)"
} catch {
    Add-Result -Step 'Get-DefenderTenantContext' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---- 3) Custom Collection corrected path ----
Write-Host "`n=== Custom Collection (Rule 8 path correction) ===" -ForegroundColor Cyan
try {
    $rules = Get-XdrCustomCollectionRule -Session $session.Session
    Add-Result -Step 'Get-XdrCustomCollectionRule' -Status 'OK' -Detail "Path /mtp/mdeCustomCollection/rules · returned $($rules.Count) rule(s)"
} catch {
    Add-Result -Step 'Get-XdrCustomCollectionRule' -Status 'FAIL' -Detail $_.Exception.Message
}

# ---- 4) Per-sub-area smoke (1 endpoint from each sub-area, low-risk) ----
Write-Host "`n=== Sub-area smoke (1 endpoint per sub-area) ===" -ForegroundColor Cyan
$manifest = Get-XdrEndpointManifest -Portal Defender
$bySubArea = @{}
foreach ($e in $manifest.Values) {
    $sub = $e.SubArea
    if (-not $bySubArea.ContainsKey($sub)) {
        # Pick the first entry WITHOUT path params (no fanout needed)
        if (-not $e.ContainsKey('PathParams') -or @($e.PathParams).Count -eq 0) {
            $bySubArea[$sub] = $e
        }
    }
}
foreach ($sub in @($bySubArea.Keys | Sort-Object)) {
    $e = $bySubArea[$sub]
    try {
        $rows = @(Invoke-MDEEndpoint -Session $session.Session -EntryKey $e.EntryKey)
        $r = Get-MDEEndpointLastResult
        Add-Result -Step "$sub :: $($e.Slug)" -Status $(if ($r.SuccessKind -in @('live','live-empty')) { 'OK' } else { 'FAIL' }) -Detail "HTTP=$($r.HttpStatus) Kind=$($r.SuccessKind) Rows=$($rows.Count)"
    } catch {
        Add-Result -Step "$sub :: $($e.Slug)" -Status 'FAIL' -Detail $_.Exception.Message
    }
}

# ---- Summary ----
$fail = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ''
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "  Total: $($results.Count) · OK: $(@($results | Where-Object Status -eq 'OK').Count) · FAIL: $($fail.Count) · SKIP: $(@($results | Where-Object Status -eq 'SKIP').Count)"

if ($fail.Count -gt 0) { exit 1 } else { exit 0 }
