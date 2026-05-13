# Enrich-CrossReferences.ps1
#
# Walk references/<portal>/<sub-area>/<endpoint>/metadata.json files and add
# accurate cross-references against:
#   - XDRInternals cmdlets (real list from MSCloudInternals/XDRInternals README)
#   - DefenderHarvester paths (real list from olafhartong/DefenderHarvester main.go)
#
# No live calls. Pure metadata enrichment.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

# ---------------------------------------------------------------------------
# Real XDRInternals cmdlet list (from MSCloudInternals/XDRInternals README, 2026-05-12)
# ---------------------------------------------------------------------------
$xdrInternalsCmdlets = @(
    'Connect-XdrByBrowser','Connect-XdrByCredential','Connect-XdrByEstsCookie',
    'Connect-XdrByPhoneSignIn','Connect-XdrBySoftwarePasskey','Connect-XdrBySSO',
    'Connect-XdrByTemporaryAccessPass','Connect-XdrEndpointDeviceLiveResponse',
    'ConvertTo-XdrEncodedAdvancedHuntingQuery','Disconnect-XdrEndpointDeviceLiveResponse',
    'Export-XdrToSentinel',
    'Get-XdrActionsCenterHistory','Get-XdrActionsCenterPending',
    'Get-XdrAdvancedHuntingFunction','Get-XdrAdvancedHuntingTableSchema',
    'Get-XdrAdvancedHuntingUnifiedDetectionRules','Get-XdrAdvancedHuntingUserHistory',
    'Get-XdrAlert','Get-XdrCloudAppsActivityTimeline','Get-XdrCloudAppsApp',
    'Get-XdrCloudAppsConfiguration','Get-XdrCloudAppsDiscovery',
    'Get-XdrCloudAppsGeneralSetting','Get-XdrCloudAppsGovernance','Get-XdrCloudAppsPolicy',
    'Get-XdrConfigurationAlertServiceSetting','Get-XdrConfigurationAlertTuning',
    'Get-XdrConfigurationAssetRuleManagement',
    'Get-XdrConfigurationCriticalAssetManagementClassification',
    'Get-XdrConfigurationCriticalAssetManagementClassificationSchema',
    'Get-XdrConfigurationPreviewFeatures','Get-XdrConfigurationServiceAccountClassification',
    'Get-XdrConfigurationUnifiedRBACWorkload',
    'Get-XdrDatalakeDatabase','Get-XdrDatalakeTableSchema',
    'Get-XdrEndpointAdvancedFeatures','Get-XdrEndpointConfigurationAdvancedFeatures',
    'Get-XdrEndpointConfigurationAuthenticatedTelemetry',
    'Get-XdrEndpointConfigurationCustomCollectionRule',
    'Get-XdrEndpointConfigurationIntuneConnection',
    'Get-XdrEndpointConfigurationLiveResponse',
    'Get-XdrEndpointConfigurationPotentiallyUnwantedApplications',
    'Get-XdrEndpointConfigurationPreviewFeature',
    'Get-XdrEndpointConfigurationPurviewSharing',
    'Get-XdrEndpointDevice','Get-XdrEndpointDeviceActionResult',
    'Get-XdrEndpointDeviceLiveResponseLibrary','Get-XdrEndpointDeviceLiveResponseLibraryFile',
    'Get-XdrEndpointDeviceModel','Get-XdrEndpointDeviceOsVersionFriendlyName',
    'Get-XdrEndpointDeviceRbacGroup','Get-XdrEndpointDeviceRbacGroupScope',
    'Get-XdrEndpointDeviceTag','Get-XdrEndpointDeviceTimeline',
    'Get-XdrEndpointDeviceTotals','Get-XdrEndpointDeviceVendor',
    'Get-XdrEndpointDeviceWindowsReleaseVersion','Get-XdrEndpointLicenseReport',
    'Get-XdrExposureManagementRecommendations',
    'Get-XdrIdentityAlertThreshold','Get-XdrIdentityConfigurationDirectoryServiceAccount',
    'Get-XdrIdentityConfigurationRemediationActionAccount',
    'Get-XdrIdentityDomainControllerCoverage','Get-XdrIdentityIdentity',
    'Get-XdrIdentityOnboardingStatus','Get-XdrIdentityServiceAccount',
    'Get-XdrIdentityStatistic','Get-XdrIdentityUser','Get-XdrIdentityUserTimeline',
    'Get-XdrIncident','Get-XdrIncidentAssociatedAlert',
    'Get-XdrMtoTenantList','Get-XdrStreamingApiConfiguration','Get-XdrSuppressionRule',
    'Get-XdrTenantContext','Get-XdrTenantWorkloadStatus',
    'Get-XdrThreatAnalyticsOutbreaks',
    'Get-XdrVulnerabilityManagementAdvisories','Get-XdrVulnerabilityManagementBaseline',
    'Get-XdrVulnerabilityManagementCertificates','Get-XdrVulnerabilityManagementChangeEvents',
    'Get-XdrVulnerabilityManagementDashboard','Get-XdrVulnerabilityManagementExtensions',
    'Get-XdrVulnerabilityManagementProducts','Get-XdrVulnerabilityManagementRemediationTasks',
    'Get-XdrVulnerabilityManagementVulnerabilities',
    'Get-XdrXspmAttackPath','Get-XdrXspmChokePoint','Get-XdrXspmTopEntryPoint','Get-XdrXspmTopTarget',
    'Invoke-XdrEndpointDeviceAction','Invoke-XdrEndpointDeviceAutomatedInvestigation',
    'Invoke-XdrEndpointDeviceLiveResponseCommand','Invoke-XdrEndpointDevicePolicySync',
    'Invoke-XdrHuntingQueryValidation','Invoke-XdrMtoAdvancedHunting',
    'Invoke-XdrRestMethod','Invoke-XdrXspmHuntingQuery',
    'Merge-XdrIncident','Move-XdrAlertToIncident',
    'New-XdrAdvancedHuntingFunction',
    'New-XdrConfigurationCriticalAssetManagementClassification',
    'New-XdrEndpointConfigurationCustomCollectionRule',
    'New-XdrEndpointDeviceLiveResponseLibraryFile','New-XdrEndpointDeviceRbacGroup',
    'New-XdrIdentityConfigurationRemediationActionAccount',
    'Remove-XdrAdvancedHuntingFunction',
    'Remove-XdrConfigurationCriticalAssetManagementClassification',
    'Remove-XdrEndpointDeviceLiveResponseLibraryFile',
    'Remove-XdrIdentityConfigurationRemediationActionAccount',
    'Set-XdrAdvancedHuntingFunction','Set-XdrCloudAppsDiscoveredApp',
    'Set-XdrConfigurationCriticalAssetManagementClassification',
    'Set-XdrConfigurationPreviewFeatures','Set-XdrConnectionSettings',
    'Set-XdrEndpointAdvancedFeatures','Set-XdrEndpointConfigurationCustomCollectionRule',
    'Set-XdrEndpointDeviceAssetValue','Set-XdrEndpointDeviceCriticalityLevel',
    'Set-XdrEndpointDeviceExclusionState','Set-XdrEndpointDeviceRbacGroup',
    'Set-XdrEndpointDeviceTag','Set-XdrIdentityConfigurationRemediationActionAccount',
    'Set-XdrSentinelConnection','Stop-XdrEndpointDeviceAction','Update-XdrConnectionSettings'
)

