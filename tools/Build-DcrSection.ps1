#Requires -Version 7.4
<#
.SYNOPSIS
    Regenerate the DCR section of mainTemplate.json deterministically:
    7 bucket-fill DCRs -> 13 per-category DCRs with descriptive names.

.DESCRIPTION
    Idempotent. Modifies mainTemplate.json in-place.

    Changes:
      - resources[] DCRs: 7 -> 13 (preserves streamDecl columns + dataFlows)
      - resources[] MMP role assignments: 7 -> 13
      - FunctionApp.properties.siteConfig.appSettings: DCR_IMMUTABLE_IDS_JSON
        env-var has each stream's DCR reference (-defender-N) updated to its
        new per-category suffix
      - FunctionApp.dependsOn: 7 DCR refs -> 13 DCR refs

    Layer-1 sites NOT touched: workspace tables, KV, Storage, FA siteConfig
    (besides the one env-var entry), AppInsights, DCE, Solution Gallery,
    Sentinel content, manifest, modules, FA functions, parsers, workbooks,
    analytic rules, hunting queries, sample queries.
#>
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/compiled/mainTemplate.json'),
    [string] $ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1')
)
$ErrorActionPreference = 'Stop'

# Category layout (D'.11 + semantic split for >10 streams)
$categoryToTable = [ordered]@{
    'Action Center'                 = 'Defender_ActionCenter_CL'
    'Configuration and Settings'    = 'Defender_ConfigurationAndSettings_CL'
    'Endpoint Configuration'        = 'Defender_EndpointConfiguration_CL'
    'Endpoint Device Management'    = 'Defender_EndpointDeviceManagement_CL'
    'Exposure Management (XSPM)'    = 'Defender_ExposureManagement_CL'
    'Identity Protection (MDI)'     = 'Defender_IdentityProtection_CL'
    'Multi-Tenant Operations'       = 'Defender_MultiTenantOperations_CL'
    'Streaming API'                 = 'Defender_StreamingApi_CL'
    'Threat Analytics'              = 'Defender_ThreatAnalytics_CL'
    'Vulnerability Management (TVM)'= 'Defender_VulnerabilityManagement_CL'
}
$categoryToDcrBase = [ordered]@{
    'Action Center'                 = 'actioncenter'
    'Endpoint Configuration'        = 'endpoint-config'
    'Endpoint Device Management'    = 'endpoint-device'
    'Identity Protection (MDI)'     = 'identity'
    'Multi-Tenant Operations'       = 'multitenant'
    'Streaming API'                 = 'streaming-api'
    'Threat Analytics'              = 'threat-analytics'
    'Vulnerability Management (TVM)'= 'vuln-mgmt'
}
$explicitSubDomains = @{
    'Configuration and Settings' = [ordered]@{
        'config-alerts-detection' = @('MDE_AlertServiceConfig_CL','MDE_AlertTuning_CL','MDE_CustomDetections_CL','MDE_PreviewFeatures_CL','MDE_SuppressionRules_CL','MDE_TenantAllowBlock_CL')
        'config-platform-rbac'    = @('MDE_AssetClassificationSchema_CL','MDE_CloudAppsConfig_CL','MDE_ConnectedApps_CL','MDE_IntuneConnection_CL','MDE_PurviewSharing_CL','MDE_RbacDeviceGroups_CL','MDE_UnifiedRbacRoles_CL','MDE_UserPreferences_CL')
    }
    'Exposure Management (XSPM)' = [ordered]@{
        'exposure-attack-surface' = @('MDE_AssetRules_CL','MDE_AttackSurfaceAttackPaths_CL','MDE_AttackSurfaceChokepoints_CL','MDE_ExposureRecommendations_CL','MDE_ExposureSnapshots_CL','MDE_XspmAttackPaths_CL','MDE_XspmChokePoints_CL','MDE_XspmConnectors_CL','MDE_XspmInitiatives_CL','MDE_XspmTopTargets_CL')
        'exposure-posture-score'  = @('MDE_AppsSecureScore_CL','MDE_DataSecureScore_CL','MDE_IdentitySecureScore_CL','MDE_PostureInitiativesSummarized_CL','MDE_PostureMetrics_CL','MDE_PostureSecurityEvents_CL','MDE_PostureTenants_CL')
    }
}

$manifest = Import-PowerShellDataFile -Path $ManifestPath
$tpl      = Get-Content -Raw $TemplatePath | ConvertFrom-Json -Depth 50

