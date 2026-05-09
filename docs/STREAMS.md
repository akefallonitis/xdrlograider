# Streams catalogue (v0.1.0 GA)

**65 portal-only stream entries** (64 active + 1 deprecated) grouped into **5 cadence tiers**, all with documented path + method + body + headers verified against XDRInternals + nodoc OpenAPI spec catalogue + live-captured against a full-access admin account.

v0.1.0 GA Phase 2 (2026-05-04) added **13 Tier A streams** from the nodoc-catalog sweep: 11 in `XspmGraph` tier (Posture metrics + SecureScore per-category + Attack Surface analytical paths/chokepoints + XSPM Connectors + Asset Classification Schema + Posture Tenants/Initiatives/Security Events) and 2 in `Configuration` tier (Threat Analytics enriched + top threats).

v0.1.0 GA Phase 1 (2026-05-07 — Section R++++++) added **6 new streams**:
- **Architecture B**: `MDE_Machines_CL` (Endpoint Device Management — foundation for PerEntityFanout)
- **G7**: `MDE_SecurityPolicies_CL` (Endpoint Configuration — POST endpoint returning ASR rules + AV settings + EDR + Firewall + Web Protection policy bodies per platform)
- **G8 TVM expansion**: `MDE_VulnerableMachines_CL` + `MDE_VulnerabilityInventory_CL` + `MDE_SoftwareInventory_CL` + `MDE_RecommendationActions_CL`

The portal-only audit DROPPED `MDE_SecureScoreBreakdown_CL` — publicly-API-covered by Microsoft Graph `/security/secureScores`; operators should use the official Graph Security data connector for that data. Deprecated streams are documented inline via the manifest `Availability='deprecated'` field with a Purpose note explaining the deprecation reason.

The source of truth is [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1). Live-response fixtures live under `tests/fixtures/live-responses/`.

---

## Cadence tiers (post-Section-R 4-function consolidation)

The connector groups streams by **how often it polls them**, not by an arbitrary priority number. Per Section R consolidation (2026-05-06), 5 separate timer functions were unified into a single dispatcher (`Xdr-Refresh`) which reads `XdrTierState` Storage table and starts orchestrations per-tier when due:

| Tier | Cadence (production) | Streams | Cron pattern (computed by Xdr-Refresh dispatcher) |
|---|---|---|---|
| `ActionCenter` | every 10 min | 2 (security events) | every 10 min |
| `XspmGraph` | hourly | 18 (XSPM posture + attack surface) | every 60 min |
| `Configuration` | every 6h | 16 (config-as-code surfaces) | every 6 hours |
| `Inventory` | daily | 27 (per-device + per-tenant inventory; +6 Phase 1 additions) | every 24 hours |
| `Maintenance` | weekly | 1 (+1 deprecated, excluded from poll) | every 7 days |

Cadence reflects the data's actual change-rate. Action Center events flow continuously so `ActionCenter` polls every 10 min; XSPM graph data churn-rate is well under 1h so `XspmGraph` matches the workbook hourly refresh; rule + RBAC + integration changes happen during weekday admin sessions so `Configuration` polls every 6 hours; settings + identity + metadata + device inventory are typically stable day-over-day so `Inventory` is daily; data-export configuration only changes during architectural reviews so `Maintenance` is weekly.

> **NOTE (v0.1.0 GA — production cadence active 2026-05-09)**: ActionCenter 10m / XspmGraph 1h / Configuration 6h / Inventory 24h / Maintenance 7d (per `src/Modules/Xdr.Sentinel.Ingest/Public/Get-XdrTierCadenceMap.ps1`). Compressed-cadence override (1h-everything) was used during Phase A audit window 2026-05-09T14:08-14:51 UTC and reverted before close-out per Plan AMEND-2 BINDING.

## Availability legend (all-live runtime classification policy)

| Tag | Meaning |
|---|---|
| `live` | Path + method + body correct. Runtime `SuccessKind` (Section R++.A truth-signal) classifies actual response: `live` (200 with rows), `live-empty` (200 with 0 rows), `tenant-gated` (4xx warning — license/feature not provisioned), `error` (5xx investigate). Operator queries `XdrConnectorHealth_CL.Reason` to see per-stream classification. |
| `deprecated` | Underlying portal endpoint has been renamed/retired by Microsoft. Filtered out by orchestrator — never polled. v0.2.0 may remove the manifest entry entirely. |

A 4xx classified `tenant-gated` at runtime is **not a bug**. It's correct behaviour for a tenant without the gating feature. Section R++ replaced hardcoded `Availability='tenant-gated'` flags with runtime classification — the manifest is now all-`live` (except the 1 deprecated). The connector adapts dynamically to license changes without code edits.

