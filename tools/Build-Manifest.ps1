<#
.SYNOPSIS
    Generates manifests/defender.psd1 from references/defender/<sub-area>/<endpoint>/metadata.json catalogue.

.DESCRIPTION
    Reads 509 endpoint metadata.json files captured during Phase 0; filters to
    492 read-only endpoints (readSemantics='read'); maps each into a manifest
    entry consumed by Invoke-MDEEndpoint at runtime. Adds one synthetic
    entry for the TenantContext endpoint so Get-DefenderTenantContext is
    represented in the manifest (used by the connector-health roll-up).

    Output is a single PSD1 hashtable with two top-level keys:
      Defaults  — defaults block (Portal, IdProperty, ProjectionMap, etc.)
      Endpoints — flat array of 493 entries

    Each entry carries:
      Stream            target table (Defender_<PascalCaseSubArea>_CL)
      Path              portal API path (incl. {placeholder} path params if any)
      Method            GET (default) — write-shaped excluded
      Tier              cadence tier driving per-sub-area timer cron
      Category          sub-area display name
      SubArea           nodoc sub-area slug (action_center, etc.)
      Slug              endpoint slug from metadata.json
      Cadence           operator-facing cadence label (10min/1h/6h/daily/weekly)
      Pagination        @{ Style; IndexParam; TokenParam; SizeParam } per metadata
      TimeFilter        @{ Supported; StartParam; EndParam; LookbackParam; Type }
      PathParams        string[] of {placeholder} names extracted from Path
      MaxPages          per Rule 14 cap (vuln_mgmt=1000; devices/cloud/identity/exposure=200; others=50)
      LicenseHint       string (empty default; sidecar-mapped where known)
      AuditScope        'portal-only' (default; Microsoft has no equivalent public API)
      ProjectionMap     empty hashtable in Phase 1 (typed-col extraction lands v0.3.0)
      Availability      'live' (per Rule 23 — license gaps are runtime, not manifest)

.PARAMETER ReferencesRoot
    Directory containing references/defender/<sub-area>/<endpoint>/metadata.json
    files. Defaults to ../references/defender relative to this script.

.PARAMETER OutputPath
    Output .psd1 path. Defaults to ../manifests/defender.psd1.

.EXAMPLE
    pwsh ./tools/Build-Manifest.ps1
    # Generates manifests/defender.psd1 with 493 entries

.NOTES
    Custom Collection path was corrected in Phase 0 from /mtp/customDataCollection/rules
    (404) to /mtp/mdeCustomCollection/rules (HTTP 200, XDRInternals canonical).
    The corrected path is already baked into the source metadata.json files;
    this builder does not re-correct.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $ReferencesRoot = (Join-Path $PSScriptRoot '..' 'references' 'defender'),
    [string] $OutputPath     = (Join-Path $PSScriptRoot '..' 'manifests' 'defender.psd1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-PascalCase {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Snake)
    $parts = $Snake -split '_'
    ($parts | ForEach-Object {
        if ($_.Length -eq 0) { return '' }
        $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
    }) -join ''
}

function Get-MaxPagesForSubArea {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string] $SubArea)
    switch ($SubArea) {
        'vulnerability_management' { 1000 }
        'endpoint_devices'         { 200 }
        'cloud_apps'               { 200 }
        'identity'                 { 200 }
        'exposure_management'      { 200 }
        default                    { 50 }
    }
}

function Get-TierFromCadence {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Cadence)
    switch ($Cadence) {
        '10min'  { 'ActionCenter' }
        '1h'     { 'XspmGraph' }
        '6h'     { 'Configuration' }
        'daily'  { 'Inventory' }
        'weekly' { 'Maintenance' }
        default  { 'Inventory' }
    }
}

