#Requires -Version 7
<#
.SYNOPSIS
    Captures live JSON responses from every ACTIVE Defender XDR portal endpoint
    and writes them as test fixtures, so offline tests can validate parser +
    DCR schema + Sentinel-content column references without hitting the live
    tenant.

.DESCRIPTION
    For each entry in endpoints.manifest.psd1 where Deferred is not $true and
    the Path has no unresolved {placeholder}, this script:

      1. Calls Invoke-MDEPortalRequest to fetch the raw response.
      2. Writes the raw response to tests/fixtures/live-responses/<Stream>-raw.json
         (after PII redaction — GUIDs, UPNs, IPv4, bearer tokens).
      3. Feeds the response through Expand-MDEResponse + ConvertTo-MDEIngestRow
         (the same pipeline the Function App runs) and writes the resulting DCE
         rows to tests/fixtures/live-responses/<Stream>-ingest.json.
      4. Accumulates a summary (HTTP status, row count, bytes).

    Fixtures are the single source of truth for downstream schema / parser /
    column-reference tests. This script is the ONLY thing that talks to the
    live portal; everything else runs offline against the fixtures.

.PARAMETER OutDir
    Output folder (default: tests/fixtures/live-responses).

.PARAMETER IncludeDeferred
    Also attempt to capture deferred streams (expected to 4xx/5xx — useful for
    verifying the deferral classification).

.PARAMETER StreamFilter
    Optional wildcard to limit which streams are captured (e.g. 'MDE_PUA*').
    Default: all.

.PARAMETER NoRedact
    Skip PII redaction. Only use for debugging against non-production tenants.

.EXAMPLE
    # Full capture against live portal (28 active streams).
    pwsh ./tools/Capture-EndpointSchemas.ps1

.EXAMPLE
    # Capture only PUA-related streams, skip redaction.
    pwsh ./tools/Capture-EndpointSchemas.ps1 -StreamFilter 'MDE_PUA*' -NoRedact

.NOTES
    .env.local must be present at tests/.env.local with:
        XDRLR_TEST_UPN
        XDRLR_TEST_AUTH_METHOD = 'CredentialsTotp' | 'Passkey' | 'DirectCookies'
        (plus the fields for your chosen method; see tests/.env.local.example)

    Read-only — the script never writes to Log Analytics.
#>
[CmdletBinding()]
param(
    [string] $OutDir,
    [switch] $IncludeDeferred,
    [string] $StreamFilter = '*',
    [switch] $NoRedact
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $OutDir) {
    $OutDir = Join-Path $repoRoot 'tests' 'fixtures' 'live-responses'
}

# -------- Load .env.local ------------------------------------------------
$envFile = Join-Path $repoRoot 'tests' '.env.local'
if (-not (Test-Path $envFile)) {
    throw "Missing $envFile. Copy tests/.env.local.example and fill in credentials."
}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"'), 'Process')
    }
}

# -------- Import modules -------------------------------------------------
Import-Module (Join-Path $repoRoot 'src' 'Modules' 'Xdr.Portal.Auth'         'Xdr.Portal.Auth.psd1')         -Force
Import-Module (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Ingest'     'XdrLogRaider.Ingest.psd1')     -Force
Import-Module (Join-Path $repoRoot 'src' 'Modules' 'XdrLogRaider.Client'     'XdrLogRaider.Client.psd1')     -Force

# -------- Build session --------------------------------------------------
$portalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }
$authMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'DirectCookies' }
$upn        = $env:XDRLR_TEST_UPN

Write-Host "===== XdrLogRaider Live Schema Capture =====" -ForegroundColor Cyan
Write-Host ("Portal      : {0}" -f $portalHost)
Write-Host ("Auth method : {0}" -f $authMethod)
Write-Host ("UPN         : {0}" -f $upn)
Write-Host ("Out dir     : {0}" -f $OutDir)
Write-Host ("Redaction   : {0}" -f (-not $NoRedact))
Write-Host ""

Write-Host "Authenticating..." -NoNewline
$session = switch ($authMethod) {
    'DirectCookies' {
        if (-not $env:XDRLR_TEST_SCCAUTH -or -not $env:XDRLR_TEST_XSRF_TOKEN) {
            throw "DirectCookies method requires XDRLR_TEST_SCCAUTH + XDRLR_TEST_XSRF_TOKEN in .env.local"
        }
        Connect-MDEPortalWithCookies `
            -Sccauth   $env:XDRLR_TEST_SCCAUTH `
            -XsrfToken $env:XDRLR_TEST_XSRF_TOKEN `
            -Upn       $upn `
            -PortalHost $portalHost
    }
    'CredentialsTotp' {
        $cred = @{
            upn         = $upn
            password    = $env:XDRLR_TEST_PASSWORD
            totpBase32  = $env:XDRLR_TEST_TOTP_SECRET
        }
        Connect-MDEPortal -Method CredentialsTotp -Credential $cred -PortalHost $portalHost -Force
    }
    'Passkey' {
        $pk = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
        $cred = @{ upn = $upn; passkey = $pk }
        Connect-MDEPortal -Method Passkey -Credential $cred -PortalHost $portalHost -Force
    }
    default { throw "Unsupported auth method: $authMethod" }
}
Write-Host " OK" -ForegroundColor Green