---

## fast (every 10 min, 2 streams)

Action Center events — operator-visible response actions and Live Response per-step output. These are event-shaped (one row per occurrence, not snapshots) so the highest cadence keeps operator latency tight on hostile-action visibility.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_ActionCenter_CL` | `/apiproxy/mtp/actionCenter/actioncenterui/history-actions` | GET | live |

## exposure (hourly @ :25, 18 streams)

Exposure Management (XSPM) — graph-shaped surfaces (attack paths, choke points, top targets) plus exposure recommendations and asset rules + posture metrics + SecureScore per-category + attack-surface analytical views (v0.1.0 GA Phase 2). Cadence-paired with the Sentinel exposure workbook (hourly refresh). XSPM graph data churn-rate is well under 1h so a faster poll wastes XSPM-API quota.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_AssetRules_CL` | `/apiproxy/mtp/xspmatlas/assetrules` | GET | live |
| `MDE_XspmInitiatives_CL` | `/apiproxy/mtp/posture/oversight/initiatives` | GET | live |
| `MDE_ExposureSnapshots_CL` | `/apiproxy/mtp/posture/oversight/updates` | GET | live |
| `MDE_ExposureRecommendations_CL` | `/apiproxy/mtp/posture/oversight/recommendations` | GET | live |
| `MDE_XspmAttackPaths_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |
| `MDE_XspmChokePoints_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |
| `MDE_XspmTopTargets_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |
| `MDE_AssetClassificationSchema_CL` | `/apiproxy/mtp/xspmatlas/assetrules/querybuilder/schema` | GET | live |
| `MDE_PostureInitiativesSummarized_CL` | `/apiproxy/mtp/posture/oversight/initiatives/summarized` | GET | live |
| `MDE_PostureMetrics_CL` | `/apiproxy/mtp/posture/oversight/metrics` | GET | live |
| `MDE_AppsSecureScore_CL` | `/apiproxy/mtp/posture/oversight/securescore/apps` | GET | live |
| `MDE_DataSecureScore_CL` | `/apiproxy/mtp/posture/oversight/securescore/data` | GET | live |
| `MDE_IdentitySecureScore_CL` | `/apiproxy/mtp/posture/oversight/securescore/identity` | GET | live |
| `MDE_PostureSecurityEvents_CL` | `/apiproxy/mtp/posture/oversight/securityEvents` | GET | live |
| `MDE_PostureTenants_CL` | `/apiproxy/mtp/posture/oversight/tenants` | GET | live |
| `MDE_AttackSurfaceAttackPaths_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/attackPaths/list` | POST | live |
| `MDE_AttackSurfaceChokepoints_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/chokepoints/list` | POST | live |
| `MDE_XspmConnectors_CL` | `/apiproxy/mtp/xspmatlas/connectors` | GET | live |

## config (every 6h @ :35, 16 streams)

Configuration / detection-rule tier — alert-pipeline rules, tenant policy, integration state, RBAC, threat intel + threat-analytics enriched outbreaks (v0.1.0 GA Phase 2), operator preferences, CASB integration. 6h matches Defender admin's typical weekday-work-cycle change cadence.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_PreviewFeatures_CL` | `/apiproxy/mtp/settings/GetPreviewExperienceSetting?context=MdatpContext` | GET | live |
| `MDE_AlertServiceConfig_CL` | `/apiproxy/mtp/alertsApiService/workloads/disabled` | GET | live |
| `MDE_AlertTuning_CL` | `/apiproxy/mtp/alertsEmailNotifications/email_notifications` | GET | live |
| `MDE_SuppressionRules_CL` | `/apiproxy/mtp/suppressionRulesService/suppressionRules` | GET | live |
| `MDE_CustomDetections_CL` | `/apiproxy/mtp/huntingService/rules/unified` | GET | live |
| `MDE_TenantAllowBlock_CL` | `/apiproxy/mtp/papin/api/cloud/public/internal/indicators/filterValues` | GET | tenant-gated |
| `MDE_ConnectedApps_CL` | `/apiproxy/mtp/responseApiPortal/apps/all` | GET | live |
| `MDE_IntuneConnection_CL` | `/apiproxy/mtp/responseApiPortal/onboarding/intune/status` | GET | live |
| `MDE_PurviewSharing_CL` | `/apiproxy/mtp/wdatpInternalApi/compliance/alertSharing/status` | GET | live |
| `MDE_RbacDeviceGroups_CL` | `/apiproxy/mtp/rbacManagementApi/rbac/machine_groups` | GET | live |
| `MDE_UnifiedRbacRoles_CL` | `/apiproxy/mtp/urbacConfiguration/gw/unifiedrbac/configuration/roleDefinitions` | GET | live |
| `MDE_ThreatAnalytics_CL` | `/apiproxy/mtp/threatAnalytics/outbreaks` | GET | live |
| `MDE_ThreatAnalyticsEnriched_CL` | `/apiproxy/mtp/threatAnalytics/outbreaks/enriched` | GET | live |
| `MDE_ThreatAnalyticsTopThreats_CL` | `/apiproxy/mtp/threatAnalytics/outbreaks/topThreats` | GET | live |
| `MDE_UserPreferences_CL` | `/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` | GET | live |
| `MDE_CloudAppsConfig_CL` | `/apiproxy/mcas/cas/api/v1/settings` | GET | tenant-gated |

