# Hits every path in endpoints.manifest.psd1 against the live portal using an
# authenticated session, and records HTTP status + payload shape per stream.
# Output: tests/results/endpoint-audit-<timestamp>.csv + .md summary.
#
# Purpose: catch manifest drift early — a path that returns 404 on the live
# portal needs fixing before the Function App tries to poll it in production.
#
# Usage (after env vars set in tests/.env.local):
#   pwsh ./tests/integration/Audit-Endpoints-Live.ps1
#
# Runs under ~2 minutes for 52 streams. Does NOT ingest — read-only probe.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Load .env.local
Get-Content "$repoRoot/tests/.env.local" | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"'), 'Process')
    }
}

Import-Module "$repoRoot/src/Modules/Xdr.Portal.Auth/Xdr.Portal.Auth.psd1"         -Force
Import-Module "$repoRoot/src/Modules/XdrLogRaider.Ingest/XdrLogRaider.Ingest.psd1" -Force
Import-Module "$repoRoot/src/Modules/XdrLogRaider.Client/XdrLogRaider.Client.psd1" -Force

$portalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }
$authMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

$credential = switch ($authMethod) {
    'CredentialsTotp' { @{ upn = $env:XDRLR_TEST_UPN; password = $env:XDRLR_TEST_PASSWORD; totpBase32 = $env:XDRLR_TEST_TOTP_SECRET } }
    'Passkey'         { @{ upn = $env:XDRLR_TEST_UPN; passkey = (Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json) } }
    default           { throw "Unsupported auth method for audit: $authMethod" }
}

Write-Host "===== XdrLogRaider Endpoint Audit ====="
Write-Host "Portal    : $portalHost"
Write-Host "Method    : $authMethod"
Write-Host "UPN       : $($credential.upn)"
Write-Host ""

Write-Host "Authenticating..."
$session = Connect-MDEPortal -Method $authMethod -Credential $credential -PortalHost $portalHost -Force
Write-Host "  sccauth acquired (TenantId $($session.TenantId))"
Write-Host ""

$manifest = Get-MDEEndpointManifest   # returns hashtable keyed by Stream name
$entries  = @($manifest.Values)       # flatten to array for iteration
Write-Host "Probing $($entries.Count) endpoints..."

$results = @()
$i = 0
foreach ($entry in $entries) {
    $i++
    # Entries are hashtables.
    $stream = $entry.Stream
    $path   = $entry.Path
    $tier   = $entry.Tier
    $filter = $entry.Filter

    # Probe with a 1-hour back FromUtc so we exercise filter handling on filterable paths.
    $fromUtc = [datetime]::UtcNow.AddHours(-1)
    $probePath = $path
    if ($filter) {
        $iso = $fromUtc.ToString('o')
        $sep = if ($path.Contains('?')) { '&' } else { '?' }
        $probePath = "$path$sep$filter=$([uri]::EscapeDataString($iso))"
    }

    $status = 'unknown'; $payloadShape = ''; $durationMs = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-MDEPortalRequest -Session $session -Path $probePath -Method GET -ErrorAction Stop
        $sw.Stop()
        $status = '200'
        if ($null -eq $resp) {
            $payloadShape = 'null'
        } elseif ($resp -is [array]) {
            $payloadShape = "array[$($resp.Count)]"
        } elseif ($resp -is [pscustomobject]) {
            $propCount = @($resp.PSObject.Properties.Name).Count
            $payloadShape = "object[$propCount props]"
        } else {
            $payloadShape = $resp.GetType().Name
        }
    } catch {
        $sw.Stop()
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        } else {
            $status = 'ERR'
        }
        $payloadShape = ($_.Exception.Message -split "`n" | Select-Object -First 1).Substring(0, [math]::Min(80, ($_.Exception.Message -split "`n")[0].Length))
    }
    $durationMs = [int]$sw.ElapsedMilliseconds

    $results += [pscustomobject]@{
        Stream      = $stream
        Tier        = $tier
        Path        = $path
        Filter      = $filter
        Status      = $status
        PayloadShape = $payloadShape
        DurationMs  = $durationMs
    }

    $colour = switch ($status) { '200' { 'Green' } '404' { 'Yellow' } default { 'Red' } }
    Write-Host ("  [{0,3}/{1}] {2,-8} {3,-40} {4,-4} {5,6}ms  {6}" -f $i, $manifest.Count, $tier, $stream, $status, $durationMs, $payloadShape) -ForegroundColor $colour

    # Be gentle on the portal — don't hammer.
    Start-Sleep -Milliseconds 200
}

# --- Reporting ---
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsDir = "$repoRoot/tests/results"
New-Item -Path $resultsDir -ItemType Directory -Force | Out-Null
$csvPath = "$resultsDir/endpoint-audit-$timestamp.csv"
$mdPath  = "$resultsDir/endpoint-audit-$timestamp.md"

$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ""
Write-Host "CSV: $csvPath"

$summary = $results | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
    "| $($_.Name) | $($_.Count) |"
}
$md = @"
# Endpoint Audit Report — $timestamp

**Portal**: $portalHost
**Method**: $authMethod
**Total streams**: $($results.Count)

## Status summary

| Status | Count |
|---|---|
$($summary -join "`n")

## All probes

| Stream | Tier | Path | Filter | Status | Shape | ms |
|---|---|---|---|---|---|---|
$($results | ForEach-Object {
    "| $($_.Stream) | $($_.Tier) | `$($_.Path)` | $($_.Filter) | **$($_.Status)** | $($_.PayloadShape) | $($_.DurationMs) |"
} | Out-String)
"@
$md | Out-File $mdPath
Write-Host "MD : $mdPath"

$ok    = ($results | Where-Object Status -eq '200').Count
$notOk = $results.Count - $ok
Write-Host ""
Write-Host "VERDICT: $ok/$($results.Count) endpoints returned 200; $notOk need review." -ForegroundColor $(if ($notOk -eq 0) { 'Green' } else { 'Yellow' })
