# Schema catalog

> **Audience**: operators writing KQL against the custom Log Analytics tables this connector populates. This document is the per-stream column reference.
>
> **TL;DR**: every `MDE_*_CL` table has four guaranteed baseline columns (`TimeGenerated`, `SourceStream`, `EntityId`, `RawJson`). Most tables also expose a set of typed columns derived from a per-stream projection map — those typed columns are listed below. Unmapped fields stay reachable through `RawJson` for backward compatibility.

This catalog complements [STREAMS.md](STREAMS.md) (which gives the higher-level per-stream summary, polling tier, and availability) by enumerating the typed columns operators can query directly without having to reach into `RawJson`. Use [STREAMS.md](STREAMS.md) when you want the bird's-eye view of "what does this connector ship and on what cadence"; use this document when you are writing or migrating a query.

---

## Overview

### Typed-column ingest model

Every row written by the connector carries the same baseline columns:

| Column | Type | Meaning |
|---|---|---|
| `TimeGenerated` | `datetime` | When the row was ingested (the `TimeGenerated` cast in DCR `transformKql`). |
| `SourceStream` | `string` | The stream name (e.g. `MDE_AdvancedFeatures_CL`). Lets a single workspace differentiate cross-stream `union` results. |
| `EntityId` | `string` | The per-row primary identifier extracted by the response-expander (rule ID, action ID, machine ID, AAD principal ID, or — for property-bag-shaped responses — the wrapper key name). |
| `RawJson` | `dynamic` | The full response object for that row preserved verbatim. Always present; existing queries that extract fields with `parse_json(RawJson).fieldName` keep working unchanged. |

On top of those four, each stream contributes a per-stream **projection map** that flattens commonly-needed fields into their own typed columns. The projection map is declared in the connector's endpoint manifest and is what powers the typed-column ingest. Three benefits:

1. **Direct querying** — you reference `RuleId` instead of `tostring(parse_json(RawJson).Id)`.
2. **Native type semantics** — `Severity` arrives as `long` (not `string`) so `where Severity > 2` works without a cast.
3. **Index-friendly filtering** — Log Analytics can index typed columns; `where IsEnabled == false` runs faster than `where toboolean(parse_json(RawJson).IsEnabled) == false`.

### Reading the column tables below

Each per-stream section lists the typed columns the connector extracts. The format is:

| Column | KQL type | Source path | Notes |

The KQL types follow Log Analytics conventions:

| Type token in projection map | KQL type | Example values |
|---|---|---|
| `$tostring:` | `string` | `"Critical"`, `"svc-account@contoso.com"` |
| `$toint:` | `long` | `42`, `0`, `-1` |
| `$tobool:` | `bool` | `true`, `false` |
| `$todatetime:` | `datetime` | `2026-04-29T12:34:56Z` |
| `$todouble:` | `real` | `3.14`, `0.0` |
| `$json:` | `dynamic` | embedded JSON (often arrays or sub-objects) flattened to a compact dynamic value |

Empty / unmappable fields project as `null`. Operators should `where isnotempty(Column)` or `where isnotnull(Column)` defensively when joining across streams.

### What if the field I want isn't in the typed-column list?

`RawJson` always carries the full response row. If you need a field that isn't projected, fall back to:

```kql
MDE_<Stream>_CL
| extend MyField = tostring(parse_json(RawJson).fieldNameInJson)
```

This pattern continues to work indefinitely; the typed columns are additive, not a replacement. See [QUERY-MIGRATION-GUIDE.md](QUERY-MIGRATION-GUIDE.md) for the full migration recipe.

### Operational tables (not in this catalog)

Two tables are emitted by the connector itself, not polled from the portal, and follow their own fixed schema (no projection map):

- `MDE_Heartbeat_CL` — one row per timer invocation. Columns: `TimeGenerated, FunctionName, Tier, StreamsAttempted, StreamsSucceeded, RowsIngested, LatencyMs, HostName, Notes(dynamic)`. See [OPERATIONS.md](OPERATIONS.md) for the heartbeat KQL cookbook.
- `App Insights customEvents (AuthChain.* events)` — one row per auth self-test. Columns: `TimeGenerated, Method, PortalHost, Upn, Success, Stage, FailureReason, EstsMs, SccauthMs, SampleCallHttpCode, SampleCallLatencyMs, SccauthAcquiredUtc`. See [UNATTENDED-AUTH.md](UNATTENDED-AUTH.md).

The remainder of this document covers the 46 telemetry streams.

---

## P0 Compliance — hourly polling

Tenant-configuration and policy state. Drift here typically maps to a Sentinel detection. Aggregated by [`MDE_Drift_Inventory`](../sentinel/parsers/MDE_Drift_Inventory.kql).

### `MDE_AdvancedFeatures_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: tenant-wide MDE feature toggles (Tamper Protection, EDR-block, Web Content Filtering, etc.). Each row represents one feature key/value pair from the tenant's `GetAdvancedFeaturesSetting` response.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Re-exposes the property-bag key. |
| `EnableWdavAntiTampering` | `bool` | `EnableWdavAntiTampering` | Tamper Protection master switch. |
| `AatpIntegrationEnabled` | `bool` | `AatpIntegrationEnabled` | Defender-for-Identity integration flag. |
| `EnableMcasIntegration` | `bool` | `EnableMcasIntegration` | Defender-for-Cloud-Apps integration flag. |
| `AutoResolveInvestigatedAlerts` | `bool` | `AutoResolveInvestigatedAlerts` | AIR auto-resolution toggle. |

**Example**:

```kql
MDE_AdvancedFeatures_CL
| where TimeGenerated > ago(24h)
| where EnableWdavAntiTampering == false
| project TimeGenerated, FeatureName, EnableWdavAntiTampering
```

### `MDE_PreviewFeatures_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: preview-ring enrolment for tenant-wide MDE features (gradual rollout state).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `SettingId` | `string` | `EntityId` | Property-bag key (e.g. `IsOptIn`). |
| `IsOptIn` | `bool` | `IsOptIn` | Whether the tenant is on the preview ring. |
| `SliceId` | `long` | `SliceId` | Microsoft slice number for staged rollout. |

