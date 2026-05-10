# Canonical Sentinel Entity Type Contract (Architecture J)

> **Purpose**: defines canonical entity-field convention applied across ALL workspace tables so operators can `join` cleanly across categories AND across portals (v0.2.0+).
>
> **Status**: BINDING for v0.1.0 GA + all future portal additions. Backward-compat preserved (raw response fields stay alongside canonical aliases).
>
> **Source of truth**: per-stream `ProjectionMap` declarations in [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1).

## Why this exists

Without canonical entity-field convention, operators write:
```kql
// Broken — different streams use different field names
Defender_VulnerabilityManagement_CL
| where SourceName == 'MDE_VulnerableMachines_CL'
| join kind=inner (
    Defender_EndpointConfiguration_CL | where SourceName == 'MDE_AntivirusPolicy_CL'
) on $left.machineId == $right.deviceId  // names differ!
```

With Architecture J canonical cols, operators write:
```kql
Defender_VulnerabilityManagement_CL
| where SourceName == 'MDE_VulnerableMachines_CL'
| join kind=inner (
    Defender_EndpointConfiguration_CL | where SourceName == 'MDE_AntivirusPolicy_CL'
) on HostMdatpId  // canonical entity col; same name everywhere
```

Cross-portal extension (v0.2.0+):
```kql
Entra_AuthenticationMethods_CL
| where AccountUPNSuffix == 'contoso.com'
| join kind=inner Defender_ActionCenter_CL on AccountObjectId
```

## Canonical entity types (13 universal)

