# XDRInternals · Cmdlet Inventory Reference

> Cross-validation source for our OpenAPI operationIds. Use when deriving a manifest entry to confirm an Operation has community precedent.

## Per-workload cmdlet samples (~120+ documented · this is a representative subset)

### Defender XDR core (MTP)

- `Get-XdrTenantContext` · returns tenant info (cached)
- `Get-XdrTenantWorkloadStatus` · evaluates workload license per tenant
- `Get-XdrMtoTenantList` · multi-tenant org enumeration

### Action Center (ActionCenter category in our manifests)

- `Get-XdrActionCenterHistory` · list completed actions (live-tenant-verified: 1,870 rows in lab)
- `Get-XdrActionCenterPending` · queue of pending actions
- `Get-XdrActionCenterFilters` · filter options for UI
- `Get-XdrActionCenterTileSummary` · dashboard tile summary

→ ActionCenter is our v0.1.0-alpha PILOT candidate (top-ranked per Plan §5.2 + §7.7).

### Advanced Hunting

- `Invoke-XdrHuntingQueryValidation` · validate KQL syntax
- `Get-XdrAdvancedHuntingSchema` · column schemas
- `Get-XdrAdvancedHuntingFunctions` · custom functions
- `Get-XdrAdvancedHuntingUnifiedDetectionRules` · detection rule inventory

### Streaming API

- `Get-XdrStreamingApiConfiguration` · returns tenant streaming export config (in operator's lab tenant: `{"_availability":"tenant-gated","_reason":"404"}` · feature not enabled · DROPPED as pilot)

### Endpoint (MDE)

- `Get-XdrEndpointDevice` · device inventory (paginated · `-PageSize` · `-All`)
- `Get-XdrEndpointConfigurationCustomCollectionRule` · custom collection rules (YAML output supported)
- `Get-XdrEndpointAdvancedFeatures` · feature flag state
- `Get-XdrEndpointSecureScoreMetric` · per-metric secure score
- `Get-XdrEndpointLicenseReport` · explicit MDE license usage report
- `Get-XdrEndpointMachineActions` · machine action history
- `Get-XdrEndpointLiveResponseConfig` · LR config snapshot

### Identity (MDI)

- `Get-XdrIdentityUser` · user inventory
- `Get-XdrIdentityServiceAccount` · service account inventory
- `Get-XdrIdentityLateralMovementPaths` · LMP graph
- `Get-XdrIdentityTimeline` · per-identity activity timeline

### Cloud Apps (MCAS)

- `Get-XdrCloudAppsActivityTimeline -LastNDays N` · activity log (proves TimeFilter pattern)
- `Get-XdrCloudAppsPolicy` · policy inventory
- `Get-XdrCloudAppsDiscovery` · shadow IT discovery
- `Get-XdrCloudAppsGovernance` · governance actions

### Vulnerability Management (MDVM)

- `Get-XdrVulnerabilityAdvisories` · CVE advisories
- `Get-XdrVulnerabilityRemediations` · remediation actions
- `Get-XdrVulnerabilityBaselines` · baseline assessment
- `Get-XdrVulnerabilityProducts` · software inventory with vulnerabilities

### Attack Surface (XSPM · Microsoft Security Exposure Management)

- `Get-XdrAttackSurfaceAttackPaths` · attack path analysis
- `Get-XdrAttackSurfaceChokepoints` · choke point identification
- `Get-XdrAttackSurfaceEntryPoints` · entry point inventory
- `Get-XdrAttackSurfaceTopTargets` · high-value targets

### Threat Analytics

- `Get-XdrThreatAnalyticsOutbreaks` · active outbreaks
- `Get-XdrThreatAnalyticsEnriched` · enriched threat intel

### Datalake / Custom Detection

- `Get-XdrDatalakeDatabase` · datalake schema
- `Get-XdrDatalakeTableSchema` · per-table column schemas
- `Get-XdrCustomDetectionRule` · custom detection rule inventory

## Generic REST passthrough (NOT for direct use · prefer typed cmdlets)

- `Invoke-XdrRestMethod` · authenticated REST call with their session context

We do NOT use this. Our equivalent is `Invoke-XdrPortalHttp` in `Xdr.Common.Runtime.psm1` (private) called by `Invoke-XdrEntryPoll`.

## How we use this inventory

When deriving a manifest entry for Operation `<Category>.<OperationId>`:
1. Search this file for a matching `Get-Xdr*` cmdlet
2. If found: cite in `Provenance.XDRInternals = '<cmdlet name>'`
3. Cross-check the cmdlet's parameters against our manifest fields (Pagination · TimeFilter · etc.)
4. If our derivation contradicts XDRInternals: investigate · re-verify live capture

If no XDRInternals cmdlet exists for an Operation: `Provenance.XDRInternals = $null` and rely on Live + Postman + OpenAPI for derivation.
