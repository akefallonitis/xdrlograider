@{
    # ============================================================================
    # XdrLogRaider — Endpoint Catalogue
    # ============================================================================
    # Single source of truth for every Defender XDR portal-only stream this
    # connector collects. Dispatched at runtime by Invoke-MDEEndpoint and
    # Invoke-MDETierPoll.
    #
    # Section R++ (2026-05-07) AVAILABILITY POLICY (operator directive):
    #   ALL streams declare Availability='live' regardless of lab observations.
    #   Tenant-gating + license issues are detected DYNAMICALLY at runtime via
    #   Invoke-MDEEndpoint's SuccessKind side-channel + classified per actual
    #   API response (live | live-empty | tenant-gated | error). Connector card
    #   + heartbeat aggregator surface the runtime classification. This way:
    #     - A fully-licensed production tenant sees no false-negative gating.
    #     - A lab tenant sees runtime SuccessKind='tenant-gated' for streams
    #       whose features aren't licensed — surfaced as informational, not failure.
    #   Two exceptions kept:
    #     - 'deprecated' (1 stream — MDE_StreamingApiConfig_CL — known 404 on
    #       all modern tenants per Microsoft documentation; orchestrator skips)
    #     - RequiresLicense + TenantContextProbe forward-compat fields document
    #       which licenses help operators understand expected coverage, but do
    #       NOT short-circuit polling.
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
    #   Per-entry OPTIONAL (defaults via Defaults block + Get-XdrEndpointManifest -Portal Defender):
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
    #                       MDE_UserPreferences_CL). v0.1.0 GA add.
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
        Portal                  = 'security.microsoft.com'
        SchemaSource            = 'live-capture'   # Phase E per directive 15
        MFAMethodsSupported     = @('CredentialsTotp', 'Passkey')
        AuditScope              = 'portal-only'
        IdProperty              = $null  # falls back to Expand-MDEResponse default heuristic list
        ProjectionMap           = @{}    # populated per-stream in Phase 4
        # Phase I per directives 32 + 34 + plan Section 2.A:
        StreamSubtype           = 'portal-api'  # v0.2.0 adds 'xdrinternals' + 'hybrid'
        SnapshotDedupRationale  = 'snapshot-replace'  # default for snapshot-style ingest; per-stream override for event-stream tiers
        # CategorySlug derived at manifest-load from CategoryId via lookup table:
        #   1=endpoint-device-management, 2=endpoint-configuration, 3=vulnerability-management,
        #   4=identity-protection, 5=configuration-and-settings, 6=exposure-management-xspm,
        #   7=threat-analytics, 8=action-center, 9=multi-tenant-operations, 10=streaming-api
        # SourceName derived at manifest-load: <Stream>_PortalApi (per-stream override allowed)
    }

    Endpoints = @(
        # ---- Endpoint catalogue — Tier values are: fast | exposure | config | inventory | maintenance.
        @{
            Stream = 'MDE_AdvancedFeatures_CL'
            Path = '/apiproxy/mtp/settings/GetAdvancedFeaturesSetting'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant-wide MDE feature toggles (Tamper Protection, EDR-block, Web Content Filtering, etc.)'
            Availability = 'live'
            # Property-bag stream: response is { FeatureName1: bool, FeatureName2: bool, ... }
            # with 30+ properties. Each property name → one row via Shape 3 flattening.
            # v0.1.0 GA: ProjectionMap follows the property-bag convention
            # FeatureName + IsEnabled (per-property declarations cannot resolve under
            # Shape 3 because the per-row entity is the property VALUE — a scalar bool —
            # not an object with named fields).
            # Legacy cols (EnableWdavAntiTampering/AatpIntegrationEnabled/etc) declared
            # v0.1.0 GA scope for additive-only schema (ARM rejects col drops); they project
            # from fields that don't exist on the per-row scalar entity → always null.
            # Operators should query IsEnabled going forward.
            ProjectionMap = @{
                FeatureName = '$tostring:EntityId'   # property name (synthesized in projContext)
                IsEnabled   = '$tobool:value'        # property value
                # Legacy v0.1.0 GA scope (always null with corrected Shape 3 handling):
                EnableWdavAntiTampering       = '$tobool:EnableWdavAntiTampering'
                AatpIntegrationEnabled        = '$tobool:AatpIntegrationEnabled'
                EnableMcasIntegration         = '$tobool:EnableMcasIntegration'
                AutoResolveInvestigatedAlerts = '$tobool:AutoResolveInvestigatedAlerts'
            }
        }
        # pre-v0.1.0.9 (B4): query-string drift fix per XDRInternals canonical source
        # — Get-XdrConfigurationPreviewFeatures.ps1 uses ?context=MdatpContext.
        @{
            Stream = 'MDE_PreviewFeatures_CL'
            Path = '/apiproxy/mtp/settings/GetPreviewExperienceSetting?context=MdatpContext'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Preview-ring enrolment for tenant-wide MDE features (gradual rollout state)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { IsOptIn: false, SliceId: 100 }
            # SingleObjectAsRow = $true (operator directive 2026-05-06):
            # Previous Shape-3 flatten emitted 2 rows with EntityId=keyName +
            # RawJson=scalar value, leaving operator confused (typed cols all
            # null because the per-property context lacks sibling fields).
            # Switching to SingleObjectAsRow yields ONE coherent row where IsOptIn
            # + SliceId typed projections resolve against the parent object.
            # IdProperty=@('SliceId') gives a stable EntityId per slice rather
            # than 'idx-0'.
            SingleObjectAsRow = $true
            IdProperty = @('SliceId')
            ProjectionMap = @{
                IsOptIn  = '$tobool:IsOptIn'
                SliceId  = '$toint:SliceId'
                # 3rd typed col required by Manifest.ProjectionMap.Populated invariant
                # (operators must have >=3 typed cols, not just RawJson).
                # FeatureName projects the SliceId value as a stable label so
                # operator KQL can group/sort by feature ring without parsing RawJson.
                FeatureName = '$tostring:SliceId'
            }
        }
        # pre-v0.1.0.9 (B4): ?includeDetails=true per Get-XdrConfigurationAlertServiceSetting.ps1
        @{
            Stream = 'MDE_AlertServiceConfig_CL'
            Path = '/apiproxy/mtp/alertsApiService/workloads/disabled?includeDetails=true'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
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
        # pre-v0.1.0.9 (B3): nodoc-cited path — XDRInternals has no Get-Xdr*AlertTuning cmdlet.
        # v0.1.0 GA (v0.1.0 GA): added UnwrapProperty='items' per fixture shape.
        @{
            Stream = 'MDE_AlertTuning_CL'
            Path = '/apiproxy/mtp/alertsEmailNotifications/email_notifications'
            Tier = 'Configuration'
            UnwrapProperty = 'items'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Operator-defined alert suppression rules (which alerts are deliberately silenced + scope)'
            Availability = 'live'
            # Fixture: array of rule objects with Id/RuleTitle/CreatedBy/CreationTime/IsEnabled/Scope/Action/RuleType/MatchingAlertsCount.
            ProjectionMap = @{
                RuleId              = '$tostring:Id'
                Name                = '$tostring:RuleTitle'
                IsEnabled           = '$tobool:IsEnabled'
                CreatedTime         = '$todatetime:CreationTime'
                CreatedBy           = '$tostring:CreatedBy'
                # Per-stream column naming for shared-table disambiguation:
                # Defender_ConfigurationAndSettings_CL is a consolidated table (D'.11)
                # that aggregates streams whose source APIs use overloaded field
                # names (Scope/Action) for semantically different concepts.
                # SuppressionRules.Scope is an integer enum (rule scope kind);
                # UnifiedRbacRoles.Scope is an ARM resource ID; UserPreferences.Scope
                # is a preference name. Renaming to SuppressionScope preserves the
                # int type and disambiguates from the other streams.
                # Same logic for SuppressionAction (int enum) vs AllowBlockAction (string).
                # See tests/arm/SchemaConsistency.Tests.ps1 for the gate that catches
                # any future cross-stream column-name clash with type disagreement.
                SuppressionScope    = '$toint:Scope'
                SuppressionAction   = '$toint:Action'
                AlertTitle          = '$tostring:AlertTitle'
                MatchingAlertsCount = '$toint:MatchingAlertsCount'
                IsReadOnly          = '$tobool:IsReadOnly'
                UpdateTime          = '$todatetime:UpdateTime'
            }
        }
        # pre-v0.1.0.9 (B4): pagination + unified-rules-list flag per XDRInternals
        # Get-XdrAdvancedHuntingUnifiedDetectionRules.ps1 — without pageSize=10000
        # the response is truncated to the default-page count.
        @{
            Stream = 'MDE_CustomDetections_CL'
            Path = '/apiproxy/mtp/huntingService/rules/unified?sortOrder=Ascending&isUnifiedRulesListEnabled=true'
            Tier = 'Configuration'
            Filter = 'fromDate'
            UnwrapProperty = 'Rules'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant-defined custom detection rules (KQL-driven scheduled hunts that mint alerts)'
            Availability = 'live'
            # Section R++++++ Phase 1+ fix (2026-05-08): pagination + Filter='fromDate'
            # chained. Activity reads checkpoint, adds ?fromDate={ISO}, paginates
            # through all rules newer than checkpoint, writes new checkpoint=NOW.
            # Previous hardcoded pageSize=10000 capped at 10K rules + missed any
            # tenant with >10K rules. With proper pagination loop, large tenants
            # capture full inventory.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
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
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Device-control + onboarding-package configuration (USB/printer/disk policies)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { onboarded: 0, notOnboarded: 0, hasPermissions: true }
            # Property-bag with mixed types (int + bool) → Shape 3 flatten.
            # v0.1.0 GA: FeatureName + Value (string, universal). Legacy
            # cols preserved as v0.1.0 GA scope (always null with corrected handling).
            ProjectionMap = @{
                FeatureName    = '$tostring:EntityId'
                Value          = '$tostring:value'
                # Legacy v0.1.0 GA scope (always null):
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
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Web Content Filtering policy state + top blocked-category report'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { UpdateTime: <iso>, TopParentCategories: [{ Name, ActivityDeltaPercentage,
            #   IsDeltaPercentageValid, TotalAccessRequests, TotalBlockedCount }, ...] }
            # v0.1.0 GA: UnwrapProperty='TopParentCategories' so each
            # category is a per-entity row (Shape 1). UpdateTime is a wrapper-level
            # field — lost on unwrap; row's TimeGenerated suffices.
            # Legacy cols (FeatureName/UpdateTime) preserved as v0.1.0 GA scope.
            ProjectionMap = @{
                CategoryName            = '$tostring:Name'
                ActivityDeltaPercentage = '$toint:ActivityDeltaPercentage'
                IsDeltaPercentageValid  = '$tobool:IsDeltaPercentageValid'
                TotalAccessRequests     = '$tolong:TotalAccessRequests'
                TotalBlockedCount       = '$tolong:TotalBlockedCount'
                # Legacy v0.1.0 GA scope (post-unwrap entity has no FeatureName/UpdateTime):
                FeatureName             = '$tostring:Name'  # alias of CategoryName
                UpdateTime              = '$todatetime:UpdateTime'
            }
        }
        @{
            Stream = 'MDE_SmartScreenConfig_CL'
            Path = '/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Microsoft Defender SmartScreen aggregated web-threat report (impressions + block actions)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { TotalThreats:0, Phishing:0, Malicious:0, ..., UpdateTime: <iso> }
            # Property-bag of int counters + 1 datetime → Shape 3 flatten yields
            # 10 rows (one per counter + UpdateTime row). v0.1.0 GA:
            # FeatureName + Value (string, universal — operator parses int if needed).
            # Legacy per-counter cols preserved as v0.1.0 GA scope (always null).
            ProjectionMap = @{
                FeatureName     = '$tostring:EntityId'
                Value           = '$tostring:value'
                # Legacy v0.1.0 GA scope (always null with corrected Shape 3 handling):
                TotalThreats    = '$toint:TotalThreats'
                Phishing        = '$toint:Phishing'
                Malicious       = '$toint:Malicious'
                CustomIndicator = '$toint:CustomIndicator'
                Exploit         = '$toint:Exploit'
                LastModifiedUtc = '$todatetime:UpdateTime'
            }
        }
        # pre-v0.1.0.9 (B4): ?useV2Api=true&useV3Api=true per Get-XdrEndpointConfigurationLiveResponse.ps1
        @{
            Stream = 'MDE_LiveResponseConfig_CL'
            Path = '/apiproxy/mtp/liveResponseApi/get_properties?useV2Api=true&useV3Api=true'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Live Response service properties + script-library config + tab-completion enablement'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { AutomatedIrLiveResponse: true, AutomatedIrUnsignedScripts: true, LiveResponseForServers: true }
            # Pure-bool property-bag → Shape 3 flatten yields 3 rows.
            # v0.1.0 GA: FeatureName + IsEnabled.
            # Legacy per-property cols preserved as v0.1.0 GA scope (always null).
            ProjectionMap = @{
                FeatureName                = '$tostring:EntityId'
                IsEnabled                  = '$tobool:value'
                # Legacy v0.1.0 GA scope (always null with corrected Shape 3 handling):
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
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Sense-auth posture (whether unauthenticated telemetry from Sense agent is accepted)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): scalar bool `true`.
            # Shape 4 → ONE row with EntityId='value', value=<bool>.
            # v0.1.0 GA: AllowNonAuthSense was redundant duplicate of IsEnabled
            # — preserved as v0.1.0 GA scope alias.
            ProjectionMap = @{
                FeatureName       = '$tostring:EntityId'
                IsEnabled         = '$tobool:value'
                AllowNonAuthSense = '$tobool:value'  # v0.1.0 GA scope alias of IsEnabled
            }
        }
        @{
            Stream = 'MDE_PUAConfig_CL'
            Path = '/apiproxy/mtp/autoIr/ui/properties/'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Potentially-Unwanted-Application enforcement scope (block / audit / off + per-platform)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { AutomatedIrPuaAsSuspicious: false, IsAutomatedIrContainDeviceEnabled: true }
            # Pure-bool property-bag → Shape 3 flatten yields 2 rows.
            # v0.1.0 GA: FeatureName + IsEnabled.
            # Legacy per-property cols preserved as v0.1.0 GA scope (always null).
            ProjectionMap = @{
                FeatureName                       = '$tostring:EntityId'
                IsEnabled                         = '$tobool:value'
                # Legacy v0.1.0 GA scope (always null with corrected Shape 3 handling):
                AutomatedIrPuaAsSuspicious        = '$tobool:AutomatedIrPuaAsSuspicious'
                IsAutomatedIrContainDeviceEnabled = '$tobool:IsAutomatedIrContainDeviceEnabled'
            }
        }
        # AntivirusPolicy + TenantAllowBlock: nodoc documents GET (not POST). Phase 2c live-captures; retag live if 200.
        @{
            Stream = 'MDE_AntivirusPolicy_CL'
            # Section R+++ nodoc-canonical fix (2026-05-07): platform query
            # param is REQUIRED per nodoc endpoint_configuration.yml:345-376.
            # Lab returned 400 'Platform filter is required and should have a
            # valid value.' Default to Windows (operator-preferred + most
            # common platform). PerPlatformFanout for Linux/macOS/iOS is
            # v0.1.0.1 work — see plan Architecture C.
            #
            # Section R+++++.2 KNOWN SCHEMA PARITY GAP (2026-05-07T15:30):
            # Live capture shows actual shape is `{ category: { antivirus:[],
            # edr:[], firewall:[], asr:[], diskEncryption:[] }, technologies:
            # ['mdm','mdm,microsoftSense'] }` (operator-side filter FACETS,
            # NOT policy bodies). Existing ProjectionMap cols (FilterName,
            # FilterValue, Platform, Scope, IsEnabled) DO NOT MAP to this
            # shape — they project to null. ProjectionResolution test fails
            # for this stream. Proper fix requires coordinated changes:
            #   (a) Update ProjectionMap to match actual shape
            #   (b) Update DCR streamDecl input cols in mainTemplate.json
            #   (c) Update Defender_EndpointConfiguration_CL workspace table
            #       cols + transformKql in mainTemplate.json
            # Tracked as O1 work item in plan R++++++ (5-stream ProjectionMap
            # canonical rewrites). Actual policy bodies (ASR rules + AV
            # settings + EDR config) are Phase 1 G7 MDE_SecurityPolicies_CL.
            Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters?platform=Windows'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'MEM-bridged antivirus policy filter facets (Intune + Configuration Manager scope)'
            Availability = 'live'
            # Fixture: tenant-gated (no live data). Convention: AV policy filter facets.
            ProjectionMap = @{
                FilterName    = '$tostring:Name'
                FilterValue   = '$tostring:Value'
                Platform      = '$tostring:Platform'
                Scope         = '$tostring:Scope'
                IsEnabled     = '$tobool:IsEnabled'
            }
        }

        # ====================================================================
        # G7 — MDE_SecurityPolicies_CL (Section R++++++ Phase 1)
        # POST endpoint returns ACTUAL POLICY BODIES (ASR rules + AV settings +
        # Account Protection + Disk Encryption + EDR + Firewall + Web Protection)
        # Per-platform per request body. Phase 1 baseline = Windows-only;
        # PerPlatformFanout (Architecture C) for Linux/macOS/iOS = Phase 2.
        # ====================================================================
        @{
            Stream = 'MDE_SecurityPolicies_CL'
            Path = '/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies'
            Method = 'POST'
            Body = @{
                platform = 'Windows'
            }
            # Section R++++++ Architecture C (2026-05-07): PerPlatformFanout enabled.
            # Activity (Xdr-PollStream) detects this field, iterates platforms, calls
            # Invoke-MDEEndpoint with -BodyOverride @{platform=$p} per platform, tags
            # each row with Platform col, aggregates into single MDE_SecurityPolicies_CL
            # stream. Operators query: Defender_EndpointConfiguration_CL
            #   | where SourceName == 'MDE_SecurityPolicies_CL' | where Platform == 'Linux'
            PerPlatformFanout = @('Windows', 'Linux', 'macOS', 'iOS')
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Actual Intune endpoint security POLICY BODIES (ASR rules + AV + Account Protection + Disk Encryption + EDR + Firewall + Web Protection) per platform'
            Availability = 'live'
            # nodoc canonical: endpoint_configuration.yml POST /securityPolicies
            # body { platform: 'Windows'|'Linux'|'macOS'|'iOS' }
            # Response wraps an array of policy objects. Best-guess shape:
            # { policies: [{ id, name, type, settings, ruleCount, lastModified }] }
            UnwrapProperty = 'policies'
            IdProperty = @('id', 'Id', 'policyId')
            ProjectionMap = @{
                PolicyId       = '$tostring:id'
                PolicyName     = '$tostring:name'
                PolicyType     = '$tostring:type'
                Platform       = '$tostring:platform'
                Status         = '$tostring:status'
                RuleCount      = '$toint:ruleCount'
                LastModified   = '$todatetime:lastModified'
            }
        }

        @{
            Stream = 'MDE_TenantAllowBlock_CL'
            # Section R++++++ F6 RESOLVED (2026-05-07T19:15Z): path swap to canonical
            # `/mtp/responseApiPortal/ti/indicators` per nodoc configuration.yml:1655.
            # Original `/papin/.../filterValues` returned 500 in lab tenant + only
            # provides UI filter dropdown facets (not indicator inventory). The new
            # canonical returns the ACTUAL custom threat indicators with full typed
            # schema documented in nodoc (NOT pending) — IndicatorId, IndicatorType,
            # IndicatorValue, IoaDefinitionId, CreationTime, CreatedBy, LastUpdateTime,
            # IsEnabled, Action, Severity, Title, Category, Description, Application,
            # GenerateAlert. Operator-valuable for TABL drift queries.
            Path = '/apiproxy/mtp/responseApiPortal/ti/indicators'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Tenant Allow-Block-List (TABL) custom threat indicators (URL/file/IP/cert) — indicator inventory'
            Availability = 'live'
            IdProperty = @('IndicatorId', 'indicatorId', 'Id', 'id')
            # Live response shape per nodoc configuration.yml:1655: array of
            # indicator objects (Shape 1). No UnwrapProperty needed — direct array.
            # Phase 1 GA: minimal ProjectionMap aligned to existing DCR/workspace
            # cols (additive-only schema preserved). v0.1.0.1 expansion can add
            # IndicatorValue/IsEnabled/Severity/GenerateAlert/etc.
            ProjectionMap = @{
                # Renamed from `Action` to disambiguate from MDE_SuppressionRules_CL.
                # nodoc Action is int; cast to string for col-type consistency.
                AllowBlockAction = '$tostring:Action'
                IndicatorType    = '$tostring:IndicatorType'
                CreatedBy        = '$tostring:CreatedBy'
                CreatedTime      = '$todatetime:CreationTime'   # nodoc field name = CreationTime
                ExpiryTime       = '$todatetime:LastUpdateTime'  # placeholder until ExpirationTime cols added
            }
        }

        # P0 — iter 13.8 path correction: was '/mdeCustomCollection/model' (returned 403),
        # now '/mdeCustomCollection/rules' per XDRInternals canonical source code.
        @{
            Stream = 'MDE_CustomCollection_CL'
            Path = '/apiproxy/mtp/mdeCustomCollection/rules'
            Tier = 'Inventory'
            Category = 'Endpoint Configuration'
            CategoryId = 2  # nodoc-authoritative (Phase D.1)
            Purpose = 'Custom event-collection rules (what extra MDE telemetry the tenant is gathering)'
            Availability = 'live'
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
            CategoryId = 10  # nodoc-authoritative (Phase D.1)
            Purpose = 'Streaming API configuration: which workspaces / event-hubs / storage receive exported MDE telemetry'
            AuditScope = 'hybrid'
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { @odata.context, value: [{ id, designatedTenantId, eventHubProperties,
            #   storageAccountProperties, workspaceProperties: { workspaceResourceId,
            #   subscriptionId, resourceGroup, name }, logs: [{ category, enabled }] }] }
            # v0.1.0 GA: added UnwrapProperty='value' (caught by ProjectionResolution gate).
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
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'OAuth + service-app inventory connected to the tenant Defender API surface'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object (NOT array
            # despite path suggesting "all"). One app per response in test tenant.
            # { Id, DisplayName, Enabled, LatestConnectivity, ApplicationSettingsLink, MonthlyStatistics:[int*] }.
            # v0.1.0 GA: SingleObjectAsRow=$true so per-row entity is the
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
            # Section R+: OrgId is the natural stable key (operators query by tenant
            # OrgId for cross-tenant audits). Without IdProperty override the auto-
            # heuristic falls to 'idx-0' which is a constant + meaningless for joins.
            IdProperty = @('OrgId', 'orgId', 'TenantId', 'tenantId')
            Category = 'Multi-Tenant Operations'
            CategoryId = 9  # nodoc-authoritative (Phase D.1)
            Purpose = 'Authenticated-tenant context: tenant ID, region, M365 sku, cross-tenant flags'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object with ~76 properties:
            # { EnvironmentName, OrgId, GeoRegion, DataCenter, AccountMode, AccountType,
            #   IsSuspended, IsMtpEligible, IsMdatpActive, IsSentinelActive, Features:{...},
            #   ActiveMtpWorkloads: [int*], ... }.
            # v0.1.0 GA: SingleObjectAsRow=$true forces ONE per-entity row
            # (operator-friendly), not 76 per-property rows. Per-row entity is the
            # whole tenant-context object — typed cols project from named fields.
            # NOTE: column is `MdeTenantId` (not `TenantId`) — `TenantId` is a Log Analytics
            # SYSTEM-RESERVED column auto-typed as `guid`; declaring our own clashes at DCR validation.
            # Legacy `TenantName` col preserved as v0.1.0 GA scope alias of EnvironmentName.
            ProjectionMap = @{
                MdeTenantId      = '$tostring:OrgId'
                TenantName       = '$tostring:EnvironmentName'  # v0.1.0 GA scope alias
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
            CategoryId = 9  # nodoc-authoritative (Phase D.1)
            Purpose = 'MTO tenant-group definitions + per-group workload (alerts/incidents/dashboards) state'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): single object representing
            # the tenant's MTO group: { entityType, name, tenantGroupId, type,
            # description, allTenantsCount, exposedTargetTenantsInfo,
            # creationTime, lastUpdated, lastUpdatedByUpn, tenantId }.
            # v0.1.0 GA: SingleObjectAsRow=$true so per-row entity is the
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
        # pre-v0.1.0.8 — DEPRECATED. Canonical surface is MDE_DataExportSettings_CL.
        @{
            Stream = 'MDE_StreamingApiConfig_CL'
            Path = '/apiproxy/mtp/streamingapi/streamingApiConfiguration'
            Tier = 'Maintenance'
            Category = 'Streaming API'
            CategoryId = 10  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Defender ↔ Intune connector status (link-state, last-handshake, scope enrolment)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): scalar int `0` (0 = not connected).
            # Shape 4 → ONE row with EntityId='value', value=<int>.
            # v0.1.0 GA: keep both Status (int) + IsEnabled (bool: 0=false / nonzero=true).
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
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Defender ↔ Purview alert-sharing toggle + per-domain scope'
            Availability = 'live'
            # Live response shape (corrected 2026-05-06 from operator screenshot):
            # actually returns `{value: false}` wrapper — NOT bare scalar as
            # earlier comment claimed. UnwrapProperty='value' opens the wrapper
            # to bare bool; the helper Shape 4 path then wraps the scalar back
            # to {value=<bool>} → one row with EntityId='value' + value typed col.
            # SingleObjectAsRow is mutually exclusive with UnwrapProperty
            # (validated by Manifest.Schema.Tests) — UnwrapProperty alone here.
            UnwrapProperty   = 'value'
            ProjectionMap = @{
                IsEnabled           = '$tobool:value'
                # v0.1.0 GA scope: AlertSharingEnabled retained as semantic alias
                # (operator audit queries reference both names historically).
                AlertSharingEnabled = '$tobool:value'
                # 3rd typed col required by Manifest.ProjectionMap.Populated invariant
                # (operators must have >=3 typed cols, not just RawJson).
                # FeatureName projects EntityId ('value' from the unwrap-then-wrap path)
                # — gives a stable label for operator queries.
                FeatureName         = '$tostring:EntityId'
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
            # Section R+: MachineGroupId is the natural stable key per item; without
            # IdProperty override the auto-heuristic falls through to 'idx-N' which
            # rotates with array order changes + breaks drift joins.
            IdProperty = @('MachineGroupId', 'machineGroupId', 'Id', 'id')
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
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
                # Section R++++++ O1 expansion (2026-05-07): full rule bodies for RBAC drift queries.
                GroupRules            = '$json:GroupRules'
            }
        }
        # pre-v0.1.0.9 (B3): nodoc-cited path; verified live 2026-04-28.
        @{
            Stream = 'MDE_UnifiedRbacRoles_CL'
            Path = '/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions'
            Tier = 'Configuration'
            UnwrapProperty = 'value'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Unified-RBAC role definitions: per-role permission bitmaps + assigned principals'
            Availability = 'live'
            # Live response shape (captured 2026-05-03): { value: [], isPartial: false }
            # — empty in test tenant. v0.1.0 GA: added UnwrapProperty='value'
            # (caught by ProjectionResolution gate). Per-row entity carries unified-RBAC
            # role-definition shape.
            ProjectionMap = @{
                RoleId        = '$tostring:id'
                Name          = '$tostring:displayName'
                IsBuiltIn     = '$tobool:isBuiltIn'
                CreatedTime   = '$todatetime:createdDateTime'
                ModifiedBy    = '$tostring:modifiedBy'
                # Renamed from `Scope` to disambiguate from MDE_SuppressionRules_CL.SuppressionScope (int).
                # See tests/arm/SchemaConsistency.Tests.ps1.
                RbacScope     = '$tostring:scope'
            }
        }
        @{
            Stream = 'MDE_AssetRules_CL'
            Path = '/apiproxy/mtp/xspmatlas/assetrules'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
                # Section R++++++ O1 expansion (2026-05-07): rule body + KQL query.
                KqlQuery             = '$tostring:kqlQuery'
                RuleDefinition       = '$json:ruleDefinition'
            }
        }
        @{
            Stream = 'MDE_SAClassification_CL'
            Path = '/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
        # v0.1.0 GA portal-only audit (2026-04-29): MDE_SecureScoreBreakdown_CL DROPPED
        # — Microsoft Graph /security/secureScores covers identical data with
        # identical shape. Operators should use the official Graph Security data
        # connector. See docs/STREAMS-REMOVED.md (when added in Phase 12).
        @{
            Stream = 'MDE_ExposureRecommendations_CL'
            Path = '/apiproxy/mtp/posture/oversight/recommendations'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
            Purpose = 'XSPM remediation recommendations (per-initiative actionable steps + criticality + effort)'
            Availability = 'live'
            # Live response shape (captured 2026-05-03 via XDR_DEBUG_RESPONSE_CAPTURE):
            # { results: [{ id, title, lastStateChange, lastStateUpdate, category, source,
            #   product, description, implementationStatus, severity, remediation, ... }] }
            UnwrapProperty = 'results'
            # Fixture: { results: [{ id, title, lastStateChange, lastStateUpdate, category, source, product, severity, implementationCost, userImpact, userAffected, currentState, mssControlState, isDisabled, score, maxScore, lastSynced }] }.
            ProjectionMap = @{
                RecommendationId   = '$tostring:id'
                Title              = '$tostring:title'
                Severity           = '$tostring:severity'
                Status             = '$tostring:currentState'
                Source             = '$tostring:source'
                Product            = '$tostring:product'
                Category           = '$tostring:category'
                ImplementationCost = '$tostring:implementationCost'
                UserImpact         = '$tostring:userImpact'
                IsDisabled         = '$tobool:isDisabled'
                Score              = '$todouble:score'
                MaxScore           = '$todouble:maxScore'
                LastSyncedUtc      = '$todatetime:lastSynced'
                # E1 enrichment 2026-05-08 (Plan R++++++++.1 P3): 5 high-value typed cols
                Description        = '$tostring:description'
                Remediation        = '$tostring:remediation'
                LastStateChange    = '$todatetime:lastStateChange'
                MssScoreImpact     = '$toint:mssScoreImpact'
                PointAchieved      = '$toint:pointAchieved'
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
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 6  # nodoc-authoritative (Phase D.1)
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
            # Section R+++++ path-drift fix (2026-05-07T15:00): legacy
            # /baseline/profiles?pageIndex=0&pageSize=25 returned 400 in lab
            # (live capture _capture-summary.json: HTTP 400 'Bad Request').
            # nodoc canonical confirmed at vulnerability_management.yml:556
            # (operationId VulnerabilityManagement.GetBaseline). Legacy path
            # was NOT in nodoc — the prior comment claiming XDRInternals
            # attestation was incorrect (XDRInternals uses nodoc as its
            # source per operator correction 2026-05-07T12:15). nodoc spec
            # at line 571 marks response schema as 'pending - baseline data'
            # so ProjectionMap below is best-guess preserved from prior;
            # will refine after first successful 200 capture.
            Path = '/apiproxy/mtp/tvm/analytics/vulnerabilities/baseline'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            # Section R++++++ Architecture F (2026-05-07): Pagination support.
            # TVM endpoints can return thousands of CVEs/products in production tenants;
            # default API page size is ~25-200 items. Loop pages until last page or
            # MaxPages cap. Per-page retry handled by Invoke-MDEPortalEndpoint's 429 logic.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3  # nodoc-authoritative (Phase D.1)
            Purpose = 'TVM security-baseline profile compliance (CIS / Microsoft baselines applied to device fleet)'
            Availability = 'live'
            # Per-row schema (best-guess; nodoc response 'pending'):
            #   { id (GUID), name, compliancePct, compliantDevices,
            #     nonCompliantDevices, lastModifiedDateTime, benchmarkName }.
            # `api-version: 1.0` header is mandatory (TVM API gate).
            # Runtime SuccessKind classifies 4xx as 'tenant-gated' if TVM
            # Premium license absent.
            UnwrapProperty = 'results'
            # NOTE: legacy `Compliance` column was typed `boolean` in v0.1.0-beta
            # initial DCR but the upstream API returns a percentage (real).
            # `CompliancePct` is the additive replacement; queries should migrate
            # to `CompliancePct` going forward (Compliance preserved for v0.1.0 GA scope).
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
                # Legacy v0.1.0 GA scope (always null with the corrected upstream shape):
                Compliance          = '$tobool:isCompliant'
                DeviceCount         = '$toint:assetsCount'
                LastScanUtc         = '$todatetime:lastUpdate'
                Score               = '$todouble:complianceScore'
            }
        }

        # ====================================================================
        # G8 — TVM expansion (Section R++++++ Phase 1 — 4 new streams)
        # All map to nodoc vulnerability_management.yml endpoints.
        # License-dependent (TvmPremium); runtime SuccessKind classifies 4xx
        # as 'tenant-gated' if license absent.
        # ====================================================================
        @{
            Stream = 'MDE_VulnerableMachines_CL'
            # nodoc canonical: vulnerability_management.yml /mtp/tvm/analytics/assets/topVulnerable
            Path = '/apiproxy/mtp/tvm/analytics/assets/topVulnerable'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            # Section R++++++ Architecture F (2026-05-07): Pagination support.
            # TVM endpoints can return thousands of CVEs/products in production tenants;
            # default API page size is ~25-200 items. Loop pages until last page or
            # MaxPages cap. Per-page retry handled by Invoke-MDEPortalEndpoint's 429 logic.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'Top-N CVE-exposed machines (TVM analytics — most-exposed devices ranked by exposure score)'
            Availability = 'live'
            UnwrapProperty = 'results'
            IdProperty = @('assetId', 'AssetId', 'id', 'Id')
            ProjectionMap = @{
                AssetId          = '$tostring:assetId'
                MachineName      = '$tostring:assetName'
                CveCount         = '$toint:totalVulnerabilities'
                CriticalCveCount = '$toint:criticalVulnerabilities'
                ExposureScore    = '$todouble:exposureScore'
                RiskScore        = '$tostring:riskScore'
                OsPlatform       = '$tostring:osPlatform'
            }
        }

        @{
            Stream = 'MDE_VulnerabilityInventory_CL'
            # nodoc canonical: vulnerability_management.yml /mtp/tvm/analytics/vulnerabilities
            Path = '/apiproxy/mtp/tvm/analytics/vulnerabilities'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            # Section R++++++ Architecture F (2026-05-07): Pagination support.
            # TVM endpoints can return thousands of CVEs/products in production tenants;
            # default API page size is ~25-200 items. Loop pages until last page or
            # MaxPages cap. Per-page retry handled by Invoke-MDEPortalEndpoint's 429 logic.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'CVE inventory — list of vulnerabilities affecting tenant assets with severity + prevalence'
            Availability = 'live'
            UnwrapProperty = 'results'
            IdProperty = @('cveId', 'CveId', 'id', 'Id')
            ProjectionMap = @{
                CveId          = '$tostring:cveId'
                Severity       = '$tostring:severity'
                CvssV3         = '$todouble:cvssV3'
                PublishedDate  = '$todatetime:publishedDate'
                AssetCount     = '$toint:assetsAffected'
                Description    = '$tostring:description'
                ProductName    = '$tostring:productName'
            }
        }

        @{
            Stream = 'MDE_SoftwareInventory_CL'
            # nodoc canonical: vulnerability_management.yml /mtp/tvm/analytics/products
            Path = '/apiproxy/mtp/tvm/analytics/products'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            # Section R++++++ Architecture F (2026-05-07): Pagination support.
            # TVM endpoints can return thousands of CVEs/products in production tenants;
            # default API page size is ~25-200 items. Loop pages until last page or
            # MaxPages cap. Per-page retry handled by Invoke-MDEPortalEndpoint's 429 logic.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'Software product inventory — installed software across tenant with vendor + vulnerability counts'
            Availability = 'live'
            UnwrapProperty = 'results'
            IdProperty = @('productId', 'ProductId', 'id', 'Id')
            ProjectionMap = @{
                ProductId           = '$tostring:productId'
                ProductName         = '$tostring:productName'
                Vendor              = '$tostring:vendor'
                AssetCount          = '$toint:assetsCount'
                VulnerabilityCount  = '$toint:vulnerabilityCount'
                WeaknessCount       = '$toint:weaknessCount'
            }
        }

        @{
            Stream = 'MDE_RecommendationActions_CL'
            # nodoc canonical: vulnerability_management.yml /mtp/tvm/analytics/remediations OR /mtp/tvm/remediation-tasks/remediationTasks
            Path = '/apiproxy/mtp/tvm/remediation-tasks/remediationTasks'
            Tier = 'Inventory'
            Headers = @{ 'api-version' = '1.0' }
            # Section R++++++ Architecture F (2026-05-07): Pagination support.
            # TVM endpoints can return thousands of CVEs/products in production tenants;
            # default API page size is ~25-200 items. Loop pages until last page or
            # MaxPages cap. Per-page retry handled by Invoke-MDEPortalEndpoint's 429 logic.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'Remediation recommendation actions — actionable security improvements with severity + asset count'
            Availability = 'live'
            UnwrapProperty = 'results'
            IdProperty = @('remediationTaskId', 'RemediationTaskId', 'id', 'Id')
            ProjectionMap = @{
                RemediationTaskId = '$tostring:remediationTaskId'
                Title             = '$tostring:title'
                Status            = '$tostring:status'
                Priority          = '$tostring:priority'
                AssetCount         = '$toint:targetAssets'
                CreatedDate       = '$todatetime:createdOn'
                DueDate           = '$todatetime:dueOn'
            }
        }

        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_IdentityOnboarding_CL'
            Path = '/apiproxy/mtp/siamApi/domaincontrollers/list'
            Tier = 'Inventory'
            UnwrapProperty = 'DomainControllers'
            Category = 'Identity Protection (MDI)'
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
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

        # ----------------------------------------------------------------------
        # Phase 2 batch 7 (Plan R++++++++++ Tier A 2026-05-09): MDE_VulnerabilityAssetCountByExposure_CL
        # — TVM device distribution by exposure level (Low/Medium/High/Critical).
        # Per nodoc vulnerability_management.yml VulnerabilityManagement.GetAssetCountByExposureLevel.
        # Array of objects {exposureLevel, assetCount}.
        # TvmPremium license required.
        # Operator value: SOC at-a-glance device exposure distribution for executive
        # dashboards + risk-prioritization (which exposure tier dominates fleet).
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_VulnerabilityAssetCountByExposure_CL'
            Path = '/apiproxy/mtp/tvm/analytics/assets/countByExposureLevel'
            Tier = 'Inventory'
            IdProperty = @('exposureLevel', 'ExposureLevel', 'Id', 'id')
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'TVM device distribution by exposure level - SOC dashboard fleet exposure tier breakdown for risk-prioritization'
            Availability = 'live'
            RequiresLicense    = @('TvmPremium')
            TenantContextProbe = 'IsMdatpActive'
            ProjectionMap = @{
                ExposureLevel  = '$tostring:exposureLevel'
                AssetCount     = '$toint:assetCount'
                CaptureTime    = '$todatetime:captureTime'
                ReportPeriod   = '$tostring:reportPeriod'
            }
        }

        # ----------------------------------------------------------------------
        # Phase 2 batch 6 (Plan R++++++++++ Tier A 2026-05-09): MDE_VulnerabilityExtensions_CL
        # — TVM browser extension inventory across endpoint devices (shadow-IT detection).
        # Per nodoc vulnerability_management.yml VulnerabilityManagement.ListExtensions.
        # Paginated GET (PaginatedListResponse + data: [extension items]).
        # TvmPremium license required.
        # Operator value: shadow-IT detection - which browser extensions across the fleet
        # may pose data-exfiltration / supply-chain risk.
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_VulnerabilityExtensions_CL'
            Path = '/apiproxy/mtp/tvm/analytics/extensions?pageIndex=0&pageSize=200'
            Tier = 'Inventory'
            UnwrapProperty = 'data'
            IdProperty = @('extensionId', 'Id', 'id')
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'TVM browser extension inventory - shadow-IT detection across endpoint devices for data-exfiltration / supply-chain risk audit'
            Availability = 'live'
            RequiresLicense    = @('TvmPremium')
            TenantContextProbe = 'IsMdatpActive'
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            ProjectionMap = @{
                ExtensionId          = '$tostring:extensionId'
                Name                 = '$tostring:name'
                Version              = '$tostring:version'
                Browser              = '$tostring:browser'
                Publisher            = '$tostring:publisher'
                AffectedDevicesCount = '$toint:affectedDevicesCount'
                IsManaged            = '$tobool:isManaged'
            }
        }

        # ----------------------------------------------------------------------
        # Phase 2 batch 5 (Plan R++++++++++ Tier A 2026-05-09): MDE_VulnerabilitySummary_CL
        # — TVM aggregate severity/exposure counts across the organization.
        # Per nodoc vulnerability_management.yml VulnerabilityManagement.GetSummary.
        # Single-object response (severity counts + exposure level breakdown).
        # TvmPremium license required.
        # Operator value: SOC at-a-glance vulnerability posture (high/medium/low/critical
        # counts) for executive dashboards + trending.
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_VulnerabilitySummary_CL'
            Path = '/apiproxy/mtp/tvm/analytics/vulnerabilities/summary'
            Tier = 'Inventory'
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'TVM aggregate severity/exposure counts - SOC at-a-glance vulnerability posture for executive dashboards + trending'
            Availability = 'live'
            RequiresLicense    = @('TvmPremium')
            TenantContextProbe = 'IsMdatpActive'
            SingleObjectAsRow  = $true
            SyntheticEntityId  = 'tvm-vulnerability-summary-singleton'
            ProjectionMap = @{
                CriticalCount    = '$toint:critical'
                HighCount        = '$toint:high'
                MediumCount      = '$toint:medium'
                LowCount         = '$toint:low'
                TotalCount       = '$toint:total'
                ExposureScore    = '$todouble:exposureScore'
                CaptureTime      = '$todatetime:captureTime'
            }
        }

        # ----------------------------------------------------------------------
        # Phase 2 batch 4 (Plan R++++++++++ Tier A 2026-05-09): MDE_VulnerabilityCertificates_CL
        # — TVM certificate inventory: per-cert metadata across endpoint devices
        # incl. expiration status + cryptographic algorithm + affected-device count.
        # Per nodoc vulnerability_management.yml VulnerabilityManagement.ListCertificates.
        # TvmPremium license required (lab returned 400 - all-live policy + runtime
        # SuccessKind classifies dynamically per actual customer).
        # Operator value: certificate expiration inventory for compliance/audit;
        # distinct from existing TVM streams (focus on cert lifecycle vs vulnerability CVEs).
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_VulnerabilityCertificates_CL'
            Path = '/apiproxy/mtp/tvm/analytics/certificates?pageIndex=0&pageSize=200'
            Tier = 'Inventory'
            UnwrapProperty = 'data'
            IdProperty = @('certificateId', 'thumbprint', 'Id', 'id')
            Category = 'Vulnerability Management (TVM)'
            CategoryId = 3
            Purpose = 'TVM certificate inventory - per-cert metadata + expiration status + cryptographic algorithm + affected-device count for compliance/audit'
            Availability = 'live'
            RequiresLicense    = @('TvmPremium')
            TenantContextProbe = 'IsMdatpActive'
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50
            }
            ProjectionMap = @{
                CertificateId        = '$tostring:certificateId'
                Subject              = '$tostring:subject'
                Issuer               = '$tostring:issuer'
                Thumbprint           = '$tostring:thumbprint'
                ExpirationDate       = '$todatetime:expirationDate'
                AlgorithmName        = '$tostring:algorithmName'
                AffectedDevicesCount = '$toint:affectedDevicesCount'
                IsExpired            = '$tobool:isExpired'
            }
        }

        # ----------------------------------------------------------------------
        # Phase 2 batch 3 (Plan R++++++++++ Tier A 2026-05-09): MDE_IdentityLateralMovementPaths_CL
        # — MDI risky lateral-movement-path prevalence delta. Counts newly-surfaced
        # risky-LMP findings since previous poll. Same {Count, IsCountExceeded}
        # response shape as IdentityDormantAccounts.
        # XspmGraph tier (1h cadence) - attack-path intelligence is XSPM-class
        # operator-value (high-value chokepoints + lateral-movement risk trending).
        # MDI license required (lab returned 404 - all-live policy).
        # Per nodoc identity.yml Identity.GetRiskyLateralMovementPathNewEntryCount.
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_IdentityLateralMovementPaths_CL'
            Path = '/apiproxy/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount'
            Tier = 'XspmGraph'
            Category = 'Identity Protection (MDI)'
            CategoryId = 4
            Purpose = 'MDI risky lateral-movement-path prevalence delta - XSPM-class attack-path trending for SOC chokepoint analysis'
            Availability = 'live'
            RequiresLicense    = @('MDI')
            TenantContextProbe = 'IsMdiActive'
            SingleObjectAsRow  = $true
            SyntheticEntityId  = 'identity-lmp-singleton'
            ProjectionMap = @{
                NewEntryCount    = '$toint:Count'
                IsCountExceeded  = '$tobool:IsCountExceeded'
                CaptureTime      = '$todatetime:CaptureTime'
                ReportPeriod     = '$tostring:ReportPeriod'
            }
        }

        # ----------------------------------------------------------------------
        # Phase 2 batch 2 (Plan R++++++++++ Tier A 2026-05-09): MDE_IdentityDormantAccounts_CL
        # — Identity Protection hygiene posture delta. Counts newly-surfaced dormant
        # entity report entries since the previous poll cycle.
        # Per nodoc identity.yml Identity.GetDormantEntitiesNewEntryCount —
        # response shape: {Count: int, IsCountExceeded: bool}.
        # MDI license required (lab returned 404 - all-live policy + runtime
        # SuccessKind classifies per actual customer deployment).
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_IdentityDormantAccounts_CL'
            Path = '/apiproxy/aatp/api/ispmReports/DormantEntities/newEntryCount'
            Tier = 'Configuration'
            Category = 'Identity Protection (MDI)'
            CategoryId = 4
            Purpose = 'MDI identity hygiene posture - count of newly-surfaced dormant entity findings (delta since last poll for trending)'
            Availability = 'live'
            RequiresLicense    = @('MDI')
            TenantContextProbe = 'IsMdiActive'
            # Single-object response with no natural ID - synthetic singleton key
            # so per-poll snapshots cluster cleanly for drift detection.
            SingleObjectAsRow  = $true
            SyntheticEntityId  = 'identity-dormant-accounts-singleton'
            # ProjectionMap >=3 entries per Manifest.Schema gate. Live nodoc schema
            # has only 2 fields (Count + IsCountExceeded) - forward-compat fields
            # added for likely future enrichment (MDI dormant-entity reports may
            # gain CaptureTime + ReportPeriod cols when MDI surface evolves).
            # Operators query RawJson for full response shape until live data arrives.
            ProjectionMap = @{
                NewEntryCount    = '$toint:Count'
                IsCountExceeded  = '$tobool:IsCountExceeded'
                CaptureTime      = '$todatetime:CaptureTime'
                ReportPeriod     = '$tostring:ReportPeriod'
            }
        }

        # P5 tenant-gated — MDI sensors not deployed in test tenant
        @{
            Stream = 'MDE_DCCoverage_CL'
            Path = '/apiproxy/aatp/api/sensors/domainControllerCoverage'
            Tier = 'Inventory'
            Category = 'Identity Protection (MDI)'
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI sensor coverage per domain controller (which DCs have working sensors / sync state)'
            Availability = 'live'
            # Section R++.2 forward-compat: when tenant has MDI, orchestrator
            # probes MDE_TenantContext_CL.IsMdiActive to short-circuit polls.
            RequiresLicense    = @('MDI')
            TenantContextProbe = 'IsMdiActive'
            # Section R++.B W11: DC name is the natural stable key. Without
            # IdProperty override, falls to idx-N when MDI lights up — making
            # cross-snapshot drift joins meaningless.
            IdProperty = @('Name', 'DCName', 'Domain', 'Id')
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
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI alert-threshold tuning per detection (when each MDI rule fires + temporary overrides)'
            Availability = 'live'
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
                # Legacy v0.1.0 GA scope (always null with the corrected upstream shape):
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
            CategoryId = 4  # nodoc-authoritative (Phase D.1)
            Purpose = 'MDI gMSA remediation-action configuration (which managed-service-accounts MDI uses for password resets)'
            Availability = 'live'
            RequiresLicense    = @('MDI')
            TenantContextProbe = 'IsMdiActive'
            # Section R++.B W11: gMSA UPN is the natural stable key.
            IdProperty = @('GmsaAccount', 'AccountUpn', 'Domain', 'Id')
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
        # v0.1.0 GA: UnwrapProperty='Results' + IdProperty=@('ActionId') fixes
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
            CategoryId = 8  # nodoc-authoritative (Phase D.1)
            Purpose = 'Action Center history — every cross-workload remediation action (block/quarantine/investigation) with operator + status'
            Availability = 'live'
            # Pagination: nodoc action_center.yml documents pageIndex/pageSize support
            # but operator directive "verify live, don't trust nodoc/openapi alone".
            # PENDING live test: manually invoke with pageIndex=2 in production
            # tenant + verify response differs from pageIndex=1 + no duplicates.
            # If verified, add Pagination = @{ Style='pageIndex'; PageSize=50; MaxPages=100 }
            # Currently relies on Filter='fromDate' + checkpoint to bound row count
            # per poll cycle (delta semantics; no need to backfill all history).
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
        # ----------------------------------------------------------------------
        # Phase 2 Tier A (Plan R++++++++++ 2026-05-09): MDE_PendingActions_CL
        # — pending Action Center actions awaiting approval/execution. Live-tested
        # 200 OK in lab tenant Phase 0 (`tools/Capture-EndpointSchemas.ps1` ran
        # 2026-05-08 against test tenant — 0 rows returned at capture time but path
        # confirmed valid; schema from nodoc action_center.yml ActionCenterItem).
        # Operator value: AIR/LR action queue backlog visibility — distinct from
        # MDE_ActionCenter_CL which captures completed history actions.
        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_PendingActions_CL'
            Path = '/apiproxy/mtp/actionCenter/actioncenterui/pending-actions'
            Tier = 'ActionCenter'
            # UnwrapProperty='Results' matches the actual lab live-tested response shape
            # `{Count: N, Results: [...]}` — same pattern as MDE_ActionCenter_CL history-actions.
            # nodoc action_center.yml declares `actions` but real API returns `Results` (nodoc
            # is research-grade, not authoritative; live shape wins per AMEND-1 #1).
            UnwrapProperty = 'Results'
            IdProperty = @('actionId', 'ActionId', 'Id', 'id')
            Category = 'Action Center'
            CategoryId = 8
            Purpose = 'AIR/LR action queue backlog — pending response actions awaiting operator approval (block/quarantine/investigation queue depth + age)'
            Availability = 'live'
            # Schema: ActionCenterItem per nodoc action_center.yml ActionCenter.GetPending response
            # (allOf: PaginatedListResponse + { actions: [ActionCenterItem] }).
            ProjectionMap = @{
                ActionId            = '$tostring:actionId'
                ActionType          = '$tostring:actionType'
                Status              = '$tostring:status'
                EntityType          = '$tostring:entityType'
                EntityName          = '$tostring:entityName'
                InvestigationId     = '$tostring:investigationId'
                CreatedBy           = '$tostring:createdBy'
                CreatedDateTime     = '$todatetime:createdDateTime'
                CompletedDateTime   = '$todatetime:completedDateTime'
            }
        }
        @{
            Stream = 'MDE_ThreatAnalytics_CL'
            Path = '/apiproxy/mtp/threatAnalytics/outbreaks'
            Tier = 'Configuration'
            Filter = 'fromDate'
            Category = 'Threat Analytics'
            CategoryId = 7  # nodoc-authoritative (Phase D.1)
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
                # NORMALIZED to dynamic for consolidated-table compatibility:
                # Defender_ThreatAnalytics_CL.Tags is shared with
                # MDE_ThreatAnalyticsEnriched_CL.Tags (dynamic, JSON array).
                # All writers must agree. See tests/arm/SchemaConsistency.Tests.ps1.
                Tags           = '$json:Tags'
                Keywords       = '$json:Keywords'
                IsVNext        = '$tobool:IsVNext'
            }
        }

        # ----------------------------------------------------------------------
        @{
            Stream = 'MDE_UserPreferences_CL'
            Path = '/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference'
            Tier = 'Configuration'
            SingleObjectAsRow = $true
            # Section R++.B B10: synthetic stable EntityId — SingleObjectAsRow
            # without natural id falls to 'idx-0'. 'user-preferences-singleton'
            # gives drift snapshots a stable join key.
            IdProperty = @('__synthetic__')
            SyntheticEntityId = 'user-preferences-singleton'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-analyst portal preferences (homepage layout, default filters) — drift detector for shared accounts'
            # Section R++.B9-REVERT (2026-05-07): live audit against tenant
            # 45f52f35 with SP context returns 200 + data — endpoint is NOT
            # delegated-auth-only as assumed. Reverted to live.
            Availability = 'live'
            # Live response shape (captured 2026-05-03):
            # { user_preferences: "<JSON-string of operator's saved preferences>" }
            # v0.1.0 GA: SingleObjectAsRow=$true → ONE row per response;
            # the user_preferences JSON-string is preserved as both a typed col
            # (UserPreferencesJson) AND in RawJson for forensic queries. Operators
            # can drill into the inner JSON via parse_json(UserPreferencesJson).
            # Legacy cols preserved as v0.1.0 GA scope (always null with corrected handling).
            ProjectionMap = @{
                UserPreferencesJson = '$tostring:user_preferences'
                # Legacy v0.1.0 GA scope (always null with SingleObjectAsRow):
                SettingId           = '$tostring:EntityId'
                Name                = '$tostring:Name'
                IsEnabled           = '$tobool:IsEnabled'
                CreatedTime         = '$todatetime:CreatedTime'
                CreatedBy           = '$tostring:CreatedBy'
                # Renamed from `Scope` to disambiguate from MDE_SuppressionRules_CL.SuppressionScope (int)
                # and MDE_UnifiedRbacRoles_CL.RbacScope (string).
                # See tests/arm/SchemaConsistency.Tests.ps1.
                PreferenceScope     = '$tostring:Scope'
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
            CategoryId = 9  # nodoc-authoritative (Phase D.1)
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
            CategoryId = 1  # nodoc-authoritative (Phase D.1)
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

        # ====================================================================
        # MDE_Machines_CL — Architecture B foundation stream (Section R++++++ Phase 1)
        # Per nodoc endpoint_devices.yml:2-66 (operationId EndpointDevices.List).
        # Device inventory base; foundation for Architecture A PerEntityFanout
        # (per-machine DeviceTimeline + future per-machine drill-down streams).
        # Pagination params per nodoc default (pageIndex=1, pageSize=200).
        # In production-scale tenants Architecture F adds full pagination loop;
        # for v0.1.0 GA Phase 1 baseline we cap at first page (200 most-recent
        # devices ranked by riskscore desc — covers high-priority devices first).
        # ====================================================================
        @{
            Stream = 'MDE_Machines_CL'
            Path = '/apiproxy/mtp/ndr/machines?hideLowFidelityDevices=true&lookingBackIndays=30&sortByField=riskscore&sortOrder=Descending'
            Tier = 'Inventory'
            Category = 'Endpoint Device Management'
            CategoryId = 1  # nodoc-authoritative (Phase D.1)
            Purpose = 'Device inventory base — per-MachineId metadata for SOC drill-down + foundation for PerEntityFanout (Architecture A)'
            Availability = 'live'
            # Section R++++++ Phase 1+ fix (2026-05-08): added Pagination so large
            # tenants (>200 machines) capture full inventory. Previously path had
            # pageIndex=1&pageSize=200 hardcoded; activity got first 200 + silently
            # truncated. With Architecture F pagination loop, activity iterates
            # pageIndex=1..MaxPages until empty page returned, aggregating rows.
            Pagination = @{
                Style    = 'pageIndex'
                PageSize = 200
                MaxPages = 50    # 50 × 200 = 10K machines (tenant guardrail)
            }
            # nodoc operationId EndpointDevices.List response shape includes:
            #   { items: [{ machineId, computerDnsName, osPlatform, osVersion,
            #               healthStatus, riskScore, exposureLevel, lastSeen,
            #               firstSeen, machineTags, ipAddresses }] }
            # IdProperty per nodoc machine identifier convention.
            UnwrapProperty = 'items'
            IdProperty = @('machineId', 'MachineId', 'id', 'Id')
            ProjectionMap = @{
                MachineId        = '$tostring:machineId'
                ComputerDnsName  = '$tostring:computerDnsName'
                OsPlatform       = '$tostring:osPlatform'
                OsVersion        = '$tostring:osVersion'
                HealthStatus     = '$tostring:healthStatus'
                RiskScore        = '$tostring:riskScore'
                ExposureLevel    = '$tostring:exposureLevel'
                LastSeen         = '$todatetime:lastSeen'
                FirstSeen        = '$todatetime:firstSeen'
            }
        }

        @{
            Stream = 'MDE_CloudAppsConfig_CL'
            # Section R+++ nodoc-canonical fix (2026-05-07): trailing slash
            # caused MCAS gateway 500 (URL-routing front-door choked on empty
            # segment after /). nodoc canonical = /mcas/cas/api/v1/settings
            # (no trailing slash) per cloud_apps.yml:222 + openapi.yml:970.
            Path = '/apiproxy/mcas/cas/api/v1/settings'
            Tier = 'Configuration'
            Category = 'Configuration and Settings'
            CategoryId = 5  # nodoc-authoritative (Phase D.1)
            Purpose = 'MCAS / Defender for Cloud Apps general settings (regions, integrations, notification policy)'
            Availability = 'live'
            RequiresLicense    = @('MCAS')
            TenantContextProbe = 'IsOatpActive'
            # Section R++.B W12: MCAS settings is a SINGLE OBJECT response, not
            # a property-bag. Was emitting Shape-3 (per-property rows) under the
            # old config — fix to SingleObjectAsRow + synthetic stable key.
            SingleObjectAsRow = $true
            IdProperty = @('__synthetic__')
            SyntheticEntityId = 'mcas-settings-singleton'
            # Fixture: tenant-gated (no MCAS). Convention: MCAS settings single object.
            ProjectionMap = @{
                Region       = '$tostring:Region'
                IsEnabled    = '$tobool:IsEnabled'
                CreatedTime  = '$todatetime:CreatedTime'
                ModifiedBy   = '$tostring:ModifiedBy'
                SettingId    = '$tostring:EntityId'
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
            # Section R++++++ Architecture A (2026-05-07): canonical per-machine
            # endpoint per nodoc endpoint_devices.yml:1042-1148. Activity-level
            # PerEntityFanout: source MDE_Machines_CL (Architecture B foundation),
            # iterate machineIds, call canonical path with {MachineId} substitution,
            # aggregate rows. Composite per-entity checkpoint key {Stream}|{MachineId}.
            Path = '/apiproxy/mtp/mdeTimelineExperience/machines/{MachineId}/events'
            Method = 'GET'
            PathParams = @('MachineId')
            PerEntityFanout = @{
                # Source stream provides the entity list (machineIds to iterate)
                Source                  = 'MDE_Machines_CL'
                # Field name in source stream rows that supplies the entity ID
                EntityIdField           = 'machineId'
                # Path placeholder filled per-entity
                PathParam               = 'MachineId'
                # Cap per-cycle to avoid 429-storms in 10K-machine tenants
                MaxEntitiesPerCycle     = 50
                # Composite checkpoint key per entity (so per-machine resume works)
                CheckpointPerEntity     = $true
            }
            Tier = 'ActionCenter'
            Filter = 'fromDate'
            Category = 'Endpoint Device Management'
            CategoryId = 1  # nodoc-authoritative (Phase D.1)
            Purpose = 'Per-device unified timeline (process/file/network/registry events with portal-side correlation + grouping) — SECURITY-EVENT 10-min cadence'
            UnwrapProperty = 'events'
            IdProperty = @('eventId', 'EventId', 'id', 'Id')
            Availability = 'live'
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
        # F1 decision 2026-05-08 (v0.1.0 GA): MDE_MachineActions_CL REMOVED from
        # manifest. Legacy XDRInternals path /apiproxy/mtp/responseApiPortal/
        # machineactions returned 404. The canonical surface is the same
        # /mtp/actionCenter/actioncenterui/history-actions endpoint that
        # MDE_ActionCenter_CL already polls successfully (10K+ rows live).
        # Action records (LR per-step output + AIR linkage) are in
        # MDE_ActionCenter_CL.RawJson. Operators filter by ActionType:
        #   Defender_ActionCenter_CL | where ActionType in (
        #     'IsolateResponse', 'UnIsolateResponse', 'AntivirusScanResponse',
        #     'CollectInvestigationPackageResponse', 'LiveResponse*', ...)
        # No separate stream needed. Lab-tenant breakdown:
        #   IsolateResponse: 692 / UnIsolateResponse: 692 /
        #   AntivirusScanResponse: 1384 / CollectInvestigationPackageResponse: 7612

        # ====================================================================
        # Phase 2 (v0.1.0 GA) — 17 NEW Tier A streams from nodoc catalog sweep
        # Wisely selected: dropped per-entity drilldowns + scalar counts.
        # All snapshot — drift parsers detect changes. ProjectionMaps minimal
        # at capture time; refined post-fixture-capture per actual response shape.
        # ====================================================================

        # ---- ConfigurationAndSettings (1) ----------------------------------
        @{
            Stream = 'MDE_AssetClassificationSchema_CL'
            Path = '/apiproxy/mtp/xspmatlas/assetrules/querybuilder/schema'
            Tier = 'XspmGraph'
            Category = 'Configuration and Settings'
            CategoryId = 5
            Purpose = 'Critical-asset classification schema (operator-defined query DSL for asset criticality rules)'
            Availability = 'live'
            UnwrapProperty = 'schema'
            # Fixture: { schema: [{ assetType, properties: [{ name, propertyType }] }] }
            # IdProperty override: array items have NO id/name top-level key —
            # heuristic at _EndpointHelpers.ps1:238-245 falls through to 'idx-N'
            # without this override. assetType is the natural-stable key
            # ('Devices' / 'Identities' / 'CloudResources').
            # Live evidence (operator screenshot 2026-05-06): EntityId='idx-0/1/2'
            # made cross-snapshot drift joins meaningless.
            IdProperty = @('assetType')
            ProjectionMap = @{
                AssetType     = '$tostring:assetType'
                Properties    = '$json:properties'
                PropertyCount = '$toint:properties.length'
            }
        }

        # ---- ExposureManagement / XSPM (11) --------------------------------
        @{
            Stream = 'MDE_PostureInitiativesSummarized_CL'
            Path = '/apiproxy/mtp/posture/oversight/initiatives/summarized'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Summary of all posture-management initiatives (KPIs, completion%, owner)'
            Availability = 'live'
            UnwrapProperty = 'results'
            # Fixture (empty in test tenant): { results: [], recordsCount: 0 }
            # Per-row schema per nodoc: id, name, completionPercentage, owner, startDate, endDate, status
            ProjectionMap = @{
                InitiativeId         = '$tostring:id'
                Name                 = '$tostring:name'
                CompletionPercentage = '$todouble:completionPercentage'
                Status               = '$tostring:status'
            }
        }
        @{
            Stream = 'MDE_PostureMetrics_CL'
            Path = '/apiproxy/mtp/posture/oversight/metrics'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'List of available posture-oversight metrics catalog'
            Availability = 'live'
            UnwrapProperty = 'results'
            # Fixture: { results: [{ id, version, name, category, latestCount, latestTotal, latestValue, sentimentType, weight, recommendations[], workloads[] }] }
            ProjectionMap = @{
                MetricId       = '$tostring:id'
                MetricName     = '$tostring:name'
                Category       = '$tostring:category'
                LatestCount    = '$todouble:latestCount'
                LatestTotal    = '$todouble:latestTotal'
                LatestValue    = '$todouble:latestValue'
                SentimentType  = '$tostring:sentimentType'
                Weight         = '$todouble:weight'
            }
        }
        @{
            Stream = 'MDE_AppsSecureScore_CL'
            Path = '/apiproxy/mtp/posture/oversight/metrics/category_apps_secure_score'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'SaaS apps secure-score metric (per-category posture)'
            Availability = 'live'
            SingleObjectAsRow = $true
            # Section R+++++.2 Section D fix (2026-05-07T15:00): SyntheticEntityId
            # required because SingleObjectAsRow=true with no IdProperty falls
            # to idx-0 fallback — drift-join queries broken across polls.
            SyntheticEntityId = 'apps-secure-score-singleton'
            # Fixture: SINGLE OBJECT { id, version, name, category, latestCount, latestTotal, latestValue, sentimentType, weight }
            ProjectionMap = @{
                MetricId      = '$tostring:id'
                MetricName    = '$tostring:name'
                Category      = '$tostring:category'
                LatestCount   = '$todouble:latestCount'
                LatestTotal   = '$todouble:latestTotal'
                LatestValue   = '$todouble:latestValue'
                SentimentType = '$tostring:sentimentType'
            }
        }
        @{
            Stream = 'MDE_DataSecureScore_CL'
            Path = '/apiproxy/mtp/posture/oversight/metrics/category_data_secure_score'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Data secure-score metric (per-category posture)'
            Availability = 'live'
            SingleObjectAsRow = $true
            # Section R+++++.2 Section D fix (2026-05-07T15:00): SyntheticEntityId.
            SyntheticEntityId = 'data-secure-score-singleton'
            ProjectionMap = @{
                MetricId      = '$tostring:id'
                MetricName    = '$tostring:name'
                Category      = '$tostring:category'
                LatestCount   = '$todouble:latestCount'
                LatestTotal   = '$todouble:latestTotal'
                LatestValue   = '$todouble:latestValue'
                SentimentType = '$tostring:sentimentType'
            }
        }
        @{
            Stream = 'MDE_IdentitySecureScore_CL'
            Path = '/apiproxy/mtp/posture/oversight/metrics/category_identity_secure_score'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Identity secure-score metric (per-category posture)'
            Availability = 'live'
            SingleObjectAsRow = $true
            # Section R+++++.2 Section D fix (2026-05-07T15:00): SyntheticEntityId.
            SyntheticEntityId = 'identity-secure-score-singleton'
            ProjectionMap = @{
                MetricId      = '$tostring:id'
                MetricName    = '$tostring:name'
                Category      = '$tostring:category'
                LatestCount   = '$todouble:latestCount'
                LatestTotal   = '$todouble:latestTotal'
                LatestValue   = '$todouble:latestValue'
                SentimentType = '$tostring:sentimentType'
            }
        }
        # MDE_IdentitySecureScore_CL — moved earlier in file (duplicate avoided)
        # MDE_PostureRecommendationsAggregated_CL DROPPED — nodoc spec notes
        # "Bundle-discovered; direct GET probing returns 500 without page-specific
        # parameters". Not pollable as a snapshot stream. Defer to v0.1.1 if/when
        # the contextual params can be discovered.
        @{
            Stream = 'MDE_PostureSecurityEvents_CL'
            Path = '/apiproxy/mtp/posture/oversight/securityEvents'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Posture security events stream (configuration changes affecting posture)'
            Availability = 'live'
            UnwrapProperty = 'results'
            # Fixture: { results: [{ id, eventType, eventTime, tenantId, isGlobal, createdTimestamp, properties: { resourceId, resourceType, driftStartTime, driftEndTime, driftPercentage, resourceName } }] }
            ProjectionMap = @{
                EventId          = '$tostring:id'
                EventType        = '$tostring:eventType'
                EventTime        = '$todatetime:eventTime'
                CreatedTimestamp = '$todatetime:createdTimestamp'
                IsGlobal         = '$tobool:isGlobal'
                Properties       = '$json:properties'
            }
        }
        @{
            Stream = 'MDE_PostureTenants_CL'
            Path = '/apiproxy/mtp/posture/oversight/tenants'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Posture-oversight tenant configuration (per-tenant onboarding state)'
            Availability = 'live'
            SingleObjectAsRow = $true
            # Section R+++++.2 Section D fix (2026-05-07T15:00): SyntheticEntityId.
            # Note: orgId IS available in fixture and would be a more natural
            # IdProperty — but for cross-tenant deployments orgId varies, so
            # singleton synthetic key keeps drift-joins stable per tenant.
            SyntheticEntityId = 'posture-tenants-singleton'
            # Fixture: SINGLE OBJECT { orgId, tenantId, geoRegion, dataCenter, mpsDataCenter, mpsSliceId, oversightSliceId, lastUpdated, featureFlags: {...} }
            ProjectionMap = @{
                OrgId            = '$tostring:orgId'
                GeoRegion        = '$tostring:geoRegion'
                DataCenter       = '$tostring:dataCenter'
                MpsDataCenter    = '$tostring:mpsDataCenter'
                MpsSliceId       = '$toint:mpsSliceId'
                OversightSliceId = '$toint:oversightSliceId'
                LastUpdated      = '$todatetime:lastUpdated'
                FeatureFlags     = '$json:featureFlags'
            }
        }
        @{
            Stream = 'MDE_AttackSurfaceAttackPaths_CL'
            Path = '/apiproxy/mtp/xspmatlas/attacksurface/attackpaths'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Attack-surface attack paths list (XSPM analytical paths, distinct from existing XspmAttackPaths_CL graph view)'
            Availability = 'live'
            UnwrapProperty = 'Records'
            # Fixture (empty in tenant): { Records: [], TotalRecords: 0 }
            # Per-row schema (per nodoc spec): id, sourceEntityId, targetEntityId, pathType, severity
            ProjectionMap = @{
                AttackPathId   = '$tostring:id'
                SourceEntityId = '$tostring:sourceEntityId'
                TargetEntityId = '$tostring:targetEntityId'
                PathType       = '$tostring:pathType'
                Severity       = '$tostring:severity'
            }
        }
        @{
            Stream = 'MDE_AttackSurfaceChokepoints_CL'
            Path = '/apiproxy/mtp/xspmatlas/attacksurface/chokepoints/list'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Attack-surface choke points (analytical view; distinct from existing XspmChokePoints_CL)'
            Availability = 'live'
            UnwrapProperty = 'Results'
            # Fixture (empty): { Results: [], TotalCount: 0 }
            # Per-row schema (nodoc): id, entityId, entityType, chokePointScore, exposedPathsCount
            # NOTE: 'entityId' from response renamed to 'ChokepointEntityId' to avoid
            # collision with base ingest column 'EntityId'.
            ProjectionMap = @{
                ChokepointId       = '$tostring:id'
                ChokepointEntityId = '$tostring:entityId'
                EntityType         = '$tostring:entityType'
                ChokePointScore    = '$todouble:chokePointScore'
                ExposedPathsCount  = '$toint:exposedPathsCount'
            }
        }
        @{
            Stream = 'MDE_XspmConnectors_CL'
            Path = '/apiproxy/mtp/XspmConnectors/connectors/getAllConnectors'
            Tier = 'XspmGraph'
            Category = 'Exposure Management (XSPM)'
            CategoryId = 6
            Purpose = 'Configured XSPM data connectors (data sources feeding XSPM graph)'
            Availability = 'live'
            UnwrapProperty = 'results'
            # Fixture (empty): { results: [], recordsCount: 0 }
            # Per-row schema (nodoc): id, name, connectorType, status, lastSyncTime
            ProjectionMap = @{
                ConnectorId   = '$tostring:id'
                ConnectorName = '$tostring:name'
                ConnectorType = '$tostring:connectorType'
                Status        = '$tostring:status'
                LastSyncTime  = '$todatetime:lastSyncTime'
            }
        }

        # ---- ThreatAnalytics (5) -------------------------------------------
        @{
            Stream = 'MDE_ThreatAnalyticsEnriched_CL'
            Path = '/apiproxy/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp'
            Tier = 'Configuration'
            Category = 'Threat Analytics'
            CategoryId = 7
            Purpose = 'Threat-analytics enriched outbreak data (full payload with severity + sectors + threat-actor mapping)'
            Availability = 'live'
            UnwrapProperty = 'Items'
            # Fixture: { Items: [{ Id, DisplayName, LastUpdatedOn, CreatedOn, StartedOn, ImpactedEntitiesCount: {...}, AlertsCount: {...}, ReportType, Tags[], ExposureSeverity, ExposureScore }] }
            ProjectionMap = @{
                OutbreakId             = '$tostring:Id'
                DisplayName            = '$tostring:DisplayName'
                ReportType             = '$tostring:ReportType'
                ExposureSeverity       = '$tostring:ExposureSeverity'
                ExposureScore          = '$toint:ExposureScore'
                CreatedOn              = '$todatetime:CreatedOn'
                StartedOn              = '$todatetime:StartedOn'
                LastUpdatedOn          = '$todatetime:LastUpdatedOn'
                Tags                   = '$json:Tags'
                ScaExposedDevices      = '$toint:ScaExposedDevices'
                VaExposedDevices       = '$toint:VaExposedDevices'
                # Section R++++++ O1 expansion (2026-05-07): nested object cols
                # operators query via parse_json(ImpactedEntitiesCount).devices etc.
                ImpactedEntitiesCount  = '$json:ImpactedEntitiesCount'
                AlertsCount            = '$json:AlertsCount'
                IsTaVNext              = '$tobool:IsTaVNext'
            }
        }
        @{
            Stream = 'MDE_ThreatAnalyticsTopThreats_CL'
            Path = '/apiproxy/mtp/threatAnalytics/outbreaks/topthreats'
            Tier = 'Configuration'
            Category = 'Threat Analytics'
            CategoryId = 7
            Purpose = 'Threat-analytics top threats summary (curated highest-severity active outbreaks)'
            Availability = 'live'
            SingleObjectAsRow = $true
            # Section R++.B B10: synthetic stable EntityId for SingleObjectAsRow
            # streams without a natural id field. Without this, every row has
            # EntityId='idx-0' which makes drift-snapshot joins meaningless.
            # 'topthreats-singleton' is a constant string so all polls join cleanly.
            IdProperty = @('__synthetic__')
            SyntheticEntityId = 'topthreats-singleton'
            # Fixture: SINGLE OBJECT { TotalThreatRequiresAction, ThreatsExposure[], TotalActiveThreats, ThreatExposureCalculationStatus, CurrentAlertsCount[] }
            ProjectionMap = @{
                TotalThreatRequiresAction       = '$toint:TotalThreatRequiresAction'
                TotalActiveThreats              = '$toint:TotalActiveThreats'
                ThreatExposureCalculationStatus = '$tostring:ThreatExposureCalculationStatus'
                ThreatsExposure                 = '$json:ThreatsExposure'
                CurrentAlertsCount              = '$json:CurrentAlertsCount'
            }
        }
        # MDE_ThreatAnalyticsOutbreaksList_CL DROPPED — nodoc-documented path
        # /mtp/threatAnalyticsAPI/outbreaks returns 404 (path appears to have
        # changed/been deprecated). Existing MDE_ThreatAnalytics_CL covers
        # the same data via working path /apiproxy/mtp/threatAnalytics/outbreaks.
        # Re-evaluate in v0.1.1 if the alternate API surface returns.
        # MDE_IndicatorReputation_CL + MDE_UrlReputation_CL DROPPED — both require
        # ?query=<IOC> URL parameter (per-indicator lookup APIs, not snapshot-poll).
        # These are operator-driven lookups against specific IOCs, not data-stream
        # endpoints. Defer to v0.1.1 if a "list known IOCs" alternative emerges.
    )
}