Aligned with [Microsoft Sentinel Entity Type schema](https://learn.microsoft.com/en-us/azure/sentinel/entities-reference) so analytic rules' `entityMappings` auto-extract entities + investigation graph pivots work natively.

### Host (device)

| Canonical column | Type | Source field mapping (typical) |
|---|---|---|
| `HostName` | string | hostname only (e.g., `WORKSTATION01`) |
| `HostFullName` | string | FQDN / `computerDnsName` (e.g., `workstation01.contoso.com`) |
| `HostDnsDomain` | string | domain part (e.g., `contoso.com`) |
| `HostMdatpId` | string | Defender `machineId` GUID |
| `HostAadId` | string | Azure AD device ID (where present) |
| `HostOSFamily` | string | Windows / Linux / macOS / iOS / Android |

**Streams that populate**: EndpointDeviceMgmt + EndpointConfiguration + VulnerabilityMgmt + ActionCenter + ExposureMgmt (any stream returning per-device data).

### Account (user)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `AccountName` | string | sAMAccountName / left-of-`@` UPN |
| `AccountUPNSuffix` | string | right-of-`@` UPN (e.g., `contoso.com`) |
| `AccountObjectId` | string | Azure AD user object GUID |
| `AccountSid` | string | on-prem SID (where present) |

**Streams that populate**: IdentityProtection + ActionCenter (per-user response actions) + Configuration (RBAC role assignments).

### IP

| Canonical column | Type | Source field mapping |
|---|---|---|
| `IpAddress` | string | `ipAddress` / `lastSeenIp` / `localIp` |

**Streams that populate**: EndpointDeviceMgmt (latest IPs) + ThreatAnalytics (indicator reputation) + IdentityProtection (signin IPs).

### File

| Canonical column | Type | Source field mapping |
|---|---|---|
| `FileName` | string | `fileName` |
| `FileDirectory` | string | `filePath` directory portion |
| `FileHashType` | string | SHA1 / SHA256 / MD5 |
| `FileHashValue` | string | hex hash value |

**Streams that populate**: Files (per-file events) + ThreatAnalytics (file reputation) + ActionCenter (file response actions).

### URL

| Canonical column | Type | Source field mapping |
|---|---|---|
| `Url` | string | `url` / `urlValue` |

**Streams that populate**: ThreatAnalytics + EntityPivots + Configuration (TI indicators).

### DNS

| Canonical column | Type | Source field mapping |
|---|---|---|
| `DomainName` | string | `domain` / `domainName` |

**Streams that populate**: ThreatAnalytics + EntityPivots.

### Process

| Canonical column | Type | Source field mapping |
|---|---|---|
| `ProcessName` | string | `processName` / `imageName` |
| `ProcessCommandLine` | string | `commandLine` |

**Streams that populate**: EndpointDeviceMgmt per-machine processes (Tier B PerEntityFanout).

### AzureResource

| Canonical column | Type | Source field mapping |
|---|---|---|
| `ResourceId` | string | `azureResourceId` / `arn` |

**Streams that populate**: ExposureMgmt (cloud asset inventory).

### CVE (custom Sentinel-extension)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `CveId` | string | `id` (per nodoc canonical) / `cveId` / `vulnerabilityId` |

**Streams that populate**: VulnerabilityMgmt + per-CVE drilldowns (Tier B).

### Outbreak (custom)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `OutbreakId` | string | `outbreakId` / `threatId` |

**Streams that populate**: ThreatAnalytics + per-outbreak Tier B.

### AlertId (for SecurityAlert join)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `AlertId` | string | `alertId` / `incidentId` |

**Streams that populate**: ActionCenter (response actions linked to alerts).

### PolicyId (custom)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `PolicyId` | string | `policyId` / `policyName` |

**Streams that populate**: Configuration + EndpointConfiguration.

### MachineGroup (custom RBAC)

| Canonical column | Type | Source field mapping |
|---|---|---|
| `MachineGroupId` | string | `groupId` |
| `MachineGroupName` | string | `groupName` |

**Streams that populate**: Configuration (RBAC) + EndpointDeviceMgmt.

## Implementation rules

### Rule 1: Apply WHERE the source response carries the field

Don't force entity columns that don't exist in the API response. A stream's `ProjectionMap` only includes canonical entity cols when the field is present.

Per-stream classification:
- **Primary entity stream** (e.g., `MDE_Machines_CL` is centrally about Host) → populate Host fields fully
- **Drilldown stream** (Tier B PerEntityFanout, e.g., `MDE_VulnerabilityAssetVulnerabilities_CL`) → populate BOTH source entity (`HostMdatpId`) AND drilled-into entity (`CveId`)
- **Aggregate stream** (e.g., `MDE_VulnerabilityCertificates_CL` per-cert may have machine-count rollup) → populate the indexed entity if present
- **Pure config stream** (e.g., `MDE_AdvancedFeatures_CL` is tenant-level singleton) → no canonical entity cols populated; just `EntityId='advanced-features-singleton'`

### Rule 2: ProjectionMap convention

Every stream's `ProjectionMap` declares which canonical entity fields it populates from its raw response:
```powershell
ProjectionMap = @{
    # ... typed cols ...
    HostMdatpId  = '$tostring:machineId'
    HostFullName = '$tostring:computerDnsName'
    AccountUPNSuffix = '$tostring:userPrincipalName.Split(''@'')[1]'
    CveId        = '$tostring:id'  # nodoc canonical
}
```

### Rule 3: DCR streamDecl declares canonical cols

Every `Custom-MDE_<Stream>_CL` streamDecl declares the relevant canonical entity columns with consistent types (`string` for all entity IDs).

### Rule 4: Workspace table includes canonical cols per category

Each `Defender_<Category>_CL` table column schema includes the canonical entity columns relevant to streams in that category. Cross-stream within a category share columns; cross-category use the same column names so `join` works.

### Rule 5: Sentinel content uses canonical fields

Analytic rules' `entityMappings` populate native Sentinel Entity Types from canonical fields. Hunting queries + workbook panels use canonical field names natively.

Example analytic rule mapping:
```yaml
entityMappings:
  - entityType: Host
    fieldMappings:
      - identifier: HostName
        columnName: HostName
      - identifier: NTDomain
        columnName: HostDnsDomain
      - identifier: AzureID
        columnName: HostAadId
      - identifier: MdatpDeviceId
        columnName: HostMdatpId
  - entityType: Account
    fieldMappings:
      - identifier: Name
        columnName: AccountName
      - identifier: UPNSuffix
        columnName: AccountUPNSuffix
      - identifier: AadUserId
        columnName: AccountObjectId
```

### Rule 6: Backward compatibility

Original raw response fields preserved alongside canonical aliases. Operators with hand-written queries against `MachineId` continue to work; new queries can use canonical `HostMdatpId`. RawJson preserved on every row for forensic queries.

## Cross-portal extension contract (v0.2.0+)

Future portals declare canonical cols where applicable:

| Portal | Primary entity types | Examples |
|---|---|---|
| Entra | Account + Host (device-bound) + Group | `Entra_AuthenticationMethods_CL.AccountObjectId` joins `Defender_ActionCenter_CL.AccountObjectId` |
| Purview | Account + File + MailMessage* | `Purview_DLP_CL.AccountUPNSuffix` joins `Defender_IdentityProtection_CL.AccountUPNSuffix` |
| Intune | Host + PolicyId | `Intune_CompliancePolicies_CL.HostMdatpId` joins `Defender_EndpointDeviceManagement_CL.HostMdatpId` |
| Power Platform | AzureResource + Account | `PowerPlatform_Apps_CL.AccountObjectId` joins `Entra_*_CL.AccountObjectId` |
| M365 Admin | Account + Group | `M365Admin_Users_CL.AccountUPNSuffix` joins anything |
| SharePoint | Account + File + Url | `SharePoint_Audit_CL.Url` joins `Defender_ThreatAnalytics_CL.Url` |
| Teams | Account + MailMessage* | `Teams_Audit_CL.AccountObjectId` joins anywhere |
| Security Copilot | (singleton) | tenant-level, no entity correlation |

`*MailMessage` is a Sentinel Entity Type extension; only Purview + Teams populate.

Universal types (Host / Account / IP / File / URL / DNS / Process / AzureResource / CVE) work across all portals.

## Per-stream entity-col matrix (current 72 v0.1.0 GA streams)

> Auto-derived from `endpoints.manifest.psd1` ProjectionMap fields. Generation: future tool `tools/Build-EntityMatrix.ps1` (deferred to v0.1.0.x patch).

| Stream | Tier | Category | Primary Host cols | Primary Account cols | Other entity cols |
|---|---|---|---|---|---|
| MDE_Machines_CL | Inventory | Endpoint Device Mgmt | HostName / HostFullName / HostMdatpId / HostAadId / HostOSFamily / IpAddress | — | — |
| MDE_DeviceTimeline_CL | ActionCenter | Endpoint Device Mgmt | HostMdatpId | AccountName / AccountUPNSuffix | ProcessName / ProcessCommandLine / FileName |
| MDE_VulnerabilityInventory_CL | Inventory | TVM | — | — | CveId / PublishedDate / AssetCount |
| MDE_VulnerableMachines_CL | Inventory | TVM | HostMdatpId / HostFullName | — | CveCount |
| MDE_SoftwareInventory_CL | Inventory | TVM | — | — | ProductId / ProductName / AssetCount |
| MDE_RecommendationActions_CL | Inventory | TVM | — | — | RecommendationId / Severity |
| MDE_SecurityBaselines_CL | Inventory | TVM | HostMdatpId | — | PolicyId |
| MDE_ActionCenter_CL | ActionCenter | Action Center | HostMdatpId | AccountUPNSuffix | AlertId / FileName |
| MDE_AdvancedFeatures_CL | Configuration | Endpoint Configuration | — | — | (tenant singleton) |
| MDE_AntivirusPolicy_CL | Configuration | Endpoint Configuration | — | — | PolicyId / Platform |
| MDE_SecurityPolicies_CL | Configuration | Endpoint Configuration | — | — | PolicyId / Platform |
| MDE_AlertServiceConfig_CL | Configuration | Configuration & Settings | — | — | (tenant singleton) |
| MDE_AlertTuning_CL | Configuration | Configuration & Settings | HostMdatpId | AccountUPNSuffix | AlertId |
| MDE_AssetClassificationSchema_CL | XspmGraph | Configuration & Settings | — | — | (tenant singleton) |
| MDE_RbacDeviceGroups_CL | Configuration | Configuration & Settings | — | — | MachineGroupId / MachineGroupName |
| MDE_UnifiedRbacRoles_CL | Configuration | Configuration & Settings | — | AccountObjectId | (role assignments) |
| MDE_TenantContext_CL | Inventory | Multi-Tenant Operations | — | — | (tenant capability flags) |
| MDE_TenantWorkloadStatus_CL | Inventory | Multi-Tenant Operations | — | — | (workload provisioning) |
| MDE_MtoTenants_CL | Inventory | Multi-Tenant Operations | — | — | (cross-tenant inventory) |
| MDE_DCCoverage_CL | Inventory | Identity Protection | HostFullName | — | (MDI sensor coverage) |
| MDE_IdentityServiceAccounts_CL | Inventory | Identity Protection | — | AccountObjectId / AccountUPNSuffix | (SA inventory) |
| MDE_IdentityAlertThresholds_CL | Inventory | Identity Protection | — | — | (tenant singleton) |
| MDE_IdentityOnboarding_CL | Inventory | Identity Protection | — | — | (MDI status) |
| MDE_RemediationAccounts_CL | Inventory | Identity Protection | — | AccountObjectId | (remediation status) |
| MDE_SAClassification_CL | XspmGraph | Identity Protection | — | AccountObjectId | (SA classification) |
| MDE_ThreatAnalytics_CL | Configuration | Threat Analytics | — | — | OutbreakId |
| MDE_ThreatAnalyticsEnriched_CL | Configuration | Threat Analytics | — | — | OutbreakId |
| MDE_ThreatAnalyticsTopThreats_CL | Configuration | Threat Analytics | — | — | OutbreakId |
| MDE_XspmAttackPaths_CL | XspmGraph | Exposure Management | — | — | (attack path graph) |
| MDE_XspmChokePoints_CL | XspmGraph | Exposure Management | HostMdatpId | — | (chokepoint nodes) |
| MDE_XspmTopTargets_CL | XspmGraph | Exposure Management | HostMdatpId | — | (high-value targets) |
| MDE_XspmConnectors_CL | XspmGraph | Exposure Management | — | — | (cloud connector inventory) |
| MDE_XspmInitiatives_CL | XspmGraph | Exposure Management | — | — | (security initiatives) |
| MDE_AttackSurfaceAttackPaths_CL | XspmGraph | Exposure Management | — | — | (attack surface paths) |
| MDE_AttackSurfaceChokepoints_CL | XspmGraph | Exposure Management | HostMdatpId | — | (chokepoint analysis) |
| MDE_ExposureRecommendations_CL | XspmGraph | Exposure Management | — | — | RecommendationId |
| MDE_ExposureSnapshots_CL | XspmGraph | Exposure Management | — | — | (posture snapshot) |
| MDE_AssetRules_CL | XspmGraph | Exposure Management | — | — | (asset criticality rules) |
| MDE_AppsSecureScore_CL | XspmGraph | Exposure Management | — | — | (apps secure score singleton) |
| MDE_DataSecureScore_CL | XspmGraph | Exposure Management | — | — | (data secure score singleton) |
| MDE_IdentitySecureScore_CL | XspmGraph | Exposure Management | — | — | (identity secure score singleton) |
| MDE_PostureInitiativesSummarized_CL | XspmGraph | Exposure Management | — | — | (initiatives summary) |
| MDE_PostureMetrics_CL | XspmGraph | Exposure Management | — | — | (posture metrics) |
| MDE_PostureSecurityEvents_CL | XspmGraph | Exposure Management | ResourceId | — | (security events) |
| MDE_PostureTenants_CL | XspmGraph | Exposure Management | — | — | (tenant posture singleton) |
| MDE_LicenseReport_CL | Inventory | Endpoint Device Mgmt | — | — | (license inventory) |
| MDE_LiveResponseConfig_CL | Configuration | Endpoint Configuration | — | — | (LR policy singleton) |
| MDE_DeviceControlPolicy_CL | Configuration | Endpoint Configuration | — | — | PolicyId |
| MDE_WebContentFiltering_CL | Configuration | Endpoint Configuration | — | — | PolicyId / DomainName |
| MDE_SmartScreenConfig_CL | Configuration | Endpoint Configuration | — | — | (SmartScreen singleton) |
| MDE_PUAConfig_CL | Configuration | Endpoint Configuration | — | — | (PUA policy singleton) |
| MDE_AuthenticatedTelemetry_CL | Configuration | Endpoint Configuration | — | — | (authenticated telemetry config) |
| MDE_CustomCollection_CL | Configuration | Endpoint Configuration | — | — | (custom rules) |
| MDE_ConnectedApps_CL | Configuration | Configuration & Settings | — | AccountObjectId | (app registrations) |
| MDE_CustomDetections_CL | Configuration | Configuration & Settings | — | — | (custom detection rules) |
| MDE_IntuneConnection_CL | Configuration | Configuration & Settings | — | — | (Intune integration status) |
| MDE_PreviewFeatures_CL | Configuration | Configuration & Settings | — | — | (preview feature flags singleton) |
| MDE_PurviewSharing_CL | Configuration | Configuration & Settings | — | — | (Purview integration) |
| MDE_SuppressionRules_CL | Configuration | Configuration & Settings | HostMdatpId | AccountUPNSuffix | AlertId / PolicyId |
| MDE_TenantAllowBlock_CL | Configuration | Configuration & Settings | — | — | DomainName / Url / FileHashValue |
| MDE_UserPreferences_CL | Configuration | Configuration & Settings | — | AccountObjectId | (per-SA preferences) |
| MDE_DataExportSettings_CL | Maintenance | Streaming API | — | — | (export destinations) |
| MDE_StreamingApiConfig_CL | Maintenance | Streaming API | — | — | DEPRECATED |
| MDE_PendingActions_CL | ActionCenter | Action Center | HostMdatpId | AccountUPNSuffix | AlertId |
| MDE_IdentityDormantAccounts_CL | Inventory | Identity Protection | — | AccountObjectId / AccountUPNSuffix | — |
| MDE_IdentityLateralMovementPaths_CL | XspmGraph | Identity Protection | — | AccountObjectId | (LMP graph) |
| MDE_VulnerabilityCertificates_CL | Inventory | TVM | — | — | (cert inventory) |
| MDE_VulnerabilitySummary_CL | Inventory | TVM | — | — | (severity counts singleton) |
| MDE_VulnerabilityExtensions_CL | Inventory | TVM | — | — | (browser ext inventory) |
| MDE_VulnerabilityAssetCountByExposure_CL | Inventory | TVM | — | — | (exposure distribution) |
| MDE_VulnerabilityAdvisories_CL | Inventory | TVM | — | — | (vendor advisories) |

**Total: 72 streams**. Future v0.2.0+ portal streams extend this matrix per portal categories.

## Verification gate (offline)

`tests/arm/EntityFieldCoverage.Tests.ps1` (deferred to v0.1.0.x patch) — asserts each consolidated `Defender_<Cat>_CL` table has the expected canonical entity cols + each stream's ProjectionMap populates the expected ones per matrix above.

## References

- [Microsoft Sentinel entities reference](https://learn.microsoft.com/en-us/azure/sentinel/entities-reference)
- [Architecture J in Plan SECTION FINAL.MASTER](../.claude/plans/immutable-splashing-waffle.md) (canonical entity contract)
- Manifest source: [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1)
- DCR transformKql canonical projections: [`deploy/compiled/mainTemplate.json`](../deploy/compiled/mainTemplate.json) (DCR section)
- Drift parsers preserving canonical cols: [`sentinel/parsers/MDE_Drift_*.kql`](../sentinel/parsers/)
