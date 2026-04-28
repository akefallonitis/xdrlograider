#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.8 path-drift regression gate: every manifest entry must have its
    path attested against one of the canonical research sources (XDRInternals,
    nodoc, DefenderHarvester, FalconForce blog series).

.DESCRIPTION
    Live evidence (iter-13.8 path-research audit, 2026-04-27): two manifest
    entries had paths that didn't match any canonical research source —
    `MDE_CustomCollection_CL` used `/model` instead of `/rules` (XDRInternals
    `Get-/New-/Set-XdrEndpointConfigurationCustomCollectionRule.ps1`), and
    `MDE_StreamingApiConfig_CL` had a renamed-by-Microsoft path. Both produced
    silent 4xx in production with no clear root cause.

    This gate prevents the bug class from re-occurring: every NEW manifest
    entry must either (a) match a path in the canonical-source map below, OR
    (b) carry an explicit `Source` annotation citing the file/line in
    XDRInternals/nodoc/DefenderHarvester that documents it, OR
    (c) be explicitly marked `Availability = 'deprecated'`.

    Maintenance: when adding a new manifest entry, also add its path to the
    $script:CanonicalPathMap below with the citation. Reviewers see the
    citation in code review, not in a separate doc.
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client' 'endpoints.manifest.psd1'

    # Canonical path → research-source citation map.
    # When adding a manifest entry, add its path here with the citation.
    # Format: 'path' = 'source:file:lines'
    $script:CanonicalPathMap = @{
        # ---- P0 ----
        '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting'                                                = 'XDRInternals:Get-XdrEndpointConfigurationAdvancedFeature.ps1'
        '/apiproxy/mtp/settings/GetPreviewExperienceSetting?context=MdatpContext'                          = 'XDRInternals:Get-XdrConfigurationPreviewFeatures.ps1 (iter-13.9 added context query-string)'
        '/apiproxy/mtp/alertsApiService/workloads/disabled?includeDetails=true'                            = 'XDRInternals:Get-XdrConfigurationAlertServiceSetting.ps1 (iter-13.9 added includeDetails)'
        '/apiproxy/mtp/alertsEmailNotifications/email_notifications'                                       = 'nodoc:alert-tuning surface (XDRInternals has no Get-Xdr*AlertTuning cmdlet)'
        '/apiproxy/mtp/suppressionRulesService/suppressionRules'                                           = 'XDRInternals:Get-XdrSuppressionRule.ps1'
        '/apiproxy/mtp/huntingService/rules/unified?pageIndex=1&pageSize=10000&sortOrder=Ascending&isUnifiedRulesListEnabled=true' = 'XDRInternals:Get-XdrAdvancedHuntingUnifiedDetectionRules.ps1 (iter-13.9 added pagination + unifiedRulesList flag)'
        '/apiproxy/mtp/siamApi/Onboarding'                                                                 = 'XDRInternals:Get-XdrEndpointConfigurationDeviceControl.ps1 / Get-XdrIdentityOnboarding.ps1'
        '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'                = 'XDRInternals:Get-XdrEndpointConfigurationWebContentFiltering.ps1'
        '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary'                            = 'XDRInternals:Get-XdrEndpointConfigurationSmartScreen.ps1'
        '/apiproxy/mtp/liveResponseApi/get_properties?useV2Api=true&useV3Api=true'                         = 'XDRInternals:Get-XdrEndpointConfigurationLiveResponse.ps1 (iter-13.9 added V2/V3 api flags)'
        '/apiproxy/mtp/responseApiPortal/senseauth/allownonauthsense'                                      = 'XDRInternals:Get-XdrEndpointConfigurationAuthenticatedTelemetry.ps1'
        '/apiproxy/mtp/autoIr/ui/properties/'                                                              = 'XDRInternals:Get-XdrEndpointConfigurationPotentiallyUnwantedApplications.ps1'
        '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters'         = 'MS Learn:defender-endpoint/mde-security-settings-management (Intune-bridge surface)'
        '/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues'                            = 'Portal trace:tenant-allow-block (papin namespace; preview surface)'
        '/apiproxy/mtp/mdeCustomCollection/rules'                                                          = 'XDRInternals:Get-/New-/Set-XdrEndpointConfigurationCustomCollectionRule.ps1 (iter-13.8 corrected from /model)'

        # ---- P1 ----
        '/apiproxy/mtp/wdatpApi/dataexportsettings'                                                        = 'XDRInternals:Get-XdrDataExportSetting.ps1'
        '/apiproxy/mtp/responseApiPortal/apps/all'                                                         = 'XDRInternals:Get-XdrConnectedApp.ps1'
        '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'                                     = 'XDRInternals:Get-XdrTenantContext.ps1'
        '/apiproxy/mtoapi/tenantGroups'                                                                    = 'XDRInternals:Get-XdrMtoTenantGroup.ps1 (mtoproxyurl:MTO header required)'
        '/apiproxy/mtp/streamingapi/streamingApiConfiguration'                                             = 'DEPRECATED in iter-13.8 (path renamed; canonical now collides with /wdatpApi/dataexportsettings)'
        '/apiproxy/mtp/responseApiPortal/onboarding/intune/status'                                         = 'XDRInternals:Get-XdrEndpointConfigurationIntuneConnection.ps1'
        '/apiproxy/mtp/wdatpInternalApi/compliance/alertSharing/status'                                    = 'XDRInternals:Get-XdrEndpointConfigurationPurviewSharing.ps1'

        # ---- P2 ----
        '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups?addAadGroupNames=true&addMachineGroupCount=false' = 'XDRInternals:Get-XdrEndpointDeviceRbacGroup.ps1 (iter-13.9 added addAadGroupNames + UnwrapProperty=items)'
        '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions'                    = 'nodoc:URBAC roleDefinitions (XDRInternals Get-XdrConfigurationUnifiedRBACWorkload uses /tenantinfo/, different surface)'
        '/apiproxy/mtp/xspmatlas/assetrules'                                                               = 'XDRInternals:Get-XdrXspmAssetRule.ps1'
        '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall'                            = 'XDRInternals:Get-XdrIdentityServiceAccountClassification.ps1'

        # ---- P3 ----
        '/apiproxy/mtp/posture/oversight/initiatives'                                                      = 'XDRInternals:Get-XdrXspmInitiative.ps1'
        '/apiproxy/mtp/posture/oversight/updates'                                                          = 'XDRInternals:Get-XdrXspmExposureSnapshot.ps1'
        '/apiproxy/mtp/secureScore/security/secureScoresV2'                                                = 'XDRInternals:Get-XdrSecureScore.ps1'
        '/apiproxy/mtp/posture/oversight/recommendations'                                                  = 'XDRInternals:Get-XdrExposureRecommendation.ps1'
        '/apiproxy/mtp/xspmatlas/attacksurface/query'                                                      = 'XDRInternals:Invoke-XdrXspmHuntingQuery.ps1 (POST + x-tid + x-ms-scenario-name)'
        '/apiproxy/mtp/tvm/analytics/baseline/profiles?pageIndex=0&pageSize=25'                            = 'XDRInternals:Get-XdrVulnerabilityManagementBaseline.ps1'

        # ---- P5 ----
        '/apiproxy/aatp/api/sensors/domainControllerCoverage'                                              = 'XDRInternals:Get-XdrIdentityDomainControllerCoverage.ps1'
        '/apiproxy/mtp/siamApi/domaincontrollers/list'                                                     = 'XDRInternals:Get-XdrIdentityOnboarding.ps1 (UnwrapProperty=DomainControllers)'
        '/apiproxy/aatp/api/alertthresholds/withExpiry'                                                    = 'XDRInternals:Get-XdrIdentityAlertThreshold.ps1'
        '/apiproxy/aatp/api/remediationActions/configuration'                                              = 'XDRInternals:Get-XdrIdentityConfigurationRemediationActionAccount.ps1'
        '/apiproxy/mdi/identity/userapiservice/serviceAccounts'                                            = 'XDRInternals:Get-XdrIdentityServiceAccount.ps1'

        # ---- P6 ----
        '/apiproxy/mtp/threatAnalytics/outbreaks'                                                          = 'XDRInternals:Get-XdrThreatAnalytic.ps1'
        '/apiproxy/mtp/actionCenter/actioncenterui/history-actions/?type=history&useMtpApi=true&pageIndex=1&pageSize=1000&sortByField=ActionCreationTime&sortOrder=Descending' = 'XDRInternals:Get-XdrActionsCenterHistory.ps1 (iter-13.9 added required type/useMtpApi/pageSize)'

        # ---- P7 ----
        '/apiproxy/mtoapi/tenants/TenantPicker'                                                            = 'XDRInternals:Get-XdrMtoTenant.ps1 (mtoproxyurl:MTO header required)'
        '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference'                     = 'XDRInternals:Get-XdrUserPreference.ps1'
        '/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport'                             = 'XDRInternals:Get-XdrLicenseReport.ps1 (UnwrapProperty=sums)'
        '/apiproxy/mcas/cas/api/v1/settings/'                                                              = 'XDRInternals:Get-XdrCloudAppsGeneralSetting.ps1 (iter-13.9 added trailing slash; MS Learn /defender-cloud-apps confirms canonical)'
    }
}