## Inventory (daily @ 02:00 UTC, 27 streams)

Inventory tier — endpoint config, MDI identity surfaces, tenant context, security baselines, MTO, license report, device timeline + Phase 1 additions: device inventory base + actual security policies + TVM expansion (4 streams). Daily matches the typical change-rate of these surfaces; faster polling costs 429 budget without operator value.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_AdvancedFeatures_CL` | `/apiproxy/mtp/settings/GetAdvancedFeaturesSetting` | GET | live |
| `MDE_DeviceControlPolicy_CL` | `/apiproxy/mtp/siamApi/Onboarding` | GET | live |
| `MDE_WebContentFiltering_CL` | `/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | GET | live |
| `MDE_SmartScreenConfig_CL` | `/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | GET | live |
| `MDE_LiveResponseConfig_CL` | `/apiproxy/mtp/liveResponseApi/get_properties` | GET | live |
| `MDE_AuthenticatedTelemetry_CL` | `/apiproxy/mtp/responseApiPortal/senseauth/allownonauthsense` | GET | live |
| `MDE_PUAConfig_CL` | `/apiproxy/mtp/autoIr/ui/properties/` | GET | live |
| `MDE_AntivirusPolicy_CL` | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters?platform=Windows` | GET | live (filter facets — see SecurityPolicies for actual policy bodies) |
| `MDE_CustomCollection_CL` | `/apiproxy/mtp/mdeCustomCollection/rules` | GET | live |
| `MDE_TenantContext_CL` | `/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` | GET | live |
| `MDE_TenantWorkloadStatus_CL` | `/apiproxy/mtoapi/tenantGroups` | GET | live |
| `MDE_SAClassification_CL` | `/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall` | GET | live |
| `MDE_IdentityOnboarding_CL` | `/apiproxy/mtp/siamApi/domaincontrollers/list` | GET | live |
| `MDE_IdentityServiceAccounts_CL` | `/apiproxy/mdi/identity/userapiservice/serviceAccounts` | POST | live |
| `MDE_DCCoverage_CL` | `/apiproxy/aatp/api/sensors/domainControllerCoverage` | GET | live |
| `MDE_IdentityAlertThresholds_CL` | `/apiproxy/aatp/api/alertthresholds/withExpiry` | GET | live |
| `MDE_RemediationAccounts_CL` | `/apiproxy/mdi/identity/identitiesapiservice/remediationAccount` | GET | live |
| `MDE_SecurityBaselines_CL` | `/apiproxy/mtp/tvm/analytics/vulnerabilities/baseline` | GET | live (R+++++ path-drift fix 2026-05-07) |
| `MDE_MtoTenants_CL` | `/apiproxy/mtoapi/tenants/TenantPicker` | GET | live |
| `MDE_LicenseReport_CL` | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport` | GET | live |
| `MDE_DeviceTimeline_CL` | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machinetimeline` | POST | live (legacy path; PerEntityFanout to nodoc canonical = Phase 2 Architecture A6) |
| **`MDE_Machines_CL`** *(NEW Phase 1 Architecture B)* | `/apiproxy/mtp/ndr/machines?hideLowFidelityDevices=true&lookingBackIndays=30&pageIndex=1&pageSize=200&sortByField=riskscore&sortOrder=Descending` | GET | live |
| **`MDE_SecurityPolicies_CL`** *(NEW Phase 1 G7)* | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies` | POST `{platform:'Windows'}` | live (Windows-only Phase 1; PerPlatformFanout = Phase 2 C2) |
| **`MDE_VulnerableMachines_CL`** *(NEW Phase 1 G8)* | `/apiproxy/mtp/tvm/analytics/assets/topVulnerable` | GET | live |
| **`MDE_VulnerabilityInventory_CL`** *(NEW Phase 1 G8)* | `/apiproxy/mtp/tvm/analytics/vulnerabilities` | GET | live |
| **`MDE_SoftwareInventory_CL`** *(NEW Phase 1 G8)* | `/apiproxy/mtp/tvm/analytics/products` | GET | live |
| **`MDE_RecommendationActions_CL`** *(NEW Phase 1 G8)* | `/apiproxy/mtp/tvm/remediation-tasks/remediationTasks` | GET | live |

## maintenance (weekly Sun @ 03:00 UTC, 1 active stream + 1 deprecated)

Rare-change long-tail surfaces. The active stream is `MDE_DataExportSettings_CL` (the canonical streaming-API export configuration); the deprecated `MDE_StreamingApiConfig_CL` stream is retained for one cycle but **excluded from the actual poll** (returns 404 on modern tenants — superseded by DataExportSettings).

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_DataExportSettings_CL` | `/apiproxy/mtp/wdatpApi/dataexportsettings` | GET | live |
| `MDE_StreamingApiConfig_CL` | `/apiproxy/mtp/streamingapi/streamingApiConfiguration` | — | deprecated *(excluded from poll)* |

