#Requires -Version 7.4
<#
.SYNOPSIS
v13 catalogue coverage + MECHANISM-DISTRIBUTION report (plan §6/§7). Aggregates all 20 per-portal catalogue.json
into one evidence report: per-portal/status coverage, pagination/timefilter/param shapes, telemetry-class split,
and the v0.1.0/v0.2.0/v0.3.0 scope buckets. This is the references→functionality bridge — the catalogue's evidence
tells us which runtime mechanisms each phase actually needs (so we build to evidence, not assumption).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [switch] $WriteFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# v0.1.0 Defender · v0.2.0 the 4 sub-portals (auth proven) · v0.3.0 M365/Power-Platform (operator in/out)
$scope = @{
    'nodoc-defender-xdr' = 'v0.1.0'
    'nodoc-entra-b2c' = 'v0.2.0'; 'nodoc-entra-idgov' = 'v0.2.0'; 'nodoc-entra-iga' = 'v0.2.0'; 'nodoc-entra-pim' = 'v0.2.0'
    'nodoc-intune-autopatch' = 'v0.2.0'; 'nodoc-intune-portal' = 'v0.2.0'
    'nodoc-purview' = 'v0.2.0'; 'nodoc-purview-portal' = 'v0.2.0'; 'nodoc-security-copilot' = 'v0.2.0'
    'nodoc-m365-admin' = 'v0.3.0'; 'nodoc-m365-apps-config' = 'v0.3.0'; 'nodoc-m365-apps-inventory' = 'v0.3.0'
    'nodoc-m365-apps-services' = 'v0.3.0'; 'nodoc-power-platform' = 'v0.3.0'; 'nodoc-sharepoint-admin' = 'v0.3.0'
    'nodoc-teams' = 'v0.3.0'; 'nodoc-viva-engage' = 'v0.3.0'; 'nodoc-exchange-beta' = 'v0.3.0'; 'nodoc-ibiza-iam' = 'v0.3.0'
}

$all = @()
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'references/inventory/nodoc-*/catalogue.json') | Sort-Object FullName)) {
    $c = Get-Content $f.FullName -Raw | ConvertFrom-Json
    foreach ($op in $c.Operations) { $all += [pscustomobject]@{
        PortalKey = $c.PortalKey; Scope = $(if ($scope.ContainsKey($c.PortalKey)) { $scope[$c.PortalKey] } else { '?' })
        Category = $op.Category; Status = $op.Status; Method = $op.Method
        PagMode = $(if ($op.PSObject.Properties['Pagination'] -and $op.Pagination) { $op.Pagination.Mode } else { 'none' })
        ParamSource = $op.ParamSource; HasParam = ([bool](@($op.PathParams).Count -gt 0)); TelemetryClass = $op.TelemetryClass
        IngestionMode = $(if ($op.PSObject.Properties['IngestionMode']) { $op.IngestionMode } else { $null })
    } }
}

function Tally($prop) { $all | Group-Object $prop | Sort-Object Count -Descending | ForEach-Object { "    {0,-18} {1,5}" -f $_.Name, $_.Count } }

$lines = @()
$lines += "# XdrLogRaider · catalogue coverage + mechanism distribution (v13 · $($all.Count) ops · 20 portals)"
$lines += ""
$lines += "## Status (honest gating)"
$lines += (Tally 'Status')
$lines += ""
$lines += "## Scope buckets (phase)"
$lines += ($all | Group-Object Scope | Sort-Object Name | ForEach-Object { "    {0,-8} {1,5} ops · {2} portals" -f $_.Name, $_.Count, (@($_.Group | Select-Object -Unique PortalKey).Count) })
$lines += ""
$lines += "## Method"
$lines += (Tally 'Method')
$lines += ""
$lines += "## Pagination mode (the runtime shapes expansion must speak)"
$lines += (Tally 'PagMode')
$lines += ""
$lines += "## ParamSource (telemetry that needs a {param} · entity-chain = roadmap)"
$lines += (Tally 'ParamSource')
$lines += ("    {0,-18} {1,5}" -f '{param} ops total', (@($all | Where-Object HasParam).Count))
$lines += ""
$lines += "## TelemetryClass (InternalOnly = ingest · others = excluded)"
$lines += (Tally 'TelemetryClass')
$lines += ""
$lines += "## Defender-only · pagination shapes (drives P-ENG validation for the next phase)"
$lines += ($all | Where-Object { $_.Scope -eq 'v0.1.0' } | Group-Object PagMode | Sort-Object Count -Descending | ForEach-Object { "    {0,-18} {1,5}" -f $_.Name, $_.Count })

$report = $lines -join "`n"
if ($WriteFile) {
    $out = Join-Path $RepoRoot 'references/inventory/CATALOGUE-COVERAGE.md'
    $report | Out-File $out -Encoding utf8
    Write-Host "[Report-Catalogue] wrote $out"
}
$report
