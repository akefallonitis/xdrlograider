<#
.SYNOPSIS
    Schema validator for manifests/defender.psd1.

.DESCRIPTION
    Loads the manifest via the runtime path (Get-XdrEndpointManifest), then
    runs structural checks that complement the Pester unit tests. Used by
    Preflight-Local.ps1 + CI gates.

.PARAMETER ManifestPath
    Path to manifests/defender.psd1.

.OUTPUTS
    Exit 0 on pass, 1 on failure.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ManifestPath = (Resolve-Path $ManifestPath).Path
$errors = New-Object System.Collections.Generic.List[string]

# Two-stage parse (Phase 1 manifest > 95KB)
$raw = $null
try {
    $raw = Import-PowerShellDataFile -Path $ManifestPath -ErrorAction Stop
} catch {
    $raw = & ([scriptblock]::Create((Get-Content -Raw -Path $ManifestPath)))
}

if (-not $raw.Endpoints) { $errors.Add('Missing Endpoints array') }
if (-not $raw.Defaults)  { $errors.Add('Missing Defaults block') }

$entryCount = $raw.Endpoints.Count
if ($entryCount -ne 493) { $errors.Add("Expected 493 entries (492 read + 1 synthetic TenantContext); got $entryCount") }

# Phase 1 sub-areas
$expectedSubAreas = @(
    'action_center','attack_simulator','cloud_apps','configuration','data_lake',
    'endpoint_configuration','endpoint_devices','entity_pivots','exposure_management',
    'files','identity','multi_tenant','portal_services','secure_score',
    'sentinel_precision','streaming','threat_analytics','vulnerability_management'
)
$presentSubAreas = @($raw.Endpoints | ForEach-Object { $_['SubArea'] } | Sort-Object -Unique)
$missing = $expectedSubAreas | Where-Object { $_ -notin $presentSubAreas }
foreach ($m in $missing) { $errors.Add("Sub-area missing: $m") }

# Wholesale-excluded
$forbidden = @('advanced_hunting','alerts_incidents','live_response','common')
foreach ($f in $forbidden) {
    if ($presentSubAreas -contains $f) { $errors.Add("Sub-area MUST be excluded: $f") }
}

# Stream naming (Rule 5)
$badStreams = @($raw.Endpoints | Where-Object { $_['Stream'] -notmatch '^Defender_[A-Z][A-Za-z0-9]+_CL$' })
if ($badStreams.Count -gt 0) {
    $errors.Add("$($badStreams.Count) entries violate Rule 5 stream naming (Defender_<Pascal>_CL)")
}

# EntryKey uniqueness
$keys = @($raw.Endpoints | ForEach-Object { $_['EntryKey'] })
$unique = ($keys | Sort-Object -Unique).Count
if ($keys.Count -ne $unique) {
    $errors.Add("EntryKey collision: $($keys.Count) entries, $unique unique keys")
}

# Availability=live (Rule 23)
$nonLive = @($raw.Endpoints | Where-Object { $_['Availability'] -ne 'live' })
if ($nonLive.Count -gt 0) { $errors.Add("$($nonLive.Count) entries have Availability != 'live' (Rule 23)") }

# MaxPages caps (Rule 14)
$rule14 = @{
    'vulnerability_management' = 1000
    'endpoint_devices' = 200
    'cloud_apps' = 200
    'identity' = 200
    'exposure_management' = 200
}
foreach ($sub in $rule14.Keys) {
    $sample = @($raw.Endpoints | Where-Object { $_['SubArea'] -eq $sub } | Select-Object -First 1)
    if ($sample.Count -gt 0 -and $sample[0]['MaxPages'] -ne $rule14[$sub]) {
        $errors.Add("Rule 14 violation: $sub MaxPages should be $($rule14[$sub]); got $($sample[0]['MaxPages'])")
    }
}

# Custom Collection path correction (must use /mtp/mdeCustomCollection)
$badCustomCollection = @($raw.Endpoints | Where-Object { $_['Path'] -match '/mtp/customDataCollection' })
if ($badCustomCollection.Count -gt 0) {
    $errors.Add("$($badCustomCollection.Count) Custom Collection entries still use /mtp/customDataCollection (404). Path must be /mtp/mdeCustomCollection.")
}

# TenantContext entry must exist
$tc = @($raw.Endpoints | Where-Object { $_['EntryKey'] -eq 'portal_services::GetTenantContext' })
if ($tc.Count -ne 1) { $errors.Add("Synthetic TenantContext entry missing or duplicated") }

# ----- Report ----------------------------------------------------------------
if ($errors.Count -gt 0) {
    Write-Host "Validate-Manifest: $($errors.Count) issue(s):" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

Write-Host "Validate-Manifest: OK ($entryCount entries · $(($presentSubAreas).Count) sub-areas)" -ForegroundColor Green
exit 0
