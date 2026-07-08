# XdrLogRaider · references/ INVENTORY

**Generated**: 2026-06-01T19:48Z by Phase 0.3 consolidation
**Plan reference**: §Φ16 Phase 0.3 · Consolidate raw references (NOT artifacts)
**Methodology binding**: verify · never trust · do not inherit · do not copy paste

This directory contains **RAW SOURCES ONLY** — never tooling outputs, manifests, or derived artifacts. All 621 files were copied byte-faithfully from prior repos (preserved read-only in `../xdrlograider-archive/`).

> **2026-06-04 correction**: the `live/` section was stale — it claimed **322 files / 2 sources** but the tree actually holds **470 files across 3 source dirs** (the third, `source-xdrlograider-raw/`, was omitted). The live count and the grand total below now reflect the on-disk reality (verified by file enumeration, not inherited). See `live/CONSOLIDATION.md` for the per-OperationKey dedup analysis across the 3 dirs.

---

## Total inventory

| Source kind | Count | Size | Provenance repo |
|---|---|---|---|
| OpenAPI YAML specs | 128 | 3.11 MB | `xdrlograider` (a72ea30) · `.internal/nodoc-reference/specifications/` |
| Postman collections | 20 | 31 MB | `xdrlograider` (a72ea30) · `.internal/nodoc-reference/postman/collections/` |
| Live captures · source A (`live/source-final-cross/`) | 159 | ~1 MB | `xdrlograider-final` (a33023f) · `references/cross-source/live-extracted/` |
| Live captures · source B (`live/source-mvp-fixtures/`) | 163 | ~16 MB | `xdrlograider-mvp` (6887683) · `tests/fixtures/live/` |
| Live captures · source C (`live/source-xdrlograider-raw/`) | 148 | ~22 MB | `xdrlograider` (a72ea30) · `tests/fixtures/live-responses/` |
| Marketplace assets | 3 | <1 MB | `xdrlograider-final` (a33023f) · `Package/` |
| **TOTAL** | **621** | **~73 MB** | 3 source repos |

Live subtree = **470 files / 3 source dirs** (159 + 163 + 148). Per-OperationKey dedup analysis lives in `live/CONSOLIDATION.md`.

The earlier note "Source C duplicate (`xdrlograider-final\references\cross-source\mvp-fixtures\`) intentionally skipped" still holds — that bit-identical *copy* of source B was not re-imported. It is unrelated to `live/source-xdrlograider-raw/`, which is a genuinely distinct third capture (raw + post-ingest pairs at CL-table granularity) and **is** present on disk.

---

## openapi/ · 128 OpenAPI YAML specifications across 20 portals

Pre-existing portal directory structure preserved. Naming convention: `nodoc-<portal-key>/specification/<operation>.yml`

| Portal directory | Spec count | Notes |
|---|---:|---|
| `nodoc-ibiza-iam/` | 34 | Entra ID admin portal (largest portal · access management) |
| `nodoc-m365-admin/` | 26 | Microsoft 365 admin center |
| `nodoc-defender-xdr/` | 23 | **PRIMARY v0.1.0 target** · Defender XDR portal |
| `nodoc-purview/` | 20 | Purview compliance/governance |
| `nodoc-power-platform/` | 10 | Power Apps/Automate/Pages |
| `nodoc-entra-b2c/` | 1 | Entra B2C (external identities) |
| `nodoc-entra-idgov/` | 1 | Entra ID Governance |
| `nodoc-entra-iga/` | 1 | Entra Identity Governance (different SKU than -idgov) |
| `nodoc-entra-pim/` | 1 | Entra Privileged Identity Management |
| `nodoc-exchange-beta/` | 1 | Exchange admin (beta API) |
| `nodoc-intune-autopatch/` | 1 | Intune Autopatch |
| `nodoc-intune-portal/` | 1 | Intune device admin |
| `nodoc-m365-apps-config/` | 1 | M365 Apps deployment policies |
| `nodoc-m365-apps-inventory/` | 1 | M365 Apps software inventory |
| `nodoc-m365-apps-services/` | 1 | M365 Apps service status |
| `nodoc-purview-portal/` | 1 | Purview portal UI metadata |
| `nodoc-security-copilot/` | 1 | Security Copilot |
| `nodoc-sharepoint-admin/` | 1 | SharePoint admin |
| `nodoc-teams/` | 1 | Teams admin |
| `nodoc-viva-engage/` | 1 | Viva Engage |
| **TOTAL** | **128** | **20 distinct portal sources** |

**Discovery implication for Phase 0.4**: §Φ16 plan referenced "5 portals" (Defender + Entra + Intune + Purview + SecurityCopilot) but raw OpenAPI shows 20 portal sources. Phase 0.4 will reconcile:
- Whether `nodoc-ibiza-iam` + `nodoc-entra-*` (4 variants) should aggregate into "Entra" superset
- Whether `nodoc-intune-*` (2 variants) should aggregate into "Intune" superset
- Whether `nodoc-m365-*` (4 variants) is a NEW 6th portal (M365)
- Whether `nodoc-purview-portal` is distinct from `nodoc-purview`
- Whether `nodoc-exchange-beta`, `nodoc-sharepoint-admin`, `nodoc-teams`, `nodoc-viva-engage`, `nodoc-power-platform` are independent portals (v0.3.0+ expansion) or aggregate into existing ones

