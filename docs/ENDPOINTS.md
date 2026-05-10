# Endpoint Catalog (per-stream reference)

> **Purpose**: per-stream endpoint catalog auto-derivable from manifest. For each stream: canonical path · auth · headers · UnwrapProperty · ProjectionMap targets · Tier · Category · sample response shape.
>
> **Source of truth**: [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1) (72 stream entries).
>
> **Live response shapes**: [`tests/fixtures/live-responses/`](../tests/fixtures/live-responses/) (60+ pairs of `<Stream>-raw.json` + `<Stream>-ingest.json`); see [`tests/fixtures/live-responses/_capture-summary.json`](../tests/fixtures/live-responses/_capture-summary.json) for SuccessKind verdict per stream.
>
> **OpenAPI fallback**: [`tests/fixtures/openapi-derived/`](../tests/fixtures/openapi-derived/) for tenant-license-gated streams without live data (per Architecture E generator).

## How to read this catalog

Each stream entry includes:
- **Path**: canonical Defender XDR portal path (per nodoc + XDRInternals + live verification)
- **Method**: GET / POST
- **Auth**: ESTSAUTH→sccauth→session via service-account portal-auth (`Connect-DefenderPortal`)
- **Tier**: ActionCenter (10m) / XspmGraph (1h) / Configuration (6h) / Inventory (24h) / Maintenance (7d)
- **Category**: 1 of 10 nodoc-authoritative categories
- **UnwrapProperty**: which JSON key holds the array of records (or empty for single-object responses)
- **ProjectionMap targets**: typed columns extracted into the `Defender_<Category>_CL` workspace table
- **RawJson**: every row preserves the full response in `RawJson` col for forensic queries
- **Sample response**: see fixture at `tests/fixtures/live-responses/<Stream>-raw.json`

## Endpoint inventory by tier

### ActionCenter tier (10-min cadence — security events)

| Stream | Path | Method | UnwrapProperty | Notes |
|---|---|---|---|---|
| MDE_ActionCenter_CL | `/apiproxy/mtp/actionCenter/actioncenterui/history-actions` | GET | `Results` | per-action history (last 24h paged) |
| MDE_DeviceTimeline_CL | `/apiproxy/mtp/k8sMachineApi/ine/machineapiservice/machinetimeline` | GET | (per-event array) | per-machine fanout via Architecture A; PerEntityFanout |
| MDE_PendingActions_CL | `/apiproxy/mtp/actionCenter/actioncenterui/pending-actions` | GET | `Results` | actions awaiting approval |

### XspmGraph tier (1h — XSPM posture deltas)