**Example**:

```kql
MDE_PreviewFeatures_CL
| where TimeGenerated > ago(7d)
| where IsOptIn == true
| summarize arg_max(TimeGenerated, *) by SettingId
```

### `MDE_AlertServiceConfig_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: per-workload alert-source enable/disable matrix (which detection sources fire alerts).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `WorkloadId` | `string` | `WorkloadId` | Workload identifier (e.g. `Endpoint`, `Identity`). |
| `Name` | `string` | `Name` | Human-readable workload name. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the workload's alert source is on. |
| `LastModifiedUtc` | `datetime` | `LastModifiedUtc` | Last config-change timestamp. |
| `ModifiedBy` | `string` | `ModifiedBy` | UPN of the operator who last modified. |

**Example**:

```kql
MDE_AlertServiceConfig_CL
| where IsEnabled == false
| project TimeGenerated, Name, ModifiedBy, LastModifiedUtc
```

### `MDE_AlertTuning_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: email-notification rules for alerts (recipients, severity filters, delivery cadence).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `RuleId` | Tuning-rule identifier. |
| `Name` | `string` | `Name` | Rule display name. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the tuning rule is active. |
| `CreatedTime` | `datetime` | `CreatedTime` | When the rule was first created. |
| `CreatedBy` | `string` | `CreatedBy` | UPN of rule creator. |
| `Severity` | `string` | `NotificationType` | Notification scope label. |

**Example**:

```kql
MDE_AlertTuning_CL
| where TimeGenerated > ago(7d)
| where IsEnabled == true
| project TimeGenerated, Name, Severity, CreatedBy
```

### `MDE_SuppressionRules_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: operator-defined alert suppression rules (which alerts are deliberately silenced + scope).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `Id` | Suppression-rule identifier. |
| `Name` | `string` | `RuleTitle` | Rule display name. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the rule is active. |
| `CreatedTime` | `datetime` | `CreationTime` | First-seen timestamp. |
| `CreatedBy` | `string` | `CreatedBy` | Creator UPN. |
| `Scope` | `long` | `Scope` | Numeric scope code. |
| `Action` | `long` | `Action` | Numeric action code (suppress / hide / etc.). |
| `AlertTitle` | `string` | `AlertTitle` | Alert display name the rule targets. |
| `MatchingAlertsCount` | `long` | `MatchingAlertsCount` | How many alerts the rule has matched lifetime. |
| `IsReadOnly` | `bool` | `IsReadOnly` | Whether the rule was system-created. |
| `UpdateTime` | `datetime` | `UpdateTime` | Last-modified timestamp. |

**Example**:

```kql
MDE_SuppressionRules_CL
| where IsEnabled == true
| summarize arg_max(TimeGenerated, *) by RuleId
| project Name, Scope, MatchingAlertsCount, CreatedBy, CreatedTime
```

### `MDE_CustomDetections_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: tenant-defined custom detection rules (KQL-driven scheduled hunts that mint alerts).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `Id` | Detection-rule identifier. |
| `Name` | `string` | `DisplayName` | Rule display name. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the rule is currently scheduled. |
| `CreatedTime` | `datetime` | `CreationTime` | First-seen timestamp. |
| `CreatedBy` | `string` | `CreatedBy` | Creator UPN. |
| `Severity` | `string` | `Severity` | Severity label (Informational / Low / Medium / High). |
| `LastRunStatus` | `string` | `LastRunStatus` | Most-recent execution status. |
| `LastModifiedUtc` | `datetime` | `LastModifiedTime` | Last-edit timestamp. |

**Example**:

```kql
MDE_CustomDetections_CL
| where IsEnabled == true
| where Severity in ('High','Medium')
| project Name, Severity, LastRunStatus, LastModifiedUtc
```

### `MDE_DeviceControlPolicy_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: device-control + onboarding-package configuration (USB/printer/disk policies).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `Onboarded` | `long` | `onboarded` | Count of onboarded devices. |
| `NotOnboarded` | `long` | `notOnboarded` | Count of non-onboarded devices. |
| `HasPermissions` | `bool` | `hasPermissions` | Whether the polling account had permission. |

**Example**:

```kql
MDE_DeviceControlPolicy_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, Onboarded, NotOnboarded, HasPermissions
```

### `MDE_WebContentFiltering_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: Web Content Filtering policy state + top blocked-category report.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `UpdateTime` | `datetime` | `UpdateTime` | Last reporting update from the portal. |
| `CategoryName` | `string` | `Name` | Category label (Adult, Gambling, etc.). |
| `ActivityDeltaPercentage` | `long` | `ActivityDeltaPercentage` | Period-over-period delta. |
| `TotalAccessRequests` | `long` | `TotalAccessRequests` | Access attempts in the reporting window. |
| `TotalBlockedCount` | `long` | `TotalBlockedCount` | Block actions in the reporting window. |

**Example**:

```kql
MDE_WebContentFiltering_CL
| top 10 by TotalBlockedCount
| project CategoryName, TotalBlockedCount, ActivityDeltaPercentage
```

### `MDE_SmartScreenConfig_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: Microsoft Defender SmartScreen aggregated web-threat report (impressions + block actions).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `TotalThreats` | `long` | `TotalThreats` | Aggregate threats observed. |
| `Phishing` | `long` | `Phishing` | Phishing block count. |
| `Malicious` | `long` | `Malicious` | Malicious block count. |
| `CustomIndicator` | `long` | `CustomIndicator` | Tenant-allow-list custom-indicator block count. |
| `Exploit` | `long` | `Exploit` | Exploit block count. |
| `LastModifiedUtc` | `datetime` | `UpdateTime` | Reporting window timestamp. |

**Example**:

```kql
MDE_SmartScreenConfig_CL
| where TimeGenerated > ago(7d)
| summarize sum(Phishing), sum(Malicious), sum(Exploit) by bin(TimeGenerated, 1d)
```

