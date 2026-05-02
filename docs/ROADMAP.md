# Roadmap

Capability ladder for the connector. Each version below is a discrete shipping
milestone with explicit deliverables.

The connector's purpose is **portal-only telemetry from Microsoft Defender XDR
(and, in v0.2.0+, additional Microsoft 365 portals) that is not exposed by
official Microsoft Graph / public APIs**. Surfaces already covered by Microsoft
Graph Security or by the Microsoft 365 Defender Public APIs are explicitly out
of scope — operators should use the corresponding official Microsoft Sentinel
data connectors for those.

---

## v0.1.0-beta — production-ready first publish

The current shipping version. Production-grade for unattended ingestion of
Microsoft Defender XDR portal-only telemetry into a customer-owned Sentinel
workspace.

**Architecture**:
- 46 portal-only data streams + 1 operational Heartbeat = 47 streams total,
  partitioned across 5 DCRs sharing 1 DCE (Microsoft canonical pattern: each
  dataFlow single-stream with `outputStream` + `transformKql='source'`).
- 5 cadence-purpose tiers: `fast` (10 min — 2 streams), `exposure` (1h — 7),
  `config` (6h — 14), `inventory` (daily — 21), `maintenance` (weekly — 1);
  each tier on its own timer-triggered Function. Tenant-feature-gated streams
  (MDI / MCAS / TVM / Intune AV / MDO / Custom Collection) skip cleanly when
  the tenant feature isn't licensed.
- Per-stream typed columns at ingest via projection map; `RawJson` preserved
  alongside for forensic queries.
- 5-module L1-L4 architecture (`Xdr.Common.Auth` + `Xdr.Defender.Auth` +
  `Xdr.Sentinel.Ingest` + `Xdr.Defender.Client` + `Xdr.Connector.Orchestrator`)
  — portal-generic L1+L4 lets v0.2.0 add new portals as file-add operations.

**Auth**:
- CredentialsTotp (RFC 6238) + Software Passkey (FIDO2 ECDSA-P256) for
  unattended portal sign-in. Both auto-refresh; 50-min portal-cookie cache,
  3h30m hard rotate, 401-reactive re-auth. KV-stored credentials, never
  logged at any verbosity. Auth chain diagnostics flow to App Insights
  `customEvents` (`AuthChain.*` event names) — secrets-redacted.
- Key Vault credential cache TTL (1h default) — rotated KV secrets pick up
  automatically on next cache miss; no Function App restart required.

**Reliability**:
- HTTPS Logs Ingestion API with gzip compression (5-10× bandwidth);
  413 split-and-retry; per-batch + cumulative metrics in
  `MDE_Heartbeat_CL.Notes`.
- 429 Retry-After honoured; on terminal failure, batches go to a
  `dlq` Storage Table dead-letter queue (partitioned by stream); poll-* timer
  functions retry from DLQ at the start of each cycle before issuing new
  polls. **No data loss on rate-limit storms.**
- Null-response → boundary marker row (heartbeat-visible) instead of silent
  zero.

**Security**:
- System-Assigned Managed Identity only — 7 narrowly-scoped role
  assignments (KV Secrets User on KV; Storage Table Contributor on Storage;
  Monitoring Metrics Publisher per-DCR × 5).
- Optional `restrictPublicNetwork` parameter for regulated tenants
  (Storage / Key Vault / App Insights public-network-access disabled).
- Key Vault Get/List Secret events flow to the workspace via Diagnostic
  Settings (`enableKeyVaultDiagnostics` default true) — full credential-access
  audit trail.
- Pre-commit hook blocks accidental AI-attribution trailers; GitHub Actions
  pinned to commit SHAs; SBOM (SPDX) shipped per release.

**Hosting plans**:
- `consumption-y1` (default) — lowest cost; Y1 Linux content-share platform
  constraint requires the shared key (Microsoft documented platform behaviour);
  partial Managed Identity.
- `flex-fc1` — modern Flex Consumption; full Managed Identity (no shared
  keys); container-based deployment.
- `premium-ep1` — Elastic Premium; full MI + always-warm + private-endpoint
  capable.
- All 3 deploy paths covered by ARM conditional appSettings (`HostingPlanAppSettingsConsistency.Tests.ps1` gate).

**Sentinel content** (toggleable via `deploySentinelContent` parameter):
- 4 KQL parsers (`MDE_Drift_*` per cadence bucket — drift detection on typed
  columns)
- 14 analytic rules (ship `enabled: false` per Microsoft best practice;
  operator opts in)
- 9 hunting queries with `author`/`version`/`tags` metadata
- 7 workbooks including Action Center for Device Timeline + Machine Actions
- All custom tables explicit `plan: 'Analytics'`

**Observability**:
- App Insights structured telemetry — `traces` (routine flow) + `customEvents`
  (`AuthChain.*`, `Stream.Polled`, etc.) + `customMetrics` (`xdr.poll.duration_ms`,
  `xdr.ingest.{rows,bytes_compressed,retry_count,dce_latency_ms}`,
  `xdr.dlq.{push_count,pop_count,depth}`, `xdr.kv.{cache_hit,cache_miss}`)
  + `exceptions` (full stacks) + `dependencies` (every portal HTTP call +
  every DCE batch). `OperationId`-stamped for end-to-end transaction view.
- Idempotency keys (`x-ms-client-request-id`) on every DCE batch — DCE-side
  retry deduplication.