function ConvertTo-PsdLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        $Value,
        [int] $Indent = 0
    )
    $pad = ' ' * $Indent
    # PSD1 strict-parser rejects $null (dynamic expression). Use empty string
    # as the null sentinel; consumers check IsNullOrEmpty.
    if ($null -eq $Value) { return "''" }
    if ($Value -is [bool])    { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    if ($Value -is [string]) {
        # PSD1 strict-parser: use single quotes; escape embedded single quotes by doubling
        return "'" + ($Value -replace "'", "''") + "'"
    }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Value.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($key in $Value.Keys) {
            $keyToken = if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { [string]$key } else { "'$([string]$key -replace "'", "''")'" }
            $rendered = ConvertTo-PsdLiteral -Value $Value[$key] -Indent ($Indent + 4)
            $lines += "$pad    $keyToken = $rendered"
        }
        $lines += "$pad}"
        return ($lines -join "`n")
    }
    if ($Value -is [pscustomobject]) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return '@{}' }
        $lines = @('@{')
        foreach ($p in $props) {
            $keyToken = if ($p.Name -match '^[A-Za-z_][A-Za-z0-9_]*$') { $p.Name } else { "'$($p.Name -replace "'", "''")'" }
            $rendered = ConvertTo-PsdLiteral -Value $p.Value -Indent ($Indent + 4)
            $lines += "$pad    $keyToken = $rendered"
        }
        $lines += "$pad}"
        return ($lines -join "`n")
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $arr = @($Value)
        if ($arr.Count -eq 0) { return '@()' }
        $items = $arr | ForEach-Object { ConvertTo-PsdLiteral -Value $_ -Indent ($Indent + 4) }
        if (($items | Where-Object { $_ -match "`n" } | Measure-Object).Count -eq 0 -and ($items -join ', ').Length -lt 100) {
            return '@(' + ($items -join ', ') + ')'
        }
        $lines = @('@(')
        foreach ($i in $items) { $lines += "$pad    $i" }
        $lines += "$pad)"
        return ($lines -join "`n")
    }
    # Fallback: coerce to string
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

# ----------- 1) Collect read-only entries ------------------------------------
$ReferencesRoot = (Resolve-Path $ReferencesRoot).Path
Write-Verbose "Reading metadata from $ReferencesRoot"

$metaFiles = Get-ChildItem -Path $ReferencesRoot -Recurse -Filter 'metadata.json' -File
$entries   = New-Object System.Collections.Generic.List[object]
$skipped   = 0

foreach ($f in $metaFiles) {
    $m = $null
    try { $m = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json -Depth 30 } catch { continue }
    if (-not $m) { continue }

    if ($m.readSemantics -ne 'read') { $skipped++; continue }

    $subArea = [string]$m.subArea
    $slug    = [string]$m.slug
    $path    = [string]$m.path
    $methods = @($m.methods)
    # Filter by INTENT (readSemantics), NOT HTTP method. POST-style "search" reads
    # are still reads (Phase 0 audit § O).
    $method = if ($methods -contains 'get') { 'GET' } elseif ($methods -contains 'post') { 'POST' } else { 'GET' }

    $pascalSub = ConvertTo-PascalCase -Snake $subArea
    $stream    = "Defender_${pascalSub}_CL"

    $pathParams = @()
    foreach ($mp in ([regex]::Matches($path, '\{([A-Za-z0-9_]+)\}'))) {
        $pathParams += $mp.Groups[1].Value
    }

    $pagination = [ordered]@{}
    if ($m.pagination) {
        $pagination['Style']      = [string]$m.pagination.style
        $pagination['IndexParam'] = $m.pagination.indexParam
        $pagination['TokenParam'] = $m.pagination.tokenParam
        $pagination['SizeParam']  = $m.pagination.sizeParam
    } else {
        $pagination['Style'] = 'none'
    }

    $timeFilter = [ordered]@{}
    if ($m.timeFilter) {
        $timeFilter['Supported']     = [bool]$m.timeFilter.supported
        $timeFilter['Type']          = $m.timeFilter.type
        $timeFilter['StartParam']    = $m.timeFilter.startParam
        $timeFilter['EndParam']      = $m.timeFilter.endParam
        $timeFilter['LookbackParam'] = $m.timeFilter.lookbackParam
    } else {
        $timeFilter['Supported'] = $false
    }

    $cadence = if ($m.PSObject.Properties['suggestedCadence']) { [string]$m.suggestedCadence } else { 'daily' }
    if ([string]::IsNullOrWhiteSpace($cadence)) { $cadence = 'daily' }
    $tier = Get-TierFromCadence -Cadence $cadence

    $entry = [ordered]@{
        EntryKey      = "${subArea}::${slug}"
        Stream        = $stream
        Path          = $path
        Method        = $method
        Tier          = $tier
        Category      = $subArea
        SubArea       = $subArea
        Slug          = $slug
        Cadence       = $cadence
        Pagination    = $pagination
        TimeFilter    = $timeFilter
        PathParams    = $pathParams
        MaxPages      = Get-MaxPagesForSubArea -SubArea $subArea
        LicenseHint   = ''
        AuditScope    = 'portal-only'
        ProjectionMap = [ordered]@{}
        Availability  = 'live'
    }
    $entries.Add([pscustomobject]$entry)
}

