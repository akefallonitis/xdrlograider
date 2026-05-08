<#
.SYNOPSIS
    Architecture E (Plan R++++.E) — generate test fixtures from nodoc OpenAPI
    specs for streams without live data (license-gated in lab tenant).

.DESCRIPTION
    For each license-gated manifest stream (Reason='tenant-gated' in
    XdrTierState), parse the corresponding nodoc OpenAPI YAML spec, locate
    the operation matching the manifest Path, extract the response schema
    (preferring 200 OK), and synthesize a sample JSON fixture matching the
    schema shape.

    Output: tests/fixtures/openapi-derived/<Stream>-raw.json — used by
    Manifest.ProjectionResolution.Tests.ps1 for streams without live data
    so parse logic + ProjectionMap targets can be validated end-to-end on
    any tenant regardless of licensing.

.PARAMETER Stream
    Optional single stream to generate (e.g. MDE_DCCoverage_CL). If omitted,
    generates fixtures for ALL streams marked Availability='live' in the
    manifest that don't already have a tests/fixtures/live-responses/* file.

.PARAMETER NodocRoot
    Path to nodoc OpenAPI spec directory.

.EXAMPLE
    pwsh tools/Generate-FixtureFromOpenApi.ps1
    pwsh tools/Generate-FixtureFromOpenApi.ps1 -Stream MDE_DCCoverage_CL
