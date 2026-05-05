# Operator KQL Pack (v0.1.0 GA)

Canned KQL queries for the most common day-to-day operations on the
XdrLogRaider connector. Paste into the Microsoft Sentinel **Logs** view
or save as a workbook panel.

The connector emits structured telemetry across two surfaces:

| Surface | Where | Use case |
|---|---|---|
| `Defender_<Category>_CL` consolidated tables (10 + `XdrConnectorHealth_CL`) | Log Analytics workspace | Drift detection, content queries, analytic rules |
| `AppRequests` / `AppEvents` / `AppMetrics` / `AppExceptions` / `AppTraces` / `AppDependencies` | Application Insights | Auth chain diagnostics, per-stream poll outcomes, latency / retry / rate-429 telemetry |

Each query below is portable — no parameters required other than optional time-range overrides.

## Two operator-side query patterns

The connector uses two complementary KQL patterns. Operators choose based on **what question they're answering**:

### Pattern A — Snapshot streams use `arg_max` for "current state"

For streams that re-ingest **full state per poll** (51 of 59 streams; everything except the 8 `Filter='fromDate'` delta streams), every poll deposits a fresh full snapshot. Operators querying "what's the current state?" use `arg_max` to retrieve the latest row per entity:

```kql
Defender_ConfigurationAndSettings_CL
| where SourceName == 'MDE_AdvancedFeatures_CL'
| where TimeGenerated > ago(7d)
| summarize arg_max(TimeGenerated, *) by EntityId
| project FeatureName = EntityId, IsEnabled, TimeGenerated
| order by FeatureName asc
```

This pattern works for: feature flags, RBAC roles, suppression rules, secure-score breakdown, exposure recommendations, attack paths, posture metrics — anything where the operator wants the LATEST state, not the change history.

### Pattern B — Drift parsers use `mv-apply` for "change events"

For streams that need **field-level change detection** (any snapshot stream is eligible), the v0.1.0 GA architecture provides 4 cadence-tier drift parsers (`MDE_Drift_Configuration`, `MDE_Drift_Inventory`, `MDE_Drift_Exposure`, `MDE_Drift_Maintenance`). Operators query the parser, NOT the raw table:

```kql
MDE_Drift_Configuration(7d, 6h)
| where StreamName == 'MDE_AdvancedFeatures_CL'
| where ChangeType == 'Modified'
| where FieldName in ('TamperProtectionEnabled', 'EdrInBlockMode')
| project TimeGenerated, EntityId, FieldName, OldValue, NewValue, ChangeType
| order by TimeGenerated desc
```

This pattern works for: configuration drift alerts, RBAC change tracking, posture-score regressions, exposure-recommendation lifecycle, threat-analytics outbreak deltas — anything where the operator wants the CHANGE history, not the current state.

### When to use which

| Question | Pattern |
|---|---|
| What's the current value of feature X? | A — `arg_max` on the category table |
| Did feature X change in the last 24h? | B — drift parser |
| Which entities are missing from yesterday's poll? | B — drift parser (ChangeType == 'Removed') |
| What's the row count per stream over time? | A — direct count() on category table |
| Which entities had ANY field change between two snapshots? | B — drift parser |
| What's the latest XSPM attack-path score for entity Y? | A — `arg_max` on `Defender_ExposureManagement_CL` filtered by SourceName |

Operators **NEVER** need to write `arg_max` against the parser output (the parser already runs `arg_max` internally for its current/previous join). Operators **NEVER** need to manually compare two snapshots — the parser does field-level diff via `mv-apply set_union(CurrentFields, PreviousFields)` and emits `ChangeType` (Added | Removed | Modified) per field.

This is the v0.1.0 GA D'.50 architectural pattern. It avoids per-stream operator-side `arg_max` boilerplate that bloats rule queries to 50+ lines and degrades query CPU.

Each query below is portable — no parameters required other than optional time-range overrides.

---

## 1. "Is the connector healthy right now?"

Single-row Connected / Degraded / Failed verdict.

```kql
let last5m = XdrConnectorHealth_CL | where TimeGenerated > ago(5m);
let pollSuccess = toscalar(last5m | where StreamsSucceeded > 0 | count);
let authFailures = toscalar(
    customEvents
    | where timestamp > ago(5m)
    | where name == "AuthChain.AADSTSError"
    | count
);
print
    Verdict = case(
        authFailures > 0, strcat("FAILED — auth errors in last 5m: ", authFailures),
        pollSuccess == 0, "DEGRADED — no successful polls in last 5m",
        "HEALTHY"
    ),
    LastHeartbeat = toscalar(XdrConnectorHealth_CL | summarize max(TimeGenerated))
```

---

## 2. "Did auth fail in the last hour?"

Lists every AADSTS-coded auth failure with the AAD error code surfaced
as a custom dimension. Microsoft AppInsights `customEvents` table —
emitted by the FA's `Send-XdrAppInsightsCustomEvent` helper.