# Index existing DCR streamDecls + dataFlows (preserve column types)
$existingStreamDecls = @{}
$existingDataFlows   = @{}
foreach ($d in $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }) {
    foreach ($prop in $d.properties.streamDeclarations.PSObject.Properties) {
        $sn = $prop.Name -replace '^Custom-', ''
        $existingStreamDecls[$sn] = $prop.Value
    }
    foreach ($df in $d.properties.dataFlows) {
        $sn = ($df.streams[0] -replace '^Custom-', '')
        $existingDataFlows[$sn] = $df
    }
}

# Build category -> streams map from manifest
$categoryStreams = [ordered]@{}
foreach ($cat in $categoryToTable.Keys) { $categoryStreams[$cat] = @() }
foreach ($e in $manifest.Endpoints | Sort-Object Stream) {
    if ($e.Category -and $categoryToTable.Contains($e.Category)) { $categoryStreams[$e.Category] += $e.Stream }
}

# Build DCR layout
$dcrLayout = [ordered]@{}
foreach ($cat in $categoryStreams.Keys) {
    $streams = $categoryStreams[$cat]
    if ($streams.Count -eq 0) { continue }
    $table = $categoryToTable[$cat]
    if ($explicitSubDomains.ContainsKey($cat)) {
        $assigned = @{}
        foreach ($subKey in $explicitSubDomains[$cat].Keys) {
            $subStreams = $explicitSubDomains[$cat][$subKey]
            foreach ($s in $subStreams) {
                if ($assigned.ContainsKey($s)) { throw "Duplicate stream $s in sub-domain map" }
                $assigned[$s] = $subKey
            }
            $dcrLayout[$subKey] = @{ Streams = @($subStreams); Table = $table; Category = $cat }
        }
        foreach ($s in $streams) {
            if (-not $assigned.ContainsKey($s)) { throw "Stream $s in '$cat' missing from sub-domain map" }
        }
    } else {
        if ($streams.Count -gt 10) { throw "Category '$cat' has > 10 streams without sub-domain split" }
        $dcrLayout[$categoryToDcrBase[$cat]] = @{ Streams = $streams; Table = $table; Category = $cat }
    }
}
$dcrLayout['ops'] = @{ Streams = @('XdrConnectorHealth_CL'); Table = 'XdrConnectorHealth_CL'; Category = 'Operations' }

Write-Host "===== DCR LAYOUT =====" -ForegroundColor Cyan
foreach ($suffix in $dcrLayout.Keys) {
    Write-Host ("  xdrlr-dcr-{0,-26} -> {1,-45} ({2,2} streams)" -f $suffix, $dcrLayout[$suffix].Table, $dcrLayout[$suffix].Streams.Count)
}
$totalStreams = ($dcrLayout.Values | ForEach-Object { $_.Streams.Count } | Measure-Object -Sum).Sum
Write-Host ("  Total: {0} DCRs, {1} streams" -f $dcrLayout.Keys.Count, $totalStreams) -ForegroundColor Cyan
if ($totalStreams -ne 60) { throw "Expected 60 streamDecls (59 + ops). Got $totalStreams." }

# Build stream -> new DCR-suffix map
$streamToDcr = @{}
foreach ($suffix in $dcrLayout.Keys) {
    foreach ($s in $dcrLayout[$suffix].Streams) { $streamToDcr[$s] = $suffix }
}

# ----- Build new DCR resource blocks (preserve streamDecl + dataFlow content) -----
$newDcrs = @()
foreach ($suffix in $dcrLayout.Keys) {
    $entry = $dcrLayout[$suffix]
    $dcrNameExpr = "[concat(variables('dcrName'), '-$suffix')]"
    $streamDeclarations = [ordered]@{}
    foreach ($s in $entry.Streams) {
        if (-not $existingStreamDecls.ContainsKey($s)) { throw "Stream $s missing in template" }
        $streamDeclarations["Custom-$s"] = $existingStreamDecls[$s]
    }
    $dataFlows = @()
    foreach ($s in $entry.Streams) {
        if (-not $existingDataFlows.ContainsKey($s)) { throw "DataFlow for $s missing" }
        $dataFlows += $existingDataFlows[$s]
    }
    $newDcrs += [ordered]@{
        type       = 'Microsoft.Insights/dataCollectionRules'
        apiVersion = '2023-03-11'
        name       = $dcrNameExpr
        location   = "[parameters('workspaceLocation')]"
        tags       = "[variables('commonTag')]"
        dependsOn  = @(
            "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            "[concat('customTables-', variables('suffix'))]"
        )
        properties = [ordered]@{
            dataCollectionEndpointId = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
            streamDeclarations       = $streamDeclarations
            destinations             = [ordered]@{
                logAnalytics = @([ordered]@{ name = 'la-destination'; workspaceResourceId = "[parameters('existingWorkspaceId')]" })
            }
            dataFlows                = $dataFlows
        }
    }
}