### `MDE_LiveResponseConfig_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: Live Response service properties + script-library config + tab-completion enablement.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `AutomatedIrLiveResponse` | `bool` | `AutomatedIrLiveResponse` | LR-from-AIR enablement. |
| `AutomatedIrUnsignedScripts` | `bool` | `AutomatedIrUnsignedScripts` | Unsigned-script policy (high-risk if true). |
| `LiveResponseForServers` | `bool` | `LiveResponseForServers` | LR enablement on server-class endpoints. |

**Example**:

```kql
MDE_LiveResponseConfig_CL
| summarize arg_max(TimeGenerated, *) by FeatureName
| where AutomatedIrUnsignedScripts == true
```

### `MDE_AuthenticatedTelemetry_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: Sense-auth posture (whether unauthenticated telemetry from Sense agent is accepted).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `IsEnabled` | `bool` | `value` | Wrapped scalar. |
| `AllowNonAuthSense` | `bool` | `value` | Re-exposed semantic alias. |

**Example**:

```kql
MDE_AuthenticatedTelemetry_CL
| where AllowNonAuthSense == true
| project TimeGenerated, AllowNonAuthSense
```

### `MDE_PUAConfig_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: live
- **Description**: Potentially-Unwanted-Application enforcement scope (block / audit / off + per-platform).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `AutomatedIrPuaAsSuspicious` | `bool` | `AutomatedIrPuaAsSuspicious` | Whether AIR treats PUAs as suspicious. |
| `IsAutomatedIrContainDeviceEnabled` | `bool` | `IsAutomatedIrContainDeviceEnabled` | AIR auto-containment toggle. |

**Example**:

```kql
MDE_PUAConfig_CL
| summarize arg_max(TimeGenerated, *) by FeatureName
| where AutomatedIrPuaAsSuspicious == false
```

