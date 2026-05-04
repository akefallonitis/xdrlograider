# Cost model

Estimated monthly Azure costs for a typical XdrLogRaider deployment.

## Summary

**Default (Consumption tier, Pay-as-you-go LA)**: ~$6-30/month

| Component | Monthly estimate | Notes |
|---|---|---|
| Function App (Consumption Y1) | ~$0 | 65k executions/month within free tier |
| Log Analytics ingestion | ~$4-17 | 1.5-6 GB/month at $2.76/GB (Pay-as-you-go) |
| Key Vault | ~$0 | 7,200 operations/month; first 10k free |
| Storage Account (Table) | cents | <1 MB/day |
| App Insights | ~$2-10 | 100-500 MB/month |
| DCE ingestion | included in LA | |
| Data Collection Rule | $0 | |

## Per-tier breakdown

| Tier | Streams | Cadence | Executions/day | Est. GB/day |
|---|---|---|---|---|
| Connector-Heartbeat | 1 | 5 min | 288 | ~0.5 MB |
| (auth chain — see App Insights customEvents) | 1 | 10 min initially, hourly after | ~100 | ~0.1 MB |
| Defender-Inventory-Refresh | 19 | 1h | 24 | ~20 MB |
| Defender-Configuration-Refresh | 7 | 30 min | 48 | ~5 MB |
| Defender-Configuration-Refresh | 7 | 1d | 1 | ~5 MB (once per day) |
| Defender-XspmGraph-Refresh | 8 | 1h | 24 | ~30 MB |
| Defender-Inventory-Refresh | 5 | 1d | 1 | ~3 MB |
| Defender-ActionCenter-Refresh | 2 | 10 min | 144 | ~10 MB |
| Defender-Configuration-Refresh | 4 | 1d | 1 | ~2 MB |
| **Total** | 52 | | ~600 | ~75 MB/day = ~2.25 GB/month |

## Cost levers (default-on in v1.0)

1. **Auth cookie cache** — one auth chain per hour shared across timers (vs 9× per run without cache). Saves ~9× auth-chain HTTP calls.

2. **Batch DCE POST** — streams within a tier are sent as one HTTP POST to DCE (vs one per stream). Saves ~50× DCE requests.

3. **Conditional ingestion via hash compare** — skip emitting rows if the typed-column-bag hash matches the prior snapshot. Saves 40-80% ingestion on low-volatility configs.

4. **Consumption plan (Y1)** — free tier covers typical workload. Premium plan (EP1) would add ~$160/month baseline.

## Scaling costs

For large tenants (10k+ machines, 100+ attack paths, heavy XSPM):
- P3 exposure can grow to 500 MB/day
- Typical large-tenant total: ~4 GB/day = 120 GB/month → ~$330/month at Pay-as-you-go

Mitigations for large tenants:
1. Move to Log Analytics **Commitment Tier** (100 GB/day) — amortized ~$2.30/GB vs $2.76/GB
2. Reduce P3 cadence from 1h to 4h
3. Exclude low-value XSPM snapshot fields via DCR `transformKql`
4. Use dedicated cluster if multiple Sentinel solutions share the workspace

## Monitoring cost

Workbook panel: add to MDE Compliance Dashboard:

```kql
Usage
| where TimeGenerated > ago(7d)
| where DataType startswith "MDE_"
| summarize GBs = sum(Quantity) / 1000 by DataType
| order by GBs desc
```

Or in Azure Cost Management: filter resource group to XdrLogRaider RG.

## Cost alerts

Recommended budget alert on the XdrLogRaider RG: $50/month with 80% warning, 100% actual. Create in Azure Cost Management.

## If costs exceed budget

1. Identify the noisy stream via `Usage` table
2. Reduce cadence for that stream in ARM + redeploy
3. If single stream > 50% of total, investigate why — bug in endpoint wrapper?
4. Worst case: disable the stream by removing from tier poller endpoints list