---

## postman/ · 20 Postman collections

Naming convention: `<portal-key>.collection.json`

| File | Size | Coverage |
|---|---:|---|
| `defender.collection.json` | 12.2 MB | **PRIMARY v0.1.0 target** · Defender XDR portal |
| `entra-iam.collection.json` | 7.7 MB | Entra ID + IAM (matches nodoc-ibiza-iam) |
| `m365-admin.collection.json` | 3.8 MB | M365 admin center |
| `purview.collection.json` | 2.3 MB | Purview |
| `power-platform.collection.json` | 1.7 MB | Power Platform |
| `teams.collection.json` | 1.0 MB | Teams admin |
| `intune-autopatch.collection.json` | 0.9 MB | Intune Autopatch |
| `sharepoint-admin.collection.json` | 0.5 MB | SharePoint admin |
| `exchange-beta.collection.json` | 0.5 MB | Exchange beta |
| `security-copilot.collection.json` | 0.3 MB | Security Copilot |
| `m365-apps-inventory.collection.json` | 0.3 MB | M365 Apps inventory |
| `m365-apps-config.collection.json` | 0.2 MB | M365 Apps config |
| `entra-pim.collection.json` | 0.2 MB | Entra PIM |
| `entra-idgov.collection.json` | 0.2 MB | Entra IDGov |
| `purview-portal.collection.json` | 0.1 MB | Purview portal |
| `entra-iga.collection.json` | 0.1 MB | Entra IGA |
| `m365-apps-services.collection.json` | 0.1 MB | M365 Apps services |
| `intune-portal.collection.json` | <0.1 MB | Intune portal |
| `entra-b2c.collection.json` | <0.1 MB | Entra B2C |
| `viva-engage.collection.json` | <0.1 MB | Viva Engage |
| **TOTAL** | **31 MB** | 20 portal collections |

Postman collections enrich OpenAPI with **BodyTemplate examples**, **header overrides**, and **request-chaining metadata** (e.g., POST endpoints with response-derived path params). Phase 0.4 will cross-correlate Postman ↔ OpenAPI per Operation.

---

## live/ · 470 live API response captures (3 sources)

| Source dir | Files | Granularity | Layout | Provenance |
|---|---:|---|---|---|
| `source-final-cross/` | 159 | per-operation | FLAT `by-path/<category>__<op>.json` (metadata-wrapped) | `xdrlograider-final` (a33023f) · `references/cross-source/live-extracted/` |
| `source-mvp-fixtures/` | 163 | per-operation | NESTED `<Op>/response.json` (raw body) | `xdrlograider-mvp` (6887683) · `tests/fixtures/live/` |
| `source-xdrlograider-raw/` | 148 | per-CL-table | FLAT `MDE_<Table>_CL-{raw,ingest}.json` (+`_capture-summary.json`) | `xdrlograider` (a72ea30) · `tests/fixtures/live-responses/` |

These three dirs heavily overlap (same Defender operations captured three ways) and have **never been deduped**. The per-OperationKey dedup groups + canonical-pick recommendation are in **`live/CONSOLIDATION.md`** (document-only — no files moved/deleted).

### source-final-cross/ · 159 files

**Provenance**: `xdrlograider-final` (a33023f) · `references/cross-source/live-extracted/`

**Path pattern**: FLAT — `by-path/<category>__<operation>.json`

Sample paths:
- `by-path/actioncenter__exporthistory.json`
- `by-path/actioncenter__gethistory.json`
- `by-path/actioncenter__gethistoryfilters.json`

**Shape**: each file is a **metadata-wrapped** capture — `OperationMatch` (`PathKey` = `<subarea>/<slug>`, `SubArea`, `Slug`), `Fields` (ResponseShape, `ExampleResponseExcerpt`, QueryParameters, …). The response body is embedded under `Fields.ExampleResponseExcerpt`, NOT at the file root.

**Interpretation**: Operator's lab tenant captures · extracted from a prior cross-source consolidation step in iter=Phi10.x. Path encoding: `<lowercase-category>__<lowercase-operation>.json`. Across 159 files there are **157 distinct operation slugs** (two slugs — `tenantcontext`, `getsecuritycopilottrial` — appear under two SubAreas each).

### source-mvp-fixtures/ · 163 files

**Provenance**: `xdrlograider-mvp` (6887683) · `tests/fixtures/live/`

**Path pattern**: NESTED — `<OperationName>/response.json` (all 163 leaf files are literally named `response.json`; no `<Variant>/` subdirs exist on disk in this snapshot).

Sample paths:
- `AttackSimulator_GetRecommendations/response.json`
- `CheckAppGovernanceOnboarding/response.json`
- `ExportHistory/response.json`
- `GetHistory/response.json`

