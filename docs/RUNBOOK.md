# Operator runbook

Daily, weekly, and quarterly operational tasks for XdrLogRaider.

## Daily (2 min)

```kql
// Is the connector alive? (heartbeat-5m + 5 cadence-tier polls)
MDE_Heartbeat_CL
| where TimeGenerated > ago(1h)
| summarize LastSeen = max(TimeGenerated) by FunctionName
| extend AgeMinutes = datetime_diff("minute", now(), LastSeen)

// Is auth healthy? (auth chain diagnostics live in App Insights customEvents)
customEvents
| where name in ('AuthChain.AADSTSError', 'AuthChain.Completed')
| order by timestamp desc
| take 5
| project timestamp, name, customDimensions

// Any inventory-tier streams failing silently?
MDE_Heartbeat_CL
| where TimeGenerated > ago(2h) and Tier == 'inventory'
| summarize Success = max(StreamsSucceeded), Attempted = max(StreamsAttempted) by FunctionName
| where Success < Attempted
```

## Weekly (10 min)

- Review `MDE_Drift_Inventory(30d, 1d)` — any unexpected daily-cadence changes?
- Review `MDE_Drift_Configuration(7d, 6h)` — any rule / RBAC drift?
- Review `MDE_Drift_Exposure(7d, 1h)` — any new XSPM attack paths?
- Review `sentinel/analytic-rules/*` firings — tune false positives
- Check Azure cost report for XdrLogRaider RG — any spikes?
- Verify service account hasn't been modified: `MDE_Drift_Configuration(7d, 6h) | where EntityId contains service-account-upn`

## Monthly

- Run `./tests/Run-Tests.ps1 -Category local-online` to verify auth chain still works
- Review CHANGELOG.md for upstream fixes — upgrade if behind
- Rotate service account password (if using Credentials+TOTP) and re-run `Initialize-XdrLogRaiderAuth.ps1`

## Quarterly

- Review service account RBAC (still minimum necessary?)
- Review Key Vault access logs (only Function App MI accessing secrets?)
- Review named-location CA exception (if applicable) still scoped correctly
- Verify Function App is on a supported PowerShell version
- Regenerate software passkey if approaching registration anniversary (organizational policy)

## Incident response

### Auth chain failure (no AuthChain.Completed in App Insights)

**Symptom**: `customEvents` in App Insights shows `AuthChain.AADSTSError` events with no recent `AuthChain.Completed`, and `MDE_Heartbeat_CL` rows show `StreamsSucceeded = 0`. All tier pollers refuse to run (they gate on the auth-selftest flag) so nothing ingests until this resolves.

```kql
// App Insights — most recent auth chain event
customEvents
| where timestamp > ago(1h)
| where name startswith 'AuthChain.'
| order by timestamp desc
| take 5
| project timestamp, name, customDimensions
```

**Diagnose by `name` + `customDimensions.Stage`**:

| Event / Stage | Most likely cause | First action |
|---|---|---|
| `AuthChain.AADSTSError` (any AADSTSCode) | Entra sign-in blocked | Check Entra sign-in logs for the service account — look for Conditional Access deny, password expired, or MFA enrolment lapse |
| `Stage = credentials` | KV read failed | Check FA's MI has `Key Vault Secrets User`; verify secrets exist (`mde-portal-upn`, `mde-portal-password`, `mde-portal-totp` OR `mde-portal-passkey`) |
| `Stage = auth-chain` (sccauth not issued) | Portal rejected ESTS cookie | Service account lacks portal access — verify Defender RBAC role (`Defender XDR Analyst` or equivalent read role) |
| `Stage = sample-call` (HTTP 401/403) | Service account roles missing | Verify both `Security Reader` (Entra) + Defender RBAC are assigned |
| `AuthChain.RateLimited` repeatedly | Rate limits hit | Check `customDimensions.RetryAfterMs`; reduce poll cadence in the affected tier; investigate noisy stream |