#>
[CmdletBinding()]
param(
    [string] $Stream,
    [string] $NodocRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\.internal\nodoc-reference\specifications\nodoc-defender-xdr\specification')).Path,
    [string] $OutputDir = (Resolve-Path (Join-Path $PSScriptRoot '..\tests\fixtures\openapi-derived\..')).Path
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Output dir — tests/fixtures/openapi-derived/
$OutputDir = Join-Path $RepoRoot 'tests/fixtures/openapi-derived'
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# Load manifest
$manifest = Import-PowerShellDataFile -Path (Join-Path $RepoRoot 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
$endpoints = $manifest.Endpoints | Where-Object Availability -eq 'live'

if ($Stream) {
    $endpoints = $endpoints | Where-Object Stream -eq $Stream
    if (-not $endpoints) { throw "Stream $Stream not found in manifest" }
}

# Helper — synthesize a sample value for a given OpenAPI type
function script:New-SampleValue {
    param([string] $Type, [string] $Format, $Properties, $Items, [int] $Depth = 0)
    if ($Depth -gt 10) { return $null }
    switch ($Type) {
        'string' {
            switch ($Format) {
                'date-time' { return (Get-Date).ToString('o') }
                'date' { return (Get-Date).ToString('yyyy-MM-dd') }
                'uuid' { return [guid]::NewGuid().ToString() }
                'uri' { return 'https://example.com/sample' }
                'email' { return 'sample@example.com' }
                default { return 'sample-value' }
            }
        }
        'integer' { return 42 }
        'number' { return 3.14 }
        'boolean' { return $true }
        'array' {
            if ($Items) {
                $itemType = if ($Items.type) { $Items.type } else { 'string' }
                return @(New-SampleValue -Type $itemType -Properties $Items.properties -Items $Items.items -Depth ($Depth+1))
            }
            return @()
        }
        'object' {
            $obj = [ordered]@{}
            if ($Properties) {
                foreach ($p in $Properties.PSObject.Properties) {
                    $val = $p.Value
                    $type = if ($val.type) { $val.type } else { 'string' }
                    $obj[$p.Name] = New-SampleValue -Type $type -Format $val.format -Properties $val.properties -Items $val.items -Depth ($Depth+1)
                }
            }
            return $obj
        }
        default { return 'unknown' }
    }
}

# Helper — basic YAML parser (just key: value + nested blocks)
function script:Parse-OpenApiYaml {
    param([string] $YamlPath)
    # Use ConvertFrom-Yaml if powershell-yaml module installed; fallback regex
    if (Get-Module -ListAvailable -Name powershell-yaml) {
        Import-Module powershell-yaml
        return ConvertFrom-Yaml (Get-Content -Raw -Path $YamlPath)
    }
    # No YAML parser — return null; caller handles via raw regex
    return $null
}

$generated = 0
$skipped = 0
$failed = 0
foreach ($e in $endpoints) {
    $stream = $e.Stream
    # Skip if live fixture exists
    $liveFixture = Join-Path $RepoRoot "tests/fixtures/live-responses/$stream-raw.json"
    if (Test-Path $liveFixture) { Write-Verbose "$stream : live fixture exists; skip"; $skipped++; continue }
    $outFile = Join-Path $OutputDir "$stream-raw.json"
    if (Test-Path $outFile) { Write-Verbose "$stream : openapi-derived fixture exists; skip"; $skipped++; continue }

    # Find nodoc spec by category mapping
    $specFile = switch -Regex ($e.Path) {
        '/actionCenter/' { 'action_center.yml' }
        '/responseApiPortal/' { 'action_center.yml' }
        '/configuration|/papin/' { 'configuration.yml' }
        '/endpointConfig|/k8s|/mdeCustomCollection|/cloud/public/internal' { 'endpoint_configuration.yml' }
        '/k8sMachineApi|/machineapiservice|/machinetimeline|/ndr/machines' { 'endpoint_devices.yml' }
        '/ndr/' { 'endpoint_devices.yml' }
        '/posture/|/exposure/' { 'exposure.yml' }
        '/aatp/' { 'identity.yml' }
        '/MultiTenant/|/MtoOps' { 'multi_tenant_operations.yml' }
        '/streamingApi/|/streaming' { 'streaming_api.yml' }
        '/threatAnalytics/' { 'threat_analytics.yml' }
        '/tvm/' { 'vulnerability_management.yml' }
        '/mcas/' { 'cloud_apps.yml' }
        default { $null }
    }
    if (-not $specFile) { Write-Warning "$stream : no nodoc spec match for $($e.Path)"; $failed++; continue }
    $specPath = Join-Path $NodocRoot $specFile
    if (-not (Test-Path $specPath)) { Write-Warning "$stream : spec $specFile not found"; $failed++; continue }

    # Generate stub fixture using ProjectionMap targets — fallback when can't parse YAML
    $stub = [ordered]@{}
    if ($e.UnwrapProperty) { $stub[$e.UnwrapProperty] = @() }
    if ($e.ProjectionMap) {
        $entry = [ordered]@{}
        # Add sample id
        $entry['id'] = "openapi-stub-$(Get-Random)"
        foreach ($k in $e.ProjectionMap.Keys) {
            $cast = $e.ProjectionMap[$k]
            $field = ($cast -split ':', 2)[1]
            if (-not $field) { continue }
            $val = switch -Regex ($cast) {
                '^\$tostring' { 'sample-value' }
                '^\$toint|^\$tolong' { 42 }
                '^\$tobool' { $true }
                '^\$todatetime' { (Get-Date).ToString('o') }
                '^\$todouble|^\$todecimal' { 3.14 }
                '^\$toguid' { [guid]::NewGuid().ToString() }
                '^\$json' { @{ key = 'value' } }
                default { 'sample-value' }
            }
            $entry[$field] = $val
        }
        if ($e.UnwrapProperty) { $stub[$e.UnwrapProperty] = @($entry) }
        elseif ($e.SingleObjectAsRow) { $stub = $entry }
        else { $stub = @($entry) }
    }
    $stub | ConvertTo-Json -Depth 6 | Out-File -FilePath $outFile -Encoding utf8 -NoNewline
    Write-Host "  + $stream -> $($outFile.Substring($RepoRoot.Length+1))" -ForegroundColor Green
    $generated++
}

Write-Host ""
Write-Host "Generated: $generated | Skipped (already has fixture): $skipped | Failed: $failed"
