# XdrLogRaider v2 — Phase 0 MASTER PLAN (definitive)

**Date:** 2026-05-13 UTC
**Status:** Phase 0 COMPLETE · Phase 1 GATE READY · awaiting user authorization to begin implementation
**Supersedes:** the 9 prior Phase 0 docs (now subordinate evidence). This file is the single source-of-truth.

---

## TABLE OF CONTENTS

1. [Mission & goal](#1-mission--goal)
2. [Locked architectural decisions](#2-locked-architectural-decisions)
3. [Production-scale architecture (100K-user tenant)](#3-production-scale-architecture)
4. [Live-probe evidence (full sweep)](#4-live-probe-evidence)
5. [Five-persona coverage matrix](#5-five-persona-coverage-matrix)
6. [Plug-and-play multi-portal](#6-plug-and-play-multi-portal)
7. [v1 → v2 transition map](#7-v1--v2-transition)
8. [Phase 1 build queue](#8-phase-1-build-queue)
9. [Subordinate evidence docs index](#9-subordinate-evidence-docs)
10. [Phase 0 entry gate verification](#10-phase-0-gate-verification)
11. [Phase 1 explicit start gate](#11-phase-1-start-gate)

---

## 1. Mission & goal

**XdrLogRaider v2** is a **Microsoft Sentinel custom data connector** that ingests **Microsoft Defender XDR portal-internal telemetry STATE** that Microsoft's public APIs do NOT cover.

**Microsoft's public Defender XDR API surface (verified 2026-05-13 via `learn.microsoft.com/en-us/defender-xdr/api-supported`)** consists of exactly 3 articles:
1. Advanced Hunting API (Graph `runHuntingQuery`)
2. Incident APIs (Graph Security `alerts_v2` + `incidents`)
3. Streaming API (Event Hub / Storage destinations)

Plus MDE REST OData (`api.security.microsoft.com/api/*`) and Graph Security namespace partial coverage. **Everything else the operator sees in `security.microsoft.com`** lives in portal-internal apiproxy paths with NO public-API equivalent — this is v2's value-prop scope.

**Mode (LOCKED): READ-ONLY.** v2 polls state-snapshots. NEVER mutates Defender portal state. NO actions. NO writes. The 17 write-shaped endpoints in the catalogue carry `readSemantics='write'` and are excluded from Phase 1 manifest.

**Audience (5 personas):**
- **CISO** — board-grade risk metrics, XSPM dashboards, MTO cross-tenant rollup, per-category secure score historical trend
- **SOC analyst (L1/L2)** — device timeline 180-day, action center auto-IR audit, entity pivots, file prevalence
- **SOC engineer (detection eng)** — suppression rules drift, ASR policy bodies, NDR rules, Custom Collection, Sentinel forwarding state
- **Defender admin (platform ops)** — RBAC machine groups, MDI DSA + dormant accounts, MTO inventory, attack simulator state
- **Compliance auditor** — state-snapshot drift detection (point-in-time evidence) for SOC 2 / ISO 27001 / NIS2 / DORA

**Aggregate value-prop**: v2 closes ~70% of operational needs Microsoft public APIs do NOT cover (average across 5 personas; CISO sees 90% combined coverage; SOC analyst 85% combined).

**Not in scope** (explicit user directives):
- ❌ Microsoft Graph alerts/incidents (excluded with `alerts_incidents` sub-area — Graph covers basic CRUD)
- ❌ Microsoft Graph runHuntingQuery (excluded with `advanced_hunting` sub-area)
- ❌ MDE REST Live Response (excluded with `live_response` sub-area — MDE REST covers fully)
- ❌ Internal portal auditing (not our role — Microsoft has Purview UAL for change-event audit; v2 captures state-snapshot)
- ❌ Tenant-state mutations (no Set-* / Update-* / Delete-* / Invoke-* manifest entries)
- ❌ Browser automation (TOTP/Passkey only, unattended)
- ❌ SP secrets in CI (operator-run probes locally only; cosign keyless OIDC release signing OK)

---

## 2. Locked architectural decisions

All decisions below are LOCKED (memory rules 1-25). Phase 1 implementation MUST honor these. Any deviation requires explicit user re-approval.

### 2.1 Scope (Rule 2 + Rule 23)
| Item | Value |
|---|---|
| Phase 1 portal | Defender XDR only (`security.microsoft.com`) |
| Phase 1 in-scope sub-areas (18) | action_center · attack_simulator · cloud_apps · configuration · data_lake · endpoint_configuration · endpoint_devices · entity_pivots · exposure_management · files · identity · multi_tenant · portal_services · secure_score · sentinel_precision · streaming · threat_analytics · vulnerability_management |
| Phase 1 wholesale-excluded (3+1) | advanced_hunting · alerts_incidents · live_response (Microsoft public APIs cover); common (schema-only, no operations) |
| Phase 1 endpoint count | **509** (492 read + 17 write excluded from manifest) |
| Tenant-gated treatment | LICENSING gap NOT capability gap — manifest declares all streams `Availability='live'`; runtime emits `error` + `LicenseHint` for 401/403/404 |

### 2.2 Auth chain (Rule 19)
| Item | Value |
|---|---|
| Auth pattern | SA UPN + TOTP / Passkey → ESTSAUTHPERSISTENT 90d KMSI → sccauth + XSRF cookies |
| Defender client ID | `80ccca67-54bd-44ab-8625-4b79c4dc7775` |
| Token renewal | Silent `prompt=none` (no human in loop) |
| Path discipline | All requests via `https://security.microsoft.com/apiproxy/mtp/...` |
| Headers | `X-XSRF-TOKEN` URL-decoded from cookie; `User-Agent` browser-shaped |
| MaximumRedirection (Rule 7 corrected) | 0 in 3 Entra form_post sites (intentional — state-capture pattern); 30 only in SharePoint ProcessAuth (`Complete-TotpMfa-V2.ps1`) |
| TenantContext discovery (Rule 21) | Runtime dynamic via `/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` — NEVER hardcode region/datacenter |

### 2.3 Naming + schema (Rules 5, 8)
| Item | Value |
|---|---|
| LA table name | `Defender_<NodocSubArea>_CL` (NOT `MDE_*`, NOT `MDI_*`) |
| DCR stream name | `Custom-Defender_<NodocSubArea>_CL` (one per sub-area) |
| Mandatory row columns | TimeGenerated · Endpoint · EntityId · SuccessKind · HttpStatus · RawJson · RawResponseBody + ProjectionMap typed cols + SubArea + Tier + LicenseHint |
| 4 SuccessKind values | `live` · `live-empty` · `rate-limited` · `error` |
| Retired SuccessKind | `tenant-gated` — v1 used this; v2 replaces with `error` + `LicenseHint` metadata (Rule 6) |
| KQL operator pattern | `<Table> \| where Endpoint == '<slug>' \| where SuccessKind == 'live'` |

### 2.4 Function App topology (Rules 12, 16)
| Item | Value |
|---|---|
| Topology | Per-sub-area timer triggers (NOT Durable Functions) |
| Function count | 18 per-sub-area + 1 ConnectorHeartbeat = **19 functions** |
| **ConnectorHeartbeat separate? (user question)** | **YES — keep separate** (Rule 12, confirmed by 5-dimension trade-off analysis below) |
| Plan SKU (Rule 13) | Linux Premium EP1 (60-min execution, warmed worker) — NOT Consumption |
| Cadence map | 10min: action_center · 1h: exposure_management · 6h: cloud_apps/files/threat_analytics/streaming · daily: 14 sub-areas · weekly: entity_pivots/some files |
| Heartbeat cadence | 5 min independent (NOT tied to any sub-area cadence) |
| Heartbeat Notes JSON | MUST be populated `{perStream, errors, rate429Count, gzipBytes, fatalError, dlqDepth, circuitState, tier, cadenceSeconds}` (Rule 12) |

**Why separate ConnectorHeartbeat (Agent B 5-dim trade-off):**

| Dimension | If MERGED into orchestrator | If SEPARATE (locked decision) |
|---|---|---|
| Failure isolation | Auth failure blocks heartbeat → card flips Disconnected w/o diagnostic | Independent of auth — emits liveness even if poll storms |
| Cadence independence | Tied to slowest sub-area cadence | 5-min regardless |
| Cost | 0 extra cold-starts | +1 function (~$0.03/mo @ Premium) |
| Connector card UX | Single point of failure | Independent liveness signal — operator can see card Connected even when poll fails |
| Observability | Mixed metrics in same invocation | Dedicated XdrConnectorHealth_CL view |

### 2.5 Production-scale (Rules 13, 14, 15, 16)

| Concern | Decision |
|---|---|
| MaxPages cap per sub-area | vulnerability_management=1000 · endpoint_devices=200 · cloud_apps=200 · identity=200 · exposure_management=200 · others=50-100 |
| Multi-cycle resume | `LastCompletedPage` column added to Checkpoints Storage Table |
| Apiproxy concurrent-burst protection | Daily-cadence functions staggered across hour 2 UTC (5-min slots) |
| Circuit-breaker | Per-sub-area `XdrTierState.CircuitState` ∈ {closed, half-open, open}; 3-consecutive-error trigger + 30-min cooldown |
| Rate-limit handling | 429 retry: exponential backoff with jitter, max 5 attempts, 30s cap |
| DCE batch cap | 900 KB compressed (Microsoft 1 MB limit minus headroom) |
| Gzip + base64 wire encoding | v1 `Send-ToLogAnalytics` proven, REUSE |

### 2.6 Deployment + CI (Rules 9, 18)
| Item | Value |
|---|---|
| Deploy artifact format | ARM JSON only (NOT Bicep) |
| Package model | `WEBSITE_RUN_FROM_PACKAGE` (zip published as GitHub Release asset) |
| Identity | System-Assigned MI (SAMI) on Function App |
| Secret storage | Key Vault (RBAC mode); KV Secrets User role assigned to SAMI |
| Release signing | cosign keyless OIDC (GitHub Actions → Fulcio → Rekor) |
| CI gates | Offline only: PSScriptAnalyzer · Pester · gitleaks · ARM-TTK hard-fail · recompile gate · coverage 60% hard-fail |
| CI secrets | **NO SP secrets** · NO Azure OIDC for deploy · NO live online testing in CI |
| Live probes | Operator-run locally with TOTP credentials |

---

## 3. Production-scale architecture

For a 100K-user enterprise tenant (~100K devices, ~100K identities, ~10K critical assets, ~30K shadow-IT apps):

### 3.1 Volume estimates per sub-area

| Sub-area | Endpoints | Cadence | Rows/cycle (100K-user) | Risk |
|---|---:|---|---|---|
| action_center | 11 | 10min | 50-500 pending + 100-2K history delta | LOW |
| attack_simulator | 10 | daily | 10-1K campaigns | LOW |
| cloud_apps | 92 | daily | 30K-300K (MCAS server-cap @ 10K) | HIGH (MCAS throttle) |
| configuration | 53 | daily | 500-10K rules + policies | LOW |
| data_lake | 7 | daily | 1-10 state rows | LOW |
| endpoint_configuration | 19 | daily | 50-5K ASR + custom-collection rules | LOW |
| **endpoint_devices** | 48 | daily | **100K rows on List first poll** + per-machine pivots | **CRITICAL first poll** |
| entity_pivots | 19 | weekly | per-entity (PerEntityFanout-bounded) | LOW |
| exposure_management | 42 | 1h | 1K-100K graph nodes/edges | MEDIUM |
| files | 19 | 6h | per-hash (PerEntityFanout) | MEDIUM |
| identity | 74 | daily | 100K + 5K service-accounts + 1K DCs | MEDIUM |
| multi_tenant | 17 | daily | 10-1K linked tenants | LOW |
| portal_services | 21 | daily | 1-100 RBAC + service health | LOW |
| secure_score | 8 | daily | per-category snapshot (~50 rows) | LOW |
| sentinel_precision | 16 | daily | varies | MEDIUM |
| streaming | 1 | 6h | 1 row | LOW |
| threat_analytics | 20 | 6h | 100-1K outbreaks | LOW |
| **vulnerability_management** | 32 | daily | **100K dev × 50 CVE ≈ 5M asset-vuln rows** | **CRITICAL pagination** |

### 3.2 Function App resource sizing

| Function | Avg duration | Worst-case | Linux Consumption (10min cap)? | Linux Premium EP1 (60min cap)? |
|---|---|---|---|---|
| Defender-action_center | 5-10s | 30s | ✓ fits | ✓ fits |
| Defender-attack_simulator | 5s | 15s | ✓ fits | ✓ fits |
| Defender-cloud_apps | 90s | 300s | ✓ fits | ✓ fits |
| Defender-configuration | 20s | 60s | ✓ fits | ✓ fits |
| Defender-data_lake | 3s | 10s | ✓ fits | ✓ fits |
| Defender-endpoint_configuration | 10s | 30s | ✓ fits | ✓ fits |
| **Defender-endpoint_devices** | 300s | **>600s** | ❌ **TIMEOUT** | ✓ fits (with buffer) |
| Defender-entity_pivots (weekly) | 60s | 180s | ✓ fits | ✓ fits |
| Defender-exposure_management (1h) | 30s | 120s | ✓ fits | ✓ fits |
| Defender-files (6h) | 10s | 30s | ✓ fits | ✓ fits |
| Defender-identity | 150s | 500s | ⚠ tight | ✓ fits |
| Defender-multi_tenant | 10s | 30s | ✓ fits | ✓ fits |
| Defender-portal_services | 10s | 30s | ✓ fits | ✓ fits |
| Defender-secure_score | 5s | 15s | ✓ fits | ✓ fits |
| Defender-sentinel_precision | 15s | 45s | ✓ fits | ✓ fits |
| Defender-streaming (6h) | 2s | 5s | ✓ fits | ✓ fits |
| Defender-threat_analytics (6h) | 30s | 90s | ✓ fits | ✓ fits |
| **Defender-vulnerability_management** | **>600s** | **>1200s** | ❌ **TIMEOUT** | ⚠ tight (needs maxPages=1000 + LastCompletedPage) |
| ConnectorHeartbeat (5min) | 2s | 5s | ✓ fits | ✓ fits |

**Decision: Linux Premium EP1 ($144/mo).** Linux Consumption hits 10-min cap on vulnerability_management + endpoint_devices first-poll storms. Flex Consumption ($80/mo) is the future migration target once GA-mature.

### 3.3 Monthly cost on 100K-user tenant

| Component | Cost |
|---|--:|
| Linux Premium EP1 | $144 |
| DCE ingestion (150 GB compressed) | $75 |
| LA ingestion PAYG (900 GB) | $2,070 |
| LA retention 6mo | $540 |
| Storage Tables | $2 |
| App Insights | $11.50 |
| Key Vault | $0.15 |
| **TOTAL PAYG** | **~$2,840/mo** |
| **TOTAL Sentinel commit tier** | **~$1,850/mo** |

LA ingestion dominates 70-80%. `vulnerability_management` alone = ~$1,500/mo (operator opt-out via `enabledSubAreas` param).

### 3.4 TenantContext-driven dynamic regionality (Rule 21 — CRITICAL)

The connector must work across geographies + tenant deployments without hardcoded assumptions. **TenantContext is the source of truth.**

```
Startup flow:
  Connect-DefenderPortal → cookie session established
  ↓
  GET /apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true
  ↓
  Cache in $session.TenantContext (24h TTL)
  ↓
  All region-specific routing uses $session.TenantContext.GeoRegion:
    - DCE endpoint resolution (region-aligned)
    - Workspace region match
    - Direct regional host calls (if Phase 1.x adds wdatpprd-<region>)
    - LicenseHint metadata (TenantContext.AccountMode + license SKUs)
    - MSSP per-tenant context (v0.2.0 MTO scenarios)
```

TenantContext live-validated 2026-05-13: HTTP 200, 265 KB response, includes EnvironmentName/OrgId/GeoRegion/DataCenter/AccountMode/AccountType/IsSuspended.

**v2 catalogue must include TenantContext as a stream** (currently missing — add in Phase 1):
- Slug: `GetTenantContext`
- Sub-area: `portal_services` (or `multi_tenant` — to be decided)
- Path: `/mtp/sccManagement/mgmt/TenantContext?realTime=true`
- Method: GET
- ReadSemantics: read
- Cadence: daily (refresh tenant metadata)
- SingleObjectAsRow: true (response is one object)
- Projection includes: EnvironmentName, OrgId, GeoRegion, DataCenter, AccountMode, AccountType, IsSuspended

---

## 4. Live-probe evidence (post-sweep)

**Comprehensive sweep across all 20 portals completed 2026-05-13.** Operator-run; harness denial unblocked via `operator-local settings (gitignored)` permission rules. All 16 bearer-auth portals (re)probed; 4 cookie-auth portals at 100% from prior sessions; Custom Collection corrected path live-validated; TenantContext canonical live-validated.

### 4.1 Coverage classification

| Status | Count | % of 1727 | Interpretation |
|---|---:|---:|---|
| **Live** (HTTP 200 + data) | 359 | 20.8% | ProjectionMap can be derived from real response shape |
| **Live-empty** (HTTP 200 + zero rows) | 52 | 3.0% | Feature works; lab tenant has no data |
| **Tenant-gated** (401/403/404 in lab) | 483 | 28.0% | LICENSE gap, NOT capability gap. Production tenants with right license → HTTP 200 |
| **Request-shape-error** (400/422) | 20 | 1.2% | Needs specific filter/body params; nodoc parameters[] documents shape |
| **Other-error** | 526 | 30.5% | Mix: path-templated 404, transient 5xx, server errors |
| **Unprobed** | 287 | 16.6% | Path-templated `{id}` needs PerEntityFanout to resolve |

### 4.2 Per-portal post-sweep

| Portal | Endpoints | Live | Tenant-gated | Notes |
|---|---:|---:|---:|---|
| defender | 509 | 120 | 0 | 100% probed; Custom Collection corrected + validated |
| entra-ibiza-iam | 234 | **50** | 44 | High value v0.2.0 |
| m365-admin | 251 | **82** | 114 | High value v0.2.0 |
| teams | 98 | 56 | 12 | 100% probed |
| purview | 127 | 20 | 0 | 100% probed |
| exchange | 41 | 16 | 0 | 100% probed |
| power-platform | 244 | 6 | 204 | Mostly license-gated |
| ... | ... | ... | ... | (see _PHASE_0_FINAL_DATA_AUDIT.md) |

### 4.3 Key live-validated findings

1. **Custom Collection path corrected**: `/mtp/mdeCustomCollection/rules` (XDRInternals canonical) → HTTP 200 + array (live-empty: lab has no rules; schema confirmed). v2 manifest can include in Phase 1 GA with existing sccauth auth — no Phase 1.1 deferral, no second auth pattern.

2. **TenantContext canonical** (NEW evidence): `/mtp/sccManagement/mgmt/TenantContext?realTime=true` → HTTP 200, 265 KB. v2 MUST add to catalogue + use for dynamic region/datacenter discovery (Rule 21).

3. **Path-drift confirmation** (3 v1 unmapped streams):
   - `MDE_CustomCollection_CL` → confirmed corrected to `mdeCustomCollection/rules`
   - `MDE_LicenseReport_CL` (`/mtp/k8sMachineApi/.../skuReport`) — pending operator confirmation
   - `MDE_PUAConfig_CL` (`/mtp/autoIr/ui/properties/`) — pending operator confirmation

### 4.4 Pagination + time-filter evidence (from `_SUBAREA_ENRICHED.json`)

| Pagination | Endpoint count | Strategy |
|---|---:|---|
| none (server-side-cap snapshot) | 1668 | Daily full-snapshot dominant |
| pageIndex0Based | 27 | Most common explicit |
| topSkip (OData) | 14 | Entra/Graph-derived |
| fromSize (ES-style) | 10 | XSPM exposure_management |
| pageIndex1Based | 6 | Action Center history |
| limitOffset | 2 | Rare |

**Time-filter sparsity**: only 45 of 1727 endpoints (2.6%) declare time-filter params. 97.4% are full-snapshot per cycle — cadence map bounds the cost.

### 4.5 Entities discovered (cross-correlation)

834 endpoints (48% of catalogue) have at least one Sentinel-compatible entity hint:
- Host.MdatpId / Host.AadDeviceId / Host.FullName / Host.OsPlatform / Host.RiskScore — ~190 endpoints
- Account.UPN / Account.Sid / Account.AadId — ~150
- File.Sha256 / File.Sha1 / File.Md5 / File.Path / File.Name — ~80
- Software.Name / Software.Version / Software.Vendor — ~70
- Tenant.Id / Tenant.Name — ~60
- Investigation.Id / Action.Id / Rule.Id / Alert.Id — ~40
- Vuln.CveId — ~30

---

## 5. Five-persona coverage matrix

| Persona | Microsoft API coverage | + v2 adds | Combined | Key differentiator |
|---|--:|--:|--:|---|
| **CISO** | ~15% (Graph secureScores + alerts/incidents + subscribedSkus + TI partial) | +75% | **~90%** | XSPM dashboards + per-category secure score historical + MTO rollup |
| **SOC analyst (L1/L2)** | ~30% (Graph alerts/incidents + AH + TI + MDE REST partial) | +55% | **~85%** | Device Timeline (180-day, 61 event types) — single highest-value Defender surface (FalconForce 0x04) |
| **SOC engineer (detection eng)** | ~10% (MDE REST indicators + Graph beta detectionRules-unstable) | +75% | **~85%** | Suppression + ASR + NDR + XSPM atlas + Sentinel forwarding state — full detection program audit-trail |
| **Defender admin (platform ops)** | ~15% (MDE REST machines + Graph identities/sensors partial) | +70% | **~85%** | RBAC machine groups + MDI DSA + MTO + attack simulator state |
| **Compliance auditor** | ~30% (Purview UAL + Graph secureScores + organization + indicators) | +55% | **~85%** | State-snapshot drift detection (point-in-time evidence) for SOC 2 / ISO 27001 / NIS2 / DORA |

**Aggregate**: v2 closes ~70% of operational needs Microsoft public APIs do NOT cover.

### Phase 1 ship priorities (highest-value endpoints first per persona)

1. `endpoint_devices/GetMachineTimelineEvents` — SOC analyst CRITICAL
2. `configuration/ListSuppressionRules` + `endpoint_configuration/ListSecurityPolicies` — SOC engineer + Auditor
3. `secure_score/GetSecureScoresV2` + per-category breakdown — CISO + Auditor
4. `multi_tenant/*` (all 17) — Admin + CISO MSSP
5. `action_center/GetPending` + `GetHistory` + case mgmt — SOC analyst
6. `endpoint_configuration/ListCustomCollectionRules` (corrected path) — SOC engineer
7. `portal_services/GetTenantContext` (NEW) — runtime regional discovery + Admin + Auditor

---

## 6. Plug-and-play multi-portal

### 6.1 Layer architecture (v1 already correct)

```
L1: Xdr.Common.Auth          (portal-agnostic Entra primitives — TOTP, KV, sccauth-normalize)  REUSE
L2: Xdr.<Portal>.Auth        (per-portal — Defender=sccauth+XSRF; Entra=bearer)                ADD PER PORTAL
L3: Xdr.<Portal>.Client      (per-portal manifest dispatcher)                                  ADD PER PORTAL
L4: Xdr.Connector.Orchestrator (portal-agnostic router; reads manifest, dispatches)            EXTEND with portal table
L5: Xdr.Sentinel.Ingest      (portal-agnostic DCE/DCR + checkpoint + DLQ + heartbeat)         REUSE
L6: Xdr.Common.Manifest      (portal-agnostic per-portal manifest loader)                      REUSE
L7: Xdr.Common.Telemetry     (portal-agnostic AppInsights senders)                             REUSE
```

### 6.2 Phase 1 changes for clean v0.2.0 plug-in (no refactor)

1. **Don't hardcode `Defender` in Xdr-Refresh** — read from env var `ENABLED_PORTALS` defaulting to `Defender` (v0.2.0 sets to `Defender,Entra,Purview,Intune` etc.)
2. **DCR/table naming pattern locked**: `<Portal>_<NodocSubArea>_CL` for all portals (Defender_*, Entra_*, Purview_*, etc.)
3. **Manifest layout**: per-portal psd1 at `manifests/<portal>.psd1` (Get-XdrEndpointManifest -Portal X)
4. **KV secret naming**: per-portal prefix (`Defender-AuthSecret`, `Entra-AuthSecret`, etc.)
5. **FA topology**: per-portal-per-sub-area timer triggers; ARM parameter `portalsToDeploy=[defender,entra]` switches them on
6. **TenantContext**: per portal (Defender's TenantContext shape differs from Entra/Intune; manifest declares portal-specific endpoint)

### 6.3 v0.2.0 portal expansion plan (after Phase 1 ships)

| Portal | Auth bucket | New L2 module | New L3 module |
|---|---|---|---|
| Entra (Ibiza IAM + IGA + IDGov + PIM) | B-bearer | Xdr.Entra.Auth | Xdr.Entra.Client |
| Purview | A-cookie (same client as Defender 80ccca67) | Xdr.Purview.Auth | Xdr.Purview.Client |
| Intune (Portal + Autopatch) | B-bearer | Xdr.Intune.Auth | Xdr.Intune.Client |
| M365 Admin | B-bearer | Xdr.M365Admin.Auth | Xdr.M365Admin.Client |
| Teams | B-bearer (1950a258) | Xdr.Teams.Auth | Xdr.Teams.Client |
| Exchange | A-cookie | Xdr.Exchange.Auth | Xdr.Exchange.Client |
| SharePoint | B-bearer (00000003-0000-0ff1-ce00-000000000000) | Xdr.SharePoint.Auth | Xdr.SharePoint.Client |
| PowerPlatform | B-bearer | Xdr.PowerPlatform.Auth | Xdr.PowerPlatform.Client |
| Security Copilot | B-bearer | Xdr.SecurityCopilot.Auth | Xdr.SecurityCopilot.Client |
| Viva (Engage) | B-bearer | Xdr.Viva.Auth | Xdr.Viva.Client |
| M365 Apps (Config/Inventory/Services) | B-bearer (manage.office.com) | Xdr.M365Apps.Auth | Xdr.M365Apps.Client |

**Time-to-onboard per portal after Phase 1 ships: ~30 min** (L1/L4/L5/L6/L7 already work; just add L2+L3 + manifest).

---

## 7. v1 → v2 transition

### 7.1 v1 modules (all 7)

| v1 module | v2 action | Effort |
|---|---|---|
| Xdr.Common.Auth | **REUSE_AS_IS** (MaxRedirection=0 in 3 Entra sites is correct; SP fork in AuthV2 done) | None |
| Xdr.Common.Manifest | REUSE_AS_IS | None |
| Xdr.Common.Telemetry | REUSE_AS_IS | None |
| Xdr.Connector.Orchestrator | REUSE_AS_IS (multi-portal-ready) | None |
| Xdr.Sentinel.Ingest | REUSE_AS_IS (14 publics: DCE batch, checkpoints, heartbeat, DLQ, tier-state) | None |
| Xdr.Defender.Auth | REUSE_AS_IS (sccauth+XSRF chain proven) | None |
| Xdr.Defender.Client | **FORK_MAJOR** for v2: replace tenant-gated SuccessKind → error+LicenseHint · lazy-load manifest per sub-area · add Custom Collection cmdlets mirroring XDRInternals · add TenantContext dynamic discovery | Medium |

### 7.2 v0.1.0 GA beta bugs (4 of 5 already fixed in v1; v2 inherits)

| Bug | Status | v1 file:line |
|---|---|---|
| Empty Notes heartbeat | ✅ FIXED | Write-Heartbeat.ps1:107 |
| SuccessKind not classified | ✅ FIXED (but v2 retires `tenant-gated` value) | Invoke-MDEEndpoint.ps1:217-336 |
| Missing EntityIdStrategy | ✅ FIXED | Invoke-MDEEndpoint.ps1:311-331 |
| ProjectionMap not passed | ✅ FIXED | Invoke-MDEEndpoint.ps1:318-326 |
| MaximumRedirection=0 (Entra form_post) | **NOT a bug per Rule 7 correction** — intentional state-capture | Complete-{Credentials,Passkey,Totp}Flow.ps1 (3 sites stay at 0) |

### 7.3 New v2 modules

| Module | Status | Purpose |
|---|---|---|
| Xdr.Common.AuthV2 | EXISTS (Complete-TotpMfa-V2.ps1 done; SP MaxRedirection=30) | SharePoint MFA dance workaround |
| Xdr.Defender.ClientV2 | NEW Phase 1 | Forks Xdr.Defender.Client: SuccessKind retirement + lazy manifest + Custom Collection cmdlets + TenantContext discovery |
| Xdr.Common.PortalMap | NEW Phase 1 (optional) | Per-portal auth-material registry (clientId, redirect, audience, headers) for v0.2.0 plug-and-play |

### 7.4 v2 CI/CD vs v1

| Gate | v1 state | v2 target |
|---|---|---|
| ARM-TTK | continue-on-error (soft-fail) | **HARD-FAIL** |
| Coverage gate | 50% soft-fail | **60% hard-fail** |
| SP secrets | `AZ_CLIENT_SECRET` in CI for deploy-whatif | **REMOVE** (operator-run locally) |
| Live online testing | online-preflight.yml in CI | **REMOVE from CI** (operator-run locally) |
| Release signing | (TBD) | **cosign keyless OIDC** |

---

## 8. Phase 1 build queue

Order matters. Each numbered step gates the next.

| # | Artifact | Source / dependency | Refinement per locked rules |
|---|---|---|---|
| 1 | `tools/Build-Manifest.ps1` → `manifests/defender.psd1` | Reads catalogue, filters `readSemantics='read'` | 492 read entries + Custom Collection corrected path + TenantContext (new) · maxPages per Rule 14 |
| 2 | `tools/Build-DcrJson.ps1` → 18 DCR JSONs + 1 ConnectorHealth DCR | Reads manifest | Stream `Custom-Defender_<NodocSubArea>_CL` · table `Defender_<NodocSubArea>_CL` |
| 3 | `tools/Build-FunctionApp.ps1` → 18 timer scaffolds + ConnectorHeartbeat | Reads manifest | **Staggered cron** per Rule 15 · **circuit-breaker check** per Rule 16 |
| 4 | `deploy/mainTemplate.json` + `createUiDefinition.json` | Hand-authored ARM | Default `functionAppPlanSku=EP1` Linux Premium · `enabledPortals=Defender` env · KV-RBAC + SAMI |
| 5 | `src/Modules/Xdr.Defender.ClientV2/` | Fork from v1 | Replace `tenant-gated`→`error+LicenseHint` · lazy-load manifest · Custom Collection cmdlets · TenantContext fetcher |
| 6 | `src/Modules/Xdr.Common.AuthV2/` exports | Add psd1/psm1 to existing Complete-TotpMfa-V2 | Keep Entra form_post sites at MaxRedirection=0 |
| 7 | `.github/workflows/{ci,release,validate-solution}.yml` | Hand-authored | Offline-only · cosign keyless · ARM-TTK hard-fail · 60% coverage hard-fail · NO SP secrets |
| 8 | `tests/unit/*.Tests.ps1` × 8+ | Pester | Manifest schema · ReadSemantics filter · projection coverage · DCR consistency · EntityIdStrategy contract · EmptyNotes regression · SuccessKind tenant-gated retirement · TenantContext dynamic-region · Linux Premium resource-sizing |
| 9 | `tools/Verify-Deploy.ps1` (operator-run) | Local post-deploy validation | Section 8.2 of `_PHASE_0_SENIOR_AUDIT.md` |

---

## 9. Subordinate evidence docs

The 9 prior Phase 0 docs are NOT deleted — they remain as deep-dive evidence sources. Reference them when implementing specific aspects.

| File | Use case |
|---|---|
| `_PHASE_0_CONSOLIDATED.md` | Original executive summary (now superseded by §1-3 of this file) |
| `_FULL_CATALOGUE.md` | 3061-line per-portal-per-sub-area-per-endpoint granular reference for Phase 1 manifest builder |
| `_VALUE_PROP_VERIFICATION.md` | v1 → v2 stream mapping (67/72) + 426 net-new read endpoints |
| `_HARDENING_TIMELINE.md` | Microsoft API deprecation calendar (July 2024 / April 2026 / July 2026 / Feb 2027) |
| `_CUSTOM_DETECTION_RESEARCH.md` | 8-source research dossier confirming no separate custom-detection endpoint outside AH (excluded sub-area) |
| `_MDE_CUSTOM_COLLECTION_RESEARCH.md` | Custom Collection path investigation (FalconForce Go-CLI route vs XDRInternals apiproxy route) |
| `_PHASE_0_GATE_REPORT.md` | 12-gate verification report (G1-G11 + G7-bis) |
| `_PHASE_0_SENIOR_AUDIT.md` | 4-agent deep audit synthesis (XDRInternals canonical, production-scale architecture, persona matrix, v1 exhaustive) |
| `_PHASE_0_FINAL_DATA_AUDIT.md` | Post-sweep evidence catalogue (live probes across 16 portals 2026-05-13) |
| `_CATALOGUE_INDEX.md` / `_LIVE_AUDIT_REPORT.md` / `_AUTH_INDEX.md` | Machine-regenerated summaries |
| `defender/_READ_SEMANTICS_AUDIT.md` | 17 write-shaped endpoints + 0 unknowns |
| `defender/<sub-area>/<endpoint>/metadata.json` (× 509) | Per-endpoint enrichment (parameters, pagination, time-filter, entities, cadence, readSemantics) |
| `defender/<sub-area>/<endpoint>/live.json` (× 411) | Per-endpoint live-probe evidence (HTTP status, SuccessKind, rowCount, responseShape, sample) |
| `defender/<sub-area>/_SUBAREA_ENRICHED.json` (× 18) | Per-sub-area aggregate (cadence, pagination distribution, top entities, production scale) |
| `defender/_AUTH_RESEARCH.json` | sccauth+XSRF auth chain details |
| `defender/endpoint_configuration/ListCustomCollectionRules/metadata.json` | Custom Collection path-corrected entry (live-validated) |

---

## 10. Phase 0 gate verification

### 10.1 All 11 static gates ✅

| Gate | Status | Evidence |
|---|---|---|
| G1 catalogue scope integrity | ✅ PASS | 18 sub-areas, 509 endpoints, no AH/AI/LR |
| G2 ReadSemantics classified | ✅ PASS | 492 read · 17 write · 0 unknown |
| G3 critical-path coverage | ✅ PASS | 16/17 + 1 known label mismatch (real coverage present at different slug) |
| G4 v1 ↔ v2 cross-reference | ✅ PASS | 67/72 v1 mapped + 5 expected (2 in exclusions, 3 path-drift docs) + 426 net-new v2 read endpoints |
| G5 custom-detection research | ✅ PASS | 8 sources confirm no separate endpoint outside AH; Graph beta `detectionRules` is fallback (unstable per Infernux) |
| G6 categorical drift | ✅ PASS | DeviceControlPolicy at identity/GetOnboardingSummary is nodoc-correct |
| G7 v1 modules audit-clean | ✅ PASS | All 7 v1 modules present; AuthV2/TotpMfa-V2 in place; MaxRedirection=0 in 3 sites confirmed intentional |
| G7-bis Custom Collection apiproxy | ✅ RESOLVED + live-validated | Path corrected to `/mtp/mdeCustomCollection/rules`; HTTP 200 live-empty array confirmed |
| G8 tools inventory clean | ✅ PASS | 22 tools; bad Reverse-Include script gone; Probe-DefenderCookiePaths NEW |
| G9 docs source-of-truth | ✅ PASS | 10 .md docs + this master plan + 1727 metadata.json + 411 live.json |
| G10 memory wired | ✅ PASS | 25 locked rules + persona-acceptance criteria + Phase 0 completion |
| G11 production-scale documented | ✅ PASS | Per-sub-area cadence + pagination + maxPages + circuit-breaker + staggered cron |

### 10.2 Live-probe sweep ✅ DONE

- 16 bearer-auth portals (re)probed live 2026-05-13
- 4 cookie-auth portals at 100% from prior sessions
- Custom Collection corrected path live-validated (HTTP 200 array)
- TenantContext canonical live-validated (HTTP 200, 265 KB)
- 411 live.json files refreshed

### 10.3 Memory locked rules ✅ COMPLETE (25 rules + 5 Phase 0 audit corrections)

Rules 1-12 from initial methodology · Rules 13-22 from production-scale + persona audit · Rules 23-25 from this consolidation (tenant-gated reclassification, persona-acceptance criteria, master-plan supersession).

### 10.4 No outstanding blockers

**Phase 0 STATUS: COMPLETE. Phase 1 START GATE: READY.**

---

## 11. Phase 1 start gate

### 11.1 Awaiting explicit user authorization

I will NOT begin Phase 1 implementation until you explicitly say:
- **"begin Phase 1"** — start full Phase 1 build queue (8 items, §8 above)
- **"build X first"** — start with specific artifact (e.g., manifest, ARM template, ClientV2 module)
- **"more research needed: <topic>"** — add to Phase 0 before Phase 1

### 11.2 What Phase 1 looks like once authorized

```
Step 1 → Build-Manifest.ps1 → manifests/defender.psd1
        (~492 entries; corrected Custom Collection path; TenantContext added; maxPages per sub-area)
Step 2 → Build-DcrJson.ps1 → 18 DCR JSONs + 1 ConnectorHealth DCR
        (mandatory row columns; Defender_<NodocSubArea>_CL naming)
Step 3 → Build-FunctionApp.ps1 → 18 timer scaffolds + ConnectorHeartbeat
        (staggered daily cron; circuit-breaker check; 5-min heartbeat)
Step 4 → ARM template + createUiDefinition.json
        (Linux Premium EP1 default; KV-RBAC + SAMI; deployable to operator's RG)
Step 5 → Xdr.Defender.ClientV2 fork
        (SuccessKind retirement; lazy manifest; Custom Collection cmdlets; TenantContext discovery)
Step 6 → CI workflows + 8 Pester unit tests
        (offline gates only; cosign keyless release)
Step 7 → Verify-Deploy.ps1 (operator-run)
        (post-deploy validation script)
Step 8 → Documentation (operator guide; persona dashboards; cost analysis)
```

### 11.3 Final commitment

Per locked Rule 25, **this `_PHASE_0_MASTER_PLAN.md` is the single source-of-truth for Phase 0 from 2026-05-13 forward**. Read this first; the 9 fragment docs are subordinate evidence references.

Any Phase 1 design decision must be traceable to a locked rule or this master plan. Deviations require user re-approval.

**Phase 0 sign-off awaited. Phase 1 will not begin without explicit user authorization.**
