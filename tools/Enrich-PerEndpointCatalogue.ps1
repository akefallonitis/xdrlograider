# Enrich-PerEndpointCatalogue.ps1
#
# Phase 0 critical deliverable: text-mine every endpoint's nodoc.yml + existing metadata
# to populate parameters / pagination / time-filter / entities / cadence / production-scale.
# No live probes. Idempotent (re-runs build on existing data).
#
# Covers ALL 1,727 endpoints × 19 portals — including ones we have no live data for.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

$ErrorActionPreference = 'Stop'

# Pagination patterns (case-insensitive substring match against parameter name)
$paginationPatterns = @{
    'pageIndex0Based'    = @('pageIndex', 'page')
    'pageIndex1Based'    = @()   # detected by default value = 1
    'topSkip'            = @('top', 'skip', '$top', '$skip')
    'continuationToken'  = @('continuationToken', 'continuation', 'nextLink', '$skiptoken', 'pageToken')
    'limitOffset'        = @('limit', 'offset')
    'fromSize'           = @('from', 'size')
}

# Time-filter parameter patterns
$timeFilterPatterns = @(
    'startDateTime','endDateTime','startTime','endTime',
    'since','before','after','from','to',
    'updatedAfter','updatedBefore','modifiedAfter','modifiedSince',
    'lastModifiedDateTime','createdDateTime','timestamp',
    '$filter'  # OData filter may contain timestamps
)

# Entity field name patterns (cross-correlation join keys)
# Maps response-field name patterns to canonical Sentinel entity types
$entityFieldPatterns = @(
    @{ Pattern = '^(machineId|deviceId|aadDeviceId|computerId|hostId)$'; Entity='Host.MdatpId' }
    @{ Pattern = '^(computerDnsName|dnsName|hostName|machineName|deviceName)$'; Entity='Host.FullName' }
    @{ Pattern = '^(osPlatform|operatingSystem|osType)$'; Entity='Host.OsPlatform' }
    @{ Pattern = '^(healthStatus|deviceHealthStatus|complianceStatus)$'; Entity='Host.HealthStatus' }
    @{ Pattern = '^(riskScore|exposureScore|deviceRiskScore)$'; Entity='Host.RiskScore' }
    @{ Pattern = '^(aadId|azureAdDeviceId|aadObjectId)$'; Entity='Host.AadDeviceId' }
    @{ Pattern = '^(userId|userObjectId|aadUserId)$'; Entity='Account.AadId' }
    @{ Pattern = '^(userPrincipalName|upn|userEmail|mail)$'; Entity='Account.UPN' }
    @{ Pattern = '^(samAccountName|samName|onPremSamAccountName)$'; Entity='Account.SamName' }
    @{ Pattern = '^(securityIdentifier|sid|userSid)$'; Entity='Account.Sid' }
    @{ Pattern = '^(fileName|name|fileNameOnly)$'; Entity='File.Name' }
    @{ Pattern = '^(filePath|fullPath|path)$'; Entity='File.Path' }
    @{ Pattern = '^(sha256|fileSha256|hashSha256)$'; Entity='File.Sha256' }
    @{ Pattern = '^(sha1|fileSha1|hashSha1)$'; Entity='File.Sha1' }
    @{ Pattern = '^(md5|fileMd5|hashMd5)$'; Entity='File.Md5' }
    @{ Pattern = '^(ip|ipAddress|sourceIp|destinationIp|remoteIp)$'; Entity='IP.Address' }
    @{ Pattern = '^(url|requestUrl|webAddress)$'; Entity='Url.Full' }
    @{ Pattern = '^(domain|hostname|domainName)$'; Entity='Url.Domain' }
    @{ Pattern = '^(softwareName|appName|productName|displayName)$'; Entity='Software.Name' }
    @{ Pattern = '^(version|productVersion|softwareVersion)$'; Entity='Software.Version' }
    @{ Pattern = '^(vendor|publisher|softwareVendor)$'; Entity='Software.Vendor' }
    @{ Pattern = '^(cve|cveId|vulnerabilityId)$'; Entity='Vuln.CveId' }
    @{ Pattern = '^(tenantId|aadTenantId|directoryId|orgId)$'; Entity='Tenant.Id' }
    @{ Pattern = '^(actionId|investigationId|alertId|incidentId)$'; Entity='Action.Id' }
    @{ Pattern = '^(policyId|ruleId|configId)$'; Entity='Policy.Id' }
    @{ Pattern = '^(timeGenerated|createdDateTime|lastModifiedDateTime|timestamp|eventTime)$'; Entity='Time.Generated' }
)