# ---------------------------------------------------------------------------
# Real DefenderHarvester paths (from olafhartong/DefenderHarvester/main.go, 2026-05-12)
# ---------------------------------------------------------------------------
$defenderHarvesterPaths = @{
    '/api/ine/huntingservice/schema'                          = 'Advanced Hunting table schema'
    '/api/detection/experience/timeline/machines/{machineId}/events/' = 'Device timeline events'
    '/api/autoir/actioncenterui/history-actions'              = 'Action Center history'
    '/api/machineactions'                                     = 'Machine actions'
    '/api/ine/huntingservice/rules'                           = 'Custom detection rules'
    '/api/settings/GetAdvancedFeaturesSetting'                = 'Advanced features toggles'
    '/api/ine/suppressionrulesservice/suppressionRules'       = 'Suppression rules'
    '/rbac/machine_groups'                                    = 'RBAC machine groups'
    '/api/cloud/portal/apps/all'                              = 'Connected cloud apps'
    '/api/ine/huntingservice/reports'                         = 'Hunting reports'
    '/api/ine/alertsapiservice/workloads/disabled'            = 'Alert service workloads disabled'
    '/api/dataexportsettings'                                 = 'Streaming/Data export destinations'
}

# ---------------------------------------------------------------------------
# Build cmdlet → operationId match index
# Match strategy: cmdlet name minus 'Get-Xdr' / 'Set-Xdr' / 'New-Xdr' prefix, normalized
# to lowercase, against operationId's tail portion (after the dot)
# ---------------------------------------------------------------------------
function Match-XdrInternalsCmdlet {
    param([string]$OperationId)
    if (-not $OperationId -or -not $OperationId.Contains('.')) { return $null }
    $parts  = $OperationId -split '\.', 2
    $catRaw = $parts[0]                       # 'ActionCenter'
    $opTail = $parts[1]                       # 'GetHistory'
    $opBase = $opTail -replace '^(Get|List|Query|Set|Update|Create|Delete|Post|Put)', ''  # 'History'

    # Try several category-name variations that XDRInternals might use
    $catVariations = New-Object System.Collections.Generic.HashSet[string]
    [void]$catVariations.Add($catRaw)
    [void]$catVariations.Add(($catRaw -replace 's$', ''))
    [void]$catVariations.Add("${catRaw}s")
    if ($catRaw -eq 'ActionCenter')       { [void]$catVariations.Add('ActionsCenter') }
    if ($catRaw -eq 'XdrInternals')       { [void]$catVariations.Add('XSPM') }
    if ($catRaw -eq 'EndpointDevices')    { [void]$catVariations.Add('EndpointDevice') }
    if ($catRaw -eq 'EndpointConfiguration') { [void]$catVariations.Add('EndpointConfiguration') }
    if ($catRaw -eq 'CloudApps')          { [void]$catVariations.Add('CloudApps') }
    if ($catRaw -eq 'MultiTenant')        { [void]$catVariations.Add('Mto') }
    if ($catRaw -eq 'SecureScore')        { [void]$catVariations.Add('Endpoint') }     # XDRInternals folds in Endpoint
    if ($catRaw -eq 'Streaming')          { [void]$catVariations.Add('StreamingApi') }

    foreach ($cat in $catVariations) {
        $candidates = $xdrInternalsCmdlets | Where-Object { $_ -match "Xdr$cat" }
        foreach ($c in $candidates) {
            $cBase = $c -replace '^(Get|Set|New|Remove|Connect|Disconnect|Invoke|Stop|Move|Merge|Update|Convert|Export)-Xdr', ''
            $cBase = $cBase -replace "^$cat", ''
            if ($cBase -ieq $opBase) { return $c }
            # Plural/singular variations
            $cBaseNorm  = ($cBase -replace 'ies$', 'y') -replace 's$', ''
            $opBaseNorm = ($opBase -replace 'ies$', 'y') -replace 's$', ''
            if ($cBaseNorm -ieq $opBaseNorm) { return $c }
            # Contains either direction (loose match)
            if ($cBase.Length -ge 5 -and $opBase.Length -ge 5) {
                if ($cBase.ToLower().Contains($opBase.ToLower()) -or $opBase.ToLower().Contains($cBase.ToLower())) {
                    return $c
                }
            }
        }
    }
    return $null
}