| Stream | Path | Method | UnwrapProperty | Notes |
|---|---|---|---|---|
| MDE_XspmAttackPaths_CL | `/apiproxy/mtp/xspm/api/attack-paths` | POST | (paged) | XSPM attack-path graph |
| MDE_XspmChokePoints_CL | `/apiproxy/mtp/xspm/api/chokepoints` | POST | (paged) | XSPM chokepoints |
| MDE_XspmTopTargets_CL | `/apiproxy/mtp/xspm/api/top-targets` | POST | (paged) | XSPM top targets |
| MDE_XspmConnectors_CL | `/apiproxy/mtp/xspm/api/connectors` | GET | `connectors` | cloud connector inventory |
| MDE_XspmInitiatives_CL | `/apiproxy/mtp/xspm/api/initiatives` | GET | `initiatives` | XSPM initiatives |
| MDE_AttackSurfaceAttackPaths_CL | `/apiproxy/mtp/attackSurface/api/attackPaths` | POST | (paged) | attack surface paths |
| MDE_AttackSurfaceChokepoints_CL | `/apiproxy/mtp/attackSurface/api/chokepoints` | POST | (paged) | attack surface chokepoints |
| MDE_ExposureRecommendations_CL | `/apiproxy/mtp/exposureManagement/recommendations` | GET | `value` | XSPM remediation guidance |
| MDE_ExposureSnapshots_CL | `/apiproxy/mtp/exposureManagement/snapshots` | GET | `snapshots` | posture snapshots |
| MDE_AssetRules_CL | `/apiproxy/mtp/exposureManagement/assetClassificationRules` | GET | `rules` | operator-defined criticality rules |
| MDE_AppsSecureScore_CL | `/apiproxy/mtp/exposureManagement/secureScore/apps` | GET | (singleton) | apps secure score; `SyntheticEntityId='apps-secure-score-singleton'` |
| MDE_DataSecureScore_CL | `/apiproxy/mtp/exposureManagement/secureScore/data` | GET | (singleton) | data secure score; SyntheticEntityId |
| MDE_IdentitySecureScore_CL | `/apiproxy/mtp/exposureManagement/secureScore/identity` | GET | (singleton) | identity secure score; SyntheticEntityId |
| MDE_PostureInitiativesSummarized_CL | `/apiproxy/mtp/exposureManagement/initiatives/summarized` | GET | `summarized` | initiatives summary |
| MDE_PostureMetrics_CL | `/apiproxy/mtp/exposureManagement/metrics` | GET | `metrics` | posture metrics |
| MDE_PostureSecurityEvents_CL | `/apiproxy/mtp/exposureManagement/securityEvents` | GET | `events` | drift events with `resourceId` + `resourceType` |
| MDE_PostureTenants_CL | `/apiproxy/mtp/exposureManagement/tenants` | GET | (singleton) | tenant posture singleton; SyntheticEntityId |
| MDE_SAClassification_CL | `/apiproxy/mdi/identity/userapiservice/serviceAccounts/classification` | GET | `classifications` | SA classification |
| MDE_AssetClassificationSchema_CL | `/apiproxy/mtp/exposureManagement/assetClassificationSchema` | GET | (singleton) | asset classification schema; `SyntheticEntityId='asset-classification-schema-singleton'` |
| MDE_IdentityLateralMovementPaths_CL | `/apiproxy/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount` | GET | `entries` | LMP graph |

### Configuration tier (6h — config-as-code)

| Stream | Path | Method | UnwrapProperty | Notes |
|---|---|---|---|---|
| MDE_AlertServiceConfig_CL | `/apiproxy/mtp/configuration/alertServiceConfig` | GET | (singleton) | alert service config singleton |
| MDE_AlertTuning_CL | `/apiproxy/mtp/configuration/alertTuning` | GET | `items` | alert tuning rules |
| MDE_ConnectedApps_CL | `/apiproxy/mtp/configuration/connectedApps` | GET | `apps` | app registrations |
| MDE_CustomDetections_CL | `/apiproxy/mtp/configuration/customDetections` | GET | `detections` | custom detection rules |
| MDE_IntuneConnection_CL | `/apiproxy/mtp/configuration/intuneConnection` | GET | (singleton) | Intune integration status |
| MDE_PreviewFeatures_CL | `/apiproxy/mtp/configuration/previewFeatures` | GET | (singleton) | preview feature flags; SingleObjectAsRow |
| MDE_PurviewSharing_CL | `/apiproxy/mtp/configuration/purviewSharing` | GET | `value` | Purview integration; SingleObjectAsRow |
| MDE_RbacDeviceGroups_CL | `/apiproxy/mtp/configuration/rbac/deviceGroups` | GET | `groups` | RBAC machine groups |
| MDE_SuppressionRules_CL | `/apiproxy/mtp/configuration/suppressionRules` | GET | `rules` | alert suppression rules |
| MDE_TenantAllowBlock_CL | `/apiproxy/mtp/configuration/tenantAllowBlock` | GET | `entries` | TI allow/block list |
| MDE_UnifiedRbacRoles_CL | `/apiproxy/mtp/configuration/unifiedRbac/roles` | GET | `roles` | unified RBAC roles |
| MDE_UserPreferences_CL | `/apiproxy/mtp/configuration/userPreferences` | GET | (singleton) | per-SA preferences |
| MDE_CloudAppsConfig_CL | `/apiproxy/mtp/cloudAppSecurity/configuration` | GET | (singleton) | MCAS integration config |
| MDE_ThreatAnalytics_CL | `/apiproxy/mtp/threatAnalytics` | GET | `threats` | threat analytics overview |
| MDE_ThreatAnalyticsEnriched_CL | `/apiproxy/mtp/threatAnalytics/enriched` | GET | `enriched` | threat analytics enriched |
| MDE_ThreatAnalyticsTopThreats_CL | `/apiproxy/mtp/threatAnalytics/topThreats` | GET | (singleton) | top threats summary; SingleObjectAsRow |
| MDE_AdvancedFeatures_CL | `/apiproxy/mtp/configuration/advancedFeatures` | GET | (property bag) | tenant features singleton |
| MDE_AntivirusPolicy_CL | `/apiproxy/mtp/configuration/securityPolicies/filters?platform=Windows` | GET | `filters` | AV policy filters (Architecture C platform fanout: Windows + Linux + macOS + iOS in single stream) |
| MDE_SecurityPolicies_CL | `/apiproxy/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies` | POST `{platform: <X>}` | `policies` | Architecture C PerPlatformFanout × 4 platforms |
| MDE_AuthenticatedTelemetry_CL | `/apiproxy/mtp/configuration/authenticatedTelemetry` | GET | (singleton) | telemetry auth config |
| MDE_CustomCollection_CL | `/apiproxy/mtp/mdeCustomCollection/rules` | GET | `rules` | custom collection rules; tenant-license-gated |
| MDE_DeviceControlPolicy_CL | `/apiproxy/mtp/configuration/deviceControl` | GET | `policy` | device control policy; SingleObjectAsRow |
| MDE_LiveResponseConfig_CL | `/apiproxy/mtp/configuration/liveResponse` | GET | (singleton) | LR policy singleton |
| MDE_PUAConfig_CL | `/apiproxy/mtp/configuration/pua` | GET | (singleton) | PUA policy singleton |
| MDE_SmartScreenConfig_CL | `/apiproxy/mtp/configuration/smartScreen` | GET | (singleton) | SmartScreen singleton |
| MDE_WebContentFiltering_CL | `/apiproxy/mtp/configuration/webContentFiltering` | GET | `categories` | web filtering policy |