# ----------- 2) Add synthetic TenantContext entry under portal_services ------
$entries.Add([pscustomobject]([ordered]@{
    EntryKey      = 'portal_services::GetTenantContext'
    Stream        = 'Defender_PortalServices_CL'
    Path          = '/mtp/sccManagement/mgmt/TenantContext?realTime=true'
    Method        = 'GET'
    Tier          = 'Inventory'
    Category      = 'portal_services'
    SubArea       = 'portal_services'
    Slug          = 'GetTenantContext'
    Cadence       = 'daily'
    Pagination    = [ordered]@{ Style = 'none' }
    TimeFilter    = [ordered]@{ Supported = $false }
    PathParams    = @()
    MaxPages      = 1
    LicenseHint   = ''
    AuditScope    = 'portal-only'
    ProjectionMap = [ordered]@{}
    Availability  = 'live'
}))

Write-Host "Manifest entries: $($entries.Count) (skipped non-read: $skipped)"

# ----------- 3) Emit PSD1 ----------------------------------------------------
$header = @"
@{
    # ============================================================================
    # Generated by tools/Build-Manifest.ps1 — DO NOT HAND-EDIT
    # ============================================================================
    # Source: references/defender/<sub-area>/<endpoint>/metadata.json
    # Entry count: $($entries.Count) (492 catalogue read + 1 synthetic TenantContext)
    # Deterministic regeneration: rebuilding from the same metadata produces
    # a byte-identical output (Preflight-Local § 6 enforces this).
    #
    # Per-entry schema:
    #   Stream         target table (Defender_<PascalCaseSubArea>_CL)
    #   Path           portal API path (relative to https://security.microsoft.com/apiproxy)
    #   Method         'GET' (write-shaped excluded at build time)
    #   Tier           cadence tier (ActionCenter/XspmGraph/Configuration/Inventory/Maintenance)
    #   Category       sub-area display name
    #   SubArea        nodoc sub-area slug
    #   Slug           endpoint slug
    #   Cadence        operator-facing cadence label
    #   Pagination     @{ Style; IndexParam; TokenParam; SizeParam }
    #   TimeFilter     @{ Supported; Type; StartParam; EndParam; LookbackParam }
    #   PathParams     string[] of {placeholder} names extracted from Path
    #   MaxPages       per-sub-area cap (Rule 14)
    #   LicenseHint    SKU/feature hint surfaced on HTTP 401/403/404 (Rule 23)
    #   AuditScope     'portal-only' (default)
    #   ProjectionMap  typed-column extraction map (empty Phase 1; populated v0.3.0+)
    #   Availability   'live' (license-gating handled at runtime per Rule 23)
    # ============================================================================

    Defaults = @{
        Portal             = 'security.microsoft.com'
        SchemaSource       = 'live-capture'
        MFAMethodsSupported = @('CredentialsTotp', 'Passkey')
        AuditScope         = 'portal-only'
        IdProperty         = ''
        ProjectionMap      = @{}
        Method             = 'GET'
    }

    Endpoints = @(
"@

$body = $entries | ForEach-Object {
    $literal = ConvertTo-PsdLiteral -Value $_ -Indent 8
    "        $literal"
} | Out-String

$footer = @"
    )
}
"@

$out = ($header + "`n" + $body.TrimEnd() + "`n" + $footer)

$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$out | Set-Content -Path $OutputPath -NoNewline -Encoding utf8

# ----------- 4) Verify Import-PowerShellDataFile parses ----------------------
try {
    $parsed = Import-PowerShellDataFile -Path $OutputPath
    Write-Host "Import-PowerShellDataFile OK · entries: $($parsed.Endpoints.Count)"
} catch {
    Write-Warning "Import-PowerShellDataFile failed: $_"
    Write-Host "Falling back to scriptblock-eval verification..."
    try {
        $sb = [scriptblock]::Create((Get-Content -Raw $OutputPath))
        $parsed = & $sb
        Write-Host "Scriptblock-eval OK · entries: $($parsed.Endpoints.Count)"
    } catch {
        throw "Manifest emission failed BOTH parsers: $_"
    }
}

Write-Host "Wrote $OutputPath ($([math]::Round((Get-Item $OutputPath).Length / 1KB, 1)) KB)"