### `MDE_AntivirusPolicy_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: tenant-gated (MEM-bridge feature)
- **Description**: MEM-bridged antivirus policy filter facets (Intune + Configuration Manager scope).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FilterName` | `string` | `Name` | Filter facet name. |
| `FilterValue` | `string` | `Value` | Filter facet value. |
| `Platform` | `string` | `Platform` | Target platform (Windows / macOS). |
| `Scope` | `string` | `Scope` | Targeting scope. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the policy is active. |

**Example**:

```kql
MDE_AntivirusPolicy_CL
| where Platform == 'Windows'
| where IsEnabled == false
| project FilterName, FilterValue, Scope
```

### `MDE_TenantAllowBlock_CL`

- **Tier**: P0
- **Category**: Configuration and Settings
- **Availability**: tenant-gated (TABL feature)
- **Description**: Tenant Allow-Block-List (TABL) filter facet — IP/URL/file-hash indicator inventory.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `IndicatorType` | `string` | `Type` | Indicator class (URL / IP / FileHash / Sender). |
| `Action` | `string` | `Action` | Allow / Block / Warn. |
| `CreatedBy` | `string` | `CreatedBy` | Creator UPN. |
| `CreatedTime` | `datetime` | `CreatedTime` | When the indicator was added. |
| `ExpiryTime` | `datetime` | `ExpirationTime` | Indicator expiration. |

**Example**:

```kql
MDE_TenantAllowBlock_CL
| where Action == 'Allow'
| where ExpiryTime > now()
| project IndicatorType, CreatedBy, ExpiryTime
```

### `MDE_CustomCollection_CL`

- **Tier**: P0
- **Category**: Endpoint Configuration
- **Availability**: tenant-gated (MDE Custom Collection licensed)
- **Description**: custom event-collection rules (what extra MDE telemetry the tenant is gathering).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `Id` | Collection-rule identifier. |
| `Name` | `string` | `Name` | Rule display name. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the rule is active. |
| `CreatedTime` | `datetime` | `CreatedTime` | Creation timestamp. |
| `CreatedBy` | `string` | `CreatedBy` | Creator UPN. |
| `Scope` | `string` | `Scope` | Targeting scope. |

**Example**:

```kql
MDE_CustomCollection_CL
| where IsEnabled == true
| project Name, Scope, CreatedBy, CreatedTime
```

---

## P1 Pipeline — 30-minute polling

Tenant-integration plumbing: data export, connected apps, tenant context. Aggregated by [`MDE_Drift_Configuration`](../sentinel/parsers/MDE_Drift_Configuration.kql).

### `MDE_DataExportSettings_CL`

- **Tier**: P1
- **Category**: Streaming API
- **Availability**: live (hybrid — public ARM covers the SET surface; the read-side queryable list is portal-only)
- **Description**: Streaming API configuration: which workspaces / event-hubs / storage receive exported MDE telemetry.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `ConfigId` | `string` | `id` | Per-destination config row identifier. |
| `Destination` | `string` | `workspaceProperties.name` | Workspace display name. |
| `Workspace` | `string` | `workspaceProperties.workspaceResourceId` | Full LA workspace resource ID. |
| `SubscriptionId` | `string` | `workspaceProperties.subscriptionId` | Target subscription. |
| `ResourceGroup` | `string` | `workspaceProperties.resourceGroup` | Target RG. |
| `LogsCount` | `long` | `logs.length` | Number of categories enabled. |
| `EnabledLogs` | `string` | `logs[*].category` | Comma-flattened category names. |

**Example**:

```kql
MDE_DataExportSettings_CL
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by ConfigId
| project Destination, SubscriptionId, ResourceGroup, LogsCount, EnabledLogs
```

### `MDE_ConnectedApps_CL`

- **Tier**: P1
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: OAuth + service-app inventory connected to the tenant Defender API surface.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `AppId` | `string` | `Id` | App registration identifier. |
| `Name` | `string` | `DisplayName` | App display name. |
| `IsEnabled` | `bool` | `Enabled` | Whether the connection is active. |
| `LatestConnectivity` | `datetime` | `LatestConnectivity` | Most-recent successful API call. |
| `SettingsLink` | `string` | `ApplicationSettingsLink` | Portal deep-link to app settings. |

**Example**:

```kql
MDE_ConnectedApps_CL
| summarize arg_max(TimeGenerated, *) by AppId
| where IsEnabled == true
| project Name, LatestConnectivity, SettingsLink
```

### `MDE_TenantContext_CL`

- **Tier**: P1
- **Category**: Multi-Tenant Operations
- **Availability**: live
- **Description**: authenticated-tenant context: tenant ID, region, M365 sku, cross-tenant flags.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `TenantId` | `string` | `OrgId` | Authenticated tenant GUID. |
| `TenantName` | `string` | `EntityId` | Property-bag key (display name). |
| `Region` | `string` | `GeoRegion` | Microsoft datacenter region. |
| `DataCenter` | `string` | `DataCenter` | Data-center label. |
| `EnvironmentName` | `string` | `EnvironmentName` | Cloud environment (Prod / Gov / etc.). |
| `AccountType` | `string` | `AccountType` | Account-type label. |
| `IsHomeTenant` | `bool` | `IsMtpEligible` | Whether this is the home tenant. |
| `IsMdatpActive` | `bool` | `IsMdatpActive` | MDE provisioning state. |
| `IsSentinelActive` | `bool` | `IsSentinelActive` | Sentinel provisioning state. |

**Example**:

```kql
MDE_TenantContext_CL
| summarize arg_max(TimeGenerated, *) by TenantId
| project TenantId, Region, AccountType, IsMdatpActive, IsSentinelActive
```

### `MDE_TenantWorkloadStatus_CL`

- **Tier**: P1
- **Category**: Multi-Tenant Operations
- **Availability**: live (tenant-gated when MTO not configured)
- **Description**: MTO tenant-group definitions + per-group workload (alerts/incidents/dashboards) state.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `TenantId` | `string` | `tenantId` | Target tenant GUID. |
| `TenantGroupId` | `string` | `tenantGroupId` | MTO group GUID. |
| `TenantName` | `string` | `name` | Display name. |
| `EntityType` | `string` | `entityType` | Group-row type label. |
| `AllTenantsCount` | `long` | `allTenantsCount` | Number of tenants in the group. |
| `CreatedTime` | `datetime` | `creationTime` | Group creation timestamp. |
| `LastUpdated` | `datetime` | `lastUpdated` | Last group-edit timestamp. |
| `LastUpdatedByUpn` | `string` | `lastUpdatedByUpn` | UPN of the most recent editor. |

**Example**:

```kql
MDE_TenantWorkloadStatus_CL
| summarize arg_max(TimeGenerated, *) by TenantGroupId
| project TenantName, AllTenantsCount, LastUpdated, LastUpdatedByUpn
```

### `MDE_StreamingApiConfig_CL`

- **Tier**: P1
- **Category**: Streaming API
- **Availability**: deprecated (canonical surface is `MDE_DataExportSettings_CL`)
- **Description**: returns 404 on modern tenants. Slated for removal in a future release; this stream has no projection map. Operators should query `MDE_DataExportSettings_CL` instead.

No typed columns. The deprecated stream has an empty projection map.

### `MDE_IntuneConnection_CL`

- **Tier**: P1
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: Defender ↔ Intune connector status (link-state, last-handshake, scope enrolment).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `Status` | `long` | `value` | Numeric status (0 = not connected). |
| `IsEnabled` | `bool` | `value` | Truthy on non-zero status. |

**Example**:

```kql
MDE_IntuneConnection_CL
| summarize arg_max(TimeGenerated, *) by FeatureName
| where IsEnabled == false
```

### `MDE_PurviewSharing_CL`

- **Tier**: P1
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: Defender ↔ Purview alert-sharing toggle + per-domain scope.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `FeatureName` | `string` | `EntityId` | Property-bag key. |
| `IsEnabled` | `bool` | `value` | Whether sharing is on. |
| `AlertSharingEnabled` | `bool` | `value` | Re-exposed semantic alias. |

**Example**:

```kql
MDE_PurviewSharing_CL
| where AlertSharingEnabled == true
| project TimeGenerated, FeatureName
```

---

## P2 Governance — daily polling

RBAC, asset-classification, service-account governance. Aggregated by [`MDE_Drift_Configuration`](../sentinel/parsers/MDE_Drift_Configuration.kql).

### `MDE_RbacDeviceGroups_CL`

- **Tier**: P2
- **Category**: Configuration and Settings
- **Availability**: live (hybrid — public `/api/machinegroups` exposes id+name only; portal exposes AAD-group bindings + machine-count + role assignments)
- **Description**: RBAC device groups + AAD-group bindings + per-group machine count + role assignments.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `GroupId` | `long` | `MachineGroupId` | Group identifier. |
| `Name` | `string` | `Name` | Group display name. |
| `Description` | `string` | `Description` | Group description. |
| `AutoRemediationLevel` | `long` | `AutoRemediationLevel` | Auto-IR level for the group. |
| `Priority` | `long` | `Priority` | Group ordering priority. |
| `LastUpdated` | `datetime` | `LastUpdated` | Last-edit timestamp. |
| `MachineCount` | `long` | `MachineCount` | Devices in the group. |
| `IsUnassigned` | `bool` | `IsUnassignedMachineGroup` | True for the catch-all group. |
| `RuleCount` | `long` | `GroupRules.length` | How many membership rules. |

**Example**:

```kql
MDE_RbacDeviceGroups_CL
| summarize arg_max(TimeGenerated, *) by GroupId
| project Name, MachineCount, AutoRemediationLevel, RuleCount
```

### `MDE_UnifiedRbacRoles_CL`

- **Tier**: P2
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: unified-RBAC role definitions: per-role permission bitmaps + assigned principals.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RoleId` | `string` | `id` | Role-definition identifier. |
| `Name` | `string` | `displayName` | Role display name. |
| `IsBuiltIn` | `bool` | `isBuiltIn` | Microsoft-builtin vs custom. |
| `CreatedTime` | `datetime` | `createdDateTime` | Creation timestamp. |
| `ModifiedBy` | `string` | `modifiedBy` | Last-modifier UPN. |
| `Scope` | `string` | `scope` | Role scope (tenant / group). |

**Example**:

```kql
MDE_UnifiedRbacRoles_CL
| where IsBuiltIn == false
| summarize arg_max(TimeGenerated, *) by RoleId
| project Name, Scope, ModifiedBy, CreatedTime
```