**Resolution paths**:
1. **Password expired**: reset in Entra → re-run `Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <name>`
2. **TOTP seed rotated**: re-enrol at `mysignins.microsoft.com` → re-run helper
3. **Passkey revoked**: re-register → re-run helper
4. **CA policy blocks the SP**: add the service account to the CA exclusion list OR register a named location exception
5. **Never resolves**: follow [TROUBLESHOOTING.md](TROUBLESHOOTING.md) + file a `bug_report` issue

Until fixed, **no data flows** — the auth-selftest gate is intentional (see `docs/ARCHITECTURE.md`), preventing 401 storms on misconfigured auth.

### Specific stream endpoint broken (Microsoft hardened it)

1. Identify via `MDE_Heartbeat_CL | extend e = tostring(parse_json(Notes).errors) | where isnotempty(e)`
2. File `portal_endpoint_broken` issue with repo — see template
3. Workaround: remove the broken stream from the tier poller temporarily
4. Wait for release with fix / removal

### Ingestion cost spike

1. `Usage | where DataType startswith "MDE_" | summarize GBs = sum(Quantity) / 1000 by DataType | order by GBs desc`
2. Identify the noisy stream
3. Increase `cadence` parameter for that stream in the ARM / Bicep, redeploy
4. Consider adding hash-based dedupe in the endpoint wrapper

### Service account compromised

1. Disable the service account in Entra
2. Revoke all active sessions: `Revoke-MgUserSignInSession`
3. Purge Key Vault secrets: `Remove-AzKeyVaultSecret`
4. Create new service account + creds + passkey
5. Re-run `Initialize-XdrLogRaiderAuth.ps1`
6. Review `MDE_Drift_Configuration` + `MDE_Drift_Inventory` for the period of compromise — look for policy / RBAC / settings changes made by the compromised account

## App Insights structured-logging KQL

The connector emits Microsoft-best-practices structured logging to App Insights.
Auth-chain failures, rate-limit pressure and ingest gaps land as
`customEvents` with stable property bags + `operation_Id` correlation. Three
critical event types (`AuthChain.AADSTSError`, `AuthChain.RateLimited`,
`AuthChain.BoundaryMarker`) are excluded from adaptive sampling so they're
never dropped under load.

```kql
// AADSTS error breakdown — pivot by code + auth method
customEvents
| where name == 'AuthChain.AADSTSError'
| summarize count() by tostring(customDimensions.AADSTSCode), tostring(customDimensions.Method)

// Per-stream latency P95 (Stream.Polled fires once per stream per tier-poll)
customEvents
| where name == 'Stream.Polled'
| extend Stream = tostring(customDimensions.Stream), Latency = todouble(customDimensions.LatencyMs)
| summarize P95 = percentile(Latency, 95) by Stream

// 429 pressure over the last hour
customEvents
| where name == 'AuthChain.RateLimited' and timestamp > ago(1h)
| summarize Retries = count(), MaxRetryAfterMs = max(toint(customDimensions.RetryAfterMs)) by tostring(customDimensions.Path)

// Boundary markers — distinguishes "API working but no data" from "API failed"
customEvents
| where name == 'Ingest.BoundaryMarker'
| summarize count() by tostring(customDimensions.Stream), tostring(customDimensions.Reason)
```

End-to-end transaction stitching: every Connect-DefenderPortal call mints one
`OperationId` (GUID) cached on the session. Downstream
Invoke-DefenderPortalRequest + Invoke-MDETierPoll reuse it, so AI's
transaction view shows the full auth-chain -> portal request -> per-stream
poll graph for a single auth attempt.

## Contact

- Repo: https://github.com/akefallonitis/xdrlograider
- Issues: use the templates (`bug_report`, `portal_endpoint_broken`, `new_stream_request`, `feature_request`)
- Security: private disclosure via GitHub Security Advisories (see SECURITY.md)
