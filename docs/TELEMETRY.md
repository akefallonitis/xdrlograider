# XdrLogRaider Telemetry — operator KQL guide

> v0.1.0 GA. Classification rubric for what lands where + KQL examples per native AppInsights table.

## Why this matters

The connector emits operational telemetry through the Function App's Application Insights instance (env var `APPLICATIONINSIGHTS_CONNECTION_STRING`). Operators query this from Sentinel via cross-resource queries (or directly in App Insights). Picking the right native table per signal type makes your KQL faster, cheaper, and more searchable than dumping everything into `customEvents`.

## Classification rubric (Section 2.3 of the senior-architect plan)

| Native table | Use for | Examples we emit |
|---|---|---|
| `customEvents` | Domain-lifecycle milestones — discrete business events that don't fit native types. Low-cardinality, named, structured properties. | `AuthChain.{Started,Completed,CacheHit,CacheEvict,Reauth,ProactiveRefresh,RateLimited}`, `Ingest.{BoundaryMarker,DlqEnqueued,DlqDrained,RawResponseShape}`, `KV.CacheEvicted` |
| `customMetrics` | Numeric observables — anything that's a count, duration, byte size, ratio, with operator-relevant dimensions. | `xdr.stream.poll_duration_ms`, `xdr.stream.rows_emitted`, `xdr.poll.duration_ms`, `xdr.ingest.rows`, `xdr.ingest.bytes_compressed`, `xdr.ingest.compression_ratio`, `xdr.ingest.dce_latency_ms`, `xdr.ingest.retry_count`, `xdr.ingest.rate429_count`, `xdr.dlq.push_count`, `xdr.dlq.pop_count`, `xdr.dlq.depth`, `xdr.kv.cache_hit`, `xdr.kv.cache_miss`, `xdr.portal.rate429_count` |
| `exceptions` | Errors operators alert on — auth failures, ingest drops, transport faults. Auto-captures stack trace + Properties. | `AuthChain.AADSTSError` (typed via `ErrorClass`), `Ingest.DlqStuck`, `Ingest.DlqDropped`, KV credential fetch failures, post-reauth-retry portal failures, DCE ingest failures |
| `dependencies` | Outbound HTTP / Azure SDK calls. Auto-correlates via OperationId for end-to-end transaction view. | Portal `POST /apiproxy/...` (target=hostname; name=path), DCE `POST .../streams/...` (target=DCE endpoint; resultCode/duration per attempt) |
| `traces` | Structured diagnostics — Write-Information / Write-Warning equivalents with property bags. Operators search by SeverityLevel + structured customDimensions. | Diagnostic logs that don't fit the other categories (e.g. "manifest cache loaded N entries", "tier-poll started for N streams"). |
| `requests` | Function App auto-instruments timer trigger invocations — we don't re-emit. | (FA runtime; `AppRequests | where Name == 'poll-fast-10m'`) |

## Why NOT customEvents for everything?

`customEvents` is designed for low-cardinality named domain events with structured properties. Misusing it for numeric metrics or errors:
- **Numeric in customEvents** — defeats AppInsights metric aggregation; operators can't chart it efficiently. Moves to `customMetrics`.
- **Errors in customEvents** — no stack trace, no automatic alert, no `failedRequests` rollup. Moves to `exceptions`.
- **Logs in customEvents** — wrong table; native `traces` provides SeverityLevel + cleaner KQL.

## Operator KQL examples

### Connector health (per-stream success rate)
```kql
customMetrics
| where TimeGenerated > ago(24h)
| where name == 'xdr.stream.poll_duration_ms'
| extend Stream = tostring(customDimensions.Stream),
         Tier = tostring(customDimensions.Tier),
         Success = tostring(customDimensions.Success)
| summarize TotalPolls = count(),
            SuccessfulPolls = countif(Success == 'True'),
            P50LatencyMs = percentile(value, 50),
            P95LatencyMs = percentile(value, 95)
            by Stream, Tier
| extend SuccessRate = round(100.0 * SuccessfulPolls / TotalPolls, 2)
| order by SuccessRate asc, P95LatencyMs desc
```

### Auth chain failures (last 7 days)
```kql
exceptions
| where TimeGenerated > ago(7d)
| where customDimensions.ErrorClass == 'AuthChain.AADSTSError'
| extend AADSTSCode = tostring(customDimensions.AADSTSCode),
         Stage = tostring(customDimensions.Stage)
| summarize Count = count() by AADSTSCode, Stage, bin(TimeGenerated, 1h)
| render columnchart
```