```kql
customEvents
| where timestamp > ago(1h)
| where name == "AuthChain.AADSTSError"
| project timestamp,
          AADSTSCode = tostring(customDimensions.AADSTSCode),
          Stage      = tostring(customDimensions.Stage),
          Upn        = tostring(customDimensions.Upn),
          PortalHost = tostring(customDimensions.PortalHost),
          Message    = tostring(customDimensions.Message)
| order by timestamp desc
```

---

## 3. "Heartbeat by tier — last 24h"

Operator dashboard for the 5-tier polling model + the operational
heartbeat tier. Includes the embedded `Notes.rate429Count` and
`Notes.gzipBytes` fields.

```kql
XdrConnectorHealth_CL
| where TimeGenerated > ago(24h)
| extend n = parse_json(Notes)
| project TimeGenerated, Tier, FunctionName, StreamsAttempted, StreamsSucceeded,
          RowsIngested, LatencyMs,
          Rate429Count = toint(n.rate429Count),
          GzipBytes    = tolong(n.gzipBytes)
| order by TimeGenerated desc
```

---

## 4. "What changed in last 24h?" — drift across all tiers

Drift detection unioned across the 4 cadence-bucket parsers. Excludes
the `fast` tier (Action Center is events not snapshots).

```kql
union (MDE_Drift_Configuration("24h", "1h")),
      (MDE_Drift_Exposure("24h", "1h")),
      (MDE_Drift_Inventory("24h", "1h")),
      (MDE_Drift_Maintenance("24h", "1h"))
| where ChangeType in ("Added", "Modified", "Removed")
| project TimeGenerated, StreamName, EntityId, FieldName, OldValue, NewValue, ChangeType
| order by TimeGenerated desc
```

To scope to a single tier, pick the parser by name:
`MDE_Drift_Exposure("24h", "1h")` etc.

---

## 5. "Who modified suppression rules?"

Identity attribution for security-relevant config drift. Joins the
drift detection output to `AuditLogs` by ±5-minute time-proximity.

```kql
MDE_Drift_Configuration("24h", "1h")
| where StreamName == "MDE_SuppressionRules_CL"
| where ChangeType in ("Added", "Modified")
| extend changeTime = TimeGenerated
| join kind=inner (
    AuditLogs
    | where TimeGenerated > ago(25h)
    | where OperationName has_any ("alert", "suppression", "rule")
    | project AuditTime = TimeGenerated, InitiatedBy_user = tostring(InitiatedBy.user.userPrincipalName), OperationName
) on $left.changeTime == $right.AuditTime
| where abs(datetime_diff('minute', changeTime, AuditTime)) <= 5
| project changeTime, EntityId, FieldName, OldValue, NewValue, InitiatedBy_user, OperationName
| order by changeTime desc
```

---

## 6. "Which streams failed to poll in the last hour?"

Per-stream success/failure rollup from `customEvents`.

```kql
customEvents
| where timestamp > ago(1h)
| where name == "Stream.Polled"
| extend Stream  = tostring(customDimensions.Stream),
         Tier    = tostring(customDimensions.Tier),
         Outcome = tostring(customDimensions.Outcome)
| summarize
      Successful = countif(Outcome == "success"),
      Failed     = countif(Outcome == "fail")
  by Stream, Tier
| where Failed > 0
| order by Failed desc
```

---

## 7. "Action Center — recent remediation activity"

The `fast` tier (10-min cadence) emits Action Center + Machine Action
events. Use this to audit Live Response runs, machine isolation,
file blocking, etc.

```kql
MDE_ActionCenter_CL
| where TimeGenerated > ago(24h)
| project TimeGenerated, EntityId, ActionType, ActionStatus, MachineId, RequestSource, CreationDateTimeUtc
| order by TimeGenerated desc
| take 50
```

---

## 8. "Rate-limited polls — 429s in last 24h"

Detect portal API rate limiting per stream (operator-actionable: tune
cadence or implement DLQ in v0.3.0).

```kql
customEvents
| where timestamp > ago(24h)
| where name == "AuthChain.RateLimited"
| project timestamp,
          Stream     = tostring(customDimensions.Stream),
          Tier       = tostring(customDimensions.Tier),
          RetryAfter = toint(customDimensions.RetryAfterSeconds)
| summarize Count = count(), MaxRetryAfter = max(RetryAfter) by Stream, Tier
| order by Count desc
```

---

## 9. "Boundary-marker rows — was the API silent or empty?"

When a stream's API call returns 200 but no data, the connector emits a
`boundary-empty-<id>` marker row to distinguish "API healthy but no data"
from "API broken". Use this to verify a quiet tenant isn't a connector
fault.

```kql
union MDE_*_CL
| where TimeGenerated > ago(24h)
| where EntityId startswith "boundary-empty-" or EntityId startswith "boundary-null-"
| summarize MarkerCount = count() by Type, EntityIdShape = strcat_array(extract_all(@'^(boundary-\w+)-', EntityId), ',')
| order by MarkerCount desc
```

---

## 10. "Per-tier ingestion volume — last 7 days"

Cost transparency: which tiers are ingesting how much data into Log
Analytics, broken out by stream.