Describe 'Path drift regression gate (iter 13.8)' {

    It 'every manifest entry path is attested against a canonical research source' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $entries  = @($manifest.Endpoints)

        $unattested = @()
        foreach ($e in $entries) {
            # Strip query-string for the lookup but keep it in the message
            $pathKey = $e.Path
            if ($script:CanonicalPathMap.ContainsKey($pathKey)) { continue }

            # Some paths have placeholder substitutions like {machineId}; allow
            # match by stripping the placeholder for the lookup
            $stripped = $pathKey -replace '\{[^}]+\}', '{ID}'
            if ($script:CanonicalPathMap.ContainsKey($stripped)) { continue }

            $unattested += "$($e.Stream) -> $($e.Path)"
        }

        $unattested | Should -BeNullOrEmpty -Because (
            'iter-13.8: every manifest path must be attested against a canonical research source. ' +
            'Add the path + citation to $script:CanonicalPathMap in this test file when adding a new entry. ' +
            'Unattested entries:' + [Environment]::NewLine + ($unattested -join [Environment]::NewLine)
        )
    }

    It 'manifest contains no path that was previously deprecated/retired (catches accidental revivals)' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $entries  = @($manifest.Endpoints)

        # Paths we deliberately retired — re-introducing one without bumping
        # iter version would silently re-introduce the bug class.
        $retiredPaths = @(
            '/apiproxy/mtp/mdeCustomCollection/model'  # iter-13.8: corrected to /rules per XDRInternals
        )

        $revivals = @()
        foreach ($e in $entries) {
            if ($retiredPaths -contains $e.Path -and $e.Availability -ne 'deprecated') {
                $revivals += "$($e.Stream) -> $($e.Path) (re-introduced after iter-13.8 retirement)"
            }
        }

        $revivals | Should -BeNullOrEmpty -Because (
            'iter-13.8: re-introducing a retired path without justification re-opens the bug class. ' +
            'Either correct the path OR mark the entry Availability=deprecated. Revivals: ' + ($revivals -join '; ')
        )
    }

    It 'every deprecated entry has a documented STREAMS-REMOVED.md note' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $deprecated = @($manifest.Endpoints | Where-Object { $_.Availability -eq 'deprecated' }).Stream

        $streamsRemoved = Get-Content (Join-Path $script:RepoRoot 'docs/STREAMS-REMOVED.md') -Raw

        $missing = @()
        foreach ($s in $deprecated) {
            if ($streamsRemoved -notmatch [regex]::Escape($s)) {
                $missing += $s
            }
        }
        $missing | Should -BeNullOrEmpty -Because (
            'iter-13.8: every deprecated stream must be documented in STREAMS-REMOVED.md so operators know not to wire downstream parsers/rules to it. Missing: ' + ($missing -join ', ')
        )
    }

    It 'CanonicalPathMap covers every live + tenant-gated manifest entry (no orphan citations)' {
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $manifestPaths = @($manifest.Endpoints | Where-Object { $_.Availability -in 'live','tenant-gated' }).Path |
            ForEach-Object { $_ -replace '\{[^}]+\}', '{ID}' } |
            Sort-Object -Unique

        $orphans = @()
        foreach ($k in $script:CanonicalPathMap.Keys) {
            if ($manifestPaths -notcontains $k) {
                # Allow deprecated paths in the map (so their citation is preserved historically)
                $manifestEntry = $manifest.Endpoints | Where-Object { $_.Path -eq $k }
                if ($manifestEntry -and $manifestEntry.Availability -eq 'deprecated') { continue }
                if (-not $manifestEntry) {
                    # Path is in the map but not in the manifest at all (orphan citation)
                    $orphans += $k
                }
            }
        }
        # Deprecated entries' paths are intentionally retained
        $orphans | Should -BeNullOrEmpty -Because (
            'iter-13.8: a citation in CanonicalPathMap that no longer corresponds to a manifest entry is dead code. Orphans: ' + ($orphans -join '; ')
        )
    }
}
