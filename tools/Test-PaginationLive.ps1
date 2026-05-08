<#
.SYNOPSIS
    LIVE pagination support tester. Invokes a Defender XDR portal endpoint
    twice (pageIndex=1 + pageIndex=2) and reports whether the API actually
    paginates (different rows per page) or just ignores pageIndex (same
    data; can't paginate; would cause duplicates if added to manifest).

.DESCRIPTION
    Per operator directive 2026-05-08: "verify live tests, don't rely only
    on nodoc and openapi". Decisions on adding Pagination config to manifest
    streams need live confirmation that the underlying API supports it.

    For each candidate stream, this tool:
      1. Fetches an Defender portal session via existing auth chain
      2. Calls endpoint with ?pageIndex=1&pageSize=N
      3. Calls endpoint with ?pageIndex=2&pageSize=N
      4. Compares row IDs across both responses
      5. Reports: PAGINATES (different rows), NO-PAGINATION (same rows),
         EMPTY (no data to test)

.PARAMETER Stream
    Stream name to test (e.g. MDE_ActionCenter_CL).

.PARAMETER PageSize
    Page size for the two test calls. Default: 50.

.EXAMPLE
    pwsh tools/Test-PaginationLive.ps1 -Stream MDE_ActionCenter_CL
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Stream,
    [int] $PageSize = 50
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Load manifest entry
$manifest = Import-PowerShellDataFile -Path (Join-Path $RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
$entry = $manifest.Endpoints | Where-Object Stream -eq $Stream | Select-Object -First 1
if (-not $entry) { throw "Stream '$Stream' not in manifest" }

$basePath = $entry.Path

# Construct paginated URLs
$page1Path = if ($basePath -match '\?') { "$basePath&pageIndex=1&pageSize=$PageSize" } else { "$basePath?pageIndex=1&pageSize=$PageSize" }
$page2Path = if ($basePath -match '\?') { "$basePath&pageIndex=2&pageSize=$PageSize" } else { "$basePath?pageIndex=2&pageSize=$PageSize" }

Write-Host "=== Pagination Live Test: $Stream ==="
Write-Host "Page 1: $page1Path"
Write-Host "Page 2: $page2Path"
Write-Host ""

# Use modules — load Xdr.Defender.Auth + invoke session
$modPath = Join-Path $RepoRoot 'src/Modules/Xdr.Defender.Auth'
Import-Module (Join-Path $modPath 'Xdr.Defender.Auth.psd1') -Force -ErrorAction Stop

# Get auth from KV (operator must have KV Secrets User on xdrlr-kv-5lsncl)
Write-Host "Fetching auth from KV..."
try {
    $auth = Get-XdrAuthFromKeyVault -KeyVaultName 'xdrlr-kv-5lsncl' -AuthSecretName 'mde-portal' -CacheTtlMinutes 0 -ErrorAction Stop
    $session = Connect-DefenderPortal -AuthBundle $auth -PortalHost 'security.microsoft.com' -ErrorAction Stop
    Write-Host "Auth OK; Session connected to $($session.PortalHost)"
} catch {
    Write-Host "Auth failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

function Invoke-Page {
    param([string] $Path)
    try {
        $r = Invoke-DefenderPortalRequest -Session $session -Path $Path -Method 'GET' -ErrorAction Stop
        return $r
    } catch {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

Write-Host ""
Write-Host "Calling page 1..."
$r1 = Invoke-Page -Path $page1Path
Write-Host "Calling page 2..."
$r2 = Invoke-Page -Path $page2Path

if (-not $r1 -or -not $r2) {
    Write-Host "[INCONCLUSIVE] One of the calls failed" -ForegroundColor Yellow
    return
}

# Try multiple wrapper field names
$unwrap = $entry.UnwrapProperty
function Get-Items {
    param($Resp, $Wrap)
    if ($Wrap -and $Resp.PSObject.Properties[$Wrap]) { return @($Resp.$Wrap) }
    if ($Resp -is [array]) { return @($Resp) }
    return @()
}
$items1 = Get-Items -Resp $r1 -Wrap $unwrap
$items2 = Get-Items -Resp $r2 -Wrap $unwrap
Write-Host ""
Write-Host "Page 1 items: $($items1.Count)"
Write-Host "Page 2 items: $($items2.Count)"

if ($items1.Count -eq 0) {
    Write-Host "[EMPTY] No data on page 1 — cannot test pagination" -ForegroundColor Yellow
    return
}
if ($items2.Count -eq 0) {
    Write-Host "[NO-PAGINATION-OR-LT-PAGESIZE] Page 2 empty. Could mean: (a) total < $PageSize so only 1 page exists; (b) API doesn't paginate. Inconclusive." -ForegroundColor Yellow
    return
}

# Extract IDs (best-effort — try multiple common id fields)
function Get-Id { param($Item)
    foreach ($k in @('Id','id','ActionId','MachineId','RuleId','IndicatorId','machineGroupId','GroupId')) {
        if ($Item.PSObject.Properties[$k]) { return [string]$Item.$k }
    }
    return ($Item | ConvertTo-Json -Compress -Depth 2)
}
$ids1 = $items1 | ForEach-Object { Get-Id -Item $_ }
$ids2 = $items2 | ForEach-Object { Get-Id -Item $_ }
$overlap = @($ids1 | Where-Object { $_ -in $ids2 })
Write-Host "Overlap (same IDs in both pages): $($overlap.Count) of $($ids1.Count)"

if ($overlap.Count -eq $items1.Count -and $overlap.Count -eq $items2.Count) {
    Write-Host "[NO-PAGINATION] Same rows on both pages — API ignores pageIndex" -ForegroundColor Red
    Write-Host "  -> DO NOT add Pagination config to manifest (would cause duplicates)"
} elseif ($overlap.Count -eq 0) {
    Write-Host "[PAGINATES] Different rows per page — pagination works" -ForegroundColor Green
    Write-Host "  -> SAFE to add Pagination config to manifest"
} else {
    Write-Host "[PARTIAL-OVERLAP] Some IDs duplicate — investigate (sort instability or ranking-only pagination?)" -ForegroundColor Yellow
}