# ----- Replace DCRs in resources[] -----
$resources = New-Object System.Collections.ArrayList
foreach ($r in $tpl.resources) {
    if ($r.type -eq 'Microsoft.Insights/dataCollectionRules') { continue }
    [void]$resources.Add($r)
}
foreach ($d in $newDcrs) { [void]$resources.Add($d) }

# ----- Replace MMP role assignments -----
$resources2 = New-Object System.Collections.ArrayList
$removedMmp = 0
foreach ($r in $resources) {
    $isMmp = $false
    if ($r.type -eq 'Microsoft.Authorization/roleAssignments' -and
        $r.PSObject.Properties.Name -contains 'properties' -and
        $r.properties.PSObject.Properties.Name -contains 'roleDefinitionId' -and
        $r.properties.roleDefinitionId -is [string] -and
        $r.properties.roleDefinitionId -match 'monitoringMetricsPublisherRoleId') {
        $isMmp = $true
    }
    if ($isMmp) { $removedMmp++; continue }
    [void]$resources2.Add($r)
}
foreach ($suffix in $dcrLayout.Keys) {
    $dcrConcat = "concat(variables('dcrName'), '-$suffix')"
    [void]$resources2.Add([ordered]@{
        type       = 'Microsoft.Authorization/roleAssignments'
        apiVersion = '2022-04-01'
        name       = "[guid(resourceId('Microsoft.Insights/dataCollectionRules', $dcrConcat), variables('funcName'), variables('monitoringMetricsPublisherRoleId'))]"
        scope      = "[concat('Microsoft.Insights/dataCollectionRules/', variables('dcrName'), '-$suffix')]"
        properties = [ordered]@{
            principalId      = "[reference(resourceId('Microsoft.Web/sites', variables('funcName')), '2023-12-01', 'Full').identity.principalId]"
            roleDefinitionId = "[resourceId('Microsoft.Authorization/roleDefinitions', variables('monitoringMetricsPublisherRoleId'))]"
            principalType    = 'ServicePrincipal'
        }
        dependsOn  = @(
            "[resourceId('Microsoft.Web/sites', variables('funcName'))]"
            "[resourceId('Microsoft.Insights/dataCollectionRules', $dcrConcat)]"
        )
    })
}
$tpl.resources = $resources2.ToArray()
Write-Host ("RBAC: removed {0} MMP, added {1} per-DCR MMP" -f $removedMmp, $dcrLayout.Keys.Count) -ForegroundColor Green

# ----- Update FA dependsOn (drop old DCR refs, add new) -----
$fa = $tpl.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
if ($fa -and $fa.PSObject.Properties.Name -contains 'dependsOn' -and $fa.dependsOn) {
    $newDeps = New-Object System.Collections.ArrayList
    foreach ($dep in $fa.dependsOn) {
        if ($dep -is [string] -and $dep -match "dataCollectionRules.*concat\(variables\('dcrName'\)") { continue }
        [void]$newDeps.Add($dep)
    }
    foreach ($suffix in $dcrLayout.Keys) {
        [void]$newDeps.Add("[resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('dcrName'), '-$suffix'))]")
    }
    $fa.dependsOn = $newDeps.ToArray()
    Write-Host ("FA dependsOn: {0} entries (incl. {1} DCR refs)" -f $newDeps.Count, $dcrLayout.Keys.Count) -ForegroundColor Green
}

# ----- Update DCR_IMMUTABLE_IDS_JSON env var: literal-string surgery per stream -----
# After ConvertFrom-Json, the appSettings string has the JSON escapes decoded:
# the original `\"<S>\":\"` becomes `"<S>":"`. We use IndexOf-based string
# surgery to find each stream's anchor + replace ONLY its DCR suffix.
if ($fa.properties.siteConfig.PSObject.Properties.Name -contains 'appSettings') {
    $appSettings = $fa.properties.siteConfig.appSettings
    if ($appSettings -is [string]) {
        $patched = $appSettings
        $envPatched = 0
        foreach ($s in ($streamToDcr.Keys | Sort-Object)) {
            $newSuffix = $streamToDcr[$s]
            $anchorOpen = '"' + $s + '":"' + "', reference(resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('dcrName'), '-"
            $anchorClose = "'))"
            $idx = $patched.IndexOf($anchorOpen)
            if ($idx -lt 0) {
                Write-Host ("  WARN: stream {0} not found in env var (already migrated or not present)" -f $s) -ForegroundColor Yellow
                continue
            }
            $valStart = $idx + $anchorOpen.Length
            $valEnd = $patched.IndexOf($anchorClose, $valStart)
            if ($valEnd -lt 0) { continue }
            $oldSuffix = $patched.Substring($valStart, $valEnd - $valStart)
            if ($oldSuffix -ne $newSuffix) {
                $patched = $patched.Substring(0, $valStart) + $newSuffix + $patched.Substring($valEnd)
                $envPatched++
            }
        }
        $fa.properties.siteConfig.appSettings = $patched
        Write-Host ("DCR_IMMUTABLE_IDS_JSON env var: patched {0} stream-to-DCR refs" -f $envPatched) -ForegroundColor Green
    }
}