**Test coverage**: 1450+ offline tests / 0 fail; `tools/Validate-ArmJson.ps1`
PASS; `tools/Preflight-Deployment.ps1` PRE-DEPLOY READY: YES; preventive
`tests/integration/Deployment-WhatIf.Tests.ps1` runs `az deployment group
what-if` against the compiled ARM (catches deploy-time RP semantic violations
offline before they hit the operator's tenant). Static gates for: DCR shape
(5 invariants), nested-template parameter alignment + scope=inner + storage-
name length (4 invariants), no-listKeys-in-variables (2 invariants),
system-reserved column names (TenantId/_ResourceId/ etc.), hunting query
field lengths (TagValue MaxLength), env-as-tag default, KV cache TTL,
DLQ round-trip, AppInsights dependency tracking + metrics density. Operator's
only post-deploy step is `Initialize-XdrLogRaiderAuth.ps1` to upload auth
secrets — the **Sentinel Data Connectors blade** flips the **XdrLogRaider**
card to **Connected** within 5–10 minutes of the first successful poll
(driven by `MDE_Heartbeat_CL` via the connector's `connectivityCriterias`).

**Forward-compat hooks** (no refactor needed for v0.2.0):
- Manifest `Portal` field per stream + L4 orchestrator dispatches by
  `manifest.Portal`
- ARM additive parameter slots reserved for v0.2.0 BYO infrastructure
  (`existingDceResourceId` / `existingDcrResourceIds`)

---

## v0.2.0 — multi-portal expansion + new streams

Additive only. No breaking changes to v0.1.0 manifest.

**New portal-only streams** (~15-20, candidate list in `docs/CANDIDATE-STREAMS-V0.2.0.md`):
- XSPM atlas: `MDE_XspmTopEntryPoint_CL`
- Identity / hunting: `MDE_AdvancedHuntingUserHistory_CL`
- Datalake catalogue: `MDE_DatalakeDatabase_CL` + `MDE_DatalakeTableSchema_CL`
- RBAC depth: `MDE_DeviceRbacGroup_CL` + `MDE_DeviceRbacGroupScope_CL`
- Asset criticality: `MDE_ConfigurationCriticalAsset_CL` + Schema
- Vulnerability tracking: `MDE_TvmRemediationTasks_CL`
- Network detection: `MDE_NdrSensorConfig_CL`

**Multi-portal foundation** (the `Portal=` abstraction goes wide):
- `admin.microsoft.com` — M365 tenant config + licence posture
- `entra.microsoft.com` — Entra ID tenant config + Conditional Access
  posture
- `compliance.microsoft.com` — Purview DLP / eDiscovery config
- `intune.microsoft.com` — Intune device/policy config

Each new portal is a file-add: per-portal `Xdr.<Portal>.Auth` (L2) +
`Xdr.<Portal>.Client` (L3) + manifest entries with `Portal=<portal>`. Zero
changes to existing modules.

**Operational hardening**:
- KV secret rotation event-grid hook (replaces v0.1.0-beta's TTL-based
  cache invalidation with push-based)
- BYO DCE/DCR via additive Bicep parameters (`existingDceResourceId` +
  `existingDcrResourceIds[]`) for tenants with shared monitoring
  infrastructure
- Local Bicep direct-deploy support (`_artifactsLocation` parameter pattern)
  alongside the Deploy-to-Azure URL flow
- Time-filter coverage extension on `Filter='fromDate'` for endpoints whose
  server-side date filtering was deferred from v0.1.0-beta pending live
  per-endpoint verification

---

## v1.0 — Microsoft Sentinel Solution Gallery listing

Microsoft Sentinel Solution submission merged into
`Azure/Azure-Sentinel/Solutions/XdrLogRaider/`. Content Hub listing live.

**Submission deliverables** (per Microsoft Sentinel Solution submission
criteria):
- CodeQL gate in CI (security scanning)
- Workbook gallery metadata (`galleryItem.json` per workbook)
- Accessibility (WCAG-AA)
- Localisation (en-US baseline + de-DE / ja-JP / fr-FR / es-ES)
- Full MITRE Att&ck coverage matrix per analytic rule
- Threat model artifact (STRIDE per surface; data-flow trust-boundary diagram)
- EV publisher certificate (code-signing the function-app.zip)
- Marketplace baseline parameter defaults: `hostingPlan=flex-fc1`,
  `restrictPublicNetwork=true`, `legacyEnvInName=false`

---

## Future capabilities (out of band — additive when delivered)

- **Durable Functions orchestrator** — collapse the 5 cadence-tier timers
  to 1 orchestrator + N activities if total stream count exceeds ~100 across
  multi-portal expansion. Trade-off: loses per-tier App Insights operation
  isolation.
- **Multi-tenant fan-out** (MSSP scenario) — single connector instance
  polling N customer tenants. Manifest `TenantId` field slot reserved.
- **Customer-pinned Function App package** — first-class support for
  pinning `WEBSITE_RUN_FROM_PACKAGE` to a private blob alongside the
  GitHub Releases default.

---

## Non-goals (permanent scope guardrails)

- **Microsoft Graph Security / Microsoft 365 Defender Public APIs** — out of
  scope. The connector's value proposition is portal-only telemetry NOT
  reachable via Graph. Graph-covered streams have official Microsoft Sentinel
  data connectors and operators should use those.
- **Schema-lock typed columns without RawJson preservation** — RawJson is
  always preserved alongside typed columns; portal API drift is real and
  schema-lock loses rows silently.
- **HAR capture as a research source** — XDRInternals + nodoc +
  MDEAutomator + DefenderHarvester + live-authenticated capture together
  are sufficient. HAR is a fallback only.
- **Premium FA plan as default** — Consumption Y1 stays the default. Flex
  Consumption + Elastic Premium are opt-ins for tenants with specific
  Managed-Identity / latency / private-endpoint requirements.
