# Runbook · Cost + Scaling (C7 · Φ-NF)

Real numbers from the live v0.1.0-pre pilot (single tenant · `Defender/Operations` · 9 ops · 2026-06-12).
Replace the per-tenant figures with your own once you have a steady-state day; the budget math is what matters.

## Cycle budget — the 600s ceiling is honored with ~10× headroom
`host.json` pins `functionTimeout = 00:10:00` (600s) — the hard ceiling. Observed on the pilot:

| Signal | Avg | Max | Budget | Headroom |
|---|---|---|---|---|
| Cold-start boot (module load + capability discovery) | 3.45 s | 5.94 s | 600 s | ~100× |
| Per-poll span (Entry.Poll.Started→Succeeded, incl. paging) | 5.7 s | 55.3 s | 600 s | ~11× |

A whole due-cycle = boot (warm: ~0) + the cadence-due ops in sequence. Even an all-9-ops cold cycle with the
slowest observed poll stays well under 600s. **Budget-honored check (run in the workspace):**
```kusto
AppEvents | where TimeGenerated > ago(2h) and Name in ('Entry.Poll.Started','Entry.Poll.Succeeded')
| extend Cid=tostring(Properties.CorrelationId)
| summarize span_s = datetime_diff('second', max(TimeGenerated), min(TimeGenerated)) by Cid
| summarize maxCycleSeconds = max(span_s)   // must be < 600; pilot observed 55
```

## Compute cost — Y1 Consumption runs effectively free for a single tenant
- **Executions/day:** Refresh timer = 1,440 (1/min). Activities = Σ(ops × daily-fires): the 3 events-tier
  ops at 10 min ≈ 3 × 144 = 432; config/inventory tiers a few each. Plus one orchestrator per due cycle.
  Order **~2,500 executions/day ≈ 75k/month** — vs the Y1 **free grant of 1,000,000/month** (~13× under).
- **GB-seconds:** ~5 s × 0.5 GB per execution × 75k ≈ **190k GB-s/month** vs the **400,000 GB-s free grant**.
- **Net:** a single-tenant deployment sits inside the Y1 free tier on both axes. EP (Elastic Premium) is only
  needed for no-cold-start latency or VNET; the 600s budget already holds on Y1.

## Ingestion cost — MB-scale per tenant
- Pilot landed **1.65 MB** total (GetHistory 1.4 MB one-time historical backfill @ 785 B/row × 1,870;
  GetTenantContext 0.25 MB). Steady-state adds only new events + SNAPSHOT re-emits (deduped client-side, so
  CURSOR ops ingest only genuinely-new rows).
- Log Analytics Analytics-plan ingestion ≈ **$2.76/GB** (commercial, list) → a tenant ingesting even 1 GB/month
  is ~**$2.76/month**. RawJson is clamped at 240 KB/row (head-preserving, LA-safe) so a pathological row cannot blow the bill.
- FA telemetry goes to **App Insights, not the customer workspace** (C7) — adaptive sampling at 5 items/s
  (`host.json`) bounds it; Request + Exception are never sampled (the health signals).

## Scaling to N tenants
Each tenant = one isolated FA + workspace (per-customer-tenant deployment, A1). Cost scales **linearly** and
each tenant independently sits in/near the Y1 free tier. No shared bottleneck: auth (KMSI per service account),
checkpoints (per-tenant storage), and ingestion (per-tenant DCR→workspace) are all tenant-local. MSSP fan-out
is therefore N independent deployments, not a scaling cliff.
