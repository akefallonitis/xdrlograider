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
    # Research basis: XDRInternals, DefenderHarvester (nodoc), community research.
    # No endpoint here triggers portal actions — all are GETs.
    #
    # Per-entry schema:
    #   Stream      [required]  Log Analytics custom table name (e.g. 'MDE_PUAConfig_CL')
    #   Path        [required]  portal API path relative to https://security.microsoft.com
    #                           Fully resolved — no placeholders.
    #   Tier        [required]  'P0' | 'P1' | 'P2' | 'P3' | 'P5' | 'P6' | 'P7'
    #                           Maps to which timer function polls it.
    #                           P0 = hourly config/compliance           (poll-p0-compliance-1h)
    #                           P1 = 30-min integration/pipeline        (poll-p1-pipeline-30m)
    #                           P2 = daily governance                   (poll-p2-governance-1d)
    #                           P3 = hourly exposure                    (poll-p3-exposure-1h)
    #                           P5 = daily identity                     (poll-p5-identity-1d)
    #                           P6 = 10-min audit/AIR                   (poll-p6-audit-10m)
    #                           P7 = daily metadata/licensing           (poll-p7-metadata-1d)
    #                           (P4 reserved historically for per-incident HTTP enrichment; dropped in v1.0.)
    #   Filter      [optional]  query-string parameter name if the endpoint accepts
    #                           server-side time filtering ('fromDate' is the common
    #                           portal convention). If set, Invoke-MDEEndpoint will
    #                           pass -FromUtc as ?<Filter>=<iso8601>.
    #   IdProperty  [optional]  override for Expand-MDEResponse's default ID lookup
    #                           (falls back to @('id','name','Id','Name','ruleId','policyId')).
    # ============================================================================

    Endpoints = @(
        # ---- P0 Compliance (19 streams, hourly) ------------------------------------
        @{ Stream = 'MDE_AdvancedFeatures_CL';          Path = '/api/settings/GetAdvancedFeaturesSetting';             Tier = 'P0' }
        @{ Stream = 'MDE_PreviewFeatures_CL';           Path = '/api/settings/previewFeatures';                        Tier = 'P0' }
        @{ Stream = 'MDE_AuthenticatedTelemetry_CL';    Path = '/api/settings/authenticatedTelemetry';                 Tier = 'P0' }
        @{ Stream = 'MDE_PUAConfig_CL';                 Path = '/api/settings/puaProtection';                          Tier = 'P0' }
        @{ Stream = 'MDE_AsrRulesConfig_CL';            Path = '/api/endpoints/asr/rules';                             Tier = 'P0' }
        @{ Stream = 'MDE_AntivirusPolicy_CL';           Path = '/api/settings/antivirus/policy';                       Tier = 'P0' }
        @{ Stream = 'MDE_AntiRansomwareConfig_CL';      Path = '/api/settings/antiRansomware';                         Tier = 'P0' }
        @{ Stream = 'MDE_ControlledFolderAccess_CL';    Path = '/api/settings/controlledFolderAccess';                 Tier = 'P0' }
        @{ Stream = 'MDE_NetworkProtectionConfig_CL';   Path = '/api/settings/networkProtection';                      Tier = 'P0' }
        @{ Stream = 'MDE_DeviceControlPolicy_CL';       Path = '/api/settings/deviceControl/policy';                   Tier = 'P0' }
        @{ Stream = 'MDE_WebContentFiltering_CL';       Path = '/api/settings/webContentFiltering/policies';           Tier = 'P0' }
        @{ Stream = 'MDE_SmartScreenConfig_CL';         Path = '/api/settings/smartScreen';                            Tier = 'P0' }
        @{ Stream = 'MDE_TenantAllowBlock_CL';          Path = '/api/allowBlockList/entries';                          Tier = 'P0' }
        @{ Stream = 'MDE_CustomCollection_CL';          Path = '/api/settings/customCollectionRules';                  Tier = 'P0' }
        @{ Stream = 'MDE_LiveResponseConfig_CL';        Path = '/api/settings/liveResponse';                           Tier = 'P0' }
        @{ Stream = 'MDE_AlertServiceConfig_CL';        Path = '/api/ine/alertsapiservice/workloads/disabled';         Tier = 'P0'; Filter = 'fromDate' }
        @{ Stream = 'MDE_AlertTuning_CL';               Path = '/api/alertTuningRules';                                Tier = 'P0'; Filter = 'fromDate' }
        @{ Stream = 'MDE_SuppressionRules_CL';          Path = '/api/ine/suppressionrulesservice/suppressionRules';    Tier = 'P0' }
        @{ Stream = 'MDE_CustomDetections_CL';          Path = '/api/ine/huntingservice/rules';                        Tier = 'P0' }

        # ---- P1 Pipeline (7 streams, 30-min) ---------------------------------------
        @{ Stream = 'MDE_DataExportSettings_CL';        Path = '/api/dataexportsettings';                              Tier = 'P1' }
        @{ Stream = 'MDE_StreamingApiConfig_CL';        Path = '/api/settings/streamingApi';                           Tier = 'P1' }
        @{ Stream = 'MDE_IntuneConnection_CL';          Path = '/api/settings/integrations/intune';                    Tier = 'P1' }
        @{ Stream = 'MDE_PurviewSharing_CL';            Path = '/api/settings/integrations/purview';                   Tier = 'P1' }
        @{ Stream = 'MDE_ConnectedApps_CL';             Path = '/api/cloud/portal/apps/all';                           Tier = 'P1' }
        @{ Stream = 'MDE_TenantContext_CL';             Path = '/api/tenant/context';                                  Tier = 'P1' }
        @{ Stream = 'MDE_TenantWorkloadStatus_CL';      Path = '/api/tenant/workloadStatus';                           Tier = 'P1' }

        # ---- P2 Governance (7 streams, daily) --------------------------------------
        @{ Stream = 'MDE_RbacDeviceGroups_CL';          Path = '/rbac/machine_groups';                                 Tier = 'P2' }
        @{ Stream = 'MDE_UnifiedRbacRoles_CL';          Path = '/api/rbac/unified/roles';                              Tier = 'P2' }
        @{ Stream = 'MDE_DeviceCriticality_CL';         Path = '/api/assetManagement/devices/criticality';             Tier = 'P2' }
        @{ Stream = 'MDE_CriticalAssets_CL';            Path = '/api/criticalAssets/classifications';                  Tier = 'P2' }
        @{ Stream = 'MDE_AssetRules_CL';                Path = '/api/assetManagement/rules';                           Tier = 'P2' }
        @{ Stream = 'MDE_SAClassification_CL';          Path = '/api/identities/serviceAccountClassifications';        Tier = 'P2' }
        @{ Stream = 'MDE_ApprovalAssignments_CL';       Path = '/api/autoir/approvers';                                Tier = 'P2' }

        # ---- P3 Exposure (8 streams, hourly) ---------------------------------------
        @{ Stream = 'MDE_XspmAttackPaths_CL';           Path = '/api/xspm/attackPaths';                                Tier = 'P3' }
        @{ Stream = 'MDE_XspmChokePoints_CL';           Path = '/api/xspm/chokePoints';                                Tier = 'P3' }
        @{ Stream = 'MDE_XspmTopTargets_CL';            Path = '/api/xspm/topTargets';                                 Tier = 'P3' }
        @{ Stream = 'MDE_XspmInitiatives_CL';           Path = '/api/xspm/initiatives';                                Tier = 'P3' }
        @{ Stream = 'MDE_ExposureSnapshots_CL';         Path = '/api/xspm/exposureSnapshots';                          Tier = 'P3' }
        @{ Stream = 'MDE_SecureScoreBreakdown_CL';      Path = '/api/secureScore/breakdown';                           Tier = 'P3' }
        @{ Stream = 'MDE_SecurityBaselines_CL';         Path = '/api/settings/securityBaselines';                      Tier = 'P3' }
        @{ Stream = 'MDE_ExposureRecommendations_CL';   Path = '/api/exposure/recommendations';                        Tier = 'P3' }

        # ---- P5 Identity (5 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_IdentityServiceAccounts_CL';   Path = '/api/identities/serviceAccounts';                      Tier = 'P5' }
        @{ Stream = 'MDE_IdentityOnboarding_CL';        Path = '/api/identities/onboardingStatus';                     Tier = 'P5' }
        @{ Stream = 'MDE_DCCoverage_CL';                Path = '/api/identities/domainControllerCoverage';             Tier = 'P5' }
        @{ Stream = 'MDE_IdentityAlertThresholds_CL';   Path = '/api/identities/alertThresholds';                      Tier = 'P5' }
        @{ Stream = 'MDE_RemediationAccounts_CL';       Path = '/api/identities/remediationActionAccounts';            Tier = 'P5' }

        # ---- P6 Audit/AIR (2 streams, 10-min) --------------------------------------
        @{ Stream = 'MDE_ActionCenter_CL';              Path = '/api/autoir/actioncenterui/history-actions';           Tier = 'P6'; Filter = 'fromDate' }
        @{ Stream = 'MDE_ThreatAnalytics_CL';           Path = '/api/threatAnalytics/outbreaks';                       Tier = 'P6' }

        # ---- P7 Metadata (4 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_LicenseReport_CL';             Path = '/api/licensing/report';                                Tier = 'P7' }
        @{ Stream = 'MDE_UserPreferences_CL';           Path = '/api/userPreferences';                                 Tier = 'P7' }
        @{ Stream = 'MDE_MtoTenants_CL';                Path = '/api/mto/tenants';                                     Tier = 'P7' }
        @{ Stream = 'MDE_CloudAppsConfig_CL';           Path = '/api/cloudApps/generalSettings';                       Tier = 'P7' }
    )
}
