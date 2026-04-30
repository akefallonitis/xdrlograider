# Operations runbook

Day-two SRE guidance for XdrLogRaider in production. Complements
[RUNBOOK.md](RUNBOOK.md) (deploy-time) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Health check — the only query you need

```kql
// Is the connector alive, authenticated, and efficient?
MDE_Heartbeat_CL
| where TimeGenerated > ago(30m)
| extend n = parse_json(Notes)
| summarize
    LastFire       = max(TimeGenerated),
    StreamsSucc    = max(StreamsSucceeded),
    RowsIngested   = sum(RowsIngested),
    Rate429Count   = sum(toint(n.rate429Count)),
    GzipBytesTotal = sum(tolong(n.gzipBytes))
    by FunctionName
| join kind=leftouter (
    App Insights customEvents
    | summarize arg_max(TimeGenerated, Success, Stage) by PortalHost
  ) on $left.FunctionName == '(auth chain — see App Insights customEvents)'
| order by FunctionName asc
```

Traffic-light reading:
- `LastFire` within the last 2x its schedule window → **green**
- `StreamsSucc == StreamsAttempted` → **green**
- `Rate429Count == 0` → **green**; if non-zero persistently, portal is throttling us (see below)
- `App Insights customEvents.Success == true` → **green**; if false for > 30 min, auth chain broke (see RUNBOOK)

## App Insights KQL cookbook (8 canned triage queries)

### 1. Fatal errors per tier (last 24h)

```kql
traces
| where cloud_RoleName contains 'xdrlr' and timestamp > ago(24h)
| where message contains 'FATAL'
| summarize count() by tostring(customDimensions.Category), bin(timestamp, 1h)
| render timechart
```

### 2. Cold-start latency histogram

```kql
traces
| where message startswith 'profile.ps1: XdrLogRaider Function App initialised'
| extend durationMs = toint(customDimensions.DurationMs)
| summarize p50=percentile(durationMs, 50), p95=percentile(durationMs, 95), p99=percentile(durationMs, 99)
```

### 3. 429 rate per tier

```kql
MDE_Heartbeat_CL
| where TimeGenerated > ago(24h)
| extend n = parse_json(Notes)
| extend r429 = toint(n.rate429Count)
| where r429 > 0
| summarize Total429 = sum(r429) by Tier, bin(TimeGenerated, 1h)
| render timechart
```

### 4. Gzip compression ratio trend

```kql
MDE_Heartbeat_CL
| where TimeGenerated > ago(7d)
| extend n = parse_json(Notes)
| extend gz = tolong(n.gzipBytes)
| where RowsIngested > 0 and gz > 0
| extend bytesPerRow = todouble(gz) / todouble(RowsIngested)
| summarize avgRatio = avg(bytesPerRow) by bin(TimeGenerated, 1d)
| render timechart
```

### 5. Per-endpoint latency p95

```kql
traces
| where message startswith 'ENDPOINT '
| parse message with 'ENDPOINT ' stream ' method=' method ' duration=' durationMs:int ' bytes=' *
| summarize p95 = percentile(durationMs, 95) by stream
| order by p95 desc
```

### 6. Auth self-test failures (RUNBOOK entry-point)

```kql
App Insights customEvents
| where TimeGenerated > ago(24h)
| where Success == false
| project TimeGenerated, Stage, FailureReason, SampleCallHttpCode
| order by TimeGenerated desc
```

### 7. Cookie TTL expiry events

```kql
traces
| where message contains 'session age' and message contains 'forcing fresh auth'
| parse message with * 'session age ' ageMin:int 'm' *
| summarize count() by bin(timestamp, 1h), ageMin
```

### 8. 413 split-recurse frequency

```kql
traces
| where message startswith 'DCE 413 Payload Too Large'
| summarize splits = count() by bin(timestamp, 1h)
| render timechart
```

## Azure Monitor alert-rule recipes