```kql
union MDE_*_CL
| where TimeGenerated > ago(7d)
| where Type !in ("XdrConnectorHealth_CL")
| summarize
      Rows  = count(),
      Bytes = sum(_BilledSize)
  by Type
| extend Tier = case(
      Type in ("MDE_ActionCenter_CL", "MDE_MachineActions_CL"),                                                         "fast",
      Type in ("MDE_AssetRules_CL", "MDE_XspmInitiatives_CL", "MDE_ExposureSnapshots_CL",
               "MDE_ExposureRecommendations_CL", "MDE_XspmAttackPaths_CL", "MDE_XspmChokePoints_CL",
               "MDE_XspmTopTargets_CL"),                                                                                "exposure",
      Type in ("MDE_DataExportSettings_CL", "MDE_StreamingApiConfig_CL"),                                               "maintenance",
      "config-or-inventory")
| project Tier, Type, Rows, Bytes_MB = format_bytes(Bytes, 2, "MB")
| order by Bytes desc
```

---

## 11. "Auth chain timing — p99 latency by stage"

Performance baseline for the auth chain's 3 stages (ESTS / sccauth /
sample-call).

```kql
customEvents
| where timestamp > ago(7d)
| where name == "AuthChain.Completed"
| extend EstsMs       = toint(customDimensions.estsMs),
         SccauthMs    = toint(customDimensions.sccauthMs),
         SampleCallMs = toint(customDimensions.sampleCallMs)
| summarize
      EstsP99       = percentile(EstsMs, 99),
      SccauthP99    = percentile(SccauthMs, 99),
      SampleCallP99 = percentile(SampleCallMs, 99),
      Calls         = count()
```

---

## 12. "Streams emitting zero rows — coverage gap detector"

Detect streams that aren't producing data after 24h (could indicate
filter mismatch, tenant feature-gating, or portal endpoint deprecation).

```kql
let allStreams = dynamic([
    "MDE_AdvancedFeatures_CL", "MDE_PreviewFeatures_CL", "MDE_AlertServiceConfig_CL",
    "MDE_AlertTuning_CL", "MDE_SuppressionRules_CL", "MDE_CustomDetections_CL",
    "MDE_DeviceControlPolicy_CL", "MDE_WebContentFiltering_CL", "MDE_SmartScreenConfig_CL",
    "MDE_LiveResponseConfig_CL", "MDE_AuthenticatedTelemetry_CL", "MDE_PUAConfig_CL",
    "MDE_AntivirusPolicy_CL", "MDE_TenantAllowBlock_CL", "MDE_CustomCollection_CL",
    "MDE_DataExportSettings_CL", "MDE_ConnectedApps_CL", "MDE_TenantContext_CL",
    "MDE_TenantWorkloadStatus_CL", "MDE_DeviceTimeline_CL", "MDE_IntuneConnection_CL",
    "MDE_PurviewSharing_CL", "MDE_RbacDeviceGroups_CL", "MDE_UnifiedRbacRoles_CL",
    "MDE_AssetRules_CL", "MDE_SAClassification_CL", "MDE_XspmInitiatives_CL",
    "MDE_ExposureSnapshots_CL", "MDE_ExposureRecommendations_CL", "MDE_XspmAttackPaths_CL",
    "MDE_XspmChokePoints_CL", "MDE_XspmTopTargets_CL", "MDE_SecurityBaselines_CL",
    "MDE_IdentityOnboarding_CL", "MDE_IdentityServiceAccounts_CL", "MDE_DCCoverage_CL",
    "MDE_IdentityAlertThresholds_CL", "MDE_RemediationAccounts_CL", "MDE_ActionCenter_CL",
    "MDE_MachineActions_CL", "MDE_ThreatAnalytics_CL", "MDE_UserPreferences_CL",
    "MDE_MtoTenants_CL", "MDE_LicenseReport_CL", "MDE_CloudAppsConfig_CL"
]);
let observed = toscalar(union MDE_*_CL | where TimeGenerated > ago(24h)
                       | summarize make_set(Type));
print Stream = allStreams
| mv-expand Stream to typeof(string)
| where Stream !in (observed)
| project StreamWithoutData = Stream
```

---

## 13. "Wire-chaining sanity check — typed columns vs RawJson"

Verify that operator queries are hitting typed columns (the v0.1.0 GA
typed-column ingest model) rather than only `RawJson`. A row count of 0 here means
the ProjectionMap fired correctly. A row count > 0 means a stream is
emitting only `RawJson` and missing typed-column extraction — file an
issue.

```kql
MDE_ActionCenter_CL
| where TimeGenerated > ago(1h)
| where isempty(ActionId) and isempty(ActionType)
| count
```

(Replace `MDE_ActionCenter_CL` + `ActionId/ActionType` with the
target stream's typed columns.)

---

## See also

- [`docs/SCHEMA-CATALOG.md`](./SCHEMA-CATALOG.md) — typed-column reference per stream
- [`docs/SCHEMA-CATALOG.md`](./SCHEMA-CATALOG.md) — per-stream typed-column reference for KQL authors
- [`docs/ANALYTIC-RULES-VETTING.md`](./ANALYTIC-RULES-VETTING.md) — per-rule operator narrative
- [`docs/RUNBOOK.md`](./RUNBOOK.md) — operational runbook
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) — failure-mode catalog