# Cadence hints based on path/operation type (rolled up to sub-area level)
$cadenceHints = @{
    'pendingActions'      = '10min'    # event-shaped
    'actionCenter'        = '10min'
    'machineActions'      = '10min'
    'incidents'           = '1h'
    'alerts'              = '1h'
    'exposure'            = '1h'
    'xspm'                = '1h'
    'posture'             = '1h'
    'attackPath'          = '1h'
    'attackSurface'       = '1h'
    'configuration'       = '6h'
    'alertService'        = '6h'
    'cloudApps'           = '6h'
    'threatAnalytics'     = '6h'
    'machines'            = 'daily'
    'devices'             = 'daily'
    'vulnerab'            = 'daily'
    'software'            = 'daily'
    'identity'            = 'daily'
    'inventory'           = 'daily'
    'secureScore'         = 'daily'
    'tenant'              = 'daily'
    'streamingApi'        = 'weekly'
    'dataExport'          = 'weekly'
    'portal'              = 'weekly'
}

function Get-CadenceHint {
    param([string]$Path, [string]$Slug)
    $lowerPath = ($Path + ' ' + $Slug).ToLower()
    foreach ($key in $cadenceHints.Keys) {
        if ($lowerPath -match $key.ToLower()) { return $cadenceHints[$key] }
    }
    return 'daily'  # safe default
}

# Production-scale heuristics per sub-area name
$productionScaleHints = @{
    'endpoint_devices'         = @{ VolumeLargeT='10K-1M rows';     RateLimitRisk='HIGH on first poll';  DeltaPollPriority='critical' }
    'identity'                 = @{ VolumeLargeT='1K-100K rows';    RateLimitRisk='MEDIUM';              DeltaPollPriority='high' }
    'vulnerability_management' = @{ VolumeLargeT='10K-500K rows';   RateLimitRisk='HIGH (paginated)';   DeltaPollPriority='critical' }
    'exposure_management'      = @{ VolumeLargeT='1K-100K rows';    RateLimitRisk='MEDIUM';              DeltaPollPriority='high' }
    'cloud_apps'               = @{ VolumeLargeT='10K+ audit/day';  RateLimitRisk='HIGH (MCAS audit)';   DeltaPollPriority='critical' }
    'configuration'            = @{ VolumeLargeT='100-10K';         RateLimitRisk='LOW';                 DeltaPollPriority='low' }
    'action_center'            = @{ VolumeLargeT='100-10K events';  RateLimitRisk='LOW';                 DeltaPollPriority='medium' }
    'threat_analytics'         = @{ VolumeLargeT='100-1K';          RateLimitRisk='LOW';                 DeltaPollPriority='low' }
    'multi_tenant'             = @{ VolumeLargeT='10-1K tenants';   RateLimitRisk='LOW';                 DeltaPollPriority='low' }
    'secure_score'             = @{ VolumeLargeT='1-100';           RateLimitRisk='LOW';                 DeltaPollPriority='none' }
    'portal_services'          = @{ VolumeLargeT='1-100';           RateLimitRisk='LOW';                 DeltaPollPriority='none' }
    'endpoint_configuration'   = @{ VolumeLargeT='10-1K';           RateLimitRisk='LOW';                 DeltaPollPriority='low' }
    'streaming'                = @{ VolumeLargeT='1-10';            RateLimitRisk='LOW';                 DeltaPollPriority='none' }
    'data_lake'                = @{ VolumeLargeT='1-10';            RateLimitRisk='LOW';                 DeltaPollPriority='none' }
    'sentinel_precision'       = @{ VolumeLargeT='varies';          RateLimitRisk='MEDIUM';              DeltaPollPriority='medium' }
    'attack_simulator'         = @{ VolumeLargeT='10-1K';           RateLimitRisk='LOW';                 DeltaPollPriority='low' }
    'files'                    = @{ VolumeLargeT='varies';          RateLimitRisk='MEDIUM';              DeltaPollPriority='medium' }
    'entity_pivots'            = @{ VolumeLargeT='per-entity';      RateLimitRisk='depends';             DeltaPollPriority='depends' }
    'advanced_hunting'         = @{ VolumeLargeT='out-of-scope';    RateLimitRisk='-';                   DeltaPollPriority='-' }
    'alerts_incidents'         = @{ VolumeLargeT='out-of-scope';    RateLimitRisk='-';                   DeltaPollPriority='-' }
    'live_response'            = @{ VolumeLargeT='out-of-scope';    RateLimitRisk='-';                   DeltaPollPriority='-' }
}

