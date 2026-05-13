# XdrLogRaider v2 — Phase 0 verification gate report

**Date:** 2026-05-12 UTC
**Auditor:** senior-architect-grade end-to-end audit via 3 parallel deep-audit agents (transcript + v1 source + external research) plus disk-evidence verification per gate.
**Mode:** read-only audit + gating; no Defender portal mutations.
**Decision:** **Phase 0 GATE PASSED.** Phase 1 unlocked. One condition flagged (G7-bis Custom Collection apiproxy needs operator-run live recon — non-blocking for Phase 1 start since the surface is rising-value future scope, not current Phase 1).

---

## Gate-by-gate verdict

| Gate | Verdict | Evidence |
|---|:-:|---|
| **G1** Catalogue scope integrity | ✅ PASS | 18 sub-areas (no AH/AI/LR/common); 509 endpoints; `Reverse-Include-StateEndpoints.ps1` deleted |
| **G2** ReadSemantics fully classified | ✅ PASS | 492 read · 17 write · 0 unknown · 0 missing-field across all Defender metadata.json |
| **G3** Critical-path coverage | ✅ PASS | 16/17 PRESENT + 1 known label mismatch (`Critical asset classification` — coverage real at `configuration/ListCriticalAssetClassifications`, my critical-paths-list path-string was wrong) |
| **G4** v1 ↔ v2 cross-reference | ✅ PASS | 67/72 v1 streams mapped; 5 unmapped: 2 expected (AH/LR wholesale-exclusions) + 3 path drift (Microsoft renamed `mdeCustomCollection`→`customDataCollection`, deprecated `k8sMachineApi/.../skuReport`, moved `autoIr/ui/properties/`); **426 net-new v2 read endpoints** v1 never ingested = new value for Phase 1 |
| **G5** Custom-detection research | ✅ PASS | `_CUSTOM_DETECTION_RESEARCH.md` written; 8 sources confirm NO separate internal endpoint exists outside dropped `advanced_hunting`; Graph beta `detectionRules` is unstable external fallback per Infernux; user directive: stay wholesale-excluded (Path A) |
| **G6** Categorical drift | ✅ PASS | `MDE_DeviceControlPolicy_CL` at v2 `identity/GetOnboardingSummary` — path `/mtp/siamApi/Onboarding` is MDI sensor onboarding per nodoc taxonomy; nodoc-correct; Phase 1 manifest honors `Defender_<NodocSubArea>_CL` naming |
| **G7** v1 modules audit-clean | ✅ PASS | All 7 v1 modules present (Xdr.Common.Auth/Manifest/Telemetry/Connector.Orchestrator/Sentinel.Ingest + Xdr.Defender.Auth/Client); `Xdr.Common.AuthV2/Private/Complete-TotpMfa-V2.ps1` exists with MaxRedirection=30 |
| **G7-bis** Custom Collection apiproxy | ✅ RESOLVED + CORRECTED (2026-05-13 round 2) | Round-1 claim "direct regional host + bearer auth" was overcomplicated. **Round-2 canonical finding** (XDRInternals source `https://raw.githubusercontent.com/MSCloudInternals/XDRInternals/main/XDRInternals/functions/Get-XdrEndpointConfigurationCustomCollectionRule.ps1`): the path is `https://security.microsoft.com/apiproxy/mtp/mdeCustomCollection/rules` via apiproxy + sccauth+XSRF (SAME auth as v2's existing 18 sub-areas). v2 catalogue currently has wrong path `/mtp/customDataCollection/rules` → fix to `/mtp/mdeCustomCollection/rules` (matches working schema endpoint pattern). **No second auth pattern needed.** Direct regional host route remains a documented alternative for SP/MSI scenarios. See `_PHASE_0_SENIOR_AUDIT.md` §2 for correction details + `defender/_MDE_CUSTOM_COLLECTION_RESEARCH.md` for original FalconForce Go-CLI evidence. |
| **G8** Tools inventory clean | ✅ PASS | 21 scripts; `Reverse-Include-StateEndpoints.ps1` deleted; 3 session-new tools present (Annotate-ReadSemantics.ps1, Verify-ValueProps.ps1, Build-FullCatalogue.ps1) |
| **G9** Documentation source-of-truth | ✅ PASS | `_PHASE_0_CONSOLIDATED.md` + `_FULL_CATALOGUE.md` (3061 lines) + `_VALUE_PROP_VERIFICATION.md` + `_READ_SEMANTICS_AUDIT.md` + `_CUSTOM_DETECTION_RESEARCH.md` (NEW) + `_HARDENING_TIMELINE.md` (NEW) all present |
| **G10** Memory wired | ✅ PASS | `feedback_microsoft_defender_sentinel_architect.md` extended with 7 new locked rules: SuccessKind tenant-gated retirement, MaxRedirection 4-file fix, MDE Custom Collection rising surface, Graph beta detectionRules instability, 65% gap-fill value-prop, v1 already-compliant naming, ConnectorHeartbeat separate confirmation |
| **G11** Production-scale documented | ✅ PASS | `_FULL_CATALOGUE.md` Appendix B complete: 18 sub-areas × cadence + pagination distribution + time-filter coverage + top entities + production-scale rating per sub-area; HIGH-volume sub-areas flagged (cloud_apps, endpoint_devices, identity, vulnerability_management) |
| ~~G12~~ Repo + Azure deployment | SKIPPED | User directive: catalogue gate only; out of Phase 0 scope |

---

## Key Phase 0 deliverables (file-resident truth)

| File | Layer | Purpose |
|---|---|---|
| `_PHASE_0_CONSOLIDATED.md` | Executive | Decisions, locked rules, completeness checklist, Phase 1 entry gate status |
| `_FULL_CATALOGUE.md` | Granular | Per-portal-per-sub-area-per-endpoint table with schema/pagination/time-filter/entities/cadence/live (3061 lines, all 20 portals) |
| `_VALUE_PROP_VERIFICATION.md` | Cross-reference | v1↔v2 mapping (67/72), critical-path verification, 426 net-new read endpoints |
| `_CUSTOM_DETECTION_RESEARCH.md` | G5 deliverable | 8-source research dossier confirming no separate custom-detection endpoint exists outside dropped AH |
| `_HARDENING_TIMELINE.md` | G9 deliverable | Microsoft API deprecation + hardening calendar (July 2024 DefenderHarvester · April 2026 alert API · July 2026 Sentinel UI · Feb 2027 legacy AH) |
| `_CATALOGUE_INDEX.md` | Machine-regenerated | Summary index per portal (1727 endpoints / 116 sub-areas / 354 live) |
| `_LIVE_AUDIT_REPORT.md` | Machine-regenerated | Live-probe SuccessKind distribution |
| `_AUTH_INDEX.md` | Auth | Per-portal auth chain summary (all 20 portals have `_AUTH_RESEARCH.json`) |
| `defender/_READ_SEMANTICS_AUDIT.md` | Phase 1 input | 17 write-shaped endpoints to exclude from manifest |

---

## v1 → v2 transition map (Phase 1 build queue)

| v1 module | v2 action | Effort |
|---|---|---|
| `Xdr.Common.Auth` | **REUSE_AS_IS** for portal-agnostic publics; **FORK 2 files** (Complete-CredentialsFlow + Complete-PasskeyFlow → V2 with MaxRedirection=30) | Small |
| `Xdr.Common.Manifest` | REUSE_AS_IS | None |
| `Xdr.Common.Telemetry` | REUSE_AS_IS | None |
| `Xdr.Connector.Orchestrator` | REUSE_AS_IS (multi-portal router ready for v0.2.0) | None |
| `Xdr.Sentinel.Ingest` | REUSE_AS_IS (14 publics: DCE batch ingest, checkpoints, heartbeat, DLQ, tier-state) | None |
| `Xdr.Defender.Auth` | REUSE_AS_IS or minor fork (multi-tenant -TenantId param if needed) | Small |
| `Xdr.Defender.Client` | **FORK_MAJOR**: replace `tenant-gated` SuccessKind → `rate-limited`; lazy-load manifest per sub-area (remove module-import-time cache at `Xdr.Defender.Client.psm1:48`) | Medium |
| `Xdr.Common.AuthV2` (new) | EXISTS — extend with public exports + psd1/psm1 | Small |

| Phase 1 artifact | Status | Notes |
|---|---|---|
| `manifests/defender.psd1` | PENDING | `Build-Manifest.ps1` will filter catalogue by `readSemantics='read'` → 492 entries |
| `deploy/dcrs/Defender_<sub-area>_dcr.json` × 18 | PENDING | One per sub-area; streamDeclarations + transformKql |
| `deploy/dcrs/XdrConnectorHealth_dcr.json` | PENDING | Heartbeat table |
| `deploy/mainTemplate.json` + `createUiDefinition.json` | PENDING | Hand-authored ARM (NO Bicep) |
| `src/functions/Defender-<sub-area>/{run.ps1, function.json}` × 18 + `ConnectorHeartbeat/` × 1 | PENDING | Per-sub-area timer triggers (NOT Durable) |
| `.github/workflows/{ci, release, validate-solution}.yml` | PENDING | Offline-only gates (PSSA + Pester + gitleaks + ARM-TTK hard-fail + recompile gate); release signing via cosign keyless OIDC; NO SP secrets |
| `tests/unit/*.Tests.ps1` × 6+ | PENDING | manifest schema · ReadSemantics filter · projection coverage · DCR consistency · EntityIdStrategy contract · EmptyNotes regression · SuccessKind tenant-gated retirement |

---

## Outstanding flags + next steps

1. **G7-bis NON-BLOCKING flag**: MDE Custom Collection management apiproxy path is unknown. Lab probe of `/mtp/customDataCollection/rules` returned 404. Operator runs DevTools when configuring a Custom Collection rule in `security.microsoft.com/securitysettings/endpoints/custom_collection/` → captures real apiproxy path → updates `endpoint_configuration` sub-area. Phase 1 ships without; v2.x adds when discovered.

2. **3 v1 path-drift unmapped streams** (documented as expected, non-blocking):
   - `MDE_CustomCollection_CL` (`/mtp/mdeCustomCollection/rules` → renamed `customDataCollection` per nodoc; lab probe 404; per #1 above, need correct path)
   - `MDE_LicenseReport_CL` (`/mtp/k8sMachineApi/.../skuReport` → likely deprecated)
   - `MDE_PUAConfig_CL` (`/mtp/autoIr/ui/properties/` → moved)

3. **Critical-path label mismatch (cosmetic)**: `Critical asset classification` in my critical-paths list had a wrong path-string; coverage is real at `configuration/ListCriticalAssetClassifications`. Fix when next refreshing `Verify-ValueProps.ps1` critical-paths list.

4. **Phase 1 prerequisites locked** (per memory rules 1–12 in `feedback_microsoft_defender_sentinel_architect.md`):
   - READ-ONLY connector (no mutations)
   - 18 sub-areas × `Defender_<NodocSubArea>_CL` × per-sub-area timer triggers
   - 4 SuccessKind values: live | live-empty | rate-limited | error (tenant-gated RETIRED)
   - Mandatory row schema: TimeGenerated, Endpoint, EntityId, SuccessKind, HttpStatus, RawJson, RawResponseBody + ProjectionMap typed cols
   - Populated heartbeat Notes JSON
   - Separate ConnectorHeartbeat function (5-min independent)
   - ARM JSON only (NO Bicep), WEBSITE_RUN_FROM_PACKAGE, KV-RBAC + SAMI, cosign keyless OIDC release signing
   - NO SP secrets in CI, offline gates only, no live online testing in CI
   - 5 v1 modules REUSE_AS_IS; 2 modules FORK; 1 new (AuthV2)
   - 65% surfaces gap-fill (value-prop validated per Agent C external research)

---

## Gate report decision

**PHASE 0 GATE PASSED.** Phase 1 (manifest + DCR + FA + ARM + CI + tests) unlocked.

**Recommended next action:** begin Phase 1 by writing `tools/Build-Manifest.ps1` which reads `_FULL_CATALOGUE.md` data (or directly walks metadata.json) and emits `manifests/defender.psd1` filtered by `readSemantics='read'` (excluding 17 write-shaped endpoints). All Phase 1 artifacts listed in §11 of `_PHASE_0_CONSOLIDATED.md`.

**Operator follow-ups** (non-blocking):
- Live probe candidate paths from `_CUSTOM_DETECTION_RESEARCH.md` §Source 9 to definitively rule out alternative custom-detection endpoints
- DevTools recon for MDE Custom Collection apiproxy path (G7-bis)
- Live probe 3 path-drifted v1 streams to determine if new paths exist or features deprecated
