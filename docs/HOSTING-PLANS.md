# Hosting plan — v0.1.0-beta

> **TL;DR** — v0.1.0-beta ships a single hosting plan: **Linux Consumption Y1**.
> No `hostingPlan` parameter; no operator decision required. Multi-tier (FC1 / EP1)
> returns in v0.2.0 once the `functionAppConfig` shape is fully tested across all
> three plans.

## Why Y1 only

| Driver | Detail |
|---|---|
| Workload fit | The connector polls the Defender XDR portal on 10-min / 1h / 6h / daily / weekly cadences. Total runtime is well within Y1's 1.5 GB / 10-min execution envelope. |
| Cost ceiling | $0–10/month for typical-tenant volumes. Free tier covers the first 1M executions / 400k GB-s memory. |
| Marketplace baseline | Microsoft Sentinel Solution Gallery community connectors target Y1 as the operator-default ingestion plane — matches the canonical Solution submission shape. |
| Single source of truth | Removing the `hostingPlan` 3-tier enum drops 600+ lines of conditional ARM (variables / appSettings / kind switches) + 590 lines of multi-plan matrix tests. |

## Documented residual risk on Y1

`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` requires the Storage Account Key on Linux Y1
(Microsoft platform constraint — Files-share-mount path needs the shared key).
Mitigations in this template:

- Storage Account `allowSharedKeyAccess: true` is required for Y1, but
- `restrictPublicNetwork=true` operator opt-in disables Storage public network access,
- App Insights + Key Vault `publicNetworkAccess` set to `Disabled` when opt-in,
- Diagnostic Settings on Key Vault stream Get/List Secret events to the workspace
  for full credential-access audit trail.

The privilege-escalation chain that was the rationale for FC1/EP1 in earlier plans is
acknowledged + documented in [SECURITY-NOTES.md](SECURITY-NOTES.md). For tenants where
that residual risk is unacceptable, defer adoption to v0.2.0 (which ships FC1/EP1 with
full Managed Identity for content-share mount).

## Roadmap

v0.2.0 reintroduces `hostingPlan` as a 3-tier enum (`consumption-y1` / `flex-fc1` / `premium-ep1`)
with full `functionAppConfig` wiring, multi-plan ARM what-if matrix in CI, and per-plan
operator decision aid. See [ROADMAP.md](ROADMAP.md#v020--multi-portal-expansion--new-streams).
