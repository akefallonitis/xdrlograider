# Operator runbook

Daily, weekly, and quarterly operational tasks for XdrLogRaider.

## Daily (2 min)

```kql
// Is the connector alive? (Connector-Heartbeat + 5 cadence-tier polls)
XdrConnectorHealth_CL
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
XdrConnectorHealth_CL
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

**Symptom**: `customEvents` in App Insights shows `AuthChain.AADSTSError` events with no recent `AuthChain.Completed`, and `XdrConnectorHealth_CL` rows show `StreamsSucceeded = 0`. All tier pollers refuse to run (they gate on the auth-selftest flag) so nothing ingests until this resolves.

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

1. Identify via `XdrConnectorHealth_CL | extend e = tostring(parse_json(Notes).errors) | where isnotempty(e)`
2. File `portal_endpoint_broken` issue with repo — see template
3. Workaround: remove the broken stream from the tier poller temporarily
4. Wait for release with fix / removal

### Ingestion cost spike

1. `Usage | where DataType startswith "MDE_" | summarize GBs = sum(Quantity) / 1000 by DataType | order by GBs desc`
2. Identify the noisy stream
3. Increase `cadence` parameter for that stream in the ARM template (`deploy/compiled/mainTemplate.json`), redeploy
4. Consider adding hash-based dedupe in the endpoint wrapper

### Service account compromised

1. Disable the service account in Entra
2. Revoke all active sessions: `Revoke-MgUserSignInSession`
3. Purge Key Vault secrets: `Remove-AzKeyVaultSecret`
4. Create new service account + creds + passkey
5. Re-run `Initialize-XdrLogRaiderAuth.ps1`
6. Review `MDE_Drift_Configuration` + `MDE_Drift_Inventory` for the period of compromise — look for policy / RBAC / settings changes made by the compromised account

### FA cold-start nudge (Y1 Linux Consumption — 503 hangs > 15 min)

**Symptom**: Function App is up but no functions firing post-deploy; portal shows the FA as Running but `AppRequests` shows zero invocations for `Xdr-Refresh` / `Connector-Heartbeat` past their cadence; Sentinel connector card stays "Disconnected".

**Root cause**: Y1 Linux Consumption Plan + WEBSITE_RUN_FROM_PACKAGE = 1 + the function-app.zip URL is hitting GitHub's 302 redirect on `/releases/latest/download/` instead of a direct release-asset URL — the FA's package fetcher hangs on the redirect.

**Fix path**:

1. Identify the actual release-asset URL:
   ```powershell
   gh release view v0.1.0 --json assets -q '.assets[] | select(.name=="function-app.zip") | .url'
   # Returns: https://github.com/akefallonitis/xdrlograider/releases/download/v0.1.0/function-app.zip
   ```
2. Update FA appSettings:
   ```powershell
   az functionapp config appsettings set --name <fn-app> --resource-group <rg> \
     --settings WEBSITE_RUN_FROM_PACKAGE='https://github.com/akefallonitis/xdrlograider/releases/download/v0.1.0/function-app.zip'
   ```
3. Stop + Start the Function App (full restart — `Restart-AzFunctionApp` is insufficient):
   ```powershell
   Stop-AzWebApp -ResourceGroupName <rg> -Name <fn-app>
   Start-AzWebApp -ResourceGroupName <rg> -Name <fn-app>
   ```
4. Wait ≤10 min for cold-start completion. Verify via:
   ```kql
   AppRequests | where TimeGenerated > ago(15m) | where Name == 'Xdr-Refresh' | take 5
   ```

### DLQ replay (drain queued failures)

**Symptom**: `XdrConnectorHealth_CL.DlqDepth > 5` for ≥1 hour, OR analytic rule `XdrOps-DlqDepthAlert` fires.

**Root cause**: terminal DCE failures (429-storm or 5xx-exhaustion) spooled rows to the dead-letter Storage table `xdrIngestDlq` (per-stream queues). Replay happens automatically on the next poll cycle for that stream — but if the underlying transient cause persists, depth grows.

**Diagnose**:

```powershell
# Get DLQ depth + age per stream
$ctx = New-AzStorageContext -StorageAccountName <sa-name> -UseConnectedAccount
$rows = Get-AzStorageTableRowAll -table (Get-AzStorageTable -Context $ctx -Name xdrIngestDlq).CloudTable
$rows | Group-Object PartitionKey | Select Name, Count, @{n='OldestUtc';e={($_.Group | Sort EnqueuedUtc | Select -First 1).EnqueuedUtc}}
```

**Force replay** (if next poll cycle is too far out):

1. Manually invoke `Pop-XdrIngestDlq` for the affected stream (runs in `Xdr-PollStream` activity context — call it via Function App console `func host run` or trigger an out-of-band orchestration via `Start-NewOrchestration`).
2. Or trigger immediate poll: bump the cadence override env var to fire the tier early, then revert.
3. If replay continues to fail with the same error class: Microsoft platform issue — file `portal_endpoint_broken` issue.

**TTL eviction**: rows older than 7 days are auto-evicted by `Pop-XdrIngestDlq`. Operators don't need to manually purge.

### B2 auth circuit-breaker reset

**Symptom**: `AppExceptions` shows `AuthChain.FailureCircuit` events. The connector entered a fail-fast state after >2 consecutive sign-in failures within 5 min — it stops trying for the cache-TTL window (default 5 min back-off + 50 min normal cache) so a stale credential doesn't re-attempt 50× and burn the lockout counter.

**Diagnose**:

```kql
AppExceptions
| where TimeGenerated > ago(1h)
| where ProblemId contains 'AuthChain.FailureCircuit' or Properties contains 'AuthChain.FailureCircuit'
| project TimeGenerated, ProblemId, Properties
| order by TimeGenerated desc
```

**Reset path**:

1. **Identify root auth failure** first (see "Auth chain failure" procedure above) — the circuit-breaker is a SYMPTOM of underlying auth issue, not the cause.
2. After fixing the underlying auth (password reset, TOTP regen, passkey re-issue, CA exclusion), force a credential cache eviction:
   - Easiest: Stop+Start the Function App (clears module-scope cache including `$script:AuthFailureCount`)
   - Or: wait the natural cache TTL (default 60 min normal, 5 min on failure circuit)
3. Verify successful sign-in:
   ```kql
   AppEvents | where Name == 'AuthChain.Completed' and TimeGenerated > ago(15m) | take 5
   ```

### Stuck Durable orchestration recovery

**Symptom**: an `Xdr-PollOrchestrator` instance has been Running > 30 min (way past tier cadence); `XdrOps-OrchestrationStuck` rule fires (if enabled); subsequent orchestrations for the same Portal+Tier are queued behind it.

**Diagnose**:

```powershell
# Connect to Storage account, query Durable Task Hub
$ctx = New-AzStorageContext -StorageAccountName <sa-name> -UseConnectedAccount
$instances = Get-AzStorageTableRowAll -table (Get-AzStorageTable -Context $ctx -Name 'XdrLogRaiderInstances').CloudTable
$instances | Where-Object { $_.RuntimeStatus -eq 'Running' } |
    Sort-Object CreatedTime |
    Select InstanceId, Name, CreatedTime, LastUpdatedTime, RuntimeStatus