# ----- Update OUTPUTS section -----
# 1. dcrImmutableIdsJson: same per-stream surgery as appSettings env var
# 2. Replace dcr1ImmutableId..dcr7ImmutableId with dcr<suffix>ImmutableId (13 outputs)
if ($tpl.PSObject.Properties.Name -contains 'outputs' -and $tpl.outputs) {
    $outputsObj = $tpl.outputs

    # 1. Patch dcrImmutableIdsJson (same string-surgery loop as appSettings)
    if ($outputsObj.PSObject.Properties.Name -contains 'dcrImmutableIdsJson' -and
        $outputsObj.dcrImmutableIdsJson.value -is [string]) {
        $patched = $outputsObj.dcrImmutableIdsJson.value
        $jsonOutPatched = 0
        foreach ($s in ($streamToDcr.Keys | Sort-Object)) {
            $newSuffix = $streamToDcr[$s]
            $anchorOpen = '"' + $s + '":"' + "', reference(resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('dcrName'), '-"
            $anchorClose = "'))"
            $idx = $patched.IndexOf($anchorOpen)
            if ($idx -lt 0) { continue }
            $valStart = $idx + $anchorOpen.Length
            $valEnd = $patched.IndexOf($anchorClose, $valStart)
            if ($valEnd -lt 0) { continue }
            $oldSuffix = $patched.Substring($valStart, $valEnd - $valStart)
            if ($oldSuffix -ne $newSuffix) {
                $patched = $patched.Substring(0, $valStart) + $newSuffix + $patched.Substring($valEnd)
                $jsonOutPatched++
            }
        }
        $outputsObj.dcrImmutableIdsJson.value = $patched
        Write-Host ("outputs.dcrImmutableIdsJson: patched {0} stream-to-DCR refs" -f $jsonOutPatched) -ForegroundColor Green
    }

    # 2. Replace per-DCR ImmutableId outputs (dcr1..7 -> 13 per-suffix)
    $newOutputs = [ordered]@{}
    foreach ($prop in $outputsObj.PSObject.Properties) {
        if ($prop.Name -match '^dcr\d+ImmutableId$') { continue }   # drop old dcr1..7
        $newOutputs[$prop.Name] = $prop.Value
    }
    foreach ($suffix in $dcrLayout.Keys) {
        # Convert kebab-case suffix to camelCase for output name
        $camel = ($suffix -split '-' | ForEach-Object {
            if ($_ -eq ($suffix -split '-')[0]) { $_ } else { $_.Substring(0,1).ToUpper() + $_.Substring(1) }
        }) -join ''
        $outName = "dcr${camel}ImmutableId"
        $newOutputs[$outName] = [ordered]@{
            type  = 'string'
            value = "[reference(resourceId('Microsoft.Insights/dataCollectionRules', concat(variables('dcrName'), '-$suffix')), '2023-03-11').immutableId]"
        }
    }
    $tpl.outputs = $newOutputs
    Write-Host ("outputs: dropped 7 dcr1..7 entries, added {0} per-suffix entries" -f $dcrLayout.Keys.Count) -ForegroundColor Green
}

# ----- Write out -----
$json = $tpl | ConvertTo-Json -Depth 50
Set-Content -Path $TemplatePath -Value $json -NoNewline

# Sanity: parse-back check
$verify = Get-Content -Raw $TemplatePath | ConvertFrom-Json -Depth 50 -ErrorAction Stop
$dcrCount = @($verify.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }).Count
$mmpCount = @($verify.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.roleDefinitionId -match 'monitoringMetricsPublisher' }).Count
Write-Host ""
Write-Host "===== VERIFY =====" -ForegroundColor Green
Write-Host ("  JSON parse: OK")
Write-Host ("  DCRs: {0}" -f $dcrCount)
Write-Host ("  MMP role assignments: {0}" -f $mmpCount)
if ($dcrCount -ne 13) { throw "Expected 13 DCRs after refactor, got $dcrCount" }
if ($mmpCount -ne 13) { throw "Expected 13 MMP role assignments, got $mmpCount" }