### Inventory tier (24h — per-device + per-tenant inventory)

| Stream | Path | Method | UnwrapProperty | Notes |
|---|---|---|---|---|
| MDE_Machines_CL | `/apiproxy/mtp/ndr/machines?hideLowFidelityDevices=true&lookingBackIndays=30&pageSize=200` | GET | `machines` | device inventory base; foundation for Architecture A PerEntityFanout |
| MDE_LicenseReport_CL | `/apiproxy/mtp/deviceManagement/deviceLicenseReport` | GET | `report` | license inventory |
| MDE_TenantContext_CL | `/apiproxy/mtp/multiTenant/tenantContext` | GET | (singleton) | tenant capability flags singleton |
| MDE_TenantWorkloadStatus_CL | `/apiproxy/mtp/multiTenant/workloadStatus` | GET | (singleton) | workload provisioning status |
| MDE_MtoTenants_CL | `/apiproxy/mtoapi/tenants` | GET | `tenantInfoList` | cross-tenant inventory |
| MDE_DCCoverage_CL | `/apiproxy/aatp/api/sensors/domainControllerCoverage` | GET | `domainControllers` | MDI sensor coverage; tenant-license-gated |
| MDE_IdentityAlertThresholds_CL | `/apiproxy/aatp/api/configuration/alertThresholds` | GET | (singleton) | MDI alert thresholds; tenant-license-gated |
| MDE_IdentityOnboarding_CL | `/apiproxy/aatp/api/onboarding/status` | GET | (singleton) | MDI onboarding status |
| MDE_IdentityServiceAccounts_CL | `/apiproxy/mdi/identity/userapiservice/serviceAccounts` | GET | `ServiceAccounts` | MDI service accounts |
| MDE_RemediationAccounts_CL | `/apiproxy/aatp/api/ispmReports/RemediationAccounts/newEntryCount` | GET | `entries` | remediation accounts; tenant-license-gated |
| MDE_IdentityDormantAccounts_CL | `/apiproxy/aatp/api/ispmReports/DormantEntities/newEntryCount` | GET | `entries` | dormant identities |
| MDE_VulnerableMachines_CL | `/apiproxy/mtp/tvm/analytics/vulnerableMachines` | GET | `value` | top-N CVE-exposed machines (Architecture B fanout source) |
| MDE_VulnerabilityInventory_CL | `/apiproxy/mtp/tvm/analytics/vulnerabilities` | GET | `value` | CVE list with prevalence; ProjectionMap fixes: `id` → `CveId`, `publishedOn` → `PublishedDate`, `numOfImpactedAssets` → `AssetCount` |
| MDE_SoftwareInventory_CL | `/apiproxy/mtp/tvm/analytics/software` | GET | `value` | installed software per machine |
| MDE_RecommendationActions_CL | `/apiproxy/mtp/tvm/analytics/recommendations` | GET | `value` | actionable security recs |
| MDE_SecurityBaselines_CL | `/apiproxy/mtp/tvm/analytics/vulnerabilities/baseline` | GET | `value` | TVM security baselines; tenant-license-gated (TvmPremium) |
| MDE_VulnerabilityCertificates_CL | `/apiproxy/mtp/tvm/analytics/certificates` | GET | `value` | cert inventory |
| MDE_VulnerabilitySummary_CL | `/apiproxy/mtp/tvm/analytics/vulnerabilities/summary` | GET | (singleton) | severity counts singleton |
| MDE_VulnerabilityExtensions_CL | `/apiproxy/mtp/tvm/analytics/extensions` | GET | `value` | browser extension inventory |
| MDE_VulnerabilityAssetCountByExposure_CL | `/apiproxy/mtp/tvm/analytics/vulnerableMachines/byExposure` | GET | `value` | exposure distribution |
| MDE_VulnerabilityAdvisories_CL | `/apiproxy/mtp/tvm/analytics/vulnerabilities/advisories` | GET | `value` | vendor advisories |

