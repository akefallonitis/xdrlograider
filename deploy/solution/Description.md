# XdrLogRaider — Sentinel Solution (v0.1.0 GA)

## What it does

XdrLogRaider ingests **Microsoft Defender XDR portal-only telemetry** into Microsoft Sentinel — configuration, compliance, drift, exposure, posture, and governance data that the public Graph Security API, Defender XDR API, and MDE public APIs don't expose. Think: Defender settings that only appear in the `security.microsoft.com` portal UI (advanced features, alert tuning, custom detections, RBAC device groups, XSPM attack paths, posture metrics, secure-score per-category, attack-surface analytical paths, threat-analytics enriched outbreaks, MDI service accounts) — now queryable in KQL.

**v0.1.0 GA** ships **493 read endpoints** across **18 in-scope nodoc sub-areas**, routed into **19 workspace tables** (18 `Defender_<Sub>_CL` per-sub-area + 1 `XdrConnectorHealth_CL` operational table) via a single Data Collection Endpoint and 19 per-sub-area Data Collection Rules. v0.2.0+ expands to other portals (Entra, Purview, Intune, M365 admin) using the same 4-Durable-Function topology — manifest-keyed per portal, no new function dirs.

## Why

Microsoft ships a lot of security-posture state that's only readable through portal web UI, not through public APIs. That leaves a visibility gap for:

- **Configuration drift** — "who changed AV exclusions last week?"
- **Compliance audit** — "are we still running all ASR rules we certified?"
- **Exposure posture trending** — "XSPM attack paths delta over 30 days"
- **RBAC governance** — "when did we add that device group?"
- **AIR / Action Center** — "what auto-remediations ran and who approved?"
- **Vulnerability inventory** — "list every device with this CVE, queryable in KQL"

## Architecture

PowerShell 7.4 Function App on Y1 Linux Consumption (default) with 4 Durable Functions:

- **Xdr-Refresh** — 1-min timer + durableClient; reads `XdrTierState[RowKey='__schedule__']` and starts orchestrations per (Portal, Tier) cadence (10m / 1h / 6h / 24h / 7d)
- **Xdr-PollOrchestrator** — orchestrationTrigger; pre-flight circuit-breaker check; fans out one activity per stream
- **Xdr-PollStream** — activityTrigger; auth + DLQ drain + EntryKey-keyed `Invoke-MDEEndpoint` + DCE ingest + ByProperties tier-state write
- **Connector-Heartbeat** — independent 5-min timer; aggregates state and emits one heartbeat row to `XdrConnectorHealth_CL` with lean Notes JSON; powers the Sentinel data connector card freshness signal

Auth uses sccauth + XSRF cookie chain via Entra TOTP or Passkey (unattended; 90-day KMSI). System-Assigned Managed Identity for Key Vault + Storage + DCR data-plane access (no Service Principal).

## What's in this solution (Phase 1 ship-lock)

- ✅ Data Connector card (registered in operator's Sentinel Content Hub Installed Solutions list)
- ⏳ Analytic rules — deferred to v0.3.0 (persona-driven content phase)
- ⏳ Hunting queries — deferred to v0.3.0
- ⏳ Workbooks — deferred to v0.3.0
- ⏳ Parsers — deferred to v0.3.0

The pilot release has 21 analytic rules + 12 hunting queries + 10 workbooks + 4 parsers ready to port; this solution intentionally ships connector-only first so operators get the data flowing before content lands.

## Release signing

All artifacts on the GitHub Release are signed with [Sigstore cosign keyless OIDC](https://docs.sigstore.dev/cosign/signing/keyless/) (Fulcio short-lived cert + Rekor transparency log). Verify any signed asset:

```bash
cosign verify-blob --certificate <file>.cert --signature <file>.sig <file>
```

## Roadmap

| Version | Adds |
|---|---|
| v0.1.x | Circuit-breaker state machine · ARM-TTK lint cleanup · path-param fan-out for per-MachineId endpoints |
| v0.2.0 | Multi-portal (Entra · Purview · Intune · M365 admin) · MSSP multi-tenant Key Vault prefix scheme |
| v0.3.0 | Persona-driven Sentinel content: 21 analytic rules + 12 hunting queries + 10 workbooks + 4 parsers |
| v0.4.0 | Operator docs + runbook · Sentinel Content Hub public catalog PR |
| v0.5.0 | Production hardening: VNet egress · CMK · cost guardrails · `enabledSubAreas` ARM param |
| v0.6.0+ | Sentinel Data Lake destination · CCF migration evaluation · Solution V3 packaging |