# Parse parameters from a nodoc.yml block (text-only, no full YAML parser)
function Get-EndpointParameters {
    param([string]$YamlPath)
    if (-not (Test-Path $YamlPath)) { return @() }
    $lines = Get-Content $YamlPath
    $params = @()
    $inParams = $false
    $currentParam = $null
    foreach ($l in $lines) {
        if ($l -match '^\s+parameters\s*:\s*$') { $inParams = $true; continue }
        if ($inParams) {
            if ($l -match '^\s{0,6}[a-zA-Z]') { $inParams = $false; break }   # back to top-level under method
            if ($l -match '^\s+-\s*name\s*:\s*[''"]?([^''"\s]+)[''"]?') {
                if ($currentParam) { $params += $currentParam }
                $currentParam = @{ name = $matches[1]; in = ''; required = $false; type = ''; default = $null; description = '' }
            } elseif ($currentParam) {
                if ($l -match '^\s+in\s*:\s*[''"]?([^''"\s]+)[''"]?') { $currentParam.in = $matches[1] }
                elseif ($l -match '^\s+required\s*:\s*(true|false)') { $currentParam.required = ($matches[1] -eq 'true') }
                elseif ($l -match '^\s+type\s*:\s*[''"]?([^''"\s]+)[''"]?') { $currentParam.type = $matches[1] }
                elseif ($l -match '^\s+default\s*:\s*[''"]?([^''"\s]+)[''"]?') { $currentParam.default = $matches[1] }
                elseif ($l -match '^\s+description\s*:\s*[''"]?([^''""\n]+)') { $currentParam.description = $matches[1] }
            }
        }
    }
    if ($currentParam) { $params += $currentParam }
    return $params
}

# Detect pagination style from parameter set
function Get-PaginationStyle {
    param([array]$Params)
    if (-not $Params -or $Params.Count -eq 0) { return 'none' }
    $names = ($Params | Where-Object { $_.name } | ForEach-Object { $_.name.ToLower() }) -join ','
    if (-not $names) { return 'none' }
    foreach ($style in $paginationPatterns.Keys) {
        $found = $false
        foreach ($p in $paginationPatterns[$style]) {
            if ($names -match [regex]::Escape($p.ToLower())) { $found = $true; break }
        }
        if ($found) {
            # Refine 0-based vs 1-based by default value
            if ($style -eq 'pageIndex0Based') {
                $idxParam = $Params | Where-Object { $_.name.ToLower() -match 'pageindex|^page$' } | Select-Object -First 1
                if ($idxParam -and $idxParam.default -eq '1') { return 'pageIndex1Based' }
            }
            return $style
        }
    }
    return 'none'
}

# Detect time-filter parameters
function Get-TimeFilterParams {
    param([array]$Params)
    $tf = @()
    if (-not $Params) { return $tf }
    foreach ($p in $Params) {
        if (-not $p.name) { continue }
        foreach ($pat in $timeFilterPatterns) {
            if ($p.name -match "^$([regex]::Escape($pat))$") {
                $tf += $p.name
                break
            }
        }
    }
    return $tf
}

