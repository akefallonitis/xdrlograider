@{
    # ============================================================================
    # XdrLogRaider — Endpoint Catalogue
    # ============================================================================
    # Single source of truth for every Defender XDR portal-only stream this
    # connector collects. Dispatched at runtime by Invoke-MDEEndpoint (per-stream)
    # and Invoke-MDETierPoll (per-tier loop).
    #
    # Scope: READ-ONLY config / compliance / audit / telemetry from
    # security.microsoft.com internal APIs not exposed by Microsoft Graph,
    # public Defender XDR APIs, or public MDE APIs.
    #
    # Research basis (2026-04-23 live audit against security.microsoft.com):
    #   - nodoc (github.com/nathanmcnulty/nodoc) OpenAPI spec, 576 unique paths
    #   - XDRInternals (github.com/MSCloudInternals/XDRInternals) source, 150 paths
    #   - DefenderHarvester (olafhartong/DefenderHarvester) — legacy WDATP paths
    #   - Live probe via tests/integration/Audit-Endpoints-Live.ps1
    #
    # Key path-pattern discoveries from the 2026-04 audit:
    #   1. Defender portal APIs live under /apiproxy/mtp/... (NOT /api/...).
    #      Paths without /apiproxy prefix return HTTP 404.
    #   2. Identity (MDI) APIs live under /apiproxy/mdi/... or /apiproxy/aatp/...
    #   3. MCAS/Cloud Apps paths live under /apiproxy/mcas/...
    #   4. Many XSPM endpoints require POST with a query body (flagged "Method=POST" below).
    #   5. Some streams (mdeTimelineExperience, cloudPivot, alerts/alertsOvertime) take
    #      time-window filters via fromDate/toDate/startTime/endTime query params.
    #
    # Per-entry schema:
    #   Stream      [required]  Log Analytics custom table name (e.g. 'MDE_PUAConfig_CL')
    #   Path        [required]  portal API path, relative to https://security.microsoft.com
    #   Tier        [required]  'P0' | 'P1' | 'P2' | 'P3' | 'P5' | 'P6' | 'P7'
    #                           P0 = hourly config/compliance           (poll-p0-compliance-1h)
    #                           P1 = 30-min integration/pipeline        (poll-p1-pipeline-30m)
    #                           P2 = daily governance                   (poll-p2-governance-1d)
    #                           P3 = hourly exposure                    (poll-p3-exposure-1h)
    #                           P5 = daily identity                     (poll-p5-identity-1d)
    #                           P6 = 10-min audit/AIR                   (poll-p6-audit-10m)
    #                           P7 = daily metadata/licensing           (poll-p7-metadata-1d)
    #   Method      [optional]  'GET' (default) or 'POST'. XSPM endpoints are POST-only.
    #   Filter      [optional]  query-string param name for delta polling
    #                           ('fromDate' on most filterable endpoints).
    #   IdProperty  [optional]  override for Expand-MDEResponse's default ID lookup.
    #   PathParams  [optional]  string[] of placeholder names to substitute in Path.
    #   Body        [optional]  hashtable used as request body for POST endpoints.
    #   Deferred    [optional]  bool. When $true, Invoke-MDETierPoll skips the entry
    #                           unless -IncludeDeferred is passed. DCR / custom-table
    #                           stays provisioned so the stream is re-enableable.
    #   DeferReason [optional]  free-form comment explaining why Deferred.
    # ============================================================================

    Endpoints = @(
        # ---- P0 Compliance (19 streams, hourly) ------------------------------------
        @{ Stream = 'MDE_AdvancedFeatures_CL';          Path = '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting';                                Tier = 'P0' }
        @{ Stream = 'MDE_PreviewFeatures_CL';           Path = '/apiproxy/mtp/settings/GetPreviewExperienceSetting';                               Tier = 'P0' }
        @{ Stream = 'MDE_AuthenticatedTelemetry_CL';    Path = '/apiproxy/mtp/deviceManagement/configuration/AuthenticatedTelemetry';              Tier = 'P0'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; likely renamed or needs query params — 2026-04-23 audit' }
        @{ Stream = 'MDE_PUAConfig_CL';                 Path = '/apiproxy/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications';     Tier = 'P0'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; requires portal experimentation — 2026-04-23 audit' }
        @{ Stream = 'MDE_AsrRulesConfig_CL';            Path = '/apiproxy/mtp/tvm/analytics/configurations/securescore/categories';                Tier = 'P0'; Deferred = $true; DeferReason = 'AV config APIs not found in 2026-04-23 catalogue' }
        @{ Stream = 'MDE_AntivirusPolicy_CL';           Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters'; Tier = 'P0'; Deferred = $true; DeferReason = 'unifiedExperience path returns 400; needs body/filter shape research' }
        @{ Stream = 'MDE_AntiRansomwareConfig_CL';      Path = '/apiproxy/mtp/tvm/analytics/configurations/securescore/categories';                Tier = 'P0'; Deferred = $true; DeferReason = 'AV config APIs not found in 2026-04-23 catalogue' }
        @{ Stream = 'MDE_ControlledFolderAccess_CL';    Path = '/apiproxy/mtp/tvm/analytics/configurations/securescore/total';                     Tier = 'P0'; Deferred = $true; DeferReason = 'AV config APIs not found in 2026-04-23 catalogue' }
        @{ Stream = 'MDE_NetworkProtectionConfig_CL';   Path = '/apiproxy/mtp/tvm/analytics/configurations/securescore/categories';                Tier = 'P0'; Deferred = $true; DeferReason = 'AV config APIs not found in 2026-04-23 catalogue' }
        @{ Stream = 'MDE_DeviceControlPolicy_CL';       Path = '/apiproxy/mtp/siamApi/Onboarding';                                                 Tier = 'P0' }
        @{ Stream = 'MDE_WebContentFiltering_CL';       Path = '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'; Tier = 'P0' }
        @{ Stream = 'MDE_SmartScreenConfig_CL';         Path = '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary';            Tier = 'P0' }
        @{ Stream = 'MDE_TenantAllowBlock_CL';          Path = '/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues';            Tier = 'P0'; Deferred = $true; DeferReason = 'papin indicators filterValues returns 500; body shape unknown — 2026-04-23 audit' }
        @{ Stream = 'MDE_CustomCollection_CL';          Path = '/apiproxy/mtp/mdeCustomCollection/model';                                          Tier = 'P0'; Deferred = $true; DeferReason = 'mdeCustomCollection/model returns 403 Forbidden with service account; permission-locked — 2026-04-23 audit' }
        @{ Stream = 'MDE_LiveResponseConfig_CL';        Path = '/apiproxy/mtp/liveResponseApi/get_properties';                                     Tier = 'P0' }
        @{ Stream = 'MDE_AlertServiceConfig_CL';        Path = '/apiproxy/mtp/alertsApiService/workloads/disabled';                                Tier = 'P0' }
        @{ Stream = 'MDE_AlertTuning_CL';               Path = '/apiproxy/mtp/alertsEmailNotifications/email_notifications';                       Tier = 'P0' }
        @{ Stream = 'MDE_SuppressionRules_CL';          Path = '/apiproxy/mtp/suppressionRulesService/suppressionRules';                           Tier = 'P0'; Filter = 'fromDate' }
        @{ Stream = 'MDE_CustomDetections_CL';          Path = '/apiproxy/mtp/huntingService/rules/unified';                                       Tier = 'P0'; Filter = 'fromDate' }

        # ---- P1 Pipeline (7 streams, 30-min) ---------------------------------------
        @{ Stream = 'MDE_DataExportSettings_CL';        Path = '/apiproxy/mtp/wdatpApi/dataexportsettings';                                        Tier = 'P1' }
        @{ Stream = 'MDE_StreamingApiConfig_CL';        Path = '/apiproxy/mtp/streamingapi/streamingApiConfiguration';                             Tier = 'P1'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; needs portal experimentation — 2026-04-23 audit' }
        @{ Stream = 'MDE_IntuneConnection_CL';          Path = '/apiproxy/mtp/deviceManagement/configuration/IntuneConnection';                    Tier = 'P1'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; needs portal experimentation — 2026-04-23 audit' }
        @{ Stream = 'MDE_PurviewSharing_CL';            Path = '/apiproxy/mtp/deviceManagement/configuration/PurviewSharing';                      Tier = 'P1'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; needs portal experimentation — 2026-04-23 audit' }
        @{ Stream = 'MDE_ConnectedApps_CL';             Path = '/apiproxy/mtp/responseApiPortal/apps/all';                                         Tier = 'P1' }
        @{ Stream = 'MDE_TenantContext_CL';             Path = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true';                     Tier = 'P1' }
        @{ Stream = 'MDE_TenantWorkloadStatus_CL';      Path = '/apiproxy/mtoapi/tenants/{TenantId}/workloadStatus';  PathParams = @('TenantId');  Tier = 'P1'; Deferred = $true; DeferReason = 'requires -PathParams @{ TenantId = ... }; poller has no TenantId source yet' }

        # ---- P2 Governance (7 streams, daily) --------------------------------------
        @{ Stream = 'MDE_RbacDeviceGroups_CL';          Path = '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups';                              Tier = 'P2' }
        @{ Stream = 'MDE_UnifiedRbacRoles_CL';          Path = '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions';    Tier = 'P2' }
        @{ Stream = 'MDE_DeviceCriticality_CL';         Path = '/apiproxy/mtp/assetvalue/machineAssetValue'; Method = 'POST';                      Tier = 'P2'; Body = @{ filter = @{} }; Deferred = $true; DeferReason = 'assetvalue POST body shape unknown; nodoc has path only — 2026-04-23 audit' }
        @{ Stream = 'MDE_CriticalAssets_CL';            Path = '/apiproxy/mtp/assetvalue/setCriticalityLevel'; Method = 'POST';                    Tier = 'P2'; Body = @{ filter = @{} }; Deferred = $true; DeferReason = 'assetvalue POST body shape unknown; nodoc has path only — 2026-04-23 audit' }
        @{ Stream = 'MDE_AssetRules_CL';                Path = '/apiproxy/mtp/xspmatlas/assetrules';                                               Tier = 'P2' }
        @{ Stream = 'MDE_SAClassification_CL';          Path = '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall';           Tier = 'P2' }
        @{ Stream = 'MDE_ApprovalAssignments_CL';       Path = '/apiproxy/mtp/responseApiPortal/requests/permissions';                             Tier = 'P2'; Deferred = $true; DeferReason = 'requests/permissions returns 400; body/filter shape unknown — 2026-04-23 audit' }

        # ---- P3 Exposure (8 streams, hourly) ---------------------------------------
        @{ Stream = 'MDE_XspmAttackPaths_CL';           Path = '/apiproxy/mtp/xspm/attackpaths';      Method = 'POST';   Body = @{ filter = @{} };  Tier = 'P3'; Deferred = $true; DeferReason = 'xspm POST with empty filter body still returns 500; needs real request-body shape capture from portal — 2026-04-23 audit' }
        @{ Stream = 'MDE_XspmChokePoints_CL';           Path = '/apiproxy/mtp/xspm/chokepoints';      Method = 'POST';   Body = @{ filter = @{} };  Tier = 'P3'; Deferred = $true; DeferReason = 'xspm POST with empty filter body still returns 500; needs real request-body shape capture from portal — 2026-04-23 audit' }
        @{ Stream = 'MDE_XspmTopTargets_CL';            Path = '/apiproxy/mtp/xspm/toptargets';       Method = 'POST';   Body = @{ filter = @{} };  Tier = 'P3'; Deferred = $true; DeferReason = 'xspm POST with empty filter body still returns 500; needs real request-body shape capture from portal — 2026-04-23 audit' }
        @{ Stream = 'MDE_XspmInitiatives_CL';           Path = '/apiproxy/mtp/posture/oversight/initiatives';                                      Tier = 'P3'; Filter = 'fromDate' }
        @{ Stream = 'MDE_ExposureSnapshots_CL';         Path = '/apiproxy/mtp/posture/oversight/updates';                                          Tier = 'P3'; Filter = 'fromDate' }
        @{ Stream = 'MDE_SecureScoreBreakdown_CL';      Path = '/apiproxy/mtp/secureScore/security/secureScoresV2';                                Tier = 'P3' }
        @{ Stream = 'MDE_SecurityBaselines_CL';         Path = '/apiproxy/mtp/tvm/analytics/baseline/profiles';                                    Tier = 'P3'; Deferred = $true; DeferReason = 'tvm baseline profiles returns 400; likely needs profileId/query params — 2026-04-23 audit' }
        @{ Stream = 'MDE_ExposureRecommendations_CL';   Path = '/apiproxy/mtp/posture/oversight/recommendations';                                  Tier = 'P3' }

        # ---- P5 Identity (5 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_IdentityServiceAccounts_CL';   Path = '/apiproxy/mdi/identity/userapiservice/serviceAccounts';   Method = 'POST';          Tier = 'P5'; Body = @{ filter = @{} } }
        @{ Stream = 'MDE_IdentityOnboarding_CL';        Path = '/apiproxy/mtp/siamApi/domaincontrollers/list';                                     Tier = 'P5' }
        @{ Stream = 'MDE_DCCoverage_CL';                Path = '/apiproxy/aatp/api/sensors/domainControllerCoverage';                              Tier = 'P5'; Deferred = $true; DeferReason = 'aatp sensors domainControllerCoverage returns 404; may require MDI license/perm — 2026-04-23 audit' }
        @{ Stream = 'MDE_IdentityAlertThresholds_CL';   Path = '/apiproxy/aatp/api/alertthresholds/withExpiry';                                    Tier = 'P5'; Deferred = $true; DeferReason = 'aatp alertthresholds returns 404; may require MDI license/perm — 2026-04-23 audit' }
        @{ Stream = 'MDE_RemediationAccounts_CL';       Path = '/apiproxy/mdi/identity/identitiesapiservice/remediationAccount';                   Tier = 'P5'; Deferred = $true; DeferReason = 'mdi remediationAccount returns 404; may require MDI license/perm — 2026-04-23 audit' }

        # ---- P6 Audit/AIR (2 streams, 10-min) --------------------------------------
        @{ Stream = 'MDE_ActionCenter_CL';              Path = '/apiproxy/mtp/actionCenter/actioncenterui/history-actions'; Filter = 'fromDate';   Tier = 'P6' }
        @{ Stream = 'MDE_ThreatAnalytics_CL';           Path = '/apiproxy/mtp/threatAnalytics/outbreaks';                                          Tier = 'P6'; Filter = 'fromDate' }

        # ---- P7 Metadata (4 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_LicenseReport_CL';             Path = '/apiproxy/mtp/deviceManagement/deviceLicenseReport';                               Tier = 'P7'; Deferred = $true; DeferReason = 'nodoc path returns 404 live; needs portal experimentation — 2026-04-23 audit' }
        @{ Stream = 'MDE_UserPreferences_CL';           Path = '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference';     Tier = 'P7' }
        @{ Stream = 'MDE_MtoTenants_CL';                Path = '/apiproxy/mtoapi/tenantGroups';                                                    Tier = 'P7'; Deferred = $true; DeferReason = 'mtoapi/tenantGroups returns 400; likely needs query params or different path for single-tenant view — 2026-04-23 audit' }
        @{ Stream = 'MDE_CloudAppsConfig_CL';           Path = '/apiproxy/mcas/cas/api/v1/settings';                                               Tier = 'P7'; Deferred = $true; DeferReason = 'mcas settings endpoint returns ERR after auto-refresh; needs MCAS license/path research — 2026-04-23 audit' }
    )
}