# -------- Redaction helpers ---------------------------------------------
# Scrub anything that looks like a tenant-identifying token so fixtures are
# safe to commit. Patterns are conservative (match only well-known shapes).
# Tenant name is derived from UPN (everything before @, and the tenant prefix
# before .onmicrosoft.com) and added to the redaction list.
$script:tenantTokens = @()
if ($upn) {
    $parts = $upn -split '@'
    if ($parts.Count -eq 2) {
        $localPart = $parts[0]
        $domain    = $parts[1]
        # Tenant prefix (first label of domain), e.g. 'contoso' from 'contoso.onmicrosoft.com'
        $tenantPrefix = ($domain -split '\.')[0]
        $script:tenantTokens = @($localPart, $tenantPrefix, $domain) |
            Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object -Unique
    }
}

function Invoke-Redact {
    param([string] $Text)
    if ($NoRedact) { return $Text }

    # Bearer tokens (long base64 strings preceded by "Bearer ")
    $Text = $Text -replace '(?i)("authorization"\s*:\s*")Bearer\s+[A-Za-z0-9_\-.=]+(")', '$1Bearer REDACTED$2'

    # JWT-shaped access tokens
    $Text = $Text -replace 'eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+', 'REDACTED-JWT'

    # GUIDs (36-char UUID)
    $Text = [regex]::Replace($Text, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '00000000-0000-0000-0000-000000000000')

    # Email-shaped identifiers (UPNs)
    $Text = [regex]::Replace($Text, '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b', 'user@example.com')

    # IPv4 addresses
    $Text = [regex]::Replace($Text, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '0.0.0.0')

    # Device hashes / device-ids (40+ hex)
    $Text = [regex]::Replace($Text, '\b[0-9a-f]{40,}\b', 'REDACTED-HASH')

    # Tenant-name tokens derived from UPN (case-insensitive)
    foreach ($token in $script:tenantTokens) {
        $escaped = [regex]::Escape($token)
        $Text = [regex]::Replace($Text, $escaped, 'example-tenant', 'IgnoreCase')
    }

    return $Text
}

# -------- Walk the manifest ---------------------------------------------
$manifest = Get-MDEEndpointManifest
$entries  = @($manifest.Values)

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host ("Manifest has {0} entries; filter='{1}'; include deferred={2}" -f $entries.Count, $StreamFilter, [bool]$IncludeDeferred)
Write-Host ""