### `MDE_AssetRules_CL`

- **Tier**: P2
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: critical-asset classification rules (which devices/identities feed XSPM as crown jewels).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `ruleId` | Classification-rule identifier. |
| `Name` | `string` | `ruleName` | Rule display name. |
| `Description` | `string` | `ruleDescription` | Rule description. |
| `CreatedBy` | `string` | `createdBy` | Creator UPN. |
| `IsEnabled` | `bool` | `isDisabled` | Truthy when the rule is enabled (note: the underlying field is `isDisabled`; the projection inverts the semantic — operators should treat `IsEnabled` as authoritative). |
| `RuleType` | `string` | `ruleType` | Rule classification (Static / Dynamic). |
| `CriticalityLevel` | `long` | `criticalityLevel` | Numeric criticality (1 = highest). |
| `AssetType` | `string` | `assetType` | Device / Identity. |
| `ClassificationValue` | `string` | `classificationValue` | The label applied (Critical / Important / Standard). |
| `AffectedAssetsCount` | `long` | `affectedAssetsCount` | Asset count matching the rule. |

**Example**:

```kql
MDE_AssetRules_CL
| where ClassificationValue == 'Critical'
| project Name, AssetType, AffectedAssetsCount, CriticalityLevel
```

### `MDE_SAClassification_CL`

- **Tier**: P2
- **Category**: Identity Protection (MDI)
- **Availability**: live
- **Description**: MDI service-account classification rules (which AD accounts MDI flags as service accounts).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RuleId` | `string` | `Id` | Rule identifier. |
| `Name` | `string` | `Name` | Rule display name. |
| `AccountType` | `string` | `AccountType` | Account class. |
| `Domain` | `string` | `Domain` | AD domain. |
| `IsActive` | `bool` | `IsActive` | Whether the rule is currently applied. |
| `LastSeenUtc` | `datetime` | `LastSeen` | Most recent observation. |

**Example**:

```kql
MDE_SAClassification_CL
| summarize arg_max(TimeGenerated, *) by RuleId
| project Name, Domain, AccountType, IsActive
```

---

## P3 Exposure / XSPM — hourly polling

Exposure-management surfaces: posture, attack paths, recommendations. Aggregated by [`MDE_Drift_Exposure`](../sentinel/parsers/MDE_Drift_Exposure.kql) (set-diff semantics).

### `MDE_XspmInitiatives_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM exposure initiatives + per-initiative completion progress + recommended actions.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `InitiativeId` | `string` | `id` | Initiative identifier. |
| `Name` | `string` | `name` | Initiative display name. |
| `TargetValue` | `real` | `targetValue` | Completion target. |
| `MetricCount` | `long` | `metricIds.length` | Total metrics in the initiative. |
| `ActiveMetricCount` | `long` | `activeMetricIds.length` | Currently-active metrics. |
| `Programs` | `string` | `programs[*]` | Program tags (flattened). |
| `IsFavorite` | `bool` | `isFavorite` | UI-pin status. |

**Example**:

```kql
MDE_XspmInitiatives_CL
| summarize arg_max(TimeGenerated, *) by InitiativeId
| extend Progress = ActiveMetricCount * 1.0 / MetricCount
| project Name, Progress, TargetValue, Programs
```

### `MDE_ExposureSnapshots_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM posture-snapshot deltas (what changed in exposure score / metrics over time).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `SnapshotId` | `string` | `id` | Snapshot identifier. |
| `MetricId` | `string` | `metricId` | Metric the snapshot pertains to. |
| `Score` | `real` | `score` | Score at snapshot time. |
| `ScoreChange` | `real` | `scoreChange` | Period-over-period delta. |
| `CreatedTime` | `datetime` | `date` | Snapshot timestamp. |
| `InitiativeId` | `string` | `initiativeId` | Parent initiative. |

**Example**:

```kql
MDE_ExposureSnapshots_CL
| where TimeGenerated > ago(7d)
| summarize avg(ScoreChange) by MetricId, bin(CreatedTime, 1d)
```

### `MDE_ExposureRecommendations_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM remediation recommendations (per-initiative actionable steps + criticality + effort).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `RecommendationId` | `string` | `id` | Recommendation identifier. |
| `Title` | `string` | `title` | Recommendation display title. |
| `Severity` | `string` | `severity` | Severity label. |
| `Status` | `string` | `currentState` | Current implementation state. |
| `Source` | `string` | `source` | Recommendation source. |
| `Product` | `string` | `product` | Target product. |
| `Category` | `string` | `category` | Recommendation category. |
| `ImplementationCost` | `string` | `implementationCost` | Effort estimate (Low / Medium / High). |
| `UserImpact` | `string` | `userImpact` | Impact estimate. |
| `IsDisabled` | `bool` | `isDisabled` | Whether dismissed. |
| `Score` | `real` | `score` | Current weight score. |
| `MaxScore` | `real` | `maxScore` | Theoretical max score. |
| `LastSyncedUtc` | `datetime` | `lastSynced` | Last sync timestamp. |

**Example**:

```kql
MDE_ExposureRecommendations_CL
| where IsDisabled == false
| where Severity in ('High','Critical')
| summarize arg_max(TimeGenerated, *) by RecommendationId
| project Title, Severity, Status, ImplementationCost, UserImpact
```

### `MDE_XspmAttackPaths_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM attack-path graph (multi-hop privesc/lateral chains from low-privilege entry to crown jewels).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `PathId` | `string` | `attackPathId` | Path identifier. |
| `Severity` | `string` | `MaxRiskLevel` | Path criticality (Critical / High / Medium / Low). |
| `Status` | `string` | `Status` | Path state (Active / Resolved / etc.). |
| `Source` | `string` | `Source.Name` | Entry-point display name. |
| `Target` | `string` | `Target.Name` | Endpoint display name. |
| `SourceId` | `string` | `Source.Id` | Entry-point identifier. |
| `TargetId` | `string` | `Target.Id` | Endpoint identifier. |
| `HopCount` | `long` | `HopsCount` | Path length. |
| `CreatedTime` | `datetime` | `CreationTime` | Path discovery timestamp. |