## Operational stream

One non-telemetry stream emitted by the Function App itself, not polled from the portal:

| Table | Emitted by | Cadence | Schema |
|---|---|---|---|
| `XdrConnectorHealth_CL` | every poll-* timer + Connector-Heartbeat | per invocation | 9 cols: `TimeGenerated, FunctionName, Tier, StreamsAttempted, StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes(dynamic)` |

Auth chain diagnostics (the previous `App Insights customEvents` table) moved to **App Insights `customEvents`** in v0.1.0 GA first publish. Query examples:

```kql
// Auth chain status (App Insights)
customEvents
| where name in ('AuthChain.AADSTSError', 'AuthChain.Completed')
| order by timestamp desc
| take 10
```

```kql
// Connector health (workspace)
XdrConnectorHealth_CL
| where TimeGenerated > ago(1h)
| where StreamsSucceeded > 0
| order by TimeGenerated desc
```

The Sentinel data connector card uses the second query for its IsConnected gate — proves a poll succeeded, not just that the heartbeat timer fired.

## Counts by tier (Phase 1 baseline; auto-derived from manifest 2026-05-07)

| Tier | Streams | Live | Tenant-gated | Deprecated |
|---|---|---|---|---|
| ActionCenter   |  3 |  3 |  0 | 0 |
| XspmGraph      | 18 | 18 |  0 | 0 |
| Configuration  | 16 | 16 |  0 | 0 |
| Inventory      | 26 | 26 |  0 | 0 |
| Maintenance    |  2 |  1 |  0 | 1 |
| **Total**      | **65** | **64** | **0** | **1** |

Plus 1 operational table (`XdrConnectorHealth_CL`) routed through DCR = **66 streamDeclarations** total.

**All-live policy** (Section R+++.4 + R++++++.10 #6): every active manifest entry is `Availability='live'`. Tenant licensing is detected at runtime via `Get-MDEEndpointLastResult.SuccessKind` (live | live-empty | tenant-gated | error) and surfaced on `XdrConnectorHealth_CL.Reason` per stream — operators correlate per-stream reasons with their licensing.

## Live fixture coverage

Every manifest entry has a fixture under `tests/fixtures/live-responses/`:

- **Real captures** — `<Stream>-raw.json` + `<Stream>-ingest.json` from the live tenant (PII-scrubbed).
- **Markers** — one-line `<Stream>-raw.json` with `{"_availability":"tenant-gated","_reason":"…"}` so offline tests detect "expected 4xx — skip" rather than fail missing-file.
- **Empty markers** — `{}` for streams whose live response is shape-equivalent (skipped from ProjectionResolution).

Downstream tests (`tests/unit/FA.ParsingPipeline.Tests.ps1`, `DCR.SchemaConsistency.Tests.ps1`, `tests/kql/*`) read these fixtures to validate parser + rule + workbook column refs match the shape our connector actually ingests.

## Per-stream operational matrix (auto-derived)

Auto-generated by `pwsh tools/Run-WiringAudit.ps1`; the latest snapshot lives at `tests/online/Wiring-Matrix-<YYYY-MM-DD>.md` and is regenerated on every release. Columns: stream / cadence / availability / shape / DCR mapping / live verification status.

The matrix mechanically reflects the manifest source-of-truth (`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`); to inspect a single stream, query the manifest directly:

```pwsh
$m = Import-PowerShellDataFile src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1
$m.Endpoints | Where-Object Stream -eq 'MDE_Machines_CL' | Format-List *
```

For Phase 2+ stream additions (per Section R++++++.7 v0.1.0.1 / v0.2.0 roadmap), see `docs/ROADMAP.md`.