function Match-DefenderHarvester {
    param([string]$Path)
    foreach ($key in $defenderHarvesterPaths.Keys) {
        # Compare on the tail portion (after /api/ or /apiproxy/)
        $keyTail = $key -replace '^/api(proxy)?', ''
        $pathTail = $Path -replace '^/api(proxy)?', '' -replace '^/mtp', ''
        if ($pathTail -like "*$keyTail*" -or $keyTail -like "*$pathTail*") {
            return [pscustomobject]@{ Path=$key; Description=$defenderHarvesterPaths[$key] }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Walk all metadata.json files; update xdrInternalsHint + defenderHarvester
# ---------------------------------------------------------------------------
$total = 0; $xdrMatched = 0; $harvMatched = 0
Get-ChildItem -Path $ReferencesRoot -Filter 'metadata.json' -Recurse | ForEach-Object {
    $f = $_.FullName
    try {
        $m = Get-Content $f -Raw | ConvertFrom-Json -Depth 30
    } catch { return }
    $total++
    $xdr = Match-XdrInternalsCmdlet -OperationId $m.operationId
    $harv = $null
    if ($m.portal -eq 'defender') {
        $harv = Match-DefenderHarvester -Path $m.path
    }
    if ($xdr) { $xdrMatched++ }
    if ($harv) { $harvMatched++ }
    # Update fields
    $m | Add-Member -NotePropertyName 'xdrInternalsCmdlet' -NotePropertyValue $xdr -Force
    if ($harv) {
        $m | Add-Member -NotePropertyName 'defenderHarvesterMatch' -NotePropertyValue (@{ Path=$harv.Path; Description=$harv.Description }) -Force
    } else {
        $m | Add-Member -NotePropertyName 'defenderHarvesterMatch' -NotePropertyValue $null -Force
    }
    # Strip the old fabricated fields
    if ($m.PSObject.Properties['xdrInternalsHint']) { $m.PSObject.Properties.Remove('xdrInternalsHint') }
    if ($m.PSObject.Properties['defenderHarvester']) { $m.PSObject.Properties.Remove('defenderHarvester') }

    $m | ConvertTo-Json -Depth 30 | Set-Content -Path $f
}

Write-Host ""
Write-Host "=== Cross-reference enrichment complete ===" -ForegroundColor Cyan
Write-Host ("  Total metadata files scanned:   {0}" -f $total)
Write-Host ("  XDRInternals cmdlet matches:    {0}" -f $xdrMatched)
Write-Host ("  DefenderHarvester path matches: {0}" -f $harvMatched)
