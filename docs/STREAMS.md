# Streams catalogue (v0.1.0-beta)

**46 portal-only stream entries** (45 active + 1 deprecated) grouped into **5 cadence tiers**, all with documented path + method + body + headers verified against XDRInternals + live-captured against a full-access admin account.

The portal-only audit DROPPED `MDE_SecureScoreBreakdown_CL` — publicly-API-covered by Microsoft Graph `/security/secureScores`; operators should use the official Graph Security data connector for that data. See [`STREAMS-REMOVED.md`](STREAMS-REMOVED.md) for the full removal history.

The source of truth is [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1). Live-response fixtures live under `tests/fixtures/live-responses/`.

---

## Cadence tiers

The connector groups streams by **how often it polls them**, not by an arbitrary priority number. Each tier has a dedicated Function App timer:

| Tier | Cadence | Cron | Streams (active) | Timer function |
|---|---|---|---|---|
| `fast` | every 10 min | `0 */10 * * * *` | 2 | `poll-fast-10m` |
| `exposure` | hourly @ :25 | `0 25 * * * *` | 7 | `poll-exposure-1h` |
| `config` | every 6h @ :35 | `0 35 */6 * * *` | 14 | `poll-config-6h` |
| `inventory` | daily @ 02:00 UTC | `0 0 2 * * *` | 21 | `poll-inventory-1d` |
| `maintenance` | weekly Sun @ 03:00 UTC | `0 0 3 * * 0` | 1 (+1 deprecated, excluded from poll) | `poll-maintenance-1w` |

Cadence reflects the data's actual change-rate. Action Center events flow continuously so the `fast` tier polls every 10 min; XSPM graph data churn-rate is well under 1h so the `exposure` tier matches the workbook hourly refresh; rule + RBAC + integration changes happen during weekday admin sessions so `config` polls every 6 hours; settings + identity + metadata are typically stable day-over-day so `inventory` is daily; data-export configuration only changes during architectural reviews so `maintenance` is weekly.

## Availability legend

| Tag | Meaning | Zero-row expectation |
|---|---|---|
| `live` | Returns 200 with data on a typical tenant. | Non-zero every poll cycle where state exists. |
| `tenant-gated` | Path + method + body correct; 4xx because tenant hasn't provisioned the feature (MDI sensors, MCAS, MTO, Intune connector, TVM add-on, etc). | Activates automatically when feature enabled. No code change needed. |
| `deprecated` | Stream entry retained for one cycle so parsers / analytic rules can be cleanly removed in v0.2.0; the underlying portal endpoint has been renamed/retired by Microsoft. Excluded from active polling. | Always zero rows. Do NOT add new entries with this tag. |

A `tenant-gated` stream is **not a bug**. It's correct behaviour for a tenant without the gating feature.

---

## fast (every 10 min, 2 streams)

Action Center events — operator-visible response actions and Live Response per-step output. These are event-shaped (one row per occurrence, not snapshots) so the highest cadence keeps operator latency tight on hostile-action visibility.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_ActionCenter_CL` | `/apiproxy/mtp/actionCenter/actioncenterui/history-actions` | GET | live |
| `MDE_MachineActions_CL` | `/apiproxy/mtp/responseApiPortal/machineactions` | GET | tenant-gated |

## exposure (hourly @ :25, 7 streams)

Exposure Management (XSPM) — graph-shaped surfaces (attack paths, choke points, top targets) plus exposure recommendations and asset rules. Cadence-paired with the Sentinel exposure workbook (hourly refresh). XSPM graph data churn-rate is well under 1h so a faster poll wastes XSPM-API quota.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_AssetRules_CL` | `/apiproxy/mtp/xspmatlas/assetrules` | GET | live |
| `MDE_XspmInitiatives_CL` | `/apiproxy/mtp/posture/oversight/initiatives` | GET | live |
| `MDE_ExposureSnapshots_CL` | `/apiproxy/mtp/posture/oversight/updates` | GET | live |
| `MDE_ExposureRecommendations_CL` | `/apiproxy/mtp/posture/oversight/recommendations` | GET | live |
| `MDE_XspmAttackPaths_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |
| `MDE_XspmChokePoints_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |
| `MDE_XspmTopTargets_CL` | `/apiproxy/mtp/xspmatlas/attacksurface/query` | POST | live |

## config (every 6h @ :35, 14 streams)

Configuration / detection-rule tier — alert-pipeline rules, tenant policy, integration state, RBAC, threat intel, operator preferences, CASB integration. 6h matches Defender admin's typical weekday-work-cycle change cadence.

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
| `MDE_UserPreferences_CL` | `/apiproxy/mtp/userPreferences/api/mgmt/userpreferencesservice/userPreference` | GET | live |
| `MDE_CloudAppsConfig_CL` | `/apiproxy/mcas/cas/api/v1/settings` | GET | tenant-gated |

## inventory (daily @ 02:00 UTC, 21 streams)