### DLQ depth + stuck-batch alerts
```kql
customMetrics
| where TimeGenerated > ago(24h)
| where name == 'xdr.dlq.depth'
| summarize CurrentDepth = arg_max(TimeGenerated, value) by tostring(customDimensions.Stream)
| where CurrentDepth > 0
| order by CurrentDepth desc
| union (
    exceptions
    | where TimeGenerated > ago(24h)
    | where customDimensions.ErrorClass == 'Ingest.DlqStuck'
    | extend Stream = tostring(customDimensions.Stream),
             AttemptCount = toint(customDimensions.AttemptCount)
    | project TimeGenerated, Stream, AttemptCount, OperationName='Ingest.DlqStuck'
)
```

### Auth chain milestone trace (per OperationId)
```kql
customEvents
| where TimeGenerated > ago(1h)
| where name startswith 'AuthChain.'
| extend Upn = tostring(customDimensions.Upn),
         Method = tostring(customDimensions.Method)
| order by operation_Id, timestamp asc
```

### Per-stream ingestion bytes (cost FinOps)
```kql
customMetrics
| where TimeGenerated > ago(30d)
| where name == 'xdr.ingest.bytes_compressed'
| summarize TotalBytes = sum(value) by tostring(customDimensions.Stream), bin(TimeGenerated, 1d)
| extend TotalGB = TotalBytes / 1073741824.0
| render timechart
```

### Boundary markers (API working but no data)
```kql
customEvents
| where TimeGenerated > ago(24h)
| where name == 'Ingest.BoundaryMarker'
| extend Stream = tostring(customDimensions.Stream),
         Reason = tostring(customDimensions.Reason)
| summarize Count = count() by Stream, Reason
| order by Count desc
```

### KV cache hit-rate
```kql
customMetrics
| where TimeGenerated > ago(24h)
| where name in ('xdr.kv.cache_hit', 'xdr.kv.cache_miss')
| summarize Count = sum(value) by name
| extend Type = iff(name == 'xdr.kv.cache_hit', 'Hit', 'Miss')
| project Type, Count
| evaluate pivot(Type, sum(Count))
| extend HitRate = round(100.0 * Hit / (Hit + Miss), 2)
```

## What we KEEP as customEvents (correctly classified)

| Event name | Why customEvent |
|---|---|
| `AuthChain.Started` / `Completed` / `CacheHit` / `CacheEvict` / `ProactiveRefresh` / `Reauth` / `RateLimited` | Auth-chain lifecycle milestones — no native table fits. Low-cardinality, named, structured. |
| `Ingest.BoundaryMarker` | "API working but no data" signal — domain-meaningful, not an error, not a metric. |
| `Ingest.DlqEnqueued` / `DlqDrained` | DLQ lifecycle — recoverable workflow milestones, not errors. |
| `Ingest.RawResponseShape` | Debug-mode capture (env-gated; off by default) — diagnostic event, not error. |
| `KV.CacheEvicted` | Cache-lifecycle milestone — informational. |

## What we MIGRATED in v0.1.0 GA

| Event | Was | Now | Why |
|---|---|---|---|
| `Stream.Polled` | customEvent | customMetrics (`xdr.stream.poll_duration_ms` + `xdr.stream.rows_emitted`) | Numeric payload — belongs in metrics for chart/alert efficiency |
| `AuthChain.AADSTSError` | customEvent | exceptions (`ErrorClass=AuthChain.AADSTSError`) | Errors operators alert on — belongs in exceptions for stack trace + auto-rollup |
| `Ingest.DlqStuck` | customEvent | exceptions (`ErrorClass=Ingest.DlqStuck`) | Retry exhaustion is a true error |
| `Ingest.DlqDropped` | customEvent | exceptions (`ErrorClass=Ingest.DlqDropped`) | Row drop is a true error |

Operators with existing KQL against the old `customEvents` event names: queries return zero rows after upgrade. Use the migration table above to update queries.

## Helper reference

Internal contributors use these PowerShell helpers (all auto-correlate via `OperationId`, all auto-redact secrets):

| Helper | Native table | When to call |
|---|---|---|
| `Send-XdrAppInsightsCustomEvent` | customEvents | Domain milestone |
| `Send-XdrAppInsightsCustomMetric` | customMetrics | Numeric observable |
| `Send-XdrAppInsightsException` | exceptions | Operator-actionable error |
| `Send-XdrAppInsightsDependency` | dependencies | Outbound HTTP/Azure call |
| `Send-XdrAppInsightsTrace` | traces | Structured diagnostic log |

All 5 helpers fall back gracefully to `Write-Information` if the TelemetryClient isn't available (test/CI environments without AppInsights connection string).