$summary = @()
$i = 0
foreach ($entry in ($entries | Sort-Object Tier, Stream)) {
    $i++
    $stream   = $entry.Stream
    $path     = $entry.Path
    $tier     = $entry.Tier
    $method   = if ($entry.ContainsKey('Method') -and $entry.Method) { $entry.Method } else { 'GET' }
    $body     = if ($entry.ContainsKey('Body')   -and $entry.Body)   { $entry.Body }   else { $null }
    $deferred = [bool]($entry.ContainsKey('Deferred') -and $entry.Deferred)
    $hasPlaceholder = $path -match '\{[^}]+\}'

    if ($stream -notlike $StreamFilter) {
        continue
    }

    $row = [pscustomobject]@{
        Stream         = $stream
        Tier           = $tier
        Deferred       = $deferred
        Method         = $method
        Path           = $path
        Status         = '-'
        RawPath        = ''
        IngestPath     = ''
        RawSizeBytes   = 0
        IngestRowCount = 0
        Notes          = ''
    }

    if ($deferred -and -not $IncludeDeferred) {
        $row.Status = 'SKIP-deferred'
        $row.Notes  = 'deferred (use -IncludeDeferred to attempt)'
        $summary += $row
        Write-Host ("  [{0,2}/{1}] {2,-4} {3,-38} {4}" -f $i, $entries.Count, $tier, $stream, 'SKIP-deferred') -ForegroundColor DarkGray
        continue
    }
    if ($hasPlaceholder) {
        $row.Status = 'SKIP-pathparam'
        $row.Notes  = 'path has unresolved {placeholder}'
        $summary += $row
        Write-Host ("  [{0,2}/{1}] {2,-4} {3,-38} {4}" -f $i, $entries.Count, $tier, $stream, 'SKIP-pathparam') -ForegroundColor DarkGray
        continue
    }

    # -------- Fetch live --------
    try {
        $resp = Invoke-MDEPortalRequest -Session $session -Path $path -Method $method -Body $body -ErrorAction Stop
        $row.Status = '200'
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'ERR' }
        $row.Status = [string]$code
        $row.Notes  = ($_.Exception.Message -split "`n" | Select-Object -First 1)
        $summary += $row
        Write-Host ("  [{0,2}/{1}] {2,-4} {3,-38} {4}  {5}" -f $i, $entries.Count, $tier, $stream, $row.Status, $row.Notes) -ForegroundColor Yellow
        Start-Sleep -Milliseconds 200
        continue
    }

    # -------- Raw fixture --------
    $rawJson = if ($null -eq $resp) { 'null' } else { $resp | ConvertTo-Json -Depth 20 -Compress:$false }
    $rawJson = Invoke-Redact -Text $rawJson
    $rawPath = Join-Path $OutDir ("{0}-raw.json" -f $stream)
    $rawJson | Out-File -FilePath $rawPath -Encoding utf8 -NoNewline
    $row.RawPath      = [IO.Path]::GetRelativePath($repoRoot, $rawPath)
    $row.RawSizeBytes = (Get-Item $rawPath).Length

    # -------- Ingest-row fixture --------
    # Same pipeline as the Function App: Expand-MDEResponse -> ConvertTo-MDEIngestRow.
    # Always emits an ingest file (even '[]') so downstream tests can rely on presence.
    $ingestPath = Join-Path $OutDir ("{0}-ingest.json" -f $stream)
    try {
        $expandArgs = @{ Response = $resp }
        if ($entry.ContainsKey('IdProperty') -and $entry.IdProperty) {
            $expandArgs['IdProperty'] = [string[]]$entry.IdProperty
        }
        $rows = @(
            foreach ($pair in (Expand-MDEResponse @expandArgs)) {
                # $pair.Entity can be $null or @() for responses shaped like
                # {"items":[]} — PS projects those as null values. Substitute an
                # empty pscustomobject so ConvertTo-MDEIngestRow's mandatory -Raw binds.
                $entityRaw = $pair.Entity
                if ($null -eq $entityRaw -or ($entityRaw -is [array] -and @($entityRaw).Count -eq 0)) {
                    $entityRaw = [pscustomobject]@{}
                }
                ConvertTo-MDEIngestRow -Stream $stream -EntityId $pair.Id -Raw $entityRaw
            }
        )
        $row.IngestRowCount = $rows.Count
        $ingestJson = if ($rows.Count -gt 0) { $rows | ConvertTo-Json -Depth 20 } else { '[]' }
    } catch {
        $row.Notes     = "ingest-flatten failed: $($_.Exception.Message)"
        $ingestJson    = '[]'
    }
    $ingestJson = Invoke-Redact -Text $ingestJson
    $ingestJson | Out-File -FilePath $ingestPath -Encoding utf8 -NoNewline
    $row.IngestPath = [IO.Path]::GetRelativePath($repoRoot, $ingestPath)

    $summary += $row
    Write-Host ("  [{0,2}/{1}] {2,-4} {3,-38} {4}  rows={5,-4} raw={6,6}B" -f `
        $i, $entries.Count, $tier, $stream, $row.Status, $row.IngestRowCount, $row.RawSizeBytes) -ForegroundColor Green

    # Be gentle on the portal
    Start-Sleep -Milliseconds 250
}

# -------- Write summary --------
$summaryPath = Join-Path $OutDir '_capture-summary.json'
$summary | ConvertTo-Json -Depth 4 | Out-File -FilePath $summaryPath -Encoding utf8

$captured = @($summary | Where-Object Status -eq '200').Count
$skipped  = @($summary | Where-Object { $_.Status -like 'SKIP*' }).Count
$errored  = @($summary | Where-Object { $_.Status -notlike 'SKIP*' -and $_.Status -ne '200' }).Count

Write-Host ""
Write-Host ("Captured : {0}" -f $captured) -ForegroundColor Green
Write-Host ("Skipped  : {0}" -f $skipped)  -ForegroundColor DarkGray
Write-Host ("Errored  : {0}" -f $errored)  -ForegroundColor $(if ($errored -gt 0) { 'Yellow' } else { 'DarkGray' })
Write-Host ("Summary  : {0}" -f ([IO.Path]::GetRelativePath($repoRoot, $summaryPath)))
Write-Host ""

if ($errored -gt 0) {
    $summary | Where-Object { $_.Status -notlike 'SKIP*' -and $_.Status -ne '200' } |
        Select-Object Stream, Tier, Status, Notes |
        Format-Table -AutoSize
}

Write-Host "Done." -ForegroundColor Cyan