```

**Force-terminate stuck instance**:

```powershell
# Use the Durable Functions HTTP admin API
$admin = Get-AzWebAppPublishingProfile -Name <fn-app> -ResourceGroupName <rg> -Format WebDeploy
$key = (az functionapp keys list --resource-group <rg> --name <fn-app> --query systemKeys.durabletask_extension -o tsv)
Invoke-RestMethod -Method Post -Uri "https://<fn-app>.azurewebsites.net/runtime/webhooks/durabletask/instances/<InstanceId>/terminate?reason=stuck-recovery&taskHub=XdrLogRaiderHub&code=$key"
```

**Identify orchestration leak root cause**:

1. Look at the `Xdr-PollStream` activity inputs for the stuck instance — was it the same stream over and over? Likely candidate: an activity that throws AND the orchestrator's `try/catch` doesn't bubble up properly.
2. Check `AppExceptions` for the stuck instance's `OperationId` — typically the activity throws into a void that the orchestrator can't observe.
3. File a `bug_report` issue with the InstanceId + activity name + exception.

### DCE flap diagnosis (ingest 5xx spikes)

**Symptom**: `XdrConnectorHealth_CL.RowsIngested` drops to zero for one or more streams while `StreamsAttempted > 0` (the activity ran and got rows but ingest failed); `AppDependencies` shows `ingest.monitor.azure.com` 5xx clusters; analytic rule `XdrOps-RowVolumeSpike` may fire on the recovery surge.

**Diagnose**:

```kql
// DCE 5xx pattern — last 6h, per-host
AppDependencies
| where TimeGenerated > ago(6h)
| where Target has 'ingest.monitor.azure.com'
| where ResultCode startswith '5'
| summarize FailCount=count(), Hosts=make_set(Target) by ResultCode, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

**Likely causes (ranked)**:

1. **DCE region outage** (rare; check Azure Service Health for region) — wait it out; data spools to DLQ; replay happens on next poll cycle.
2. **DCR throttling** — single DCR exceeded its 10-flow cap. Verify via `Audit-DcrSchema.ps1`. Resolution: split the DCR (per `tools/Build-DcrSection.ps1` redistribute logic).
3. **DCE endpoint URL stale in FA appSettings** — happens after ARM redeploy if the DCE was recreated with a new immutable ID. Verify the appSettings `DCE_ENDPOINT` matches the current DCE resource ID.
4. **Authentication regression** — SAMI token expired/refresh failed. Check `AppExceptions` for `Get-MonitorIngestionToken` errors.

**Mitigation**:

1. If DCE outage: confirm via Azure portal Service Health; wait + verify DLQ replay drains depth back to baseline.
2. If DCR throttle: the connector handles this gracefully via DLQ — depth grows then drains as the DCE recovers. If depth continues to grow > 1h, consider increasing DCR row-batch size limits (carefully — `MaxBatchBytes=900KB` per Hot-Fix 7 design) or splitting hot streams to a dedicated DCR.
3. If FA appSettings stale: re-run ARM redeploy or manually update via `az functionapp config appsettings set`.

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
