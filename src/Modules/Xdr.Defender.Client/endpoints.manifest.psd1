@{
    # ============================================================================
    # XdrLogRaider — Endpoint Catalogue
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
    # Per-entry MANDATORY:
    #     Stream         custom LA table name (e.g. 'MDE_PUAConfig_CL')
    #     Path           portal API path relative to https://<Portal>
    #     Tier           capability-themed label that drives polling frequency
    #                    (per directive 12 + Phase B.3 — operator-meaningful):
    #                      'ActionCenter'  — every 10 min (Action Center events)
    #                      'XspmGraph'     — hourly (XSPM + ExposureSnapshots)
    #                      'Configuration' — every 6 hours (rules / policies / RBAC)
    #                      'Inventory'     — daily (settings / identity / metadata)
    #                      'Maintenance'   — weekly (rare-change long-tail)
    #     Category       nathanmcnulty 10-category functional taxonomy:
    #                      'Endpoint Device Management'
    #                      'Endpoint Configuration'
    #                      'Vulnerability Management (TVM)'
    #                      'Identity Protection (MDI)'
    #                      'Configuration and Settings'
    #                      'Exposure Management (XSPM)'
    #                      'Threat Analytics'
    #                      'Action Center'
    #                      'Multi-Tenant Operations'
    #                      'Streaming API'
    #     Purpose        operator-facing one-line description
    #     Availability   'live' | 'tenant-gated' | 'deprecated'
    #
    #   Per-entry OPTIONAL (defaults via Defaults block + Get-MDEEndpointManifest):
    #     Method            'GET' (default) or 'POST'
    #     Filter            query-string param name for delta polling
    #     IdProperty        string[] — per-entry override of Expand-MDEResponse's
    #                       default ID-extraction list. E.g. ActionCenter rows
    #                       carry ActionId not id, so IdProperty = @('ActionId').
    #     PathParams        string[] of {placeholder} names in Path to substitute
    #     Body              hashtable for POST request body
    #     Headers           hashtable of custom HTTP headers. Values may contain
    #                       the template token '{TenantId}' which is resolved at
    #                       dispatch time from $Session.TenantId. XSPM queries
    #                       require x-tid + x-ms-scenario-name.
    #     UnwrapProperty    string — wrapper-property name to unwrap before
    #                       array iteration. E.g. for {Results:[…], Count:N}
    #                       responses set UnwrapProperty='Results' so
    #                       Expand-MDEResponse iterates the inner array instead
    #                       of treating Results + Count as wrapper-key entities.
    #     SingleObjectAsRow bool — when $true and the response is a single
    #                       object (not array, not wrapper, not scalar), force
    #                       it into a 1-element array so Shape 1 emits ONE
    #                       per-entity row instead of Shape 3 flattening it
    #                       to N per-property rows. Use for endpoints whose
    #                       response is a single configuration object that
    #                       should be one operator-friendly row (e.g.
    #                       MDE_TenantContext_CL, MDE_ConnectedApps_CL,
    #                       MDE_UserPreferences_CL). iter-14.0 Phase 1 add.
    #     Portal            override Defaults.Portal (v0.2.0+ multi-portal entries
    #                       set this to compliance.microsoft.com / intune.microsoft.com / etc).
    #     MFAMethodsSupported  string[] — defaults to @('CredentialsTotp','Passkey').
    #                       v0.2.0+ portals that don't support a method narrow this.
    #     AuditScope        'portal-only' (default) | 'hybrid' | 'public-api-covered'.
    #                       'portal-only' = no public API exposes equivalent data
    #                                       (the connector's raison d'être).
    #                       'hybrid'      = public API covers SOME fields; portal
    #                                       exposes additional operator-valuable
    #                                       data not in public surface. Documented
    #                                       in entry's per-entry comment.
    #                       'public-api-covered' = public API covers it fully —
    #                                              entry MUST NOT be in this manifest
    #                                              (test gate enforces); operators
    #                                              should use the official Sentinel
    #                                              data connector instead.
    #     ProjectionMap     hashtable — Phase 4 typed-column ingest map. Keys are
    #                       target column names, values are JSONPath expressions
    #                       (or type-cast hints like '$todatetime:CreatedTime').
    #                       Defaults to empty in Phase 2; populated per-stream in
    #                       Phase 4 with sensible per-Category column conventions.
    #
    # Portal-only-vs-public-API audit notes:
    #   DROPPED 1 stream: MDE_SecureScoreBreakdown_CL (Graph /security/secureScores
    #     covers the same data with the same shape).
    #   HYBRID flag (3 streams): MDE_RbacDeviceGroups_CL, MDE_LicenseReport_CL,
    #     MDE_DataExportSettings_CL. Each entry's per-entry comment documents
    #     the public-API delta + why we keep the portal version.
    #
    # Per-tier breakdown (capability-themed names per Phase B; counts verified
    # 2026-05-04 audit — corrected from prior off-by-one in inventory count):
    #   ActionCenter  =  2 streams (Action Center events, every 10 min)
    #   XspmGraph     =  7 streams (XSPM graph + Exposure snapshots, hourly)
    #   Configuration = 14 streams (alert/detect rules + RBAC + integrations, every 6h)
    #   Inventory     = 20 streams (device + identity + metadata long-tail, daily)
    #   Maintenance   =  2 streams (DataExport active + StreamingApi deprecated, weekly)
    #   TOTAL         = 45 entries (44 active + 1 deprecated)
    # ============================================================================

    Defaults = @{
        Portal              = 'security.microsoft.com'
        SchemaSource        = 'live-capture'   # Default per directive 15 (Phase E); per-stream override in v0.1.1 for nodoc-spec / XDRInternals-cmdlet / inferred classifications
        MFAMethodsSupported = @('CredentialsTotp', 'Passkey')
        AuditScope          = 'portal-only'
        IdProperty          = $null  # falls back to Expand-MDEResponse default heuristic list
        ProjectionMap       = @{}    # populated per-stream in Phase 4
    }

    Endpoints = @(
        # ---- Endpoint catalogue — Tier values are: fast | exposure | config | inventory | maintenance.
        @{
            Stream = 'MDE_AdvancedFeatures_CL'
            Path = '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant-wide MDE feature toggles (Tamper Protection, EDR-block, Web Content Filtering, etc.)'
            Availability = 'live'
            # Property-bag stream: response is { FeatureName1: bool, FeatureName2: bool, ... }
            # with 30+ properties. Each property name → one row via Shape 3 flattening.
            # iter-14.0 Phase 1: ProjectionMap follows the property-bag convention
            # FeatureName + IsEnabled (per-property declarations cannot resolve under
            # Shape 3 because the per-row entity is the property VALUE — a scalar bool —
            # not an object with named fields).
            # Legacy cols (EnableWdavAntiTampering/AatpIntegrationEnabled/etc) declared
            # back-compat for additive-only schema (ARM rejects col drops); they project
            # from fields that don't exist on the per-row scalar entity → always null.
            # Operators should query IsEnabled going forward.
            ProjectionMap = @{
                FeatureName = '$tostring:EntityId'   # property name (synthesized in projContext)
                IsEnabled   = '$tobool:value'        # property value
                # Legacy back-compat (always null with corrected Shape 3 handling):
                EnableWdavAntiTampering       = '$tobool:EnableWdavAntiTampering'
                AatpIntegrationEnabled        = '$tobool:AatpIntegrationEnabled'
                EnableMcasIntegration         = '$tobool:EnableMcasIntegration'
                AutoResolveInvestigatedAlerts = '$tobool:AutoResolveInvestigatedAlerts'
            }
        }
        # iter-13.9 (B4): query-string drift fix per XDRInternals canonical source
        # — Get-XdrConfigurationPreviewFeatures.ps1 uses ?context=MdatpContext.
        @{
            Stream = 'MDE_PreviewFeatures_CL'
            Path = '/apiproxy/mtp/settings/GetPreviewExperienceSetting?context=MdatpContext'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Preview-ring enrolment for tenant-wide MDE features (gradual rollout state)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { IsOptIn: false, SliceId: 100 }
            # Single object with mixed-type properties → Shape 3 flatten yields 2 rows
            # (EntityId='IsOptIn'+value=false, EntityId='SliceId'+value=100).
            # iter-14.0 Phase 1: FeatureName + Value convention; Value as string is
            # universal (operators parse if numeric). Legacy cols preserved as
            # back-compat (always null with corrected Shape 3 handling).
            ProjectionMap = @{
                FeatureName = '$tostring:EntityId'
                Value       = '$tostring:value'
                # Legacy back-compat (always null):
                SettingId = '$tostring:EntityId'  # alias of FeatureName for back-compat
                IsOptIn   = '$tobool:IsOptIn'
                SliceId   = '$toint:SliceId'
            }
        }
        # iter-13.9 (B4): ?includeDetails=true per Get-XdrConfigurationAlertServiceSetting.ps1
        @{
            Stream = 'MDE_AlertServiceConfig_CL'
            Path = '/apiproxy/mtp/alertsApiService/workloads/disabled?includeDetails=true'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-workload alert-source enable/disable matrix (which detection sources fire alerts)'
            Availability = 'live'
            # Fixture: empty object (live response). Per-Category convention.
            ProjectionMap = @{
                WorkloadId      = '$tostring:WorkloadId'
                Name            = '$tostring:Name'
                IsEnabled       = '$tobool:IsEnabled'
                LastModifiedUtc = '$todatetime:LastModifiedUtc'
                ModifiedBy      = '$tostring:ModifiedBy'
            }
        }
        # iter-13.9 (B3): nodoc-cited path — XDRInternals has no Get-Xdr*AlertTuning cmdlet.
        # iter-14.0 Phase 4 (v0.1.0 GA): added UnwrapProperty='items' per fixture shape.
        @{
            Stream = 'MDE_AlertTuning_CL'
            Path = '/apiproxy/mtp/alertsEmailNotifications/email_notifications'
            Tier = 'Configuration'
            UnwrapProperty = 'items'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Email-notification rules for alerts (recipients, severity filters, delivery cadence)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { items: [] } — empty in
            # test tenant; per-row entity (when populated) carries email-rule fields.
            # Convention based on email-notification rule shape.
            ProjectionMap = @{
                RuleId       = '$tostring:RuleId'
                Name         = '$tostring:Name'
                IsEnabled    = '$tobool:IsEnabled'
                CreatedTime  = '$todatetime:CreatedTime'
                CreatedBy    = '$tostring:CreatedBy'
                Severity     = '$tostring:NotificationType'
            }
        }
        @{
            Stream = 'MDE_SuppressionRules_CL'
            Path = '/apiproxy/mtp/suppressionRulesService/suppressionRules'
            Tier = 'Configuration'
            Filter = 'fromDate'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Operator-defined alert suppression rules (which alerts are deliberately silenced + scope)'
            Availability = 'live'
            # Fixture: array of rule objects with Id/RuleTitle/CreatedBy/CreationTime/IsEnabled/Scope/Action/RuleType/MatchingAlertsCount.
            ProjectionMap = @{
                RuleId              = '$tostring:Id'
                Name                = '$tostring:RuleTitle'
                IsEnabled           = '$tobool:IsEnabled'
                CreatedTime         = '$todatetime:CreationTime'
                CreatedBy           = '$tostring:CreatedBy'
                Scope               = '$toint:Scope'
                Action              = '$toint:Action'
                AlertTitle          = '$tostring:AlertTitle'
                MatchingAlertsCount = '$toint:MatchingAlertsCount'
                IsReadOnly          = '$tobool:IsReadOnly'
                UpdateTime          = '$todatetime:UpdateTime'
            }
        }
        # iter-13.9 (B4): pagination + unified-rules-list flag per XDRInternals
        # Get-XdrAdvancedHuntingUnifiedDetectionRules.ps1 — without pageSize=10000
        # the response is truncated to the default-page count.
        @{
            Stream = 'MDE_CustomDetections_CL'
            Path = '/apiproxy/mtp/huntingService/rules/unified?pageIndex=1&pageSize=10000&sortOrder=Ascending&isUnifiedRulesListEnabled=true'
            Tier = 'Configuration'
            Filter = 'fromDate'
            UnwrapProperty = 'Rules'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant-defined custom detection rules (KQL-driven scheduled hunts that mint alerts)'
            Availability = 'live'
            # Fixture: empty (no rules in test tenant). Convention from unified-detections shape.
            ProjectionMap = @{
                RuleId           = '$tostring:Id'
                Name             = '$tostring:DisplayName'
                IsEnabled        = '$tobool:IsEnabled'
                CreatedTime      = '$todatetime:CreationTime'
                CreatedBy        = '$tostring:CreatedBy'
                Severity         = '$tostring:Severity'
                LastRunStatus    = '$tostring:LastRunStatus'
                LastModifiedUtc  = '$todatetime:LastModifiedTime'
            }
        }
        @{
            Stream = 'MDE_DeviceControlPolicy_CL'
            Path = '/apiproxy/mtp/siamApi/Onboarding'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Device-control + onboarding-package configuration (USB/printer/disk policies)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { onboarded: 0, notOnboarded: 0, hasPermissions: true }
            # Property-bag with mixed types (int + bool) → Shape 3 flatten.
            # iter-14.0 Phase 1: FeatureName + Value (string, universal). Legacy
            # cols preserved as back-compat (always null with corrected handling).
            ProjectionMap = @{
                FeatureName    = '$tostring:EntityId'
                Value          = '$tostring:value'
                # Legacy back-compat (always null):
                Onboarded      = '$toint:onboarded'
                NotOnboarded   = '$toint:notOnboarded'
                HasPermissions = '$tobool:hasPermissions'
            }
        }
        @{
            Stream = 'MDE_WebContentFiltering_CL'
            Path = '/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'
            Tier = 'Inventory'
            UnwrapProperty = 'TopParentCategories'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Web Content Filtering policy state + top blocked-category report'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { UpdateTime: <iso>, TopParentCategories: [{ Name, ActivityDeltaPercentage,
            #   IsDeltaPercentageValid, TotalAccessRequests, TotalBlockedCount }, ...] }
            # iter-14.0 Phase 1: UnwrapProperty='TopParentCategories' so each
            # category is a per-entity row (Shape 1). UpdateTime is a wrapper-level
            # field — lost on unwrap; row's TimeGenerated suffices.
            # Legacy cols (FeatureName/UpdateTime) preserved as back-compat.
            ProjectionMap = @{
                CategoryName            = '$tostring:Name'
                ActivityDeltaPercentage = '$toint:ActivityDeltaPercentage'
                IsDeltaPercentageValid  = '$tobool:IsDeltaPercentageValid'
                TotalAccessRequests     = '$tolong:TotalAccessRequests'
                TotalBlockedCount       = '$tolong:TotalBlockedCount'
                # Legacy back-compat (post-unwrap entity has no FeatureName/UpdateTime):
                FeatureName             = '$tostring:Name'  # alias of CategoryName
                UpdateTime              = '$todatetime:UpdateTime'
            }
        }
        @{
            Stream = 'MDE_SmartScreenConfig_CL'
            Path = '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Microsoft Defender SmartScreen aggregated web-threat report (impressions + block actions)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { TotalThreats:0, Phishing:0, Malicious:0, ..., UpdateTime: <iso> }
            # Property-bag of int counters + 1 datetime → Shape 3 flatten yields
            # 10 rows (one per counter + UpdateTime row). iter-14.0 Phase 1:
            # FeatureName + Value (string, universal — operator parses int if needed).
            # Legacy per-counter cols preserved as back-compat (always null).
            ProjectionMap = @{
                FeatureName     = '$tostring:EntityId'
                Value           = '$tostring:value'
                # Legacy back-compat (always null with corrected Shape 3 handling):
                TotalThreats    = '$toint:TotalThreats'
                Phishing        = '$toint:Phishing'
                Malicious       = '$toint:Malicious'
                CustomIndicator = '$toint:CustomIndicator'
                Exploit         = '$toint:Exploit'
                LastModifiedUtc = '$todatetime:UpdateTime'
            }
        }
        # iter-13.9 (B4): ?useV2Api=true&useV3Api=true per Get-XdrEndpointConfigurationLiveResponse.ps1
        @{
            Stream = 'MDE_LiveResponseConfig_CL'
            Path = '/apiproxy/mtp/liveResponseApi/get_properties?useV2Api=true&useV3Api=true'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Live Response service properties + script-library config + tab-completion enablement'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { AutomatedIrLiveResponse: true, AutomatedIrUnsignedScripts: true, LiveResponseForServers: true }
            # Pure-bool property-bag → Shape 3 flatten yields 3 rows.
            # iter-14.0 Phase 1: FeatureName + IsEnabled.
            # Legacy per-property cols preserved as back-compat (always null).
            ProjectionMap = @{
                FeatureName                = '$tostring:EntityId'
                IsEnabled                  = '$tobool:value'
                # Legacy back-compat (always null with corrected Shape 3 handling):
                AutomatedIrLiveResponse    = '$tobool:AutomatedIrLiveResponse'
                AutomatedIrUnsignedScripts = '$tobool:AutomatedIrUnsignedScripts'
                LiveResponseForServers     = '$tobool:LiveResponseForServers'
            }
        }

        # P0 tenant-gated — paths corrected 2026-04-24 vs XDRInternals v1.0.3.
        @{
            Stream = 'MDE_AuthenticatedTelemetry_CL'
            Path = '/apiproxy/mtp/responseApiPortal/senseauth/allownonauthsense'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Sense-auth posture (whether unauthenticated telemetry from Sense agent is accepted)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): scalar bool `true`.
            # Shape 4 → ONE row with EntityId='value', value=<bool>.
            # iter-14.0 Phase 1: AllowNonAuthSense was redundant duplicate of IsEnabled
            # — preserved as back-compat alias.
            ProjectionMap = @{
                FeatureName       = '$tostring:EntityId'
                IsEnabled         = '$tobool:value'
                AllowNonAuthSense = '$tobool:value'  # back-compat alias of IsEnabled
            }
        }
        @{
            Stream = 'MDE_PUAConfig_CL'
            Path = '/apiproxy/mtp/autoIr/ui/properties/'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Potentially-Unwanted-Application enforcement scope (block / audit / off + per-platform)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { AutomatedIrPuaAsSuspicious: false, IsAutomatedIrContainDeviceEnabled: true }
            # Pure-bool property-bag → Shape 3 flatten yields 2 rows.
            # iter-14.0 Phase 1: FeatureName + IsEnabled.
            # Legacy per-property cols preserved as back-compat (always null).
            ProjectionMap = @{
                FeatureName                       = '$tostring:EntityId'
                IsEnabled                         = '$tobool:value'
                # Legacy back-compat (always null with corrected Shape 3 handling):
                AutomatedIrPuaAsSuspicious        = '$tobool:AutomatedIrPuaAsSuspicious'
                IsAutomatedIrContainDeviceEnabled = '$tobool:IsAutomatedIrContainDeviceEnabled'
            }
        }
        # AntivirusPolicy + TenantAllowBlock: nodoc documents GET (not POST). Phase 2c live-captures; retag live if 200.
        @{
            Stream = 'MDE_AntivirusPolicy_CL'
            Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'MEM-bridged antivirus policy filter facets (Intune + Configuration Manager scope)'
            Availability = 'tenant-gated'
            # Fixture: tenant-gated (no live data). Convention: AV policy filter facets.
            ProjectionMap = @{
                FilterName    = '$tostring:Name'
                FilterValue   = '$tostring:Value'
                Platform      = '$tostring:Platform'
                Scope         = '$tostring:Scope'
                IsEnabled     = '$tobool:IsEnabled'
            }
        }
        @{
            Stream = 'MDE_TenantAllowBlock_CL'
            Path = '/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant Allow-Block-List (TABL) filter facet — IP/URL/file-hash indicator inventory'
            Availability = 'tenant-gated'
            # Fixture: tenant-gated (no live data). Convention: TABL indicator filter facet.
            ProjectionMap = @{
                IndicatorType = '$tostring:Type'
                Action        = '$tostring:Action'
                CreatedBy     = '$tostring:CreatedBy'
                CreatedTime   = '$todatetime:CreatedTime'
                ExpiryTime    = '$todatetime:ExpirationTime'
            }
        }

        # P0 — iter 13.8 path correction: was '/mdeCustomCollection/model' (returned 403),
        # now '/mdeCustomCollection/rules' per XDRInternals canonical source code.
        @{
            Stream = 'MDE_CustomCollection_CL'
            Path = '/apiproxy/mtp/mdeCustomCollection/rules'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            NodocCategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Custom event-collection rules (what extra MDE telemetry the tenant is gathering)'
            Availability = 'tenant-gated'
            IdProperty = @('ruleId', 'RuleId', 'id', 'Id')
            # Tenant-gated (no live data). Schema cross-referenced against
            # XDRInternals Get-XdrEndpointConfigurationCustomCollectionRule.ps1
            # — bare array of rule objects (no wrapper). Per-row schema:
            #   { ruleId, ruleName, ruleDescription, table, actionType, isEnabled,
            #     platform, scope, createdBy, lastModifiedBy, creationDateTimeUtc,
            #     lastModificationDateTimeUtc, version, updateKey, filters }.
            ProjectionMap = @{
                RuleId             = '$tostring:ruleId'
                Name               = '$tostring:ruleName'
                Description        = '$tostring:ruleDescription'
                Table              = '$tostring:table'
                ActionType         = '$tostring:actionType'
                IsEnabled          = '$tobool:isEnabled'
                Platform           = '$tostring:platform'
                Scope              = '$tostring:scope'
                CreatedBy          = '$tostring:createdBy'
                LastModifiedBy     = '$tostring:lastModifiedBy'
                CreatedTime        = '$todatetime:creationDateTimeUtc'
                LastModifiedTime   = '$todatetime:lastModificationDateTimeUtc'
            }
        }

        # (grouping below is by source-of-truth ordering, not poll cadence)
        # MDE_DataExportSettings_CL — HYBRID. Public ARM resource type
        # microsoft.insights/dataCollectionRules covers the SET surface; the
        # READ-side queryable Streaming API config is portal-only.
        @{
            Stream = 'MDE_DataExportSettings_CL'
            Path = '/apiproxy/mtp/wdatpApi/dataexportsettings'
            Tier = 'Maintenance'
            UnwrapProperty = 'value'
            Category = 'Streaming API'
            NodocCategoryId = 10  # nodoc-authoritative (Phase D.1)
            Purpose = 'Streaming API configuration: which workspaces / event-hubs / storage receive exported MDE telemetry'
            AuditScope = 'hybrid'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { @odata.context, value: [{ id, designatedTenantId, eventHubProperties,
            #   storageAccountProperties, workspaceProperties: { workspaceResourceId,
            #   subscriptionId, resourceGroup, name }, logs: [{ category, enabled }] }] }
            # iter-14.0 Phase 4: added UnwrapProperty='value' (caught by ProjectionResolution gate).
            ProjectionMap = @{
                ConfigId        = '$tostring:id'
                Destination     = '$tostring:workspaceProperties.name'
                Workspace       = '$tostring:workspaceProperties.workspaceResourceId'
                SubscriptionId  = '$tostring:workspaceProperties.subscriptionId'
                ResourceGroup   = '$tostring:workspaceProperties.resourceGroup'
                LogsCount       = '$toint:logs.length'
                EnabledLogs     = '$tostring:logs[*].category'
            }
        }
        @{
            Stream = 'MDE_ConnectedApps_CL'
            Path = '/apiproxy/mtp/responseApiPortal/apps/all'
            Tier = 'Configuration'
            SingleObjectAsRow = $true
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'OAuth + service-app inventory connected to the tenant Defender API surface'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object (NOT array
            # despite path suggesting "all"). One app per response in test tenant.
            # { Id, DisplayName, Enabled, LatestConnectivity, ApplicationSettingsLink, MonthlyStatistics:[int*] }.
            # iter-14.0 Phase 1: SingleObjectAsRow=$true so per-row entity is the
            # whole app object → typed cols project from named fields.
            # v0.2.0 follow-up: investigate whether tenants with multiple connected
            # apps return an array (verify against XDRInternals canonical client).
            ProjectionMap = @{
                AppId              = '$tostring:Id'
                Name               = '$tostring:DisplayName'
                IsEnabled          = '$tobool:Enabled'
                LatestConnectivity = '$todatetime:LatestConnectivity'
                SettingsLink       = '$tostring:ApplicationSettingsLink'
            }
        }
        @{
            Stream = 'MDE_TenantContext_CL'
            Path = '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true'
            Tier = 'Inventory'
            SingleObjectAsRow = $true
            Category = 'Multi-Tenant Operations'
            NodocCategoryId = 9  # nodoc-authoritative (Phase D.1)
            Purpose = 'Authenticated-tenant context: tenant ID, region, M365 sku, cross-tenant flags'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object with ~76 properties:
            # { EnvironmentName, OrgId, GeoRegion, DataCenter, AccountMode, AccountType,
            #   IsSuspended, IsMtpEligible, IsMdatpActive, IsSentinelActive, Features:{...},
            #   ActiveMtpWorkloads: [int*], ... }.
            # iter-14.0 Phase 1: SingleObjectAsRow=$true forces ONE per-entity row
            # (operator-friendly), not 76 per-property rows. Per-row entity is the
            # whole tenant-context object — typed cols project from named fields.
            # NOTE: column is `MdeTenantId` (not `TenantId`) — `TenantId` is a Log Analytics
            # SYSTEM-RESERVED column auto-typed as `guid`; declaring our own clashes at DCR validation.
            # Legacy `TenantName` col preserved as back-compat alias of EnvironmentName.
            ProjectionMap = @{
                MdeTenantId      = '$tostring:OrgId'
                TenantName       = '$tostring:EnvironmentName'  # back-compat alias
                EnvironmentName  = '$tostring:EnvironmentName'
                Region           = '$tostring:GeoRegion'
                DataCenter       = '$tostring:DataCenter'
                AccountType      = '$tostring:AccountType'
                IsHomeTenant     = '$tobool:IsMtpEligible'
                IsMdatpActive    = '$tobool:IsMdatpActive'
                IsSentinelActive = '$tobool:IsSentinelActive'
                IsMdiActive      = '$tobool:IsMdiActive'
                IsOatpActive     = '$tobool:IsOatpActive'
                IsItpActive      = '$tobool:IsItpActive'
                IsMdcActive      = '$tobool:IsMdcActive'
                IsAadIpActive    = '$tobool:IsAadIpActive'
            }
        }

        # P1 MTO tenant groups — requires mtoproxyurl:MTO header per XDRInternals v1.0.3.
        @{
            Stream = 'MDE_TenantWorkloadStatus_CL'
            Path = '/apiproxy/mtoapi/tenantGroups'
            Tier = 'Inventory'
            Headers = @{ 'mtoproxyurl' = 'MTO' }
            SingleObjectAsRow = $true
            Category = 'Multi-Tenant Operations'
            NodocCategoryId = 9  # nodoc-authoritative (Phase D.1)
            Purpose = 'MTO tenant-group definitions + per-group workload (alerts/incidents/dashboards) state'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object representing
            # the tenant's MTO group: { entityType, name, tenantGroupId, type,
            # description, allTenantsCount, exposedTargetTenantsInfo,
            # creationTime, lastUpdated, lastUpdatedByUpn, tenantId }.
            # iter-14.0 Phase 4: SingleObjectAsRow=$true so per-row entity is the
            # whole tenant-group object (caught by ProjectionResolution gate).
            # NOTE: column is `MdeTenantId` (not `TenantId`) — `TenantId` is a Log Analytics
            # SYSTEM-RESERVED column auto-typed as `guid`; declaring our own clashes at DCR validation.
            ProjectionMap = @{
                MdeTenantId     = '$tostring:tenantId'
                TenantGroupId   = '$tostring:tenantGroupId'
                TenantName      = '$tostring:name'
                EntityType      = '$tostring:entityType'
                AllTenantsCount = '$toint:allTenantsCount'
                CreatedTime     = '$todatetime:creationTime'
                LastUpdated     = '$todatetime:lastUpdated'
                LastUpdatedByUpn = '$tostring:lastUpdatedByUpn'
            }
        }
        # iter-13.8 — DEPRECATED. Canonical surface is MDE_DataExportSettings_CL.
        @{
            Stream = 'MDE_StreamingApiConfig_CL'
            Path = '/apiproxy/mtp/streamingapi/streamingApiConfiguration'
            Tier = 'Maintenance'
            Category = 'Streaming API'
            NodocCategoryId = 10  # nodoc-authoritative (Phase D.1)
            Purpose = 'DEPRECATED — superseded by MDE_DataExportSettings_CL. Returns 404 on modern tenants.'
            Availability = 'deprecated'
            # Deprecated stream — no ProjectionMap (canonical surface is MDE_DataExportSettings_CL).
            ProjectionMap = @{}
        }
        @{
            Stream = 'MDE_IntuneConnection_CL'
            Path = '/apiproxy/mtp/responseApiPortal/onboarding/intune/status'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Defender ↔ Intune connector status (link-state, last-handshake, scope enrolment)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): scalar int `0` (0 = not connected).
            # Shape 4 → ONE row with EntityId='value', value=<int>.
            # iter-14.0 Phase 1: keep both Status (int) + IsEnabled (bool: 0=false / nonzero=true).
            ProjectionMap = @{
                FeatureName = '$tostring:EntityId'
                Status      = '$toint:value'
                IsEnabled   = '$tobool:value'
            }
        }
        @{
            Stream = 'MDE_PurviewSharing_CL'
            Path = '/apiproxy/mtp/wdatpInternalApi/compliance/alertSharing/status'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Defender ↔ Purview alert-sharing toggle + per-domain scope'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): scalar bool `false`.
            # Shape 4 → ONE row with EntityId='value', value=<bool>.
            # iter-14.0 Phase 1: AlertSharingEnabled was redundant duplicate of IsEnabled
            # — preserved as back-compat alias.
            ProjectionMap = @{
                FeatureName         = '$tostring:EntityId'
                IsEnabled           = '$tobool:value'
                AlertSharingEnabled = '$tobool:value'  # back-compat alias of IsEnabled
            }
        }

        # ----------------------------------------------------------------------
        # MDE_RbacDeviceGroups_CL — HYBRID. MDE Public /api/machinegroups exposes
        # id+name only; portal exposes AAD-group bindings + machine-count + role
        # assignments. Operator-valuable for drift detection.
        @{
            Stream = 'MDE_RbacDeviceGroups_CL'
            Path = '/apiproxy/mtp/rbacManagementApi/rbac/machine_groups?addAadGroupNames=true&addMachineGroupCount=false'
            Tier = 'Configuration'
            UnwrapProperty = 'items'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'RBAC device groups + AAD-group bindings + per-group machine count + role assignments'
            AuditScope = 'hybrid'
            Availability = 'live'
            # Fixture: array of { MachineGroupId, Name, Description, AutoRemediationLevel, Priority, LastUpdated, IsUnassignedMachineGroup, MachineCount, GroupRules: [...] }.
            ProjectionMap = @{
                GroupId               = '$toint:MachineGroupId'
                Name                  = '$tostring:Name'
                Description           = '$tostring:Description'
                AutoRemediationLevel  = '$toint:AutoRemediationLevel'
                Priority              = '$toint:Priority'
                LastUpdated           = '$todatetime:LastUpdated'
                MachineCount          = '$toint:MachineCount'
                IsUnassigned          = '$tobool:IsUnassignedMachineGroup'
                RuleCount             = '$toint:GroupRules.length'
            }
        }
        # iter-13.9 (B3): nodoc-cited path; verified live 2026-04-28.
        @{
            Stream = 'MDE_UnifiedRbacRoles_CL'
            Path = '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions'
            Tier = 'Configuration'
            UnwrapProperty = 'value'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Unified-RBAC role definitions: per-role permission bitmaps + assigned principals'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { value: [], isPartial: false }
            # — empty in test tenant. iter-14.0 Phase 4: added UnwrapProperty='value'
            # (caught by ProjectionResolution gate). Per-row entity carries unified-RBAC
            # role-definition shape.
            ProjectionMap = @{
                RoleId        = '$tostring:id'
                Name          = '$tostring:displayName'
                IsBuiltIn     = '$tobool:isBuiltIn'
                CreatedTime   = '$todatetime:createdDateTime'
                ModifiedBy    = '$tostring:modifiedBy'
                Scope         = '$tostring:scope'
            }
        }
        @{
            Stream = 'MDE_AssetRules_CL'
            Path = '/apiproxy/mtp/xspmatlas/assetrules'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'Critical-asset classification rules (which devices/identities feed XSPM as crown jewels)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { rules: [{ orgId, tenantId, ruleId, ruleName, ruleDescription, createdBy,
            #   createdByName, lastUpdatedBy, lastUpdatedByName, lastUpdateTime,
            #   ruleDefinition, kqlQuery, ... }] }
            UnwrapProperty = 'rules'
            ProjectionMap = @{
                RuleId               = '$tostring:ruleId'
                Name                 = '$tostring:ruleName'
                Description          = '$tostring:ruleDescription'
                CreatedBy            = '$tostring:createdBy'
                IsEnabled            = '$tobool:isDisabled'
                RuleType             = '$tostring:ruleType'
                CriticalityLevel     = '$toint:criticalityLevel'
                AssetType            = '$tostring:assetType'
                ClassificationValue  = '$tostring:classificationValue'
                AffectedAssetsCount  = '$toint:affectedAssetsCount'
            }
        }
        @{
            Stream = 'MDE_SAClassification_CL'
            Path = '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI service-account classification rules (which AD accounts MDI flags as service accounts)'
            Availability = 'live'
            # Fixture: null (no rules in test tenant). Convention: MDI service-account classification rule shape.
            ProjectionMap = @{
                RuleId       = '$tostring:Id'
                Name         = '$tostring:Name'
                AccountType  = '$tostring:AccountType'
                Domain       = '$tostring:Domain'
                IsActive     = '$tobool:IsActive'
                LastSeenUtc  = '$todatetime:LastSeen'
            }
        }

        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_XspmInitiatives_CL'
            Path = '/apiproxy/mtp/posture/oversight/initiatives'
            Tier = 'XspmGraph'
            Filter = 'fromDate'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM exposure initiatives + per-initiative completion progress + recommended actions'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { results: [{ id, name, description, targetValue, metricIds[], activeMetricIds[],
            #   recommendationIds[], programs[], isFavorite, dataHistory }] }
            UnwrapProperty = 'results'
            ProjectionMap = @{
                InitiativeId      = '$tostring:id'
                Name              = '$tostring:name'
                TargetValue       = '$todouble:targetValue'
                MetricCount       = '$toint:metricIds.length'
                ActiveMetricCount = '$toint:activeMetricIds.length'
                Programs          = '$tostring:programs[*]'
                IsFavorite        = '$tobool:isFavorite'
            }
        }
        @{
            Stream = 'MDE_ExposureSnapshots_CL'
            Path = '/apiproxy/mtp/posture/oversight/updates'
            Tier = 'XspmGraph'
            Filter = 'fromDate'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM posture-snapshot deltas (what changed in exposure score / metrics over time)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { results: [], recordsCount: 0 } — empty when no recent posture updates.
            UnwrapProperty = 'results'
            ProjectionMap = @{
                SnapshotId    = '$tostring:id'
                MetricId      = '$tostring:metricId'
                Score         = '$todouble:score'
                ScoreChange   = '$todouble:scoreChange'
                CreatedTime   = '$todatetime:date'
                InitiativeId  = '$tostring:initiativeId'
            }
        }
        # iter-14.0 portal-only audit (2026-04-29): MDE_SecureScoreBreakdown_CL DROPPED
        # — Microsoft Graph /security/secureScores covers identical data with
        # identical shape. Operators should use the official Graph Security data
        # connector. See docs/STREAMS-REMOVED.md (when added in Phase 12).
        @{
            Stream = 'MDE_ExposureRecommendations_CL'
            Path = '/apiproxy/mtp/posture/oversight/recommendations'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM remediation recommendations (per-initiative actionable steps + criticality + effort)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { results: [{ id, title, lastStateChange, lastStateUpdate, category, source,
            #   product, description, implementationStatus, severity, remediation, ... }] }
            UnwrapProperty = 'results'
            # Fixture: { results: [{ id, title, lastStateChange, lastStateUpdate, category, source, product, severity, implementationCost, userImpact, userAffected, currentState, mssControlState, isDisabled, score, maxScore, lastSynced }] }.
            ProjectionMap = @{
                RecommendationId  = '$tostring:id'
                Title             = '$tostring:title'
                Severity          = '$tostring:severity'
                Status            = '$tostring:currentState'
                Source            = '$tostring:source'
                Product           = '$tostring:product'
                Category          = '$tostring:category'
                ImplementationCost = '$tostring:implementationCost'
                UserImpact        = '$tostring:userImpact'
                IsDisabled        = '$tobool:isDisabled'
                Score             = '$todouble:score'
                MaxScore          = '$todouble:maxScore'
                LastSyncedUtc     = '$todatetime:lastSynced'
            }
        }

        # P3 XSPM — ACTIVATED via XDRInternals bodies (xspmatlas hunting query).
        @{
            Stream  = 'MDE_XspmAttackPaths_CL'
            Path    = '/apiproxy/mtp/xspmatlas/attacksurface/query'
            Method  = 'POST'
            Body    = @{
                query      = 'AttackPathsV2'
                options    = @{ top = 0; skip = 0 }
                apiVersion = 'v2'
            }
            Headers = @{
                'x-tid'              = '{TenantId}'
                'x-ms-scenario-name' = 'AttackPathOverview_get_has_attack_paths'
            }
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM attack-path graph (multi-hop privesc/lateral chains from low-privilege entry to crown jewels)'
            IdProperty = @('attackPathId', 'id')
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { totalRecords: 0, count: 0, skipToken: null, data: [] } — empty in test
            # tenant; non-empty rows carry { attackPathId, MaxRiskLevel, Status,
            # Source: { Name, Id }, Target: { Name, Id }, HopsCount, CreationTime, ... }.
            UnwrapProperty = 'data'
            ProjectionMap = @{
                PathId      = '$tostring:attackPathId'
                Severity    = '$tostring:MaxRiskLevel'
                Status      = '$tostring:Status'
                Source      = '$tostring:Source.Name'
                Target      = '$tostring:Target.Name'
                SourceId    = '$tostring:Source.Id'
                TargetId    = '$tostring:Target.Id'
                HopCount    = '$toint:HopsCount'
                CreatedTime = '$todatetime:CreationTime'
            }
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
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM chokepoints — single nodes that appear on many attack paths (highest-leverage remediation targets)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { totalRecords: 0, count: 0, skipToken: null, data: [] } — empty in test
            # tenant; non-empty rows carry { NodeId, NodeName, NodeType, MaxRiskLevel,
            # AttackPathsCount, EntityType } from the AttackPathDiscovery aggregation.
            UnwrapProperty = 'data'
            ProjectionMap = @{
                NodeId           = '$tostring:NodeId'
                NodeName         = '$tostring:NodeName'
                NodeType         = '$tostring:NodeType'
                Severity         = '$tostring:MaxRiskLevel'
                AttackPathsCount = '$toint:AttackPathsCount'
                EntityType       = '$tostring:EntityType'
            }
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
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            NodocCategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM top-targeted assets — critical assets reachable by the most active attack paths'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { totalRecords: 0, count: 0, skipToken: null, data: [] } — empty in test
            # tenant; non-empty rows carry { TargetId, TargetName, AttackPathsCount }
            # from the AttackPathsV2 summarize-by-target aggregation.
            UnwrapProperty = 'data'
            ProjectionMap = @{
                TargetId         = '$tostring:TargetId'
                TargetName       = '$tostring:TargetName'
                AttackPathsCount = '$toint:AttackPathsCount'
                Source           = '$tostring:Source'
                Status           = '$tostring:Status'
            }
        }

        # P3 — TVM baseline profiles. Returns 400 without 'api-version: 1.0' header.
        @{
            Stream = 'MDE_SecurityBaselines_CL'
            Path = '/apiproxy/mtp/tvm/analytics/baseline/profiles?pageIndex=0&pageSize=25'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            Category = 'Vulnerability Management (TVM)'
            NodocCategoryId = 3  # nodoc-authoritative (Phase D.1)
            Purpose = 'TVM security-baseline profile compliance (CIS / Microsoft baselines applied to device fleet)'
            Availability = 'tenant-gated'
            # Tenant-gated (no live data — TVM addon not licensed in test tenant).
            # Schema cross-referenced against XDRInternals
            # Get-XdrVulnerabilityManagementBaseline.ps1 — root response is
            # { results: [...], numOfResults: <int> }; cmdlet appends $response.results.
            # Per-row schema:
            #   { id (GUID), name, compliancePct, compliantDevices,
            #     nonCompliantDevices, lastModifiedDateTime, benchmarkName }.
            # `api-version: 1.0` header is mandatory (TVM API gate).
            UnwrapProperty = 'results'
            # NOTE: legacy `Compliance` column was typed `boolean` in v0.1.0-beta
            # initial DCR but the upstream API returns a percentage (real).
            # `CompliancePct` is the additive replacement; queries should migrate
            # to `CompliancePct` going forward (Compliance preserved for back-compat).
            # Legacy cols (Compliance/DeviceCount/LastScanUtc/Score) are declared
            # in the ProjectionMap so the DCR-mirror gate sees them as part of the
            # contract. They project from convention names that don't appear in
            # the corrected upstream shape — values stay null.
            ProjectionMap = @{
                ProfileId           = '$tostring:id'
                Name                = '$tostring:name'
                BenchmarkName       = '$tostring:benchmarkName'
                CompliancePct       = '$todouble:compliancePct'
                CompliantDevices    = '$toint:compliantDevices'
                NonCompliantDevices = '$toint:nonCompliantDevices'
                LastModifiedUtc     = '$todatetime:lastModifiedDateTime'
                # Legacy back-compat (always null with the corrected upstream shape):
                Compliance          = '$tobool:isCompliant'
                DeviceCount         = '$toint:assetsCount'
                LastScanUtc         = '$todatetime:lastUpdate'
                Score               = '$todouble:complianceScore'
            }
        }

        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_IdentityOnboarding_CL'
            Path = '/apiproxy/mtp/siamApi/domaincontrollers/list'
            Tier = 'Inventory'
            UnwrapProperty = 'DomainControllers'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI domain-controller onboarding state (per-DC sensor health + last-seen + IP)'
            Availability = 'live'
            # Fixture: null (no MDI in test tenant). Convention: MDI DC onboarding shape.
            ProjectionMap = @{
                DCName        = '$tostring:Name'
                Domain        = '$tostring:Domain'
                IpAddress     = '$tostring:IpAddress'
                SensorHealth  = '$tostring:HealthStatus'
                IsActive      = '$tobool:IsActive'
                LastSeenUtc   = '$todatetime:LastSeen'
            }
        }

        # P5 IdentityServiceAccounts — XDRInternals body schema.
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
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI service-account inventory (auto-classified service accounts + activity heuristics)'
            Availability = 'live'
            # Fixture: { ServiceAccounts: [] } (no service accounts in test tenant). Convention: MDI service-account row shape.
            ProjectionMap = @{
                AccountUpn   = '$tostring:Upn'
                AccountSid   = '$tostring:Sid'
                AccountType  = '$tostring:AccountType'
                Domain       = '$tostring:Domain'
                IsActive     = '$tobool:IsActive'
                LastSeenUtc  = '$todatetime:LastSeen'
                Risk         = '$tostring:RiskLevel'
            }
        }

        # P5 tenant-gated — MDI sensors not deployed in test tenant
        @{
            Stream = 'MDE_DCCoverage_CL'
            Path = '/apiproxy/aatp/api/sensors/domainControllerCoverage'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI sensor coverage per domain controller (which DCs have working sensors / sync state)'
            Availability = 'tenant-gated'
            # Fixture: tenant-gated (no MDI). Convention: per-DC sensor-coverage row shape.
            ProjectionMap = @{
                DCName        = '$tostring:Name'
                Domain        = '$tostring:Domain'
                IsActive      = '$tobool:HasSensor'
                LastSeenUtc   = '$todatetime:LastSyncTime'
                Risk          = '$tostring:CoverageStatus'
            }
        }
        @{
            Stream = 'MDE_IdentityAlertThresholds_CL'
            Path = '/apiproxy/aatp/api/alertthresholds/withExpiry'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI alert-threshold tuning per detection (when each MDI rule fires + temporary overrides)'
            Availability = 'tenant-gated'
            IdProperty = @('AlertName', 'AlertType', 'Id')
            # Tenant-gated (no MDI). Schema cross-referenced against
            # XDRInternals Get-XdrIdentityAlertThreshold.ps1 — root response is
            # { IsRecommendedTestModeEnabled: bool, AlertThresholds: [...] };
            # cmdlet returns $result.AlertThresholds. Per-row schema:
            #   { AlertName, Threshold (High/Medium/Low), AvailableThresholds[],
            #     Expiry, AlertTitle (cmdlet-enriched friendly name) }.
            UnwrapProperty = 'AlertThresholds'
            # NOTE: legacy `Threshold` column was typed `real` in the v0.1.0-beta
            # initial DCR — preserved for backward compatibility (queries still
            # parse). Actual MDI threshold values are categorical strings
            # (High/Medium/Low) that ride on the new `ThresholdLevel` column;
            # operators should query `ThresholdLevel` going forward.
            # Legacy cols (ThresholdId/AlertType/IsEnabled/ModifiedBy/Threshold)
            # are declared in the ProjectionMap so the DCR-mirror gate
            # (DCR.TypedColumnCoverage.Tests.ps1) sees them as part of the
            # contract. They project from fields the upstream cmdlet doesn't
            # surface — values stay null until/unless MDI exposes them.
            ProjectionMap = @{
                AlertName           = '$tostring:AlertName'
                AlertTitle          = '$tostring:AlertTitle'
                ThresholdLevel      = '$tostring:Threshold'
                AvailableThresholds = '$tostring:AvailableThresholds[*]'
                ExpiresUtc          = '$todatetime:Expiry'
                # Legacy back-compat (always null with the corrected upstream shape):
                ThresholdId         = '$tostring:Id'
                AlertType           = '$tostring:AlertType'
                IsEnabled           = '$tobool:IsEnabled'
                ModifiedBy          = '$tostring:ModifiedBy'
                Threshold           = '$todouble:Value'
            }
        }
        @{
            Stream = 'MDE_RemediationAccounts_CL'
            Path = '/apiproxy/aatp/api/remediationActions/configuration'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            NodocCategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI gMSA remediation-action configuration (which managed-service-accounts MDI uses for password resets)'
            Availability = 'tenant-gated'
            # Fixture: tenant-gated (no MDI). Convention: gMSA remediation-action shape.
            ProjectionMap = @{
                AccountUpn   = '$tostring:GmsaAccount'
                AccountType  = '$tostring:AccountType'
                Domain       = '$tostring:Domain'
                IsActive     = '$tobool:IsConfigured'
                LastSeenUtc  = '$todatetime:LastUpdated'
            }
        }

        # ----------------------------------------------------------------------
        # iter-14.0 Phase 3: UnwrapProperty='Results' + IdProperty=@('ActionId') fixes
        # the wrapper-key bug. Response shape is {Count:N, Results:[…]}; without
        # UnwrapProperty operators saw 2 rows (EntityId='Results', EntityId='Count')
        # instead of 1868 per-action rows.
        @{
            Stream = 'MDE_ActionCenter_CL'
            Path = '/apiproxy/mtp/actionCenter/actioncenterui/history-actions'
            Tier = 'ActionCenter'
            Filter = 'fromDate'
            UnwrapProperty = 'Results'
            IdProperty = @('ActionId', 'Id', 'id')
            Category = 'Action Center'
            NodocCategoryId = 8  # nodoc-authoritative (Phase D.1)
            Purpose = 'Action Center history — every cross-workload remediation action (block/quarantine/investigation) with operator + status'
            Availability = 'live'
            # Fixture: array of { InvestigationId, ActionId, StartTime, EndTime, ActionType, ActionDecision, DecidedBy, Comment, RelatedEntities, EntityType, EventTime, ActionStatus, ActionSource, Product, MachineId, ComputerName, UserPrincipalName, ActionAutomationType }.
            ProjectionMap = @{
                ActionId         = '$tostring:ActionId'
                InvestigationId  = '$tostring:InvestigationId'
                ActionType       = '$tostring:ActionType'
                ActionStatus     = '$tostring:ActionStatus'
                ActionDecision   = '$tostring:ActionDecision'
                ActionSource     = '$tostring:ActionSource'
                StartTime        = '$todatetime:StartTime'
                EndTime          = '$todatetime:EndTime'
                EventTime        = '$todatetime:EventTime'
                Operator         = '$tostring:DecidedBy'
                UserPrincipalName = '$tostring:UserPrincipalName'
                MachineId        = '$tostring:MachineId'
                ComputerName     = '$tostring:ComputerName'
                Product          = '$tostring:Product'
                Comment          = '$tostring:Comment'
                EntityType       = '$tostring:EntityType'
            }
        }
        @{
            Stream = 'MDE_ThreatAnalytics_CL'
            Path = '/apiproxy/mtp/threatAnalytics/outbreaks'
            Tier = 'Configuration'
            Filter = 'fromDate'
            Category = 'Threat Analytics'
            NodocCategoryId = 7  # nodoc-authoritative (Phase D.1)
            Purpose = 'Threat Analytics active outbreaks + per-tenant exposure score + tracked-actor links'
            Availability = 'live'
            # Fixture: array of { Id, DisplayName, CreatedOn, StartedOn, LastUpdatedOn, Severity, Keywords, References, IOAIds, MitigationTypes, ReportType, Tags, IsVNext, SecureScoreIds }.
            ProjectionMap = @{
                OutbreakId     = '$tostring:Id'
                Title          = '$tostring:DisplayName'
                Severity       = '$toint:Severity'
                ReportType     = '$tostring:ReportType'
                CreatedOn      = '$todatetime:CreatedOn'
                StartedOn      = '$todatetime:StartedOn'
                LastUpdatedOn  = '$todatetime:LastUpdatedOn'
                LastVisitTime  = '$todatetime:LastVisitTime'
                Tags           = '$tostring:Tags[*]'
                Keywords       = '$tostring:Keywords[*]'
                IsVNext        = '$tobool:IsVNext'
            }
        }

        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_UserPreferences_CL'
            Path = '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference'
            Tier = 'Configuration'
            SingleObjectAsRow = $true
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-analyst portal preferences (homepage layout, default filters) — drift detector for shared accounts'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { user_preferences: "<JSON-string of operator's saved preferences>" }
            # iter-14.0 Phase 1: SingleObjectAsRow=$true → ONE row per response;
            # the user_preferences JSON-string is preserved as both a typed col
            # (UserPreferencesJson) AND in RawJson for forensic queries. Operators
            # can drill into the inner JSON via parse_json(UserPreferencesJson).
            # Legacy cols preserved as back-compat (always null with corrected handling).
            ProjectionMap = @{
                UserPreferencesJson = '$tostring:user_preferences'
                # Legacy back-compat (always null with SingleObjectAsRow):
                SettingId           = '$tostring:EntityId'
                Name                = '$tostring:Name'
                IsEnabled           = '$tobool:IsEnabled'
                CreatedTime         = '$todatetime:CreatedTime'
                CreatedBy           = '$tostring:CreatedBy'
                Scope               = '$tostring:Scope'
            }
        }

        # P7 MTO TenantPicker — mtoproxyurl:MTO header + tenantInfoList unwrap.
        @{
            Stream = 'MDE_MtoTenants_CL'
            Path   = '/apiproxy/mtoapi/tenants/TenantPicker'
            Tier   = 'Inventory'
            Headers = @{ 'mtoproxyurl' = 'MTO' }
            UnwrapProperty = 'tenantInfoList'
            Category = 'Multi-Tenant Operations'
            NodocCategoryId = 9  # nodoc-authoritative (Phase D.1)
            Purpose = 'MTO tenant picker — list of tenants this MSSP/parent has cross-tenant access to'
            Availability = 'live'
            # Fixture: { tenantInfoList: [{ selected, lostAccess, name, tenantId, tenantAadEnvironment }] }.
            # NOTE: column is `MdeTenantId` (not `TenantId`) — `TenantId` is a Log Analytics
            # SYSTEM-RESERVED column auto-typed as `guid`; declaring our own clashes at DCR validation.
            ProjectionMap = @{
                MdeTenantId          = '$tostring:tenantId'
                TenantName           = '$tostring:name'
                TenantAadEnvironment = '$toint:tenantAadEnvironment'
                IsSelected           = '$tobool:selected'
                LostAccess           = '$tobool:lostAccess'
                IsHomeTenant         = '$tobool:selected'
            }
        }
        # MDE_LicenseReport_CL — HYBRID. MDE Public /api/machines returns one row
        # per device w/o sku rollup; portal returns aggregated sku counts.
        @{
            Stream = 'MDE_LicenseReport_CL'
            Path = '/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport'
            Tier = 'Inventory'
            UnwrapProperty = 'sums'
            Category = 'Endpoint Device Management'
            NodocCategoryId = 1  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-SKU device license rollup (how many devices on each MDE plan / per-OS / per-region)'
            AuditScope = 'hybrid'
            Availability = 'live'
            # Fixture: { Sums: [{ Sku, DetectedUsers, TotalDevices }] } — note: actual response uppercased 'Sums' but the manifest UnwrapProperty='sums' (case-insensitive lookup).
            ProjectionMap = @{
                SkuName       = '$tostring:Sku'
                DeviceCount   = '$toint:TotalDevices'
                DetectedUsers = '$toint:DetectedUsers'
            }
        }

        @{
            Stream = 'MDE_CloudAppsConfig_CL'
            Path = '/apiproxy/mcas/cas/api/v1/settings/'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            NodocCategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'MCAS / Defender for Cloud Apps general settings (regions, integrations, notification policy)'
            Availability = 'tenant-gated'
            # Fixture: tenant-gated (no MCAS). Convention: MCAS settings property-bag.
            ProjectionMap = @{
                SettingId    = '$tostring:EntityId'
                Region       = '$tostring:Region'
                IsEnabled    = '$tobool:IsEnabled'
                CreatedTime  = '$todatetime:CreatedTime'
                ModifiedBy   = '$tostring:ModifiedBy'
            }
        }

        # ---- New portal-only endpoints (added v0.1.0-beta scope expansion) -----------------
        # Two portal-only telemetry surfaces that public Microsoft APIs do NOT
        # cover (or cover only partially). Both ship as 'tenant-gated' so
        # operators with no underlying activity (no LR sessions; no recent
        # machine-actions) don't see ingest 4xx errors during cold-start; once
        # tenant has data, polls return 200 and rows land.
        #
        # Live shape verification: XDRInternals upstream documents the cmdlets
        # but the exact path + body schema vary by tenant region + Defender
        # license tier. First operator capture in production lifts these to
        # 'live' status (or contributes a path correction PR if the canonical
        # surface differs from what XDRInternals encoded).

        # Per-device timeline (process / file / network / registry events).
        # Public Defender XDR API exposes per-event hunts but NOT the unified
        # timeline view's correlation/grouping — that's portal-only.
        # Source: XDRInternals Get-XdrEndpointDeviceTimeline.ps1
        @{
            Stream = 'MDE_DeviceTimeline_CL'
            Path = '/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machinetimeline'
            Method = 'POST'
            Body = @{
                # Aggregate query (no per-machine filter); operator-side timeline
                # filter happens via KQL on the typed columns at query time.
                pageSize = 1000
                pageIndex = 0
                fromDate = ''
                toDate = ''
            }
            Tier = 'Inventory'
            Filter = 'fromDate'
            Category = 'Endpoint Device Management'
            NodocCategoryId = 1  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-device unified timeline (process/file/network/registry events with portal-side correlation + grouping)'
            UnwrapProperty = 'Results'
            IdProperty = @('eventId', 'EventId', 'id', 'Id')
            Availability = 'tenant-gated'
            ProjectionMap = @{
                EventId      = '$tostring:eventId'
                MachineId    = '$tostring:machineId'
                EventTime    = '$todatetime:eventTime'
                EventType    = '$tostring:eventType'
                ProcessName  = '$tostring:processName'
                FileName     = '$tostring:fileName'
                Severity     = '$tostring:severity'
            }
        }

        # Machine action results (LR per-step output + AIR linkage). Public
        # MDE API /api/machineactions covers metadata only — portal returns
        # the per-step script-block stdout/stderr + AIR cross-link that the
        # operator's response audit needs. AuditScope = 'hybrid' documents
        # the public-API delta.
        # Source: XDRInternals Get-XdrEndpointDeviceActionResult.ps1
        @{
            Stream = 'MDE_MachineActions_CL'
            Path = '/apiproxy/mtp/responseApiPortal/machineactions'
            Tier = 'ActionCenter'
            Filter = 'fromDate'
            Category = 'Action Center'
            NodocCategoryId = 8  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-device action results (Live Response per-step script output + AIR linkage; richer than public MDE /api/machineactions)'
            IdProperty = @('actionId', 'ActionId', 'id', 'Id')
            AuditScope = 'hybrid'
            Availability = 'tenant-gated'
            ProjectionMap = @{
                ActionId         = '$tostring:actionId'
                ActionType       = '$tostring:actionType'
                ActionStatus     = '$tostring:status'
                MachineId        = '$tostring:machineId'
                CreatedTime      = '$todatetime:creationTime'
                CompletedTime    = '$todatetime:completionTime'
                Operator         = '$tostring:requestor'
                InvestigationId  = '$tostring:investigationId'
                ScriptOutput     = '$json:scriptOutputs'
            }
        }
    )
}