### Maintenance tier (7d — rare-change ops)

| Stream | Path | Method | UnwrapProperty | Notes |
|---|---|---|---|---|
| MDE_DataExportSettings_CL | `/apiproxy/mtp/configuration/dataExport` | GET | `destinations` | streaming data destinations |
| MDE_StreamingApiConfig_CL | `/apiproxy/mtp/streamingApi/config` | GET | (singleton) | DEPRECATED — kept for forward-compat detection |

## Endpoint behavior notes

### Path drift fixes (v0.1.0 GA)

Three streams had ProjectionMap drift discovered during 2026-05-08 sweep:

| Stream | Original ProjectionMap | Corrected ProjectionMap | nodoc canonical |
|---|---|---|---|
| MDE_VulnerabilityInventory_CL | `cveId` / `publishedDate` / `assetsAffected` | `id` / `publishedOn` / `numOfImpactedAssets` | `vulnerability_management.yml:556` |
| MDE_SoftwareInventory_CL | `productId` / `productName` / `assetCount` | `id` / `name` / `assetsStatistics.totalAssetCount` | `vulnerability_management.yml` |
| MDE_VulnerableMachines_CL | `assetId` / `machineName` / `cveCount` | `id` / `name` / `discoveredVulnerabilities` | `vulnerability_management.yml` |

### UnwrapProperty defensive auto-discovery

Per Plan AMEND-9 Phase A.2 (commit `0f93c6a`), `Expand-MDEResponse` (`src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1:304-380`) implements wrapper auto-discovery: when declared `UnwrapProperty` target is null, scans response object for non-null array properties; if exactly one found, uses it; if multiple, picks largest by `.Count`; emits `Ingest.UnwrapAutoDiscovered` event. Defends against upstream Defender portal API response-shape drift (e.g., 2026-05-09 ActionCenter regression where `Results` wrapper key disappeared).

### SuccessKind classification (runtime)

Per Plan R++.A: `Get-MDEEndpointLastResult` side-channel propagates 4-state SuccessKind:
- **live** — HTTP 200 with rows
- **live-empty** — HTTP 200 with `{}` or `[]`
- **tenant-gated** — HTTP 4xx (license/feature unavailable in this tenant)
- **error** — HTTP 5xx or transport error

