# Query migration guide

> **Audience**: operators with custom KQL queries (workbooks, hunting queries, analytic rules, ad-hoc Sentinel investigations) written against the `RawJson` column on the `MDE_*_CL` tables.
>
> **TL;DR**: the connector now ships a typed-column ingest model alongside the long-standing `RawJson` dynamic. Existing queries continue to work unchanged. New queries should prefer typed columns when available — they are faster, easier to read, and arrive with native KQL types. This guide shows how to migrate.

This document complements [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md), which lists the typed columns for every stream. Use this guide for the migration mechanics; use the catalog as a reference while migrating.

---

## Why migrate

Until this release, every per-stream column extraction had to go through `RawJson`:

```kql
MDE_AdvancedFeatures_CL
| extend Tamper = tobool(parse_json(RawJson).EnableWdavAntiTampering)
| where Tamper == false
```

That works, but it has three friction points:

1. **No native types**. Every value comes back as a JSON token; you must explicitly `tobool()`, `toint()`, `todatetime()`, etc.
2. **Indexing is weaker**. Log Analytics cannot index the parsed-out fields, so filtering through `parse_json(RawJson).x` is slower than filtering on a real column.
3. **Readability**. Stacked `parse_json(...)` reaches make non-trivial queries hard to scan.

The connector now extracts a curated set of fields per stream into their own typed columns at ingest time. For queries written before this release, **nothing is required** — `RawJson` is preserved, every old query keeps running, every workbook keeps rendering. But new queries (and any rewrites operators want to do) can target the typed columns directly.

---

## Backward-compat guarantee

Three guarantees that should be sufficient for cautious upgrade:

1. **`RawJson` is always preserved**. Every row written by the connector still includes `RawJson` as a `dynamic` column with the full response object. There is no flag, no toggle, no mode switch — `RawJson` is unconditional.
2. **`TimeGenerated`, `SourceStream`, `EntityId` are unchanged**. The four baseline columns documented in [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md#typed-column-ingest-model) are stable.
3. **Typed-column population is additive**. If the connector cannot extract a typed column from a particular row (because the upstream JSON shape varies, or a field is null), the typed column projects as `null`. The row still lands; the rest of the typed columns still populate; `RawJson` still has the full object.

Practical effect: an existing query that does not reference a typed column will return identical results before and after the upgrade.

---

## Migration patterns

The four patterns below cover essentially every shape of `RawJson`-based extraction operators tend to write. For each, the **before** form (working today, will keep working) is shown next to the **after** form (recommended for new queries and rewrites).

Refer to [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md) to confirm a given typed column exists for the stream you are querying — not every field is projected.

### Pattern 1 — simple field extraction

A single top-level scalar from `RawJson`.

**Before**:

```kql
MDE_SuppressionRules_CL
| extend RuleName = tostring(parse_json(RawJson).RuleTitle)
| where RuleName has 'Test'
```

**After**:

```kql
MDE_SuppressionRules_CL
| where Name has 'Test'
```

Notes:

- The projection map renamed `RuleTitle` to `Name` for cross-stream consistency. Operators reading the catalog see the source path so the rename is discoverable.
- No `tostring()` cast needed — `Name` is already typed `string`.

### Pattern 2 — nested object

A field that lives inside a sub-object in `RawJson`.

**Before**:

```kql
MDE_DataExportSettings_CL
| extend WorkspaceName = tostring(parse_json(RawJson).workspaceProperties.name)
| where WorkspaceName has 'prod'
```

**After (when the field is in the projection map)**:

```kql
MDE_DataExportSettings_CL
| where Destination has 'prod'
```

The catalog shows that `Destination` is sourced from `workspaceProperties.name` — the connector flattens the dotted path during ingest.

**After (when the field is NOT in the projection map)**:

If you need a sub-object field that is not projected, the `parse_json(RawJson)` form continues to be the recommended fallback. There is no need to migrate — typed columns are additive, not exhaustive. The catalog explicitly documents what is and isn't projected per stream so operators can quickly decide.

### Pattern 3 — array iteration

An array of sub-records inside `RawJson`.

**Before**:

```kql
MDE_DataExportSettings_CL
| mv-expand log = parse_json(RawJson).logs
| extend Category = tostring(log.category), Enabled = tobool(log.enabled)
| where Enabled == true
```

**After (when the array is projected as a `dynamic` typed column)**:

For arrays the connector flattens to a compact JSON dynamic via `$json:` (see the `ScriptOutput` column on `MDE_MachineActions_CL` for an example), `mv-expand` over the typed column directly:

```kql
MDE_MachineActions_CL
| where TimeGenerated > ago(7d)
| mv-expand step = ScriptOutput
| project CreatedTime, Operator, MachineId, step
```

**After (when the array is summarised to a count)**:

If only the count or flat string-list is needed, the projection map often exposes a `*Count` long or a `[*]` flattened string. For example, `LogsCount` (long) and `EnabledLogs` (string) on `MDE_DataExportSettings_CL`:

```kql
MDE_DataExportSettings_CL
| where LogsCount > 0
| project Destination, LogsCount, EnabledLogs
```

If you need element-level detail, fall back to `parse_json(RawJson).logs` exactly as before — the original form keeps working.

### Pattern 4 — type coercion

A numeric or boolean field that you previously had to cast.

**Before**:

```kql
MDE_SuppressionRules_CL
| extend HitCount = toint(parse_json(RawJson).MatchingAlertsCount)
| top 10 by HitCount
```

**After**:

```kql
MDE_SuppressionRules_CL
| top 10 by MatchingAlertsCount
```

`MatchingAlertsCount` arrives typed as `long`, so the cast is unnecessary. The same pattern applies to `bool` fields (`IsEnabled`, `IsActive`, etc.) and `datetime` fields (`CreatedTime`, `LastSeenUtc`, etc.).

---

## Per-stream migration table

Quick reference for the most-commonly queried fields per stream. The "Key fields" column lists the typed columns that replace the most common `RawJson` reaches; the recipe gives one canonical migration. For full column lists per stream, see [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md).

### P0 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_AdvancedFeatures_CL` | `EnableWdavAntiTampering`, `AatpIntegrationEnabled`, `EnableMcasIntegration`, `AutoResolveInvestigatedAlerts` | `parse_json(RawJson).EnableWdavAntiTampering` → `EnableWdavAntiTampering` |
| `MDE_PreviewFeatures_CL` | `IsOptIn`, `SliceId` | `parse_json(RawJson).IsOptIn` → `IsOptIn` |
| `MDE_AlertServiceConfig_CL` | `WorkloadId`, `Name`, `IsEnabled`, `LastModifiedUtc`, `ModifiedBy` | `parse_json(RawJson).Name` → `Name`; `parse_json(RawJson).IsEnabled` → `IsEnabled` |
| `MDE_AlertTuning_CL` | `RuleId`, `Name`, `IsEnabled`, `CreatedBy`, `Severity` | `parse_json(RawJson).RuleId` → `RuleId`; `parse_json(RawJson).NotificationType` → `Severity` |
| `MDE_SuppressionRules_CL` | `RuleId`, `Name`, `IsEnabled`, `CreatedBy`, `Scope`, `Action`, `MatchingAlertsCount` | `parse_json(RawJson).RuleTitle` → `Name`; `toint(parse_json(RawJson).MatchingAlertsCount)` → `MatchingAlertsCount` |
| `MDE_CustomDetections_CL` | `RuleId`, `Name`, `IsEnabled`, `Severity`, `LastRunStatus` | `parse_json(RawJson).DisplayName` → `Name`; `parse_json(RawJson).Severity` → `Severity` |
| `MDE_DeviceControlPolicy_CL` | `Onboarded`, `NotOnboarded`, `HasPermissions` | `toint(parse_json(RawJson).onboarded)` → `Onboarded` |
| `MDE_WebContentFiltering_CL` | `CategoryName`, `TotalAccessRequests`, `TotalBlockedCount`, `ActivityDeltaPercentage` | `toint(parse_json(RawJson).TotalBlockedCount)` → `TotalBlockedCount` |
| `MDE_SmartScreenConfig_CL` | `TotalThreats`, `Phishing`, `Malicious`, `CustomIndicator`, `Exploit` | `toint(parse_json(RawJson).Phishing)` → `Phishing` |
| `MDE_LiveResponseConfig_CL` | `AutomatedIrLiveResponse`, `AutomatedIrUnsignedScripts`, `LiveResponseForServers` | `tobool(parse_json(RawJson).AutomatedIrUnsignedScripts)` → `AutomatedIrUnsignedScripts` |
| `MDE_AuthenticatedTelemetry_CL` | `IsEnabled`, `AllowNonAuthSense` | `tobool(parse_json(RawJson).value)` → `AllowNonAuthSense` |
| `MDE_PUAConfig_CL` | `AutomatedIrPuaAsSuspicious`, `IsAutomatedIrContainDeviceEnabled` | `tobool(parse_json(RawJson).AutomatedIrPuaAsSuspicious)` → `AutomatedIrPuaAsSuspicious` |
| `MDE_AntivirusPolicy_CL` | `FilterName`, `FilterValue`, `Platform`, `Scope`, `IsEnabled` | `parse_json(RawJson).Name` → `FilterName` |
| `MDE_TenantAllowBlock_CL` | `IndicatorType`, `Action`, `CreatedBy`, `CreatedTime`, `ExpiryTime` | `parse_json(RawJson).Type` → `IndicatorType`; `todatetime(parse_json(RawJson).ExpirationTime)` → `ExpiryTime` |
| `MDE_CustomCollection_CL` | `RuleId`, `Name`, `IsEnabled`, `Scope` | `parse_json(RawJson).Id` → `RuleId` |

### P1 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_DataExportSettings_CL` | `Destination`, `Workspace`, `SubscriptionId`, `ResourceGroup`, `LogsCount`, `EnabledLogs` | `parse_json(RawJson).workspaceProperties.name` → `Destination`; `parse_json(RawJson).workspaceProperties.workspaceResourceId` → `Workspace` |
| `MDE_ConnectedApps_CL` | `AppId`, `Name`, `IsEnabled`, `LatestConnectivity` | `parse_json(RawJson).DisplayName` → `Name`; `tobool(parse_json(RawJson).Enabled)` → `IsEnabled` |
| `MDE_TenantContext_CL` | `TenantId`, `TenantName`, `Region`, `IsMdatpActive`, `IsSentinelActive` | `parse_json(RawJson).OrgId` → `TenantId`; `tobool(parse_json(RawJson).IsMdatpActive)` → `IsMdatpActive` |
| `MDE_TenantWorkloadStatus_CL` | `TenantId`, `TenantGroupId`, `TenantName`, `AllTenantsCount`, `LastUpdatedByUpn` | `parse_json(RawJson).tenantId` → `TenantId`; `toint(parse_json(RawJson).allTenantsCount)` → `AllTenantsCount` |
| `MDE_StreamingApiConfig_CL` | (deprecated; no projection map — use `MDE_DataExportSettings_CL`) | Replace `MDE_StreamingApiConfig_CL` references with `MDE_DataExportSettings_CL`. |
| `MDE_IntuneConnection_CL` | `Status`, `IsEnabled` | `toint(parse_json(RawJson).value)` → `Status` |
| `MDE_PurviewSharing_CL` | `IsEnabled`, `AlertSharingEnabled` | `tobool(parse_json(RawJson).value)` → `AlertSharingEnabled` |

### P2 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_RbacDeviceGroups_CL` | `GroupId`, `Name`, `MachineCount`, `Priority`, `RuleCount` | `toint(parse_json(RawJson).MachineGroupId)` → `GroupId`; `toint(parse_json(RawJson).MachineCount)` → `MachineCount` |
| `MDE_UnifiedRbacRoles_CL` | `RoleId`, `Name`, `IsBuiltIn`, `Scope` | `parse_json(RawJson).id` → `RoleId`; `parse_json(RawJson).displayName` → `Name` |
| `MDE_AssetRules_CL` | `RuleId`, `Name`, `CriticalityLevel`, `AssetType`, `ClassificationValue`, `AffectedAssetsCount` | `parse_json(RawJson).ruleName` → `Name`; `toint(parse_json(RawJson).criticalityLevel)` → `CriticalityLevel` |
| `MDE_SAClassification_CL` | `RuleId`, `Name`, `AccountType`, `Domain`, `IsActive` | `parse_json(RawJson).Name` → `Name`; `tobool(parse_json(RawJson).IsActive)` → `IsActive` |

### P3 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_XspmInitiatives_CL` | `InitiativeId`, `Name`, `TargetValue`, `MetricCount`, `ActiveMetricCount`, `Programs` | `parse_json(RawJson).name` → `Name`; `todouble(parse_json(RawJson).targetValue)` → `TargetValue` |
| `MDE_ExposureSnapshots_CL` | `SnapshotId`, `MetricId`, `Score`, `ScoreChange`, `InitiativeId` | `todouble(parse_json(RawJson).score)` → `Score`; `todouble(parse_json(RawJson).scoreChange)` → `ScoreChange` |
| `MDE_ExposureRecommendations_CL` | `RecommendationId`, `Title`, `Severity`, `Status`, `IsDisabled`, `Score`, `MaxScore` | `parse_json(RawJson).title` → `Title`; `parse_json(RawJson).severity` → `Severity` |
| `MDE_XspmAttackPaths_CL` | `PathId`, `Severity`, `Status`, `Source`, `Target`, `HopCount` | `parse_json(RawJson).attackPathId` → `PathId`; `toint(parse_json(RawJson).HopsCount)` → `HopCount` |
| `MDE_XspmChokePoints_CL` | `NodeId`, `NodeName`, `NodeType`, `Severity`, `AttackPathsCount` | `parse_json(RawJson).NodeName` → `NodeName`; `toint(parse_json(RawJson).AttackPathsCount)` → `AttackPathsCount` |
| `MDE_XspmTopTargets_CL` | `TargetId`, `TargetName`, `AttackPathsCount`, `Status` | `parse_json(RawJson).TargetName` → `TargetName`; `toint(parse_json(RawJson).AttackPathsCount)` → `AttackPathsCount` |
| `MDE_SecurityBaselines_CL` | `ProfileId`, `Name`, `Compliance`, `DeviceCount`, `Score`, `BenchmarkName` | `tobool(parse_json(RawJson).isCompliant)` → `Compliance`; `todouble(parse_json(RawJson).complianceScore)` → `Score` |
| `MDE_DeviceTimeline_CL` | `EventId`, `MachineId`, `EventTime`, `EventType`, `ProcessName`, `FileName`, `Severity` | `parse_json(RawJson).processName` → `ProcessName`; `todatetime(parse_json(RawJson).eventTime)` → `EventTime` |

### P5 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_IdentityOnboarding_CL` | `DCName`, `Domain`, `IpAddress`, `SensorHealth`, `IsActive`, `LastSeenUtc` | `parse_json(RawJson).Name` → `DCName`; `tobool(parse_json(RawJson).IsActive)` → `IsActive` |
| `MDE_IdentityServiceAccounts_CL` | `AccountUpn`, `AccountSid`, `AccountType`, `Domain`, `IsActive`, `Risk`, `LastSeenUtc` | `parse_json(RawJson).Upn` → `AccountUpn`; `parse_json(RawJson).RiskLevel` → `Risk` |
| `MDE_DCCoverage_CL` | `DCName`, `Domain`, `IsActive`, `LastSeenUtc`, `Risk` | `parse_json(RawJson).Name` → `DCName`; `tobool(parse_json(RawJson).HasSensor)` → `IsActive` |
| `MDE_IdentityAlertThresholds_CL` | `ThresholdId`, `AlertType`, `Threshold`, `ExpiresUtc`, `IsEnabled` | `todouble(parse_json(RawJson).Value)` → `Threshold`; `todatetime(parse_json(RawJson).ExpiryTime)` → `ExpiresUtc` |
| `MDE_RemediationAccounts_CL` | `AccountUpn`, `AccountType`, `Domain`, `IsActive`, `LastSeenUtc` | `parse_json(RawJson).GmsaAccount` → `AccountUpn` |

### P6 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_ActionCenter_CL` | `ActionId`, `InvestigationId`, `ActionType`, `ActionStatus`, `Operator`, `MachineId`, `ComputerName`, `EventTime` | `parse_json(RawJson).DecidedBy` → `Operator`; `todatetime(parse_json(RawJson).EventTime)` → `EventTime` |
| `MDE_ThreatAnalytics_CL` | `OutbreakId`, `Title`, `Severity`, `ReportType`, `CreatedOn`, `LastUpdatedOn`, `Tags`, `Keywords` | `parse_json(RawJson).DisplayName` → `Title`; `toint(parse_json(RawJson).Severity)` → `Severity` |
| `MDE_MachineActions_CL` | `ActionId`, `ActionType`, `ActionStatus`, `MachineId`, `Operator`, `ScriptOutput`, `InvestigationId` | `parse_json(RawJson).requestor` → `Operator`; `mv-expand parse_json(RawJson).scriptOutputs` → `mv-expand ScriptOutput` |

### P7 streams

| Stream | Key fields (typed columns) | Common migration |
|---|---|---|
| `MDE_UserPreferences_CL` | `SettingId`, `Name`, `IsEnabled`, `Scope` | `parse_json(RawJson).Name` → `Name` |
| `MDE_MtoTenants_CL` | `TenantId`, `TenantName`, `IsSelected`, `LostAccess`, `IsHomeTenant` | `parse_json(RawJson).tenantId` → `TenantId`; `tobool(parse_json(RawJson).selected)` → `IsSelected` |
| `MDE_LicenseReport_CL` | `SkuName`, `DeviceCount`, `DetectedUsers` | `parse_json(RawJson).Sku` → `SkuName`; `toint(parse_json(RawJson).TotalDevices)` → `DeviceCount` |
| `MDE_CloudAppsConfig_CL` | `SettingId`, `Region`, `IsEnabled`, `ModifiedBy` | `parse_json(RawJson).Region` → `Region` |

---

## Validating a migrated query

When rewriting a query, run both forms side-by-side and compare row counts. For a single stream over a 24-hour window:

```kql
let LookbackHours = 24h;
let RawForm =
    MDE_SuppressionRules_CL
    | where TimeGenerated > ago(LookbackHours)
    | extend RuleName_raw = tostring(parse_json(RawJson).RuleTitle)
    | where RuleName_raw has 'Test'
    | summarize Rows_raw = count();
let TypedForm =
    MDE_SuppressionRules_CL
    | where TimeGenerated > ago(LookbackHours)
    | where Name has 'Test'
    | summarize Rows_typed = count();
RawForm | join kind=fullouter TypedForm on $left.Rows_raw == $right.Rows_typed
```

The two row counts should match. If the typed form returns fewer rows than the raw form, the typed column is null on some rows where the field is present in `RawJson` — most often because the upstream JSON shape differs across response variants. In that case, keep the raw form for that field, or extend the projection map (file an issue with the response shape).

For drift queries, the same comparison can be applied per `EntityId` — group both queries by `EntityId` and confirm the result sets agree.

---

## When to migrate

- **New queries**: prefer typed columns from the start. Faster, cleaner, more readable.
- **Existing workbooks / analytic rules**: migrate opportunistically. There is no urgency — the raw form keeps working. If you are touching a rule for tuning anyway, migrate at the same time.
- **Hunting queries**: same as above. Migrate the next time you tune.
- **Custom Sentinel content not maintained in this repo**: same backward-compat guarantee applies. Migrate at your discretion.

---

## When NOT to migrate

Two cases where the raw `parse_json(RawJson)` form is the correct choice:

1. **The field you need is not in the projection map**. Typed columns are curated; not every field is projected. The catalog explicitly lists which fields are projected per stream. Anything else stays accessible through `RawJson`.
2. **You are joining historical data across the upgrade boundary**. Rows ingested before this release have `null` typed columns (because the projection map was empty). Rows ingested after have populated typed columns. If your query spans both regimes and you need consistent semantics, use `RawJson` everywhere — it has been populated since day one.

---

## Cross-references

- [SCHEMA-CATALOG.md](SCHEMA-CATALOG.md) — full per-stream column list with KQL types and source paths.
- [STREAMS.md](STREAMS.md) — per-stream summary, polling cadence, availability.
- [DRIFT.md](DRIFT.md) — pure-KQL drift model that consumes these tables.
- [WORKBOOKS.md](WORKBOOKS.md) — the shipped workbook column references (already migrated to typed columns).
- [HUNTING-QUERIES.md](HUNTING-QUERIES.md) — analyst-facing hunts.
- [ANALYTIC-RULES-VETTING.md](ANALYTIC-RULES-VETTING.md) — per-rule narrative (rules already use typed columns where available).