**Shape**: each file is the **raw response body** only (e.g. `{"Count":0,"Results":[]}`) — no metadata wrapper.

**Interpretation**: Operator's lab tenant captures · this source predates -final's extraction step. Path encoding: `<PascalCase-Operation>/response.json`. Some dirs carry a `<Category>_` prefix (e.g. `MultiTenant_ListIdentities`, `Configuration_TenantContext`). 163 dirs collapse to **157 distinct operations** (6 dirs are duplicate-named variants of operations already present, e.g. `TenantContext` / `Configuration_TenantContext` / `MultiTenant_TenantContext`).

### source-xdrlograider-raw/ · 148 files

**Provenance**: `xdrlograider` (a72ea30) · `tests/fixtures/live-responses/`

**Path pattern**: FLAT — `MDE_<Table>_CL-raw.json` (raw API body) + `MDE_<Table>_CL-ingest.json` (post-transform projected rows), plus one `_capture-summary.json` index.

Sample paths:
- `MDE_PendingActions_CL-raw.json` + `MDE_PendingActions_CL-ingest.json`
- `MDE_Machines_CL-raw.json` + `MDE_Machines_CL-ingest.json`
- `_capture-summary.json`

**Shape**: 74 distinct `MDE_<Table>_CL` streams = **73 raw+ingest pairs + 1 raw-only** (`MDE_StreamingApiConfig_CL` has no `-ingest`), totalling 147 `.json` + 1 `_capture-summary.json` = 148 files. `-raw.json` mirrors source B's body; `-ingest.json` is the projected-row array (TimeGenerated / SourceStream / EntityId / RawJson).

**Granularity caveat (important for dedup)**: this source is keyed by **curated CL-table name** (`MDE_<Table>_CL`), a human-assigned semantic label — NOT the operation slug. It therefore does **not** mechanically join to sources A/B by filename. `_capture-summary.json` only indexes **22** of the 74 streams (and most of those 22 are error captures with empty `RawPath`), so it cannot bridge the rest either. Mapping `MDE_<Table>_CL` → `<category>__<op>` requires per-table semantic judgement (e.g. `MDE_PendingActions_CL` ⇒ `actioncenter__getpending`). `CONSOLIDATION.md` documents the one mechanical overlap (`MDE_TenantContext_CL`) and lists the remaining 73 as operator-mapping candidates.

### Phase 0.4 task: cross-source dedup by OperationKey

`live/CONSOLIDATION.md` (authored 2026-06-04) already documents the dedup groups. The Phase 0.4 physical-consolidation builder will, per group:
1. Parse the canonical OperationKey `<category>__<op>` from sources A/B path encoding (and the semantic table map for C).
2. Compute SHA256 of body content (NOT path) — comparing source B `response.json`, source C `-raw.json`, and source A `Fields.ExampleResponseExcerpt`.
3. If bodies are bit-identical → keep one canonical · note in provenance that all sources carried it.
4. If bodies differ → KEEP candidates with source-suffixed names · operator decides authoritative.

All three sources are PRESERVED in current state · NO de-dup yet (CONSOLIDATION.md is document-only). Phase 0.4 reconciles physically.

---

## Package/ · 3 marketplace assets

| File | Source | Purpose |
|---|---|---|
| `Logo/logo.svg` | xdrlograider-final/Package/Logo/ | Connector card icon (marketplace requirement · operator-designed) |
| `SolutionMetadata.json` | xdrlograider-final/Package/ | Sentinel V3 solution metadata (will be regenerated in Phase 1 against fresh discovery counts · this is the reference template) |
| `manifest.json` | xdrlograider-final/Package/ | Package manifest (will be regenerated in Phase 1 · this is the reference template) |

**v0.1.0 carry-forward**: ONLY `Logo/logo.svg` is operator-binding (it's a design asset). `SolutionMetadata.json` and `manifest.json` are REFERENCE TEMPLATES per §Φ16 anti-inheritance rule — Phase 1 will regenerate both from the actual discovered Phase 0.4 inventory (not from prior iter's count claims).

---

## Audit trail

This INVENTORY.md is itself a Phase 0.3 artifact. Subsequent phases:
- **Phase 0.4** (next): Build `references/inventory/<portal>.json` per-portal manifests + `references/contracts/<Portal>/<Category>/<Operation>.json` per-operation contracts
- **Phase 0.5**: Verify Phase 0 gate · all 5 sub-checks GREEN · transition to Phase 1

---

## NEVER do

Per §Φ16 binding methodology rule 9: **`references/live/` is truth · no live re-probe needed mid-Phase 3**. The 470 live captures here (across the 3 source dirs) are the operator's curated lab tenant snapshots. Phase 3 per-Operation iteration READS from this directory · NEVER writes to it.

If a NEW Operation needs a live capture (Phase 0.4 discovers operations in OpenAPI/Postman but no live fixture), the operator captures it in the lab tenant and adds to `references/live/Defender/<Category>/<Operation>/` manually. This is a separate operator activity outside the autonomous loop.
