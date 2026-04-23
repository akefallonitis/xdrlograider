@{
    # ============================================================================
    # XdrLogRaider — Endpoint Catalogue v1.0.2 (2026-04-23 evidence-based cleanup)
    # ============================================================================
    # Single source of truth for every Defender XDR portal-only stream this
    # connector collects. Dispatched at runtime by Invoke-MDEEndpoint and
    # Invoke-MDETierPoll.
    #
    # Live-verified 2026-04-23 against security.microsoft.com + cross-checked with:
    #   - nodoc (github.com/nathanmcnulty/nodoc) — 576 portal operations
    #   - XDRInternals (github.com/MSCloudInternals/XDRInternals) — 150 paths
    #   - DefenderHarvester (github.com/olafhartong/DefenderHarvester) — 12 legacy
    #
    # v1.0.2 cleanup (vs v1.0.1):
    #   - REMOVED 5 streams whose paths were unverified placeholders in v1.0.1
    #     and have no public portal API per any research source:
    #       MDE_AsrRulesConfig_CL, MDE_AntiRansomwareConfig_CL,
    #       MDE_ControlledFolderAccess_CL, MDE_NetworkProtectionConfig_CL,
    #       MDE_ApprovalAssignments_CL.
    #     These features are only accessible via Intune / Graph deviceManagement
    #     APIs — a scope we deliberately don't cover (see docs/ARCHITECTURE.md).
    #   - FIXED 2 WRONG_PATH streams to correct NDR endpoints per XDRInternals
    #     research (MDE_CriticalAssets_CL, MDE_DeviceCriticality_CL).
    #   - RE-DEFERRED 3 streams per live audit 2026-04-23:
    #       MDE_TenantWorkloadStatus_CL (400 — MTO not configured)
    #       MDE_IdentityServiceAccounts_CL (415 — POST body/content-type unknown)
    #       MDE_MtoTenants_CL (400 — MTO tenant picker not applicable to single-tenant)
    #
    # Result for a Security Reader + Defender XDR Analyst service account:
    #   25 ACTIVE    — live-captured 200 with real data in tests/fixtures/live-responses
    #   22 DEFERRED  — each has a specific, evidence-backed DeferReason:
    #     * FEATURE_NOT_ENABLED: path correct per research, 404 live because
    #       tenant hasn't licensed/provisioned the feature (MDI sensors, Intune
    #       connector, Purview integration, MDCA streaming, TVM add-on, PUA
    #       protection, authenticated telemetry, Defender for Business SKU).
    #       → Activates automatically per-tenant when feature enabled.
    #     * POST_BODY_UNKNOWN: path + method (POST) correct, body filter schema
    #       not documented in any public source. Needs operator HAR capture from
    #       browser session → v1.1 research.
    #     * NEEDS_HIGHER_PRIV: Security Reader + Defender XDR Analyst insufficient;
    #       endpoint requires Defender Admin or MCAS-specific role. Operator
    #       decision whether to elevate.
    #
    # Per-entry schema:
    #   Stream      [required]  custom LA table name (e.g. 'MDE_PUAConfig_CL')
    #   Path        [required]  portal API path relative to https://security.microsoft.com
    #   Tier        [required]  'P0'|'P1'|'P2'|'P3'|'P5'|'P6'|'P7' (drives which timer polls)
    #   Method      [optional]  'GET' (default) or 'POST'
    #   Filter      [optional]  query-string param name for delta polling
    #   IdProperty  [optional]  override for Expand-MDEResponse default id lookup
    #   PathParams  [optional]  string[] of {placeholder} names in Path to substitute
    #   Body        [optional]  hashtable for POST request body
    #   Deferred    [optional]  $true skips the entry in tier poller (unless -IncludeDeferred)
    #   DeferReason [optional]  MACHINE-READABLE tag: FEATURE_NOT_ENABLED |
    #                           POST_BODY_UNKNOWN | NEEDS_HIGHER_PRIV
    #                           + " - <human explanation>" suffix.
    #
    # Counts (v1.0.2 — live audit 2026-04-23):
    #   P0 = 15 (10 active + 5 deferred)
    #   P1 = 7  (3 active + 4 deferred)  ← MDE_TenantWorkloadStatus_CL re-deferred
    #   P2 = 6  (4 active + 2 deferred)
    #   P3 = 8  (4 active + 4 deferred)
    #   P5 = 5  (1 active + 4 deferred)  ← MDE_IdentityServiceAccounts_CL re-deferred
    #   P6 = 2  (2 active + 0 deferred)
    #   P7 = 4  (1 active + 3 deferred)  ← MDE_MtoTenants_CL re-deferred
    #   TOTAL: 47 data streams (25 active + 22 deferred)
    # ============================================================================

    Endpoints = @(
        # ---- P0 Compliance (15 streams, hourly) ------------------------------------
        # 10 ACTIVE + 5 DEFERRED
        @{ Stream = 'MDE_AdvancedFeatures_CL';          Path = '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting';                                Tier = 'P0' }
        @{ Stream = 'MDE_PreviewFeatures_CL';           Path = '/apiproxy/mtp/settings/GetPreviewExperienceSetting';                               Tier = 'P0' }
        @{ Stream = 'MDE_AlertServiceConfig_CL';        Path = '/apiproxy/mtp/alertsApiService/workloads/disabled';                                Tier = 'P0' }
        @{ Stream = 'MDE_AlertTuning_CL';               Path = '/apiproxy/mtp/alertsEmailNotifications/email_notifications';                       Tier = 'P0' }
        @{ Stream = 'MDE_SuppressionRules_CL';          Path = '/apiproxy/mtp/suppressionRulesService/suppressionRules';                           Tier = 'P0'; Filter = 'fromDate' }
        @{ Stream = 'MDE_CustomDetections_CL';          Path = '/apiproxy/mtp/huntingService/rules/unified';                                       Tier = 'P0'; Filter = 'fromDate' }
        @{ Stream = 'MDE_DeviceControlPolicy_CL';       Path = '/apiproxy/mtp/siamApi/Onboarding';                                                 Tier = 'P0' }
        @{ Stream = 'MDE_WebContentFiltering_CL';       Path = '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'; Tier = 'P0' }
        @{ Stream = 'MDE_SmartScreenConfig_CL';         Path = '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary';            Tier = 'P0' }
        @{ Stream = 'MDE_LiveResponseConfig_CL';        Path = '/apiproxy/mtp/liveResponseApi/get_properties';                                     Tier = 'P0' }

        # Deferred P0 — path correct but tenant hasn't enabled the feature
        @{ Stream = 'MDE_AuthenticatedTelemetry_CL';    Path = '/apiproxy/mtp/deviceManagement/configuration/AuthenticatedTelemetry';              Tier = 'P0'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - path valid per nodoc; 404 live because tenant has not provisioned MDE authenticated telemetry.' }
        @{ Stream = 'MDE_PUAConfig_CL';                 Path = '/apiproxy/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications';     Tier = 'P0'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - path valid per nodoc; 404 live, tenant-side PUA protection not configured.' }

        # Deferred P0 — POST body schema unknown
        @{ Stream = 'MDE_AntivirusPolicy_CL';           Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters'; Tier = 'P0'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - path in nodoc line 526; 400 with empty body; body schema needed via HAR capture from MEM security policies page.' }
        @{ Stream = 'MDE_TenantAllowBlock_CL';          Path = '/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues';            Tier = 'P0'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - path in nodoc line 394; 500 with empty body; filter schema needed via HAR from Indicators page.' }

        # Deferred P0 — needs privilege elevation
        @{ Stream = 'MDE_CustomCollection_CL';          Path = '/apiproxy/mtp/mdeCustomCollection/model';                                          Tier = 'P0'; Deferred = $true; DeferReason = 'NEEDS_HIGHER_PRIV - 403 Forbidden as Security Reader; requires Defender XDR Operator role.' }

        # ---- P1 Pipeline (7 streams, 30-min) ---------------------------------------
        # 3 ACTIVE + 4 DEFERRED (live audit 2026-04-23: MTO tenantGroups returns 400 on single-tenant)
        @{ Stream = 'MDE_DataExportSettings_CL';        Path = '/apiproxy/mtp/wdatpApi/dataexportsettings';                                        Tier = 'P1' }
        @{ Stream = 'MDE_ConnectedApps_CL';             Path = '/apiproxy/mtp/responseApiPortal/apps/all';                                         Tier = 'P1' }
        @{ Stream = 'MDE_TenantContext_CL';             Path = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true';                     Tier = 'P1' }

        # Deferred P1 — tenant feature
        @{ Stream = 'MDE_TenantWorkloadStatus_CL';      Path = '/apiproxy/mtoapi/tenantGroups';                                                    Tier = 'P1'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MTO (Multi-Tenant Organization) not configured; live audit 2026-04-23 returned 400. Endpoint lights up only when tenant is enrolled in an MTO.' }
        @{ Stream = 'MDE_StreamingApiConfig_CL';        Path = '/apiproxy/mtp/streamingapi/streamingApiConfiguration';                             Tier = 'P1'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - streaming API not configured on tenant (no Event Hub/Storage destination).' }
        @{ Stream = 'MDE_IntuneConnection_CL';          Path = '/apiproxy/mtp/deviceManagement/configuration/IntuneConnection';                    Tier = 'P1'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MDE-Intune connection not set up in tenant.' }
        @{ Stream = 'MDE_PurviewSharing_CL';            Path = '/apiproxy/mtp/deviceManagement/configuration/PurviewSharing';                      Tier = 'P1'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - Purview integration not configured.' }

        # ---- P2 Governance (6 streams, daily) --------------------------------------
        # 4 ACTIVE + 2 DEFERRED
        @{ Stream = 'MDE_RbacDeviceGroups_CL';          Path = '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups';                              Tier = 'P2' }
        @{ Stream = 'MDE_UnifiedRbacRoles_CL';          Path = '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions';    Tier = 'P2' }
        @{ Stream = 'MDE_AssetRules_CL';                Path = '/apiproxy/mtp/xspmatlas/assetrules';                                               Tier = 'P2' }
        @{ Stream = 'MDE_SAClassification_CL';          Path = '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall';           Tier = 'P2' }

        # Deferred P2 — paths fixed to NDR endpoints per XDRInternals lines 68-69, but POST body schema still unknown
        @{ Stream = 'MDE_DeviceCriticality_CL';         Path = '/apiproxy/mtp/ndr/machines/assetValues'; Method = 'POST';                          Tier = 'P2'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - v1.0.2 fixed path to NDR endpoint (was /assetvalue/machineAssetValue); body shape likely {machineIds:[...]}; needs HAR verification.' }
        @{ Stream = 'MDE_CriticalAssets_CL';            Path = '/apiproxy/mtp/ndr/machines/criticalityLevel'; Method = 'POST';                     Tier = 'P2'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - v1.0.2 fixed path to NDR endpoint (was /assetvalue/setCriticalityLevel); body shape needs HAR from Asset Criticality page.' }

        # ---- P3 Exposure (8 streams, hourly) ---------------------------------------
        # 4 ACTIVE + 4 DEFERRED
        @{ Stream = 'MDE_XspmInitiatives_CL';           Path = '/apiproxy/mtp/posture/oversight/initiatives';                                      Tier = 'P3'; Filter = 'fromDate' }
        @{ Stream = 'MDE_ExposureSnapshots_CL';         Path = '/apiproxy/mtp/posture/oversight/updates';                                          Tier = 'P3'; Filter = 'fromDate' }
        @{ Stream = 'MDE_SecureScoreBreakdown_CL';      Path = '/apiproxy/mtp/secureScore/security/secureScoresV2';                                Tier = 'P3' }
        @{ Stream = 'MDE_ExposureRecommendations_CL';   Path = '/apiproxy/mtp/posture/oversight/recommendations';                                  Tier = 'P3' }

        # Deferred P3 — XSPM POST endpoints
        @{ Stream = 'MDE_XspmAttackPaths_CL';           Path = '/apiproxy/mtp/xspm/attackpaths';      Method = 'POST';                             Tier = 'P3'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - XSPM attack-paths POST (nodoc line 546); filter body schema needs HAR capture from Attack Surface Map page.' }
        @{ Stream = 'MDE_XspmChokePoints_CL';           Path = '/apiproxy/mtp/xspm/chokepoints';      Method = 'POST';                             Tier = 'P3'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - XSPM choke-points POST (nodoc line 547); body schema needs HAR.' }
        @{ Stream = 'MDE_XspmTopTargets_CL';            Path = '/apiproxy/mtp/xspm/toptargets';       Method = 'POST';                             Tier = 'P3'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - XSPM top-targets POST (nodoc line 550); body schema needs HAR.' }

        # Deferred P3 — TVM licence
        @{ Stream = 'MDE_SecurityBaselines_CL';         Path = '/apiproxy/mtp/tvm/analytics/baseline/profiles';                                    Tier = 'P3'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - TVM baselines require Defender Vulnerability Management add-on licence.' }

        # ---- P5 Identity (5 streams, daily) ----------------------------------------
        # 1 ACTIVE + 4 DEFERRED (MDI-dependent streams + IdentityServiceAccounts POST body unknown)
        @{ Stream = 'MDE_IdentityOnboarding_CL';        Path = '/apiproxy/mtp/siamApi/domaincontrollers/list';                                     Tier = 'P5' }

        # Deferred P5 — MDI sensors not deployed in test tenant / POST body unknown
        @{ Stream = 'MDE_IdentityServiceAccounts_CL';   Path = '/apiproxy/mdi/identity/userapiservice/serviceAccounts';   Method = 'POST';          Tier = 'P5'; Deferred = $true; DeferReason = 'POST_BODY_UNKNOWN - live audit 2026-04-23 returned 415 Unsupported Media Type. Endpoint requires specific body + Content-Type; needs HAR from MDI Service Accounts page.' }
        @{ Stream = 'MDE_DCCoverage_CL';                Path = '/apiproxy/aatp/api/sensors/domainControllerCoverage';                              Tier = 'P5'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MDI domain-controller coverage; requires MDI (Defender for Identity) sensor deployment on DCs.' }
        @{ Stream = 'MDE_IdentityAlertThresholds_CL';   Path = '/apiproxy/aatp/api/alertthresholds/withExpiry';                                    Tier = 'P5'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MDI alert thresholds; requires MDI deployment.' }
        @{ Stream = 'MDE_RemediationAccounts_CL';       Path = '/apiproxy/mdi/identity/identitiesapiservice/remediationAccount';                   Tier = 'P5'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MDI remediation accounts; requires MDI deployment.' }

        # ---- P6 Audit/AIR (2 streams, 10-min) --------------------------------------
        # 2 ACTIVE
        @{ Stream = 'MDE_ActionCenter_CL';              Path = '/apiproxy/mtp/actionCenter/actioncenterui/history-actions'; Filter = 'fromDate';   Tier = 'P6' }
        @{ Stream = 'MDE_ThreatAnalytics_CL';           Path = '/apiproxy/mtp/threatAnalytics/outbreaks';                                          Tier = 'P6'; Filter = 'fromDate' }

        # ---- P7 Metadata (4 streams, daily) ----------------------------------------
        # 1 ACTIVE + 3 DEFERRED
        @{ Stream = 'MDE_UserPreferences_CL';           Path = '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference';     Tier = 'P7' }

        # Deferred P7 — licence / privilege / MTO feature
        @{ Stream = 'MDE_MtoTenants_CL';                Path = '/apiproxy/mtoapi/tenants/TenantPicker';                                            Tier = 'P7'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - MTO tenant picker requires multi-tenant organization; live audit 2026-04-23 returned 400 on single-tenant.' }
        @{ Stream = 'MDE_LicenseReport_CL';             Path = '/apiproxy/mtp/deviceManagement/deviceLicenseReport';                               Tier = 'P7'; Deferred = $true; DeferReason = 'FEATURE_NOT_ENABLED - licence reporting requires Defender for Business / EDR for Business SKU.' }
        @{ Stream = 'MDE_CloudAppsConfig_CL';           Path = '/apiproxy/mcas/cas/api/v1/settings';                                               Tier = 'P7'; Deferred = $true; DeferReason = 'NEEDS_HIGHER_PRIV - MCAS settings require Defender for Cloud Apps licence + MCAS Administrator role.' }
    )
}
