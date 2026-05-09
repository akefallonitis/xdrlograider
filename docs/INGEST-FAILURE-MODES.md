# Ingest failure modes — operator runbook

> v0.1.0 GA — Operator-facing classification of every error/exception class
> the connector emits to App Insights, with triage steps + recommended action.

XdrLogRaider's auth chain + ingest pipeline emit structured exceptions to
Application Insights `AppExceptions` table. Each exception has a stable
`ErrorClass` Property (e.g., `AuthChain.AADSTSError`, `Ingest.DlqStuck`)
that this runbook maps to operator action.

## Quick triage (5 min)

```kql
// Last 24h — failure classes by frequency
AppExceptions
| where TimeGenerated > ago(24h)
| extend ErrorClass = tostring(Properties.ErrorClass)
| where isnotempty(ErrorClass)
| summarize Count = count(), Latest = max(TimeGenerated) by ErrorClass
| order by Count desc
```

Match the top `ErrorClass` to the table below.

---

## Failure-mode reference table

| ErrorClass | Trigger | Severity | Operator action |
|---|---|---|---|
| `AuthChain.AADSTSError` | AAD STS rejected service-account credentials | High | (1) Verify SA password not expired. (2) Verify SA not locked out. (3) Check Conditional Access policy didn't change. (4) Re-upload secrets via `Initialize-XdrLogRaiderAuth.ps1`. |
| `AuthChain.RateLimited` | Portal returned HTTP 429 (auth call) | Medium | Connector auto-backs off (`Retry-After` honored + jitter + max-retry). If persistent: check tenant load; reduce poll cadence via app-setting overrides; verify SA isn't shared with other tooling. |
| `AuthChain.SessionTimeout` | Portal sccauth cookie expired mid-session | Low | Connector auto-reauths on next request (401/440 reauth path). No action needed unless timeout rate is anomalous (>5/h). |
| `Ingest.DlqStuck` | Row failed all DCE retries, persisted to Storage Table `xdrIngestDlq` | Medium | (1) Check DCE health in Sentinel portal. (2) Verify DCR schema matches incoming row shape. (3) Manual replay via `Pop-XdrIngestDlq` after fix. (4) If row shape genuinely incompatible: investigate manifest ProjectionMap. |
| `Ingest.DlqDropped` | Row dropped from DLQ after permanent failure | High | Investigate row shape; fix manifest ProjectionMap or DCR schema; consider data-loss reporting if dropped rows represent operator-actionable signals. |
| `Ingest.DlqExpired` | DLQ row exceeded TTL (default 7 days) | Medium | (1) Check why row was un-replayable. (2) Increase `XDR_INGEST_DLQ_TTL_DAYS` app-setting if TTL too short for known incident response cadence. (3) If chronic: address root cause of upstream failures. |
| `Ingest.BoundaryMarker` | Empty/null portal response (zero rows) | Info | NOT an error — operator-visible signal. Verify portal endpoint is live; some streams legitimately return zero on quiet tenants. |
| `Manifest.MissingProjectionMap` | Stream emits typed cols not declared in manifest | Medium | Update manifest entry's `ProjectionMap` to include the missing field; re-deploy connector. Until fixed, those fields go to `RawJson` only. |
| `Portal.Unavailable` | Portal HTTPS call timed out / 5xx | Low | Transient. Connector auto-retries with backoff. If persistent: check Microsoft 365 service health; check tenant FQDN reachability from FA outbound IP. |

---

## Per-class debug queries

### AuthChain.AADSTSError

```kql
AppExceptions
| where TimeGenerated > ago(7d)
| where Properties.ErrorClass == 'AuthChain.AADSTSError'
| project TimeGenerated,
          AADSTSCode = tostring(Properties.AADSTSCode),
          Stage = tostring(Properties.Stage),
          Upn = tostring(Properties.Upn),
          OuterMessage
| summarize Count = count() by AADSTSCode, Stage
| order by Count desc
```

Common AADSTS codes:
- `AADSTS50126` — invalid creds (password change?)
- `AADSTS50053` — account locked
- `AADSTS50058` — silent token failed (CA policy?)
- `AADSTS70000` — invalid grant (refresh token expired?)

### Ingest.DlqStuck

```kql
// Look at DLQ depth growth + per-stream dropped row count
AppMetrics
| where TimeGenerated > ago(7d)
| where Name == 'xdr.dlq.depth'
| summarize MaxDepth = max(Value), AvgDepth = avg(Value)
            by Stream = tostring(Properties.Stream), bin(TimeGenerated, 1d)
| order by MaxDepth desc
```

### Ingest.BoundaryMarker (empty responses)

```kql
// Streams with 0-row responses (legitimate empty vs. broken)
AppEvents
| where TimeGenerated > ago(24h)
| where Name == 'Ingest.BoundaryMarker'
| project TimeGenerated, Stream = tostring(Properties.Stream),
          Reason = tostring(Properties.Reason)
| summarize Count = count() by Stream, Reason
| order by Count desc
```

### Auth chain step latency

```kql
// Find slow auth steps (D'.4 metric)
AppMetrics
| where TimeGenerated > ago(24h)
| where Name == 'xdr.auth.chain_step_duration_ms'
| extend Step = tostring(Properties.Step), DurationSec = todouble(Value) / 1000.0
| summarize MaxSec = max(DurationSec), P95Sec = percentile(DurationSec, 95)
            by Step
| order by P95Sec desc
```

---

## Escalation flowchart

1. **Heartbeat absent for >30 min**
   → Connector dead. FA portal: is FA Running? If yes, check `AuthChain.Started` events.
   If no `Started` events: orchestrator dead — check `Xdr-PollOrchestrator` invocations
   in `AppRequests`. If neither: timer trigger broken — restart FA.

2. **Heartbeat present but `StreamsSucceeded == 0`**
   → Auth chain failure. Query `AuthChain.AADSTSError` exceptions per above.

3. **Heartbeat present + StreamsSucceeded > 0 but specific stream missing rows**
   → Per-stream poll failure. Filter `xdr.stream.poll_duration_ms` by stream;
   check `xdr.portal.rate429_count` for that stream.

4. **DLQ depth rising**
   → Sustained DCE write failure or row-shape mismatch. Investigate
   `Ingest.DlqStuck` exceptions per above.

5. **Connector card shows IsConnected = No**
   → IsConnectedQuery (XdrConnectorHealth_CL with Tier != 'Heartbeat' AND
   StreamsSucceeded > 0 AND RowsIngested > 0) returns no rows. Means
   either no successful poll in 1h OR all polls returned zero rows. See
   #1 + #2.

---

## Related docs

- [`docs/RUNBOOK.md`](RUNBOOK.md) — operational runbook (deploy, upgrade,
  rollback, monitor)
- [`docs/AUTH.md`](AUTH.md) — auth chain reference (passkey/TOTP/sccauth/XSRF)
- [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — broader troubleshooting
- [`docs/TELEMETRY.md`](TELEMETRY.md) — App Insights table classification
  (customMetrics / customEvents / exceptions / dependencies / traces)
