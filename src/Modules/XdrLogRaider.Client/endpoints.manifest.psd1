@{
    # ============================================================================
    # XdrLogRaider — Endpoint Catalogue v0.1.0-beta.1 (clean-slate consolidation)
    # ============================================================================
    # Single source of truth for every Defender XDR portal-only stream this
    # connector collects. Dispatched at runtime by Invoke-MDEEndpoint and
    # Invoke-MDETierPoll.
    #
    # Cross-checked with three research sources:
    #   - XDRInternals (github.com/MSCloudInternals/XDRInternals) — 150 paths,
    #     authoritative for POST body schemas (working PowerShell client).
    #   - nodoc (github.com/nathanmcnulty/nodoc) — 576 operations, authoritative
    #     for path + method catalogue.
    #   - DefenderHarvester (github.com/olafhartong/DefenderHarvester) — 12
    #     classic MDE endpoints with full worked examples.
    #
    # v0.1.0-beta.1 policy: every entry has path + method + body + headers
    # documented. No `Deferred` flag — a stream either ships with correct
    # wire contract, or is removed entirely (see docs/STREAMS-REMOVED.md).
    # Whether our particular test tenant's state triggers a 200 vs 4xx is
    # encoded in `Availability`, not in whether the entry ships.
    #
    # v0.1.0-beta.1 cleanup vs v1.0.2:
    #   REMOVED 2 write endpoints (would corrupt tenant data on read):
    #     MDE_CriticalAssets_CL, MDE_DeviceCriticality_CL.
    #     XDRInternals Set-XdrEndpointDevice{CriticalityLevel,AssetValue}.ps1
    #     proves these are write endpoints; no public read counterpart exists.
    #
    #   ACTIVATED 4 streams via XDRInternals-documented bodies:
    #     MDE_IdentityServiceAccounts_CL (Get-XdrIdentityServiceAccount.ps1:100-115)
    #     MDE_XspmAttackPaths_CL / XspmChokePoints / XspmTopTargets
    #       (Get-XdrXspm*.ps1 via Invoke-XdrXspmHuntingQuery.ps1:90-97)
    #
    #   METHOD-CORRECTED 2 streams (were POST with empty body → now GET):
    #     MDE_AntivirusPolicy_CL, MDE_TenantAllowBlock_CL (nodoc catalogues GET).
    #
    #   UNWRAP-PROPERTY for 2 streams that returned 200-null:
    #     MDE_CustomDetections_CL, MDE_IdentityOnboarding_CL.
    #
    # Per-entry schema:
    #   Stream         [required]  custom LA table name (e.g. 'MDE_PUAConfig_CL')
    #   Path           [required]  portal API path relative to https://security.microsoft.com
    #   Tier           [required]  'P0'|'P1'|'P2'|'P3'|'P5'|'P6'|'P7' (drives which timer polls)
    #   Method         [optional]  'GET' (default) or 'POST'
    #   Filter         [optional]  query-string param name for delta polling
    #   IdProperty     [optional]  override for Expand-MDEResponse default id lookup
    #   PathParams     [optional]  string[] of {placeholder} names in Path to substitute
    #   Body           [optional]  hashtable for POST request body
    #   Headers        [optional]  hashtable of custom HTTP headers. Values may
    #                              contain the template token '{TenantId}' which
    #                              is resolved at dispatch time from $Session.TenantId.
    #                              XSPM queries require x-tid + x-ms-scenario-name.
    #   UnwrapProperty [optional]  string name of a wrapper property to unwrap
    #                              before flattening. E.g. for {ServiceAccounts:[...]}
    #                              set UnwrapProperty='ServiceAccounts' so
    #                              Expand-MDEResponse iterates the inner array.
    #   Availability   [required]  'live' | 'tenant-gated' | 'role-gated'.
    #                              - 'live'         : returns 200 with data on a
    #                                                 Security Reader + XDR Analyst
    #                                                 account in our test tenant.
    #                              - 'tenant-gated' : returns 4xx because the tenant
    #                                                 hasn't provisioned the feature
    #                                                 (MDI sensors, MTO, Intune
    #                                                 connector, Streaming API, TVM
    #                                                 add-on, etc). Activates
    #                                                 automatically when feature
    #                                                 enabled — no code change.
    #                              - 'role-gated'   : returns 403 because the
    #                                                 service account lacks a
    #                                                 higher role. Activates with
    #                                                 role elevation.
    #
    # Counts (v0.1.0-beta.1, confirmed by live re-capture 2026-04-23):
    #   P0 = 15 streams (10 live + 4 tenant-gated + 1 role-gated)
    #   P1 = 7  streams (3 live + 4 tenant-gated)
    #   P2 = 4  streams (4 live) — 2 WRITE endpoints REMOVED
    #   P3 = 8  streams (6 live + 2 tenant-gated)
    #   P5 = 5  streams (2 live + 3 tenant-gated)
    #   P6 = 2  streams (2 live)
    #   P7 = 4  streams (1 live + 2 tenant-gated + 1 role-gated)
    #   TOTAL: 45 data streams (28 live + 15 tenant-gated + 2 role-gated)
    #
    # XspmAttackPaths demoted to tenant-gated — live-captured 400; ChokePoints
    # and TopTargets with inline KQL bodies work fine, so likely the
    # 'AttackPathsV2' string identifier is wrong for this endpoint. Needs
    # follow-up capture to confirm correct body.
    # ============================================================================

    Endpoints = @(
        # ---- P0 Compliance (15 streams, hourly) ------------------------------------
        @{ Stream = 'MDE_AdvancedFeatures_CL';          Path = '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting';                                Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_PreviewFeatures_CL';           Path = '/apiproxy/mtp/settings/GetPreviewExperienceSetting';                               Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_AlertServiceConfig_CL';        Path = '/apiproxy/mtp/alertsApiService/workloads/disabled';                                Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_AlertTuning_CL';               Path = '/apiproxy/mtp/alertsEmailNotifications/email_notifications';                       Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_SuppressionRules_CL';          Path = '/apiproxy/mtp/suppressionRulesService/suppressionRules';                           Tier = 'P0'; Filter = 'fromDate'; Availability = 'live' }
        @{ Stream = 'MDE_CustomDetections_CL';          Path = '/apiproxy/mtp/huntingService/rules/unified';                                       Tier = 'P0'; Filter = 'fromDate'; UnwrapProperty = 'Rules'; Availability = 'live' }
        @{ Stream = 'MDE_DeviceControlPolicy_CL';       Path = '/apiproxy/mtp/siamApi/Onboarding';                                                 Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_WebContentFiltering_CL';       Path = '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'; Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_SmartScreenConfig_CL';         Path = '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary';            Tier = 'P0'; Availability = 'live' }
        @{ Stream = 'MDE_LiveResponseConfig_CL';        Path = '/apiproxy/mtp/liveResponseApi/get_properties';                                     Tier = 'P0'; Availability = 'live' }

        # P0 tenant-gated — activate when feature is enabled on tenant
        @{ Stream = 'MDE_AuthenticatedTelemetry_CL';    Path = '/apiproxy/mtp/deviceManagement/configuration/AuthenticatedTelemetry';              Tier = 'P0'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_PUAConfig_CL';                 Path = '/apiproxy/mtp/deviceManagement/configuration/PotentiallyUnwantedApplications';     Tier = 'P0'; Availability = 'tenant-gated' }
        # AntivirusPolicy + TenantAllowBlock: nodoc documents GET (not POST). Phase 2c live-captures; retag live if 200.
        @{ Stream = 'MDE_AntivirusPolicy_CL';           Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters'; Tier = 'P0'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_TenantAllowBlock_CL';          Path = '/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues';            Tier = 'P0'; Availability = 'tenant-gated' }

        # P0 role-gated — activate when service account role elevated
        @{ Stream = 'MDE_CustomCollection_CL';          Path = '/apiproxy/mtp/mdeCustomCollection/model';                                          Tier = 'P0'; Availability = 'role-gated' }

        # ---- P1 Pipeline (7 streams, 30-min) ---------------------------------------
        @{ Stream = 'MDE_DataExportSettings_CL';        Path = '/apiproxy/mtp/wdatpApi/dataexportsettings';                                        Tier = 'P1'; Availability = 'live' }
        @{ Stream = 'MDE_ConnectedApps_CL';             Path = '/apiproxy/mtp/responseApiPortal/apps/all';                                         Tier = 'P1'; Availability = 'live' }
        @{ Stream = 'MDE_TenantContext_CL';             Path = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true';                     Tier = 'P1'; Availability = 'live' }

        # P1 tenant-gated
        @{ Stream = 'MDE_TenantWorkloadStatus_CL';      Path = '/apiproxy/mtoapi/tenantGroups';                                                    Tier = 'P1'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_StreamingApiConfig_CL';        Path = '/apiproxy/mtp/streamingapi/streamingApiConfiguration';                             Tier = 'P1'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_IntuneConnection_CL';          Path = '/apiproxy/mtp/deviceManagement/configuration/IntuneConnection';                    Tier = 'P1'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_PurviewSharing_CL';            Path = '/apiproxy/mtp/deviceManagement/configuration/PurviewSharing';                      Tier = 'P1'; Availability = 'tenant-gated' }

        # ---- P2 Governance (4 streams, daily) --------------------------------------
        # v0.1.0-beta.1: REMOVED MDE_CriticalAssets_CL + MDE_DeviceCriticality_CL —
        # XDRInternals confirms both are WRITE endpoints (Set-Xdr* functions);
        # calling as reads corrupts tenant data. See docs/STREAMS-REMOVED.md.
        @{ Stream = 'MDE_RbacDeviceGroups_CL';          Path = '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups';                              Tier = 'P2'; Availability = 'live' }
        @{ Stream = 'MDE_UnifiedRbacRoles_CL';          Path = '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions';    Tier = 'P2'; Availability = 'live' }
        @{ Stream = 'MDE_AssetRules_CL';                Path = '/apiproxy/mtp/xspmatlas/assetrules';                                               Tier = 'P2'; Availability = 'live' }
        @{ Stream = 'MDE_SAClassification_CL';          Path = '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall';           Tier = 'P2'; Availability = 'live' }

        # ---- P3 Exposure (8 streams, hourly) ---------------------------------------
        @{ Stream = 'MDE_XspmInitiatives_CL';           Path = '/apiproxy/mtp/posture/oversight/initiatives';                                      Tier = 'P3'; Filter = 'fromDate'; Availability = 'live' }
        @{ Stream = 'MDE_ExposureSnapshots_CL';         Path = '/apiproxy/mtp/posture/oversight/updates';                                          Tier = 'P3'; Filter = 'fromDate'; Availability = 'live' }
        @{ Stream = 'MDE_SecureScoreBreakdown_CL';      Path = '/apiproxy/mtp/secureScore/security/secureScoresV2';                                Tier = 'P3'; Availability = 'live' }
        @{ Stream = 'MDE_ExposureRecommendations_CL';   Path = '/apiproxy/mtp/posture/oversight/recommendations';                                  Tier = 'P3'; Availability = 'live' }

        # P3 XSPM — ACTIVATED via XDRInternals bodies (routed through xspmatlas hunting query endpoint)
        # Source: Get-XdrXspm*.ps1 via Invoke-XdrXspmHuntingQuery.ps1:90-97. Headers: x-tid + x-ms-scenario-name REQUIRED.
        # MDE_XspmAttackPaths_CL — XDRInternals documents the schema identifier
        # 'AttackPathsV2' as a query value, but live capture 2026-04-23 returned
        # 400 with that literal string. ChokePoints + TopTargets (below) use
        # inline KQL and return 200, so likely AttackPaths needs inline KQL too.
        # Marked tenant-gated until correct body is captured.
        @{
            Stream  = 'MDE_XspmAttackPaths_CL'
            Path    = '/apiproxy/mtp/xspmatlas/attacksurface/query'
            Method  = 'POST'
            Body    = @{
                query      = 'AttackPathsV2'
                options    = @{ top = 100; skip = 0 }
                apiVersion = 'v2'
            }
            Headers = @{
                'x-tid'              = '{TenantId}'
                'x-ms-scenario-name' = 'AttackPathOverview_get_has_attack_paths'
            }
            Tier = 'P3'
            Availability = 'tenant-gated'
        }
        @{
            Stream  = 'MDE_XspmChokePoints_CL'
            Path    = '/apiproxy/mtp/xspmatlas/attacksurface/query'
            Method  = 'POST'
            Body    = @{
                query = @'
AttackPathDiscovery
| where AttackPathsCount > 1
| extend RiskOrder = case(MaxRiskLevel == 'Critical', 0, MaxRiskLevel == 'High', 1, MaxRiskLevel == 'Medium', 2, MaxRiskLevel == 'Low', 3, 4)
| order by RiskOrder asc, AttackPathsCount desc
'@
                options    = @{ top = 100; skip = 0 }
                apiVersion = 'v2'
            }
            Headers = @{
                'x-tid'              = '{TenantId}'
                'x-ms-scenario-name' = 'ChokePoints_get_choke_point_types_filter'
            }
            Tier = 'P3'
            Availability = 'live'
        }
        @{
            Stream  = 'MDE_XspmTopTargets_CL'
            Path    = '/apiproxy/mtp/xspmatlas/attacksurface/query'
            Method  = 'POST'
            Body    = @{
                query = @'
AttackPathsV2
| where Status in ('Active', 'New')
| summarize AttackPathsCount = count(), TargetName = take_any(tostring(Target.Name)) by TargetId = tostring(Target.Id)
| top 100 by AttackPathsCount
'@
                options    = @{ top = 0; skip = 0 }
                apiVersion = 'v2'
            }
            Headers = @{
                'x-tid'              = '{TenantId}'
                'x-ms-scenario-name' = 'AttackPathOverview_get_attack_paths_top_targets'
            }
            Tier = 'P3'
            Availability = 'live'
        }

        # P3 tenant-gated — TVM licence
        @{ Stream = 'MDE_SecurityBaselines_CL';         Path = '/apiproxy/mtp/tvm/analytics/baseline/profiles';                                    Tier = 'P3'; Availability = 'tenant-gated' }

        # ---- P5 Identity (5 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_IdentityOnboarding_CL';        Path = '/apiproxy/mtp/siamApi/domaincontrollers/list';                                     Tier = 'P5'; UnwrapProperty = 'DomainControllers'; Availability = 'live' }

        # P5 IdentityServiceAccounts — ACTIVATED via XDRInternals (Get-XdrIdentityServiceAccount.ps1:100-115)
        @{
            Stream = 'MDE_IdentityServiceAccounts_CL'
            Path   = '/apiproxy/mdi/identity/userapiservice/serviceAccounts'
            Method = 'POST'
            Body   = @{
                PageSize               = 100
                Skip                   = 0
                Filters                = @{}
                IncludeAccountActivity = $true
            }
            UnwrapProperty = 'ServiceAccounts'
            Tier = 'P5'
            Availability = 'live'
        }

        # P5 tenant-gated — MDI sensors not deployed in test tenant
        @{ Stream = 'MDE_DCCoverage_CL';                Path = '/apiproxy/aatp/api/sensors/domainControllerCoverage';                              Tier = 'P5'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_IdentityAlertThresholds_CL';   Path = '/apiproxy/aatp/api/alertthresholds/withExpiry';                                    Tier = 'P5'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_RemediationAccounts_CL';       Path = '/apiproxy/mdi/identity/identitiesapiservice/remediationAccount';                   Tier = 'P5'; Availability = 'tenant-gated' }

        # ---- P6 Audit/AIR (2 streams, 10-min) --------------------------------------
        @{ Stream = 'MDE_ActionCenter_CL';              Path = '/apiproxy/mtp/actionCenter/actioncenterui/history-actions';                         Tier = 'P6'; Filter = 'fromDate'; Availability = 'live' }
        @{ Stream = 'MDE_ThreatAnalytics_CL';           Path = '/apiproxy/mtp/threatAnalytics/outbreaks';                                          Tier = 'P6'; Filter = 'fromDate'; Availability = 'live' }

        # ---- P7 Metadata (4 streams, daily) ----------------------------------------
        @{ Stream = 'MDE_UserPreferences_CL';           Path = '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference';     Tier = 'P7'; Availability = 'live' }

        # P7 tenant-gated
        @{ Stream = 'MDE_MtoTenants_CL';                Path = '/apiproxy/mtoapi/tenants/TenantPicker';                                            Tier = 'P7'; Availability = 'tenant-gated' }
        @{ Stream = 'MDE_LicenseReport_CL';             Path = '/apiproxy/mtp/deviceManagement/deviceLicenseReport';                               Tier = 'P7'; Availability = 'tenant-gated' }

        # P7 role-gated
        @{ Stream = 'MDE_CloudAppsConfig_CL';           Path = '/apiproxy/mcas/cas/api/v1/settings';                                               Tier = 'P7'; Availability = 'role-gated' }
    )
}