NO hardcoded license gating in manifest. All streams marked `Availability='live'` regardless of lab tenant 4xx response. Runtime classifies dynamically per actual customer deployment.

### Architecture-driven streams

| Stream | Architecture | Pattern |
|---|---|---|
| MDE_DeviceTimeline_CL | A — PerEntityFanout | iterates per-machine via MDE_Machines_CL inventory; per-entity composite checkpoint |
| MDE_AntivirusPolicy_CL | C — PerPlatformFanout | iterates 4 platforms (Windows/Linux/macOS/iOS) within single stream; Platform col tagging per row |
| MDE_SecurityPolicies_CL | C — PerPlatformFanout | iterates 4 platforms via POST body |
| (paginated streams) | F — Pagination | `pageIndex` / `pageSize` / `nextLink` patterns; per-page checkpoint advance |

### Per-stream IdProperty / SyntheticEntityId

For drift-join compatibility (parsers use mv-apply set_union per EntityId):

- **IdProperty** — composite key from raw response (e.g., `IdProperty=@('machineId')`)
- **SyntheticEntityId** — fixed singleton key for SingleObjectAsRow streams (e.g., `'apps-secure-score-singleton'`)

Streams with `idx-N` synthetic fallback are bugs (drift-join breaks); fixed in Phase 1+ commits.

## Adding a new stream (contributor workflow)

1. **Live-test the endpoint**: `pwsh tools/Capture-EndpointSchemas.ps1 -CandidateEndpoints @{Stream='MDE_<NewStream>_CL';Path='<canonical>';Method='GET'}` — write fixture to `tests/fixtures/live-responses-candidates/`
2. **Classify SuccessKind verdict**: live / live-empty / tenant-gated / error
3. **Build ProjectionMap from REAL response** (NOT from nodoc placeholder schemas)
4. **Add manifest entry** to `endpoints.manifest.psd1` with all required fields (Stream / Path / Method / Tier / Category / Purpose / Availability / IdProperty / UnwrapProperty / ProjectionMap)
5. **Add DCR streamDecl + transformKql** in `mainTemplate.json` (auto via `tools/Build-DcrSection.ps1`)
6. **Add workspace cols** to `Defender_<Category>_CL` in `mainTemplate.json customTables`
7. **Add DCR_IMMUTABLE_IDS_JSON** env var entry
8. **Update test baselines**: `Manifest.SchemaContract` / `DCR.SchemaConsistency` / `WireChaining` count expectations
9. **Capture fixture**: `tools/Capture-EndpointSchemas.ps1 -StreamFilter '<Stream>'`
10. **Recompile sentinelContent.json**: `tools/Build-SentinelContent.ps1`
11. **Run full pyramid**: `tests/Run-Tests.ps1 -Category all-offline` → 0 fail
12. **Run WiringAudit**: `tools/Run-WiringAudit.ps1` → N+1/N+1 streams clean
13. **Pre-Commit-Check**: `tools/Pre-Commit-Check.ps1` → GREEN
14. **Single squash commit** + push + CI green

## References

- Manifest source: [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1)
- Endpoint dispatch: [`src/Modules/Xdr.Defender.Client/Public/Invoke-MDEEndpoint.ps1`](../src/Modules/Xdr.Defender.Client/Public/Invoke-MDEEndpoint.ps1)
- Response-shape unwrap: [`src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1`](../src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1)
- Live capture tool: [`tools/Capture-EndpointSchemas.ps1`](../tools/Capture-EndpointSchemas.ps1)
- Live fixtures: [`tests/fixtures/live-responses/`](../tests/fixtures/live-responses/)
- Capture summary: [`tests/fixtures/live-responses/_capture-summary.json`](../tests/fixtures/live-responses/_capture-summary.json)
- Cross-portal catalogues (v0.2.0+): [`tests/online/CrossPortalCatalog-*.md`](../tests/online/)
- nodoc reference: `.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/` (10 categories)
- XDRInternals reference: [Get-XdrInternal cmdlet library](https://github.com/MSCloudInternals/MSCloudInternals)