Inventory tier — endpoint config, MDI identity surfaces, tenant context, security baselines, MTO, license report, device timeline. Daily matches the typical change-rate of these surfaces; faster polling costs 429 budget without operator value.

| Stream | Path | Method | Availability |
|---|---|---|---|
| `MDE_AdvancedFeatures_CL` | `/apiproxy/mtp/settings/GetAdvancedFeaturesSetting` | GET | live |
| `MDE_DeviceControlPolicy_CL` | `/apiproxy/mtp/siamApi/Onboarding` | GET | live |
| `MDE_WebContentFiltering_CL` | `/apiproxy/mtp/webThreatProtection/WebContentFiltering/Reports/TopParentCategories` | GET | live |
| `MDE_SmartScreenConfig_CL` | `/apiproxy/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | GET | live |
| `MDE_LiveResponseConfig_CL` | `/apiproxy/mtp/liveResponseApi/get_properties` | GET | live |
| `MDE_AuthenticatedTelemetry_CL` | `/apiproxy/mtp/responseApiPortal/senseauth/allownonauthsense` | GET | live |
| `MDE_PUAConfig_CL` | `/apiproxy/mtp/autoIr/ui/properties/` | GET | live |
| `MDE_AntivirusPolicy_CL` | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | GET | tenant-gated |
| `MDE_CustomCollection_CL` | `/apiproxy/mtp/mdeCustomCollection/rules` | GET | tenant-gated |
| `MDE_TenantContext_CL` | `/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` | GET | live |
| `MDE_TenantWorkloadStatus_CL` | `/apiproxy/mtoapi/tenantGroups` | GET | tenant-gated |
| `MDE_SAClassification_CL` | `/apiproxy/radius/api/radius/serviceaccounts/classificationrule/getall` | GET | live |
| `MDE_IdentityOnboarding_CL` | `/apiproxy/mtp/siamApi/domaincontrollers/list` | GET | live |
| `MDE_IdentityServiceAccounts_CL` | `/apiproxy/mdi/identity/userapiservice/serviceAccounts` | POST | live |
| `MDE_DCCoverage_CL` | `/apiproxy/aatp/api/sensors/domainControllerCoverage` | GET | tenant-gated |
| `MDE_IdentityAlertThresholds_CL` | `/apiproxy/aatp/api/alertthresholds/withExpiry` | GET | tenant-gated |
| `MDE_RemediationAccounts_CL` | `/apiproxy/mdi/identity/identitiesapiservice/remediationAccount` | GET | tenant-gated |
| `MDE_SecurityBaselines_CL` | `/apiproxy/mtp/tvm/analytics/baseline/profiles?pageIndex=0&pageSize=25` | GET | tenant-gated |
| `MDE_MtoTenants_CL` | `/apiproxy/mtoapi/tenants/TenantPicker` | GET | tenant-gated |
| `MDE_LicenseReport_CL` | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machines/skuReport` | GET | live |
| `MDE_DeviceTimeline_CL` | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machinetimeline` | POST | tenant-gated |

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
| `MDE_Heartbeat_CL` | every poll-* timer + heartbeat-5m | per invocation | 9 cols: `TimeGenerated, FunctionName, Tier, StreamsAttempted, StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes(dynamic)` |

Auth chain diagnostics (the previous `App Insights customEvents` table) moved to **App Insights `customEvents`** in v0.1.0-beta first publish. Query examples:

```kql
// Auth chain status (App Insights)
customEvents
| where name in ('AuthChain.AADSTSError', 'AuthChain.Completed')
| order by timestamp desc
| take 10
```

```kql
// Connector health (workspace)
MDE_Heartbeat_CL
| where TimeGenerated > ago(1h)
| where StreamsSucceeded > 0
| order by TimeGenerated desc
```

The Sentinel data connector card uses the second query for its IsConnected gate — proves a poll succeeded, not just that the heartbeat timer fired.

## Counts by tier

| Tier | Streams | Live | Tenant-gated | Deprecated |
|---|---|---|---|---|
| fast        |  2 |  1 |  1 | 0 |
| exposure    |  7 |  7 |  0 | 0 |
| config      | 14 | 12 |  2 | 0 |
| inventory   | 21 | 13 |  8 | 0 |
| maintenance |  2 |  1 |  0 | 1 |
| **Total**   | **46** | **34** | **11** | **1** |

Plus 1 operational table (Heartbeat) = **47 custom LA tables**.

## Live fixture coverage

Every manifest entry has a fixture under `tests/fixtures/live-responses/`:

- **34 real captures** — `<Stream>-raw.json` + `<Stream>-ingest.json` from the live tenant (PII-scrubbed).
- **12 markers** — one-line `<Stream>-raw.json` with `{"_availability":"tenant-gated","_reason":"…"}` so offline tests detect "expected 4xx — skip" rather than fail missing-file.

Downstream tests (`tests/unit/FA.ParsingPipeline.Tests.ps1`, `DCR.SchemaConsistency.Tests.ps1`, `tests/kql/*`) read these fixtures to validate parser + rule + workbook column refs match the shape our connector actually ingests.
