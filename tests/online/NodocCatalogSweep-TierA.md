# Nodoc catalog sweep — Tier A (MUST in v0.1.0)

Generated: 2026-05-04
Total Tier A: 32 (operator value 5/5)

Per user direction: WISE selection — only highest-value portal-only endpoints.

Each entry includes the proper category mapping, cadence tier (drives polling frequency), and time-filter strategy (drives state + no-duplication discipline).

| # | Suggested Stream | Category | Workspace Table | Cadence | TimeFilter | Value | Path | Summary |
|---|---|---|---|---|---|---|---|---|
| 1 | `MDE_ConfigurationQueryCriticalAssetClassification_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | XspmGraph | snapshot-full | 5 | `/mtp/xspmatlas/assetrules/querybuilder/assets/{encodedRuleName}` | Query critical asset classification |
| 2 | `MDE_ConfigurationGetCriticalAssetClassificationSchema_CL` | ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | XspmGraph | snapshot-full | 5 | `/mtp/xspmatlas/assetrules/querybuilder/schema` | Get critical asset classification schema |
| 3 | `MDE_EndpointDevicesGetTimeline_CL` | EndpointDeviceManagement | `Defender_EndpointDeviceManagement_CL` | Inventory | per-entity-snapshot | 5 | `/mtp/deviceTimeline/timeline/{DeviceId}` | Get device timeline |
| 4 | `MDE_ExposureManagementGetPostureOversightInitiative_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | per-entity-snapshot | 5 | `/mtp/posture/oversight/initiatives/{InitiativeId}` | Get posture oversight initiative details |
| 5 | `MDE_ExposureManagementGetPostureOversightInitiativesSummarized_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/initiatives/summarized` | Get summarized posture initiatives |
| 6 | `MDE_ExposureManagementListPostureOversightMetrics_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/metrics` | List posture oversight metrics |
| 7 | `MDE_ExposureManagementGetAppsSecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/metrics/category_apps_secure_score` | Get SaaS apps secure score metric |
| 8 | `MDE_ExposureManagementGetDataSecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/metrics/category_data_secure_score` | Get data secure score metric |
| 9 | `MDE_ExposureManagementGetIdentitySecureScoreMetric_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/metrics/category_identity_secure_score` | Get identity secure score metric |
| 10 | `MDE_ExposureManagementGetPostureOversightRecommendationsAggregated_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/recommendations/aggregated` | Get aggregated posture recommendations |
| 11 | `MDE_ExposureManagementListPostureSecurityEvents_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/securityEvents` | List posture security events |
| 12 | `MDE_ExposureManagementGetPostureOversightTenants_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/posture/oversight/tenants` | Get posture oversight tenant configuration |
| 13 | `MDE_ExposureManagementListAttackSurfaceAttackPaths_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/xspmatlas/attacksurface/attackpaths` | List attack surface attack paths |
| 14 | `MDE_ExposureManagementListAttackSurfaceChokepoints_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/xspmatlas/attacksurface/chokepoints/list` | List attack surface choke points |
| 15 | `MDE_ExposureManagementListXspmConnectors_CL` | ExposureManagement | `Defender_ExposureManagement_CL` | XspmGraph | snapshot-full | 5 | `/mtp/XspmConnectors/connectors/getAllConnectors` | List XSPM connectors |
| 16 | `MDE_IdentityGetServiceAccountsCount_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Inventory | snapshot-full | 5 | `/mdi/identity/userapiservice/serviceAccounts/count` | Get service accounts count |
| 17 | `MDE_IdentityGetUserTimeline_CL` | IdentityProtection | `Defender_IdentityProtection_CL` | Inventory | delta-by-eventTime | 5 | `/mdi/identity/userapiservice/user/timeline` | Get user timeline |
| 18 | `MDE_ThreatAnalyticsGetOutbreakDevices_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/outbreaks/outbreaks/v2/{OutbreakId}/devices` | Get outbreak devices |
| 19 | `MDE_ThreatAnalyticsGetOutbreakAlertsOverTimeSummary_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/alertsOvertimeSummary` | Get outbreak alerts over time summary |
| 20 | `MDE_ThreatAnalyticsGetOutbreakOverview_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/overview` | Get outbreak overview |
| 21 | `MDE_ThreatAnalyticsGetOutbreakPatchData_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/patchdata` | Get outbreak patch data |
| 22 | `MDE_ThreatAnalyticsGetOutbreakRelatedIntelligence_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/relatedIntelligence` | Get outbreak related intelligence |
| 23 | `MDE_ThreatAnalyticsGetEnrichedOutbreakData_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | snapshot-full | 5 | `/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp` | Get enriched outbreak data |
| 24 | `MDE_ThreatAnalyticsGetTopThreats_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | snapshot-full | 5 | `/mtp/threatAnalytics/outbreaks/topthreats` | Get top threats |
| 25 | `MDE_ThreatAnalyticsGetOutbreakImpactedAssetsOverTime_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/impactedAssetsOvertime` | Get outbreak impacted assets over time |
| 26 | `MDE_ThreatAnalyticsGetOutbreakImpactedAssetsSummary_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/impactedAssetsSummary` | Get outbreak impacted assets summary |
| 27 | `MDE_ThreatAnalyticsGetOutbreakIncidentsAlertsSummary_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/incidentsAlertsSummary` | Get outbreak incidents and alerts summary |
| 28 | `MDE_ThreatAnalyticsGetOutbreakTvmDetails_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/tvmDetails` | Get outbreak TVM details |
| 29 | `MDE_ThreatAnalyticsGetOutbreakUserExposure_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | per-entity-snapshot | 5 | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/userExposure` | Get outbreak user exposure |
| 30 | `MDE_ThreatAnalyticsListOutbreaks_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | snapshot-full | 5 | `/mtp/threatAnalyticsAPI/outbreaks` | List threat analytics outbreaks |
| 31 | `MDE_ThreatAnalyticsGetIndicatorReputation_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | snapshot-full | 5 | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation` | Get indicator reputation |
| 32 | `MDE_ThreatAnalyticsGetUrlReputation_CL` | ThreatAnalytics | `Defender_ThreatAnalytics_CL` | Configuration | snapshot-full | 5 | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/URL` | Get URL reputation |

