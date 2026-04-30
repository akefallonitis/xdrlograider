# Operator KQL Pack

Canned KQL queries for the most common day-to-day operations on the
XdrLogRaider connector. Paste into the Microsoft Sentinel **Logs** view
or save as a workbook panel.

The connector emits structured telemetry across two surfaces:

| Surface | Where | Use case |
|---|---|---|
| `MDE_*_CL` custom tables | Log Analytics workspace | Drift detection, content queries, analytic rules |
| `customEvents` / `customMetrics` / `AppTraces` | Application Insights | Auth chain diagnostics, per-stream poll outcomes, latency / retry / rate-429 telemetry |

Each query below is portable — no parameters required other than
optional time-range overrides.

---

## 1. "Is the connector healthy right now?"

Single-row Connected / Degraded / Failed verdict.

```kql
let last5m = MDE_Heartbeat_CL | where TimeGenerated > ago(5m);
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
    LastHeartbeat = toscalar(MDE_Heartbeat_CL | summarize max(TimeGenerated))
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
MDE_Heartbeat_CL
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
| where Type !in ("MDE_Heartbeat_CL")
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

Verify that operator queries are hitting typed columns (the iter-14.0
ingest model) rather than only `RawJson`. A row count of 0 here means
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
- [`docs/QUERY-MIGRATION-GUIDE.md`](./QUERY-MIGRATION-GUIDE.md) — RawJson → typed-column patterns
- [`docs/ANALYTIC-RULES-VETTING.md`](./ANALYTIC-RULES-VETTING.md) — per-rule operator narrative
- [`docs/RUNBOOK.md`](./RUNBOOK.md) — operational runbook
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) — failure-mode catalog