**Example**:

```kql
MDE_XspmAttackPaths_CL
| where TimeGenerated > ago(7d)
| where Severity == 'Critical'
| where Status in ('Active','New')
| project Source, Target, HopCount, CreatedTime
```

### `MDE_XspmChokePoints_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM chokepoints — single nodes that appear on many attack paths (highest-leverage remediation targets).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `NodeId` | `string` | `NodeId` | Chokepoint node identifier. |
| `NodeName` | `string` | `NodeName` | Chokepoint node display name. |
| `NodeType` | `string` | `NodeType` | Node type (User / Device / Group). |
| `Severity` | `string` | `MaxRiskLevel` | Chokepoint criticality. |
| `AttackPathsCount` | `long` | `AttackPathsCount` | How many paths cross this node. |
| `EntityType` | `string` | `EntityType` | Entity classification. |

**Example**:

```kql
MDE_XspmChokePoints_CL
| where TimeGenerated > ago(1h)
| top 10 by AttackPathsCount
| project NodeName, NodeType, AttackPathsCount, Severity
```

### `MDE_XspmTopTargets_CL`

- **Tier**: P3
- **Category**: Exposure Management (XSPM)
- **Availability**: live
- **Description**: XSPM top-targeted assets — critical assets reachable by the most active attack paths.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `TargetId` | `string` | `TargetId` | Target identifier. |
| `TargetName` | `string` | `TargetName` | Target display name. |
| `AttackPathsCount` | `long` | `AttackPathsCount` | Active paths terminating here. |
| `Source` | `string` | `Source` | Source-attribution label. |
| `Status` | `string` | `Status` | Path-state filter applied. |

**Example**:

```kql
MDE_XspmTopTargets_CL
| where TimeGenerated > ago(1h)
| top 20 by AttackPathsCount
| project TargetName, AttackPathsCount, Source
```

### `MDE_SecurityBaselines_CL`

- **Tier**: P3
- **Category**: Vulnerability Management (TVM)
- **Availability**: tenant-gated (TVM add-on licensed and baselines configured)
- **Description**: TVM security-baseline profile compliance (CIS / Microsoft baselines applied to device fleet).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `ProfileId` | `string` | `id` | Baseline-profile identifier. |
| `Name` | `string` | `name` | Profile display name. |
| `Compliance` | `bool` | `isCompliant` | Profile-level compliance flag. |
| `DeviceCount` | `long` | `assetsCount` | Devices in scope. |
| `LastScanUtc` | `datetime` | `lastUpdate` | Last scan timestamp. |
| `BenchmarkName` | `string` | `benchmarkName` | Underlying benchmark (e.g. CIS-Win10). |
| `Score` | `real` | `complianceScore` | Compliance percentage. |

**Example**:

```kql
MDE_SecurityBaselines_CL
| summarize arg_max(TimeGenerated, *) by ProfileId
| project Name, BenchmarkName, Compliance, Score, DeviceCount
```

### `MDE_DeviceTimeline_CL`

- **Tier**: P3
- **Category**: Endpoint Device Management
- **Availability**: tenant-gated (lifts to live after first capture in tenants with timeline activity)
- **Description**: per-device unified timeline (process / file / network / registry events with portal-side correlation + grouping). Public Defender XDR API exposes per-event hunts but not the unified timeline view's correlation/grouping.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `EventId` | `string` | `eventId` | Timeline-event identifier. |
| `MachineId` | `string` | `machineId` | Device GUID. |
| `EventTime` | `datetime` | `eventTime` | Event timestamp. |
| `EventType` | `string` | `eventType` | Event class (Process / File / Network / Registry). |
| `ProcessName` | `string` | `processName` | Originating process. |
| `FileName` | `string` | `fileName` | Target file (when applicable). |
| `Severity` | `string` | `severity` | Event severity. |

**Example**:

```kql
MDE_DeviceTimeline_CL
| where TimeGenerated > ago(24h)
| where EventType == 'Process'
| where Severity in ('High','Critical')
| project EventTime, MachineId, ProcessName, FileName
```

---

## P5 Identity — daily polling

Defender for Identity surfaces: DC onboarding, service-account inventory, alert thresholds. Aggregated by [`MDE_Drift_Inventory`](../sentinel/parsers/MDE_Drift_Inventory.kql).

### `MDE_IdentityOnboarding_CL`

- **Tier**: P5
- **Category**: Identity Protection (MDI)
- **Availability**: live (tenant-gated when no MDI sensors deployed)
- **Description**: MDI domain-controller onboarding state (per-DC sensor health + last-seen + IP).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `DCName` | `string` | `Name` | DC display name. |
| `Domain` | `string` | `Domain` | AD domain. |
| `IpAddress` | `string` | `IpAddress` | DC IPv4. |
| `SensorHealth` | `string` | `HealthStatus` | Sensor status label. |
| `IsActive` | `bool` | `IsActive` | Whether the sensor is online. |
| `LastSeenUtc` | `datetime` | `LastSeen` | Most-recent heartbeat. |

**Example**:

```kql
MDE_IdentityOnboarding_CL
| summarize arg_max(TimeGenerated, *) by DCName
| where IsActive == false
| project DCName, Domain, SensorHealth, LastSeenUtc
```

### `MDE_IdentityServiceAccounts_CL`

- **Tier**: P5
- **Category**: Identity Protection (MDI)
- **Availability**: live
- **Description**: MDI service-account inventory (auto-classified service accounts + activity heuristics).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `AccountUpn` | `string` | `Upn` | Account UPN. |
| `AccountSid` | `string` | `Sid` | AD SID. |
| `AccountType` | `string` | `AccountType` | Account class. |
| `Domain` | `string` | `Domain` | AD domain. |
| `IsActive` | `bool` | `IsActive` | Whether MDI considers the account active. |
| `LastSeenUtc` | `datetime` | `LastSeen` | Most-recent observed activity. |
| `Risk` | `string` | `RiskLevel` | MDI risk label. |

**Example**:

```kql
MDE_IdentityServiceAccounts_CL
| summarize arg_max(TimeGenerated, *) by AccountUpn
| where Risk in ('High','Critical')
| project AccountUpn, Domain, AccountType, LastSeenUtc, Risk
```

### `MDE_DCCoverage_CL`

- **Tier**: P5
- **Category**: Identity Protection (MDI)
- **Availability**: tenant-gated (MDI sensors deployed)
- **Description**: MDI sensor coverage per domain controller (which DCs have working sensors / sync state).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `DCName` | `string` | `Name` | DC display name. |
| `Domain` | `string` | `Domain` | AD domain. |
| `IsActive` | `bool` | `HasSensor` | Whether a sensor is installed. |
| `LastSeenUtc` | `datetime` | `LastSyncTime` | Most-recent sync. |
| `Risk` | `string` | `CoverageStatus` | Coverage label. |

**Example**:

```kql
MDE_DCCoverage_CL
| where IsActive == false
| project DCName, Domain, Risk, LastSeenUtc
```

### `MDE_IdentityAlertThresholds_CL`

- **Tier**: P5
- **Category**: Identity Protection (MDI)
- **Availability**: tenant-gated (MDI provisioned)
- **Description**: MDI alert-threshold tuning per detection (when each MDI rule fires + temporary overrides).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `ThresholdId` | `string` | `Id` | Threshold-row identifier. |
| `AlertType` | `string` | `AlertType` | Underlying detection name. |
| `Threshold` | `real` | `Value` | Numeric threshold value. |
| `ExpiresUtc` | `datetime` | `ExpiryTime` | When the override expires. |
| `IsEnabled` | `bool` | `IsEnabled` | Whether the override is active. |
| `ModifiedBy` | `string` | `ModifiedBy` | UPN of the operator who set the override. |

**Example**:

```kql
MDE_IdentityAlertThresholds_CL
| where ExpiresUtc > now()
| project AlertType, Threshold, ModifiedBy, ExpiresUtc
```

### `MDE_RemediationAccounts_CL`

- **Tier**: P5
- **Category**: Identity Protection (MDI)
- **Availability**: tenant-gated (MDI provisioned)
- **Description**: MDI gMSA remediation-action configuration (which managed-service-accounts MDI uses for password resets).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `AccountUpn` | `string` | `GmsaAccount` | gMSA UPN. |
| `AccountType` | `string` | `AccountType` | Account class. |
| `Domain` | `string` | `Domain` | AD domain. |
| `IsActive` | `bool` | `IsConfigured` | Whether gMSA is configured for use. |
| `LastSeenUtc` | `datetime` | `LastUpdated` | Last config change. |

**Example**:

```kql
MDE_RemediationAccounts_CL
| where IsActive == true
| summarize arg_max(TimeGenerated, *) by AccountUpn
```

---

## P6 Audit / AIR — 10-minute polling

High-cadence audit data: Action Center, threat outbreaks, machine actions. P6 is audit log (not drift) — no `MDE_Drift_P6*` parser.

### `MDE_ActionCenter_CL`

