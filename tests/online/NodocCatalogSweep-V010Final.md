# Nodoc catalog sweep — v0.1.0 GA FINAL inclusion (17 streams)

**Generated**: 2026-05-04
**Source**: `tests/online/NodocCatalogSweep-TierA.md` (32 candidates) → wisely filtered per plan §0 to 17.

## Drops (15 of 32)

| # | Stream | Reason |
|---|---|---|
| 1 | `MDE_ConfigurationQueryCriticalAssetClassification_CL` | per-entity (`{encodedRuleName}`) — defer to v0.1.1 |
| 3 | `MDE_EndpointDevicesGetTimeline_CL` | per-entity (`{DeviceId}`) — fan-out cost; defer |
| 4 | `MDE_ExposureManagementGetPostureOversightInitiative_CL` | per-entity (`{InitiativeId}`) — defer |
| 16 | `MDE_IdentityGetServiceAccountsCount_CL` | scalar count — low operator value |
| 17 | `MDE_IdentityGetUserTimeline_CL` | per-user fan-out timeline — defer |
| 18-22, 25-29 | 11 × `MDE_ThreatAnalyticsGetOutbreak*_CL` per-{OutbreakId} drilldowns | per-entity fan-out per active outbreak — operator opens portal directly for forensics; defer |

## Final 17 streams

| # | Stream | Category | Workspace Table | Cadence | Path |
|---|---|---|---|---|---|
| 1 | `MDE_ConfigurationGetCriticalAssetClassificationSchema_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | XspmGraph | `/apiproxy/mtp/xspmatlas/assetrules/querybuilder/schema` |
| 2 | `MDE_ExposureManagementGetPostureOversightInitiativesSummarized_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/initiatives/summarized` |
| 3 | `MDE_ExposureManagementListPostureOversightMetrics_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/metrics` |
| 4 | `MDE_ExposureManagementGetAppsSecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/metrics/category_apps_secure_score` |
| 5 | `MDE_ExposureManagementGetDataSecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/metrics/category_data_secure_score` |
| 6 | `MDE_ExposureManagementGetIdentitySecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/metrics/category_identity_secure_score` |
| 7 | `MDE_ExposureManagementGetPostureOversightRecommendationsAggregated_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/recommendations/aggregated` |
| 8 | `MDE_ExposureManagementListPostureSecurityEvents_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/securityEvents` |
| 9 | `MDE_ExposureManagementGetPostureOversightTenants_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/posture/oversight/tenants` |
| 10 | `MDE_ExposureManagementListAttackSurfaceAttackPaths_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/xspmatlas/attacksurface/attackpaths` |
| 11 | `MDE_ExposureManagementListAttackSurfaceChokepoints_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/xspmatlas/attacksurface/chokepoints/list` |
| 12 | `MDE_ExposureManagementListXspmConnectors_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | `/apiproxy/mtp/XspmConnectors/connectors/getAllConnectors` |
| 13 | `MDE_ThreatAnalyticsGetEnrichedOutbreakData_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | `/apiproxy/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp` |
| 14 | `MDE_ThreatAnalyticsGetTopThreats_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | `/apiproxy/mtp/threatAnalytics/outbreaks/topthreats` |
| 15 | `MDE_ThreatAnalyticsListOutbreaks_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | `/apiproxy/mtp/threatAnalyticsAPI/outbreaks` |
| 16 | `MDE_ThreatAnalyticsGetIndicatorReputation_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | `/apiproxy/mtp/threatAnalyticsIndicators/stix/oneti/reputation` |
| 17 | `MDE_ThreatAnalyticsGetUrlReputation_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | `/apiproxy/mtp/threatAnalyticsIndicators/stix/oneti/reputation/URL` |

## Distribution

- **ConfigurationAndSettings**: 1
- **ExposureManagement** (XSPM): 11 (XSPM/posture core + attack-surface graph)
- **ThreatAnalytics**: 5 (outbreak-list + reputation feeds)
- **Total**: 17 streams (15 XspmGraph cadence hourly @ :25, 2 Configuration cadence 6h @ :35)

## Existing manifest after Phase 2 — 63 streams total

| Tier | Existing | New | Total | Cadence |
|---|---|---|---|---|
| ActionCenter | 2 | 0 | 2 | 10m |
| XspmGraph | 7 | 11 | 18 | 1h @ :25 |
| Configuration | 14 | 5 | 19 | 6h @ :35 |
| Inventory | 21 | 0 | 21 | 1d @ 02:00 UTC |
| Maintenance | 2 (1 deprecated) | 0 | 2 | 7d Sun @ 03:00 UTC |
| Boundary | 0 | 0 | 0 | n/a |
| Heartbeat | 0 | 0 | 0 | 5m |
| **Total** | **46** | **17** | **63** | — |

## Per-stream time-filter strategy

All 17 are **snapshot streams** (no `Filter='fromDate'`):
- Portal returns full state per poll
- Workspace stores time-series of snapshots (intentional; feeds drift parsers)
- Drift parsers (`MDE_Drift_*.kql`) compute Added/Modified/Removed via `mv-apply` field-level diff
- Operators query parser output (not raw tables with `arg_max`)

## Next: Phase 2.2 — live capture each via `tools/Capture-EndpointSchemas.ps1`