# Mine entity field names from a nodoc.yml's response schema
function Get-EntitiesFromYaml {
    param([string]$YamlPath)
    if (-not (Test-Path $YamlPath)) { return @() }
    $content = Get-Content -Path $YamlPath -Raw
    # Extract property names under any "properties:" block (heuristic)
    $propMatches = [regex]::Matches($content, '^\s{2,}([a-zA-Z][a-zA-Z0-9]+)\s*:\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $found = @{}
    foreach ($m in $propMatches) {
        $field = $m.Groups[1].Value
        foreach ($pat in $entityFieldPatterns) {
            if ($field -match $pat.Pattern) {
                $found[$pat.Entity] = 1
                break
            }
        }
    }
    return @($found.Keys | Sort-Object)
}

# ---------------------------------------------------------------------------
# Main processing loop
# ---------------------------------------------------------------------------
Set-Location $ReferencesRoot
$portalDirs = Get-ChildItem -Directory | Sort-Object Name
Write-Host "Processing $($portalDirs.Count) portals..."

$globalStats = @{
    portals=$portalDirs.Count; subAreas=0; endpoints=0
    withPagination=0; withTimeFilter=0; withEntities=0
    paginationStyles=@{}; cadenceTiers=@{}
}

foreach ($portalDir in $portalDirs) {
    $portal = $portalDir.Name
    $subAreaDirs = Get-ChildItem -Path $portalDir.FullName -Directory
    Write-Host "  $portal : $($subAreaDirs.Count) sub-areas" -ForegroundColor Cyan

    foreach ($subAreaDir in $subAreaDirs) {
        $subArea = $subAreaDir.Name
        $globalStats.subAreas++

        # Per-sub-area aggregation
        $saStats = @{
            portal=$portal; subArea=$subArea
            endpointCount=0
            paginationStyles=@{}; timeFilterCount=0
            entitiesAll=@{}
            cadenceSuggestion=''
            productionScale=$null
        }
        if ($productionScaleHints[$subArea]) { $saStats.productionScale = $productionScaleHints[$subArea] }

        $endpointDirs = Get-ChildItem -Path $subAreaDir.FullName -Directory
        foreach ($epDir in $endpointDirs) {
            $metaFile  = Join-Path $epDir.FullName 'metadata.json'
            $nodocFile = Join-Path $epDir.FullName 'nodoc.yml'
            if (-not (Test-Path $metaFile)) { continue }
            $globalStats.endpoints++
            $saStats.endpointCount++

            try {
                $meta = Get-Content $metaFile -Raw | ConvertFrom-Json -ErrorAction Stop
            } catch { continue }

            # Mine parameters from nodoc.yml
            $params = Get-EndpointParameters -YamlPath $nodocFile
            $paginationStyle = Get-PaginationStyle -Params $params
            $tfParams = Get-TimeFilterParams -Params $params
            $entitiesYaml = Get-EntitiesFromYaml -YamlPath $nodocFile
            # Merge with existing entities (from live capture if any)
            $existingEnts = @()
            if ($meta.entities) { $existingEnts = @($meta.entities) }
            $mergedEnts = @($existingEnts + $entitiesYaml | Sort-Object -Unique)

            $cadence = Get-CadenceHint -Path $meta.path -Slug $meta.slug

            # Update metadata.json (preserve all existing keys)
            $meta | Add-Member -NotePropertyName 'parameters'       -NotePropertyValue $params              -Force
            $meta | Add-Member -NotePropertyName 'paginationStyle'  -NotePropertyValue $paginationStyle     -Force
            $meta | Add-Member -NotePropertyName 'timeFilterParams' -NotePropertyValue $tfParams            -Force
            $meta | Add-Member -NotePropertyName 'entities'         -NotePropertyValue $mergedEnts          -Force
            $meta | Add-Member -NotePropertyName 'cadenceSuggestion'-NotePropertyValue $cadence             -Force
            $meta | ConvertTo-Json -Depth 12 | Set-Content -Path $metaFile -NoNewline

            # Per-sub-area roll-ups
            if ($paginationStyle -ne 'none') { $globalStats.withPagination++ }
            if (-not $saStats.paginationStyles.ContainsKey($paginationStyle)) { $saStats.paginationStyles[$paginationStyle] = 0 }
            $saStats.paginationStyles[$paginationStyle]++
            if (-not $globalStats.paginationStyles.ContainsKey($paginationStyle)) { $globalStats.paginationStyles[$paginationStyle] = 0 }
            $globalStats.paginationStyles[$paginationStyle]++

            if ($tfParams.Count -gt 0) { $globalStats.withTimeFilter++; $saStats.timeFilterCount++ }
            if ($mergedEnts.Count -gt 0) {
                $globalStats.withEntities++
                foreach ($e in $mergedEnts) {
                    if (-not $saStats.entitiesAll.ContainsKey($e)) { $saStats.entitiesAll[$e] = 0 }
                    $saStats.entitiesAll[$e]++
                }
            }

            $saStats.cadenceSuggestion = $cadence  # last wins; usually consistent per sub-area
            if (-not $globalStats.cadenceTiers.ContainsKey($cadence)) { $globalStats.cadenceTiers[$cadence] = 0 }
            $globalStats.cadenceTiers[$cadence]++
        }

        # Write per-sub-area enriched index
        $saTop = @($saStats.entitiesAll.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { $_.Key })
        $saOut = [ordered]@{
            portal=$portal; subArea=$subArea
            endpointCount=$saStats.endpointCount
            paginationDistribution = $saStats.paginationStyles
            timeFilterEndpointCount = $saStats.timeFilterCount
            topEntities = $saTop
            cadenceSuggestion = $saStats.cadenceSuggestion
            productionScale = $saStats.productionScale
            generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $saOutFile = Join-Path $subAreaDir.FullName '_SUBAREA_ENRICHED.json'
        $saOut | ConvertTo-Json -Depth 8 | Set-Content -Path $saOutFile -NoNewline
    }
}

Write-Host ""
Write-Host "=== Global enrichment stats ===" -ForegroundColor Cyan
Write-Host "  Portals: $($globalStats.portals)"
Write-Host "  Sub-areas: $($globalStats.subAreas)"
Write-Host "  Endpoints: $($globalStats.endpoints)"
Write-Host "  Endpoints with pagination: $($globalStats.withPagination)"
Write-Host "  Endpoints with time-filter: $($globalStats.withTimeFilter)"
Write-Host "  Endpoints with entities: $($globalStats.withEntities)"
Write-Host ""
Write-Host "Pagination style distribution:"
$globalStats.paginationStyles.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Key, $_.Value) }
Write-Host ""
Write-Host "Cadence-tier distribution:"
$globalStats.cadenceTiers.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Key, $_.Value) }