- **Tier**: P6
- **Category**: Action Center
- **Availability**: live
- **Description**: Action Center history — every cross-workload remediation action (block / quarantine / investigation) with operator + status.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `ActionId` | `string` | `ActionId` | Per-action identifier (this is also the row's `EntityId`). |
| `InvestigationId` | `string` | `InvestigationId` | Parent investigation GUID. |
| `ActionType` | `string` | `ActionType` | Action class (Quarantine / Restore / Block / etc.). |
| `ActionStatus` | `string` | `ActionStatus` | Action status (Pending / Approved / Failed). |
| `ActionDecision` | `string` | `ActionDecision` | Operator decision label. |
| `ActionSource` | `string` | `ActionSource` | Source label (AIR / Manual). |
| `StartTime` | `datetime` | `StartTime` | Action start. |
| `EndTime` | `datetime` | `EndTime` | Action completion. |
| `EventTime` | `datetime` | `EventTime` | Underlying event timestamp. |
| `Operator` | `string` | `DecidedBy` | Operator UPN who decided. |
| `UserPrincipalName` | `string` | `UserPrincipalName` | Affected user (if applicable). |
| `MachineId` | `string` | `MachineId` | Affected device GUID. |
| `ComputerName` | `string` | `ComputerName` | Affected device name. |
| `Product` | `string` | `Product` | Source product (Endpoint / Identity / etc.). |
| `Comment` | `string` | `Comment` | Operator-supplied comment. |
| `EntityType` | `string` | `EntityType` | Affected entity class. |

**Example**:

```kql
MDE_ActionCenter_CL
| where TimeGenerated > ago(24h)
| where ActionType == 'Quarantine'
| where ActionStatus == 'Pending'
| project StartTime, Operator, ComputerName, Comment
```

### `MDE_ThreatAnalytics_CL`

- **Tier**: P6
- **Category**: Threat Analytics
- **Availability**: live
- **Description**: Threat Analytics active outbreaks + per-tenant exposure score + tracked-actor links.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `OutbreakId` | `string` | `Id` | Outbreak identifier. |
| `Title` | `string` | `DisplayName` | Outbreak display name. |
| `Severity` | `long` | `Severity` | Severity numeric (higher = more severe). |
| `ReportType` | `string` | `ReportType` | Report kind label. |
| `CreatedOn` | `datetime` | `CreatedOn` | Microsoft-side creation. |
| `StartedOn` | `datetime` | `StartedOn` | Outbreak observed start. |
| `LastUpdatedOn` | `datetime` | `LastUpdatedOn` | Microsoft-side last update. |
| `LastVisitTime` | `datetime` | `LastVisitTime` | Tenant-side last visit. |
| `Tags` | `string` | `Tags[*]` | Comma-flattened tags. |
| `Keywords` | `string` | `Keywords[*]` | Comma-flattened keywords. |
| `IsVNext` | `bool` | `IsVNext` | New-format report flag. |

**Example**:

```kql
MDE_ThreatAnalytics_CL
| where TimeGenerated > ago(7d)
| where Severity >= 3
| project Title, Severity, ReportType, Tags, LastUpdatedOn
```

### `MDE_MachineActions_CL`

- **Tier**: P6
- **Category**: Action Center
- **Availability**: tenant-gated (lifts to live once tenant has machine-action history)
- **Description**: per-device action results (Live Response per-step script output + AIR linkage; richer than public MDE `/api/machineactions`).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `ActionId` | `string` | `actionId` | Action identifier. |
| `ActionType` | `string` | `actionType` | Action class. |
| `ActionStatus` | `string` | `status` | Status label. |
| `MachineId` | `string` | `machineId` | Target device. |
| `CreatedTime` | `datetime` | `creationTime` | Action creation. |
| `CompletedTime` | `datetime` | `completionTime` | Action completion. |
| `Operator` | `string` | `requestor` | Initiating UPN. |
| `InvestigationId` | `string` | `investigationId` | Parent investigation. |
| `ScriptOutput` | `dynamic` | `scriptOutputs` | Compact-JSON-cast per-step Live Response output (use `mv-expand` to iterate steps). |

**Example**:

```kql
MDE_MachineActions_CL
| where TimeGenerated > ago(7d)
| where ActionType == 'LiveResponse'
| project CreatedTime, Operator, MachineId, ActionStatus, ScriptOutput
```

To iterate per-step output:

```kql
MDE_MachineActions_CL
| where TimeGenerated > ago(7d)
| mv-expand step = ScriptOutput
| project CreatedTime, Operator, MachineId, step
```

---

## P7 Metadata — daily polling

Tenant-metadata surfaces: per-analyst preferences, MTO tenant picker, license rollups. Aggregated by [`MDE_Drift_Configuration`](../sentinel/parsers/MDE_Drift_Configuration.kql).

### `MDE_UserPreferences_CL`

- **Tier**: P7
- **Category**: Configuration and Settings
- **Availability**: live
- **Description**: per-analyst portal preferences (homepage layout, default filters) — drift detector for shared accounts.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `SettingId` | `string` | `EntityId` | Property-bag key. |
| `Name` | `string` | `Name` | Preference display name. |
| `IsEnabled` | `bool` | `IsEnabled` | Preference enabled flag. |
| `CreatedTime` | `datetime` | `CreatedTime` | Preference creation. |
| `CreatedBy` | `string` | `CreatedBy` | Creator UPN. |
| `Scope` | `string` | `Scope` | Preference scope. |

**Example**:

```kql
MDE_UserPreferences_CL
| summarize arg_max(TimeGenerated, *) by SettingId
| project Name, Scope, CreatedBy, CreatedTime
```

### `MDE_MtoTenants_CL`

- **Tier**: P7
- **Category**: Multi-Tenant Operations
- **Availability**: live (tenant-gated when MTO not configured)
- **Description**: MTO tenant picker — list of tenants this MSSP/parent has cross-tenant access to.

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `TenantId` | `string` | `tenantId` | Tenant GUID. |
| `TenantName` | `string` | `name` | Display name. |
| `TenantAadEnvironment` | `long` | `tenantAadEnvironment` | AAD environment numeric. |
| `IsSelected` | `bool` | `selected` | Whether this is the active tenant in the picker. |
| `LostAccess` | `bool` | `lostAccess` | True if cross-tenant access has been revoked. |
| `IsHomeTenant` | `bool` | `selected` | Re-exposed alias of `IsSelected`. |

**Example**:

```kql
MDE_MtoTenants_CL
| summarize arg_max(TimeGenerated, *) by TenantId
| where LostAccess == false
| project TenantName, TenantId, IsSelected
```

### `MDE_LicenseReport_CL`

- **Tier**: P7
- **Category**: Endpoint Device Management
- **Availability**: live (hybrid — public `/api/machines` returns one row per device with no SKU rollup; portal returns aggregated SKU counts)
- **Description**: per-SKU device license rollup (how many devices on each MDE plan / per-OS / per-region).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `SkuName` | `string` | `Sku` | License SKU label. |
| `DeviceCount` | `long` | `TotalDevices` | Devices on the SKU. |
| `DetectedUsers` | `long` | `DetectedUsers` | Distinct users detected. |

**Example**:

```kql
MDE_LicenseReport_CL
| summarize arg_max(TimeGenerated, *) by SkuName
| project SkuName, DeviceCount, DetectedUsers
```

### `MDE_CloudAppsConfig_CL`

- **Tier**: P7
- **Category**: Configuration and Settings
- **Availability**: tenant-gated (Defender for Cloud Apps licensed)
- **Description**: MCAS / Defender for Cloud Apps general settings (regions, integrations, notification policy).

| Column | KQL type | Source path | Notes |
|---|---|---|---|
| `SettingId` | `string` | `EntityId` | Property-bag key. |
| `Region` | `string` | `Region` | MCAS region. |
| `IsEnabled` | `bool` | `IsEnabled` | Setting enabled flag. |
| `CreatedTime` | `datetime` | `CreatedTime` | Creation timestamp. |
| `ModifiedBy` | `string` | `ModifiedBy` | Last-modifier UPN. |

**Example**:

```kql
MDE_CloudAppsConfig_CL
| summarize arg_max(TimeGenerated, *) by SettingId
| project Region, IsEnabled, ModifiedBy, CreatedTime
```

---

## Cross-references

- [STREAMS.md](STREAMS.md) — higher-level per-stream summary, polling cadence, availability legend, tier counts.
- [DRIFT.md](DRIFT.md) — pure-KQL drift model; how the per-tier parsers compute change records on top of these tables.
- [QUERY-MIGRATION-GUIDE.md](QUERY-MIGRATION-GUIDE.md) — recipe for migrating queries written against `RawJson` to use the typed columns above.
- [ANALYTIC-RULES-VETTING.md](ANALYTIC-RULES-VETTING.md) — per-rule narrative + which streams + columns each rule depends on.
- [WORKBOOKS.md](WORKBOOKS.md) — per-workbook field references.
- [`endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1) — source of truth for the projection map of every stream.
- [`tests/fixtures/live-responses/`](../tests/fixtures/live-responses/) — captured response shapes verified against these column sets in CI.
