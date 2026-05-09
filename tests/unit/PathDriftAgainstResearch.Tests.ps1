#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.8 path-drift regression gate: every manifest entry must have its
    path attested against one of the canonical research sources (XDRInternals,
    nodoc, DefenderHarvester, FalconForce blog series).

.DESCRIPTION
    Live evidence (pre-v0.1.0.8 path-research audit, 2026-04-27): two manifest
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
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'

    # Canonical path → research-source citation map.
    # When adding a manifest entry, add its path here with the citation.
    # Format: 'path' = 'source:file:lines'
    $script:CanonicalPathMap = @{
        # ---- P0 ----
        '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting'                                                = 'XDRInternals:Get-XdrEndpointConfigurationAdvancedFeature.ps1'
        '/apiproxy/mtp/settings/GetPreviewExperienceSetting?context=MdatpContext'                          = 'XDRInternals:Get-XdrConfigurationPreviewFeatures.ps1 (pre-v0.1.0.9 added context query-string)'
        '/apiproxy/mtp/alertsApiService/workloads/disabled?includeDetails=true'                            = 'XDRInternals:Get-XdrConfigurationAlertServiceSetting.ps1 (pre-v0.1.0.9 added includeDetails)'
        '/apiproxy/mtp/alertsEmailNotifications/email_notifications'                                       = 'nodoc:alert-tuning surface (XDRInternals has no Get-Xdr*AlertTuning cmdlet)'
        '/apiproxy/mtp/suppressionRulesService/suppressionRules'                                           = 'XDRInternals:Get-XdrSuppressionRule.ps1'
        '/apiproxy/mtp/huntingService/rules/unified?sortOrder=Ascending&isUnifiedRulesListEnabled=true' = 'XDRInternals:Get-XdrAdvancedHuntingUnifiedDetectionRules.ps1 (Section R++++++ Phase 1+ moved pageIndex/pageSize to manifest Pagination config 2026-05-08)'
        '/apiproxy/mtp/siamApi/Onboarding'                                                                 = 'XDRInternals:Get-XdrEndpointConfigurationDeviceControl.ps1 / Get-XdrIdentityOnboarding.ps1'
        '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'                = 'XDRInternals:Get-XdrEndpointConfigurationWebContentFiltering.ps1'
        '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary'                            = 'XDRInternals:Get-XdrEndpointConfigurationSmartScreen.ps1'
        '/apiproxy/mtp/liveResponseApi/get_properties?useV2Api=true&useV3Api=true'                         = 'XDRInternals:Get-XdrEndpointConfigurationLiveResponse.ps1 (pre-v0.1.0.9 added V2/V3 api flags)'
        '/apiproxy/mtp/responseApiPortal/senseauth/allownonauthsense'                                      = 'XDRInternals:Get-XdrEndpointConfigurationAuthenticatedTelemetry.ps1'
        '/apiproxy/mtp/autoIr/ui/properties/'                                                              = 'XDRInternals:Get-XdrEndpointConfigurationPotentiallyUnwantedApplications.ps1'
        '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters?platform=Windows' = 'nodoc endpoint_configuration.yml:345-376 (Section R+++ 2026-05-07: platform query is REQUIRED — fixes 400 Bad Request; Architecture C PerPlatformFanout in v0.1.0 GA per plan R++++)'
        # Section R++++++ F6 (2026-05-07T19:15Z): TenantAllowBlock path swap from
        # /papin/.../filterValues (UI dropdown facets, returned 500 in lab) to
        # canonical /responseApiPortal/ti/indicators per nodoc configuration.yml:1655.
        '/apiproxy/mtp/responseApiPortal/ti/indicators'                                                    = 'nodoc:configuration.yml:1655 — Configuration.ListThreatIndicators (TABL custom threat indicators inventory)'
        '/apiproxy/mtp/mdeCustomCollection/rules'                                                          = 'XDRInternals:Get-/New-/Set-XdrEndpointConfigurationCustomCollectionRule.ps1 (pre-v0.1.0.8 corrected from /model)'

        # ---- P1 ----
        '/apiproxy/mtp/wdatpApi/dataexportsettings'                                                        = 'XDRInternals:Get-XdrDataExportSetting.ps1'
        '/apiproxy/mtp/responseApiPortal/apps/all'                                                         = 'XDRInternals:Get-XdrConnectedApp.ps1'
        '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'                                     = 'XDRInternals:Get-XdrTenantContext.ps1'
        '/apiproxy/mtoapi/tenantGroups'                                                                    = 'XDRInternals:Get-XdrMtoTenantGroup.ps1 (mtoproxyurl:MTO header required)'
        '/apiproxy/mtp/streamingapi/streamingApiConfiguration'                                             = 'DEPRECATED in pre-v0.1.0.8 (path renamed; canonical now collides with /wdatpApi/dataexportsettings)'
        '/apiproxy/mtp/responseApiPortal/onboarding/intune/status'                                         = 'XDRInternals:Get-XdrEndpointConfigurationIntuneConnection.ps1'
        '/apiproxy/mtp/wdatpInternalApi/compliance/alertSharing/status'                                    = 'XDRInternals:Get-XdrEndpointConfigurationPurviewSharing.ps1'

        # ---- P2 ----
        '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups?addAadGroupNames=true&addMachineGroupCount=false' = 'XDRInternals:Get-XdrEndpointDeviceRbacGroup.ps1 (pre-v0.1.0.9 added addAadGroupNames + UnwrapProperty=items)'
        '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions'                    = 'nodoc:URBAC roleDefinitions (XDRInternals Get-XdrConfigurationUnifiedRBACWorkload uses /tenantinfo/, different surface)'
        '/apiproxy/mtp/xspmatlas/assetrules'                                                               = 'XDRInternals:Get-XdrXspmAssetRule.ps1'
        '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall'                            = 'XDRInternals:Get-XdrIdentityServiceAccountClassification.ps1'

        # ---- P3 ----
        # v0.1.0 GA (2026-04-29): MDE_SecureScoreBreakdown_CL DROPPED — publicly-API-covered
        # by Microsoft Graph /security/secureScores. Citation removed because the path no
        # longer corresponds to any manifest entry (orphan-citation gate).
        '/apiproxy/mtp/posture/oversight/initiatives'                                                      = 'XDRInternals:Get-XdrXspmInitiative.ps1'
        '/apiproxy/mtp/posture/oversight/updates'                                                          = 'XDRInternals:Get-XdrXspmExposureSnapshot.ps1'
        '/apiproxy/mtp/posture/oversight/recommendations'                                                  = 'XDRInternals:Get-XdrExposureRecommendation.ps1'
        '/apiproxy/mtp/xspmatlas/attacksurface/query'                                                      = 'XDRInternals:Invoke-XdrXspmHuntingQuery.ps1 (POST + x-tid + x-ms-scenario-name)'
        '/apiproxy/mtp/tvm/analytics/vulnerabilities/baseline'                                             = 'nodoc:vulnerability_management.yml:556 (operationId VulnerabilityManagement.GetBaseline) - Section R+++++ path-drift fix 2026-05-07'

        # ---- P5 ----
        '/apiproxy/aatp/api/sensors/domainControllerCoverage'                                              = 'XDRInternals:Get-XdrIdentityDomainControllerCoverage.ps1'
        '/apiproxy/mtp/siamApi/domaincontrollers/list'                                                     = 'XDRInternals:Get-XdrIdentityOnboarding.ps1 (UnwrapProperty=DomainControllers)'
        '/apiproxy/aatp/api/alertthresholds/withExpiry'                                                    = 'XDRInternals:Get-XdrIdentityAlertThreshold.ps1'
        '/apiproxy/aatp/api/remediationActions/configuration'                                              = 'XDRInternals:Get-XdrIdentityConfigurationRemediationActionAccount.ps1'
        '/apiproxy/mdi/identity/userapiservice/serviceAccounts'                                            = 'XDRInternals:Get-XdrIdentityServiceAccount.ps1'

        # ---- P3 (cont.) — portal-only device timeline ----
        # Section R++++++ Architecture A (2026-05-07): canonical path with {MachineId}
        # placeholder per nodoc endpoint_devices.yml:1042-1148. Activity-level fanout
        # iterates machineIds from MDE_Machines_CL source stream.
        '/apiproxy/mtp/mdeTimelineExperience/machines/{MachineId}/events'                                  = 'nodoc:endpoint_devices.yml:1042-1148 (operationId EndpointDevices.GetMachineTimelineEvents) - Section R++++++ Architecture A PerEntityFanout 2026-05-07'

        # ---- P6 ----
        '/apiproxy/mtp/threatAnalytics/outbreaks'                                                          = 'XDRInternals:Get-XdrThreatAnalytic.ps1'
        '/apiproxy/mtp/actionCenter/actioncenterui/history-actions'                                        = 'XDRInternals:Get-XdrActionsCenterHistory.ps1 (pre-v0.1.0.10 rolled back query-string after live audit returned 400; original param-less form is correct)'
        '/apiproxy/mtp/actionCenter/actioncenterui/pending-actions'                                        = 'nodoc:action_center.yml ActionCenter.GetPending operationId (Phase 2 batch 1 2026-05-09 R++++++++++; live-tested 200 OK in lab Phase 0)'
        '/apiproxy/aatp/api/ispmReports/DormantEntities/newEntryCount'                                     = 'nodoc:identity.yml Identity.GetDormantEntitiesNewEntryCount operationId (Phase 2 batch 2 2026-05-09 R++++++++++; MDI-licensed; lab returned 404 expected)'
        '/apiproxy/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount'                            = 'nodoc:identity.yml Identity.GetRiskyLateralMovementPathNewEntryCount operationId (Phase 2 batch 3 2026-05-09 R++++++++++; MDI-licensed; lab returned 404 expected; XSPM-class attack-path intelligence)'
        '/apiproxy/mtp/tvm/analytics/certificates?pageIndex=0&pageSize=200'                                = 'nodoc:vulnerability_management.yml VulnerabilityManagement.ListCertificates operationId (Phase 2 batch 4 2026-05-09 R++++++++++; TvmPremium-licensed; paginated; lab returned 400 expected)'
        '/apiproxy/mtp/tvm/analytics/vulnerabilities/summary'                                              = 'nodoc:vulnerability_management.yml VulnerabilityManagement.GetSummary operationId (Phase 2 batch 5 2026-05-09 R++++++++++; TvmPremium-licensed; SOC at-a-glance vulnerability posture; lab returned 400 expected)'
        '/apiproxy/mtp/tvm/analytics/extensions?pageIndex=0&pageSize=200'                                  = 'nodoc:vulnerability_management.yml VulnerabilityManagement.ListExtensions operationId (Phase 2 batch 6 2026-05-09 R++++++++++; TvmPremium-licensed; paginated; shadow-IT browser extension inventory)'
        '/apiproxy/mtp/tvm/analytics/assets/countByExposureLevel'                                          = 'nodoc:vulnerability_management.yml VulnerabilityManagement.GetAssetCountByExposureLevel operationId (Phase 2 batch 7 2026-05-09 R++++++++++; TvmPremium-licensed; SOC dashboard fleet exposure tier breakdown)'
        '/apiproxy/mtp/tvm/analytics/advisories?pageIndex=0&pageSize=200'                                  = 'nodoc:vulnerability_management.yml VulnerabilityManagement.ListAdvisories operationId (Phase 2 batch 8 2026-05-09 R++++++++++; TvmPremium-licensed; paginated; SOC awareness of new vendor advisories)'
        # F1 2026-05-08: MachineActions REMOVED (overlapped with ActionCenter canonical endpoint)

        # ---- P7 ----
        '/apiproxy/mtoapi/tenants/TenantPicker'                                                            = 'XDRInternals:Get-XdrMtoTenant.ps1 (mtoproxyurl:MTO header required)'
        '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference'                     = 'XDRInternals:Get-XdrUserPreference.ps1'
        '/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport'                             = 'XDRInternals:Get-XdrLicenseReport.ps1 (UnwrapProperty=sums)'
        '/apiproxy/mtp/ndr/machines?hideLowFidelityDevices=true&lookingBackIndays=30&sortByField=riskscore&sortOrder=Descending' = 'nodoc:endpoint_devices.yml:2-66 (operationId EndpointDevices.List) - Section R++++++ Phase 1 Architecture B foundation stream; Phase 1+ pageIndex/pageSize moved to manifest Pagination config 2026-05-08'
        '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies' = 'nodoc:endpoint_configuration.yml POST /securityPolicies - Section R++++++ Phase 1 G7 actual policy bodies (ASR/AV/EDR/Firewall) 2026-05-07'
        '/apiproxy/mtp/tvm/analytics/assets/topVulnerable'                                  = 'nodoc:vulnerability_management.yml /mtp/tvm/analytics/assets/topVulnerable - Section R++++++ Phase 1 G8 TVM expansion 2026-05-07'
        '/apiproxy/mtp/tvm/analytics/vulnerabilities'                                       = 'nodoc:vulnerability_management.yml /mtp/tvm/analytics/vulnerabilities - Section R++++++ Phase 1 G8 TVM expansion 2026-05-07'
        '/apiproxy/mtp/tvm/analytics/products'                                              = 'nodoc:vulnerability_management.yml /mtp/tvm/analytics/products - Section R++++++ Phase 1 G8 TVM expansion 2026-05-07'
        '/apiproxy/mtp/tvm/remediation-tasks/remediationTasks'                              = 'nodoc:vulnerability_management.yml /mtp/tvm/remediation-tasks/remediationTasks - Section R++++++ Phase 1 G8 TVM expansion 2026-05-07'
        '/apiproxy/mcas/cas/api/v1/settings'                                                               = 'nodoc cloud_apps.yml:222 + openapi.yml:970 (Section R+++ 2026-05-07: trailing slash removed — caused MCAS gateway 500)'

        # ---- v0.1.0 GA Phase 2 (2026-05-04): 13 Tier A new streams from nodoc catalog sweep ----
        '/apiproxy/mtp/xspmatlas/assetrules/querybuilder/schema'                     = 'nodoc:configuration.yml — XSPM critical-asset classification schema (DSL for asset-rule querybuilder)'
        '/apiproxy/mtp/posture/oversight/initiatives/summarized'                     = 'nodoc:exposure_management.yml — posture-oversight initiatives summary'
        '/apiproxy/mtp/posture/oversight/metrics'                                    = 'nodoc:exposure_management.yml — posture-oversight metrics catalog'
        '/apiproxy/mtp/posture/oversight/metrics/category_apps_secure_score'         = 'nodoc:exposure_management.yml — SaaS apps secure-score metric'
        '/apiproxy/mtp/posture/oversight/metrics/category_data_secure_score'         = 'nodoc:exposure_management.yml — data secure-score metric'
        '/apiproxy/mtp/posture/oversight/metrics/category_identity_secure_score'     = 'nodoc:exposure_management.yml — identity secure-score metric'
        '/apiproxy/mtp/posture/oversight/securityEvents'                             = 'nodoc:exposure_management.yml — posture security events stream'
        '/apiproxy/mtp/posture/oversight/tenants'                                    = 'nodoc:exposure_management.yml — posture-oversight tenant configuration'
        '/apiproxy/mtp/xspmatlas/attacksurface/attackpaths'                          = 'nodoc:exposure_management.yml — XSPM attack-surface attack paths analytical view'
        '/apiproxy/mtp/xspmatlas/attacksurface/chokepoints/list'                     = 'nodoc:exposure_management.yml — XSPM attack-surface choke points'
        '/apiproxy/mtp/XspmConnectors/connectors/getAllConnectors'                   = 'nodoc:exposure_management.yml — XSPM data connectors list'
        '/apiproxy/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp'           = 'nodoc:threat_analytics.yml — Threat Analytics enriched outbreak data'
        '/apiproxy/mtp/threatAnalytics/outbreaks/topthreats'                         = 'nodoc:threat_analytics.yml — Threat Analytics top threats summary'
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
            'pre-v0.1.0.8: every manifest path must be attested against a canonical research source. ' +
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
            '/apiproxy/mtp/mdeCustomCollection/model'  # pre-v0.1.0.8: corrected to /rules per XDRInternals
        )

        $revivals = @()
        foreach ($e in $entries) {
            if ($retiredPaths -contains $e.Path -and $e.Availability -ne 'deprecated') {
                $revivals += "$($e.Stream) -> $($e.Path) (re-introduced after pre-v0.1.0.8 retirement)"
            }
        }

        $revivals | Should -BeNullOrEmpty -Because (
            'pre-v0.1.0.8: re-introducing a retired path without justification re-opens the bug class. ' +
            'Either correct the path OR mark the entry Availability=deprecated. Revivals: ' + ($revivals -join '; ')
        )
    }

    It 'every deprecated entry has a Purpose note explaining the deprecation reason' {
        # v0.1.0 GA: deprecated streams self-document via the manifest Purpose field
        # Deprecated streams now self-document via the Purpose field in the manifest.
        $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
        $deprecated = @($manifest.Endpoints | Where-Object { $_.Availability -eq 'deprecated' })

        $missing = @()
        foreach ($d in $deprecated) {
            if ([string]::IsNullOrWhiteSpace($d.Purpose) -or $d.Purpose.Length -lt 20) {
                $missing += $d.Stream
            }
        }
        $missing | Should -BeNullOrEmpty -Because (
            'every deprecated stream must self-document via its Purpose field (operator must understand why the stream is deprecated). Missing: ' + ($missing -join ', ')
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
            'pre-v0.1.0.8: a citation in CanonicalPathMap that no longer corresponds to a manifest entry is dead code. Orphans: ' + ($orphans -join '; ')
        )
    }
}