Minimum viable set; create in Azure Portal → Sentinel workspace → Alerts.

| Signal | Condition | Severity | Action |
|--------|-----------|----------|--------|
| Fatal heartbeat | `MDE_Heartbeat_CL | where parse_json(Notes).fatalError != ''` count > 0 in last 30 min | High | Page on-call |
| Auth self-test fail | `App Insights customEvents | where Success == false` count > 2 consecutive | High | Page + run RUNBOOK auth-chain |
| Rate429 steady-state | `MDE_Heartbeat_CL | extend r429=toint(parse_json(Notes).rate429Count) | where r429 > 5` over 1h | Medium | Investigate tenant-side portal quota, consider reducing poll frequency |
| Ingestion silence | `MDE_Heartbeat_CL | summarize max(TimeGenerated)` older than `2 × max-cron-interval` | High | FA stopped; check App Insights Exception telemetry |

## Reducing portal load (if Rate429 stays non-zero)

1. **Slow down the tier**: edit `function.json` `schedule` to a longer NCRONTAB interval (e.g. P6 from 10m to 20m).
2. **Reduce jitter ceiling**: `Invoke-MDETierPoll` uses 80-320ms per call — if you've added tracked extra headers/body, raise to 200-600ms.
3. **Add Filter on static streams**: streams without `Filter` re-pull the full snapshot every cycle. Audit candidates post-deploy:
   ```kql
   MDE_Heartbeat_CL | where TimeGenerated > ago(1d) | extend n = parse_json(Notes) | where tolong(n.gzipBytes) > 50000 | summarize avg(tolong(n.gzipBytes)) by Tier
   ```

## Package delivery — switching from GitHub URL to private blob

Default: `WEBSITE_RUN_FROM_PACKAGE` points to the GitHub release zip URL. One-click simplicity, but every cold start downloads from github.com.

For regulated/air-gapped tenants, mirror to a private blob:

```powershell
# On admin workstation with Az.Storage
$sa = 'yourcontainerstorageacct'
$ver = 'v0.1.0-beta'
Invoke-WebRequest `
  "https://github.com/akefallonitis/xdrlograider/releases/download/$ver/function-app.zip" `
  -OutFile "function-app-$ver.zip"

$ctx = (Get-AzStorageAccount -ResourceGroupName rg-shared -Name $sa).Context
Set-AzStorageBlobContent -Container fa-packages -File "function-app-$ver.zip" -Blob "function-app-$ver.zip" -Context $ctx

# Generate 1-year SAS
$sas = New-AzStorageBlobSASToken -Container fa-packages -Blob "function-app-$ver.zip" `
  -Permission r -ExpiryTime (Get-Date).AddYears(1) -Context $ctx

# Update the FA's WEBSITE_RUN_FROM_PACKAGE app-setting to the private-blob URL + SAS.
```

## KV firewall (optional tightening post-deploy)

The template provisions KV with public access. To lock down:

```powershell
az keyvault network-rule add --name <kv> --resource-group <rg> `
  --vnet-name <fa-vnet> --subnet <fa-subnet>
az keyvault update --name <kv> --default-action Deny
```

The Function App's SAMI must already have `Key Vault Secrets User` (which the template assigns). Requires FA VNet integration to be enabled separately (not in the default template).

## When the XSPM streams come back

`MDE_XspmChokePoints_CL` + `MDE_XspmTopTargets_CL` are currently `tenant-gated` with bodies that returned 400 on 2026-04-24 (regressed from 200 in v0.1.0-beta.1). When a future release ships corrected bodies:

1. Redeploy the Function App with the new release tag.
2. Confirm via:
   ```kql
   MDE_XspmChokePoints_CL | where TimeGenerated > ago(24h) | count
   MDE_XspmTopTargets_CL  | where TimeGenerated > ago(24h) | count
   ```
3. Both should start receiving rows within one P3 cycle (1h).
