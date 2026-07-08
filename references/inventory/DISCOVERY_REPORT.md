# XdrLogRaider · Phase 0.4 DISCOVERY REPORT

**Generated**: 2026-06-01T19:51Z by Phase 0.4 raw-source enumeration
**Plan reference**: §Φ16 Phase 0.4 · Discover per-Portal/Category/Operation inventory from RAW (NEVER inherit)
**Methodology**: verify · never trust · do not inherit · do not copy paste

This report documents what was discovered by parsing 128 OpenAPI YAML files. The numbers below SUPERSEDE all prior iter counts (519 / 18 / 367 / etc.). Per binding methodology rule 3, no prior catalogue was inherited.

---

## Headline numbers (raw)

| Metric | Raw count | Notes |
|---|---:|---|
| Distinct portal sources | **20** | (vs prior "5 portals" claim · ~4x richer) |
| Categories (YAML files with `paths:` defined) | **119** | excludes infrastructure schemas (common.yml · openapi.yml index) |
| Operations (path × HTTP method pairs) | **1,941** | across all 20 portals |
| Defender XDR raw Categories | **21** | (3 will be EXCLUDED per operator policy) |
| Defender XDR raw Operations | **594** | (71 in excluded categories) |
| **Defender v0.1.0 ACTIVE Categories** | **18** | matches inherited claim ±1 |
| **Defender v0.1.0 ACTIVE Operations** | **523** | inherited claim "519" was -4 short |

---

## Per-portal breakdown (alphabetical)

| Portal directory | Cats | Ops | v0.1.0 scope |
|---|---:|---:|---|
| `nodoc-defender-xdr` | 21 | **594** | **PRIMARY · ACTIVE** (18 cats / 523 ops after exclusions) |
| `nodoc-entra-b2c` | 1 | 6 | v0.3.0+ |
| `nodoc-entra-idgov` | 1 | 17 | v0.2.0 (Entra umbrella) |
| `nodoc-entra-iga` | 1 | 11 | v0.2.0 (Entra umbrella) |
| `nodoc-entra-pim` | 1 | 16 | v0.2.0 (Entra umbrella) |
| `nodoc-exchange-beta` | 1 | 61 | v0.3.0+ |
| `nodoc-ibiza-iam` | 32 | 286 | v0.2.0 (Entra umbrella · largest portal) |
| `nodoc-intune-autopatch` | 1 | 53 | v0.2.0 (Intune umbrella) |
| `nodoc-intune-portal` | 1 | 5 | v0.2.0 (Intune umbrella) |
| `nodoc-m365-admin` | 24 | 280 | v0.3.0+ (M365 portal · 6th portal candidate) |
| `nodoc-m365-apps-config` | 1 | 23 | v0.3.0+ |
| `nodoc-m365-apps-inventory` | 1 | 27 | v0.3.0+ |
| `nodoc-m365-apps-services` | 1 | 9 | v0.3.0+ |
| `nodoc-power-platform` | 9 | 244 | v0.3.0+ |
| `nodoc-purview` | 18 | 124 | v0.2.0 (Purview umbrella) |
| `nodoc-purview-portal` | 1 | 8 | v0.2.0 (merge with nodoc-purview?) |
| `nodoc-security-copilot` | 1 | 32 | v0.2.0 (SecurityCopilot scaffolded) |
| `nodoc-sharepoint-admin` | 1 | 41 | v0.3.0+ |
| `nodoc-teams` | 1 | 99 | v0.3.0+ |
| `nodoc-viva-engage` | 1 | 5 | v0.3.0+ |
| **TOTAL** | **119** | **1,941** | |

**Key observations**:
- Defender alone has 31% of raw operations
- ibiza-iam (Entra ID admin) is 2nd largest at 15% · combined with 4 sister nodoc-entra-* dirs = "Entra umbrella" with 31 categories · 336 ops
- M365 admin alone has 24 categories · is a candidate 6th portal NOT in original §Φ16 scoping
- 5 portals are single-category single-purpose (security-copilot · sharepoint-admin · teams · viva-engage · exchange-beta)

---

## Defender XDR · 21 Categories detail

| Category file | Operations | v0.1.0 Policy |
|---|---:|---|
| `action_center.yml` | 11 | ACTIVE |
| `advanced_hunting.yml` | 27 | **EXCLUDED** (operator policy · Sentinel native AH duplicate) |
| `alerts_incidents.yml` | 32 | **EXCLUDED** (operator policy · Sentinel native duplicates) |
| `attack_simulator.yml` | 10 | ACTIVE |
| `cloud_apps.yml` | 95 | ACTIVE (largest active · was "CloudApps + AppGov merged" per §Φ6.B) |
| `configuration.yml` | 56 | ACTIVE |
| `data_lake.yml` | 7 | ACTIVE |
| `endpoint_configuration.yml` | 21 | ACTIVE |
| `endpoint_devices.yml` | 49 | ACTIVE |
| `entity_pivots.yml` | 19 | ACTIVE |
| `exposure_management.yml` | 42 | ACTIVE (XSPM) |
| `files.yml` | 19 | ACTIVE |
| `identity.yml` | 77 | ACTIVE (MDI · 2nd largest active) |
| `live_response.yml` | 12 | **EXCLUDED** (operator policy · write-side endpoints) |
| `multi_tenant.yml` | 17 | ACTIVE |
| `portal_services.yml` | 22 | ACTIVE |
| `secure_score.yml` | 8 | ACTIVE |
| `sentinel_precision.yml` | 16 | ACTIVE |
| `streaming.yml` | 1 | ACTIVE (smallest · 1 endpoint · ideal pilot candidate) |
| `threat_analytics.yml` | 20 | ACTIVE |
| `vulnerability_management.yml` | 33 | ACTIVE (MDVM) |
| **TOTAL RAW** | **594** | |
| **TOTAL ACTIVE** | **523** | (18 categories) |
| **TOTAL EXCLUDED** | **71** | (3 categories per operator policy) |

Note: `common.yml` (shared schemas) + `openapi.yml` (index file) are infrastructure · not Categories. Excluded from the count.

---

## DELTA vs inherited counts (PRIVACY.md / TERMS.md / prior iter claims)

| Claim | Inherited | Actual | Delta | Implication |
|---|---|---|---|---|
| PRIVACY.md L9 "519 endpoints" | 519 | **523** | +4 | PRIVACY.md needs update (or operator confirms acceptable approximation) |
| PRIVACY.md L9 "19 Defender tables" | 19 | **18** | -1 | PRIVACY.md L9 + TERMS.md L61 need correction to "18 Defender_<Category>_CL tables" |
| Prior catalogue "367 active" | 367 | **523** | +156 | Older iter count was significantly off · this Phase 0.4 supersedes |
| TERMS.md L61 "19 SubAreas · 519 endpoints" | 19/519 | **18/523** | -1/+4 | TERMS.md needs update |
| §Φ16 plan "5 portals" | 5 | **20** | +15 | Raw OpenAPI shows 20 distinct portal sources · §Φ16 v0.1.0 still ships Defender only |

**Action needed**: Phase 1.7 marketplace asset regeneration should update PRIVACY.md + TERMS.md with `18 / 523` actuals. Operator confirms or pushes back on text revision.

---

## Postman cross-reference (583 items in defender.collection.json)

Postman items are grouped by **sub-portal namespace** (NOT by Category):

| Sub-portal namespace | Postman items | Notes |
|---|---:|---|
| `mtp` | 329 | Microsoft Threat Protection (the umbrella · most operations route here) |
| `mcas` | 87 | Cloud App Security (matches cloud_apps Category) |
| `mdi` | 35 | Microsoft Defender for Identity (matches identity Category subset) |
| `aatp` | 26 | Azure ATP (legacy name for MDI · same routing prefix) |
| `mdc` | 21 | Microsoft Defender for Cloud |
| `mtoapi` | 16 | Multi-Tenant Organization API (matches multi_tenant Category) |
| `apiproxy` | 15 | Generic /apiproxy/ path (catch-all) |
| `m365appprotection` | 12 | M365 App Protection |
| `astgws` | 11 | Attack Simulator Training Gateway (matches attack_simulator Category) |
| `radius` | 10 | RADIUS authentication endpoints |
| `securityplatform` | 7 | Security platform meta |
| `di` | 6 | Defender Investigation |
| `msgraph` | 3 | Microsoft Graph |
| `shell` · `medeina` · `cdssecuritycopilot` · `gws` · `admin` | 1 each | Edge cases |
| **TOTAL** | **583** | (60 ops less than 523 active OpenAPI ops + 71 excluded = 594 raw → Postman is incomplete) |

**Phase 2 cross-match recipe** (per-Operation):
1. For each ACTIVE Defender Operation (523 total)
2. Search Postman by URL pattern: `<sub-portal>/<rest-of-path>`
3. If match found → extract `body` (POST endpoints) + `header overrides` + `auth` settings
4. If no Postman match → `body` is empty / not applicable (most GETs)

---

## Live capture cross-reference (322 total · 2 sources)

### source-final-cross/by-path/ · 159 files · FLAT encoding `<category>__<operation>.json`

| Sample | Match to OpenAPI Category? |
|---|---|
| `actioncenter__exporthistory.json` | → `action_center.yml/ActionCenter.ExportHistory` |
| `actioncenter__gethistory.json` | → `action_center.yml/ActionCenter.GetHistory` |
| `actioncenter__gethistoryfilters.json` | → `action_center.yml/ActionCenter.GetHistoryFilters` |

**Heuristic**: Filename = `<lowercase-category>__<lowercase-operation>.json` · matches OpenAPI via `operationId.Split('.')[0].ToLower() + '__' + operationId.Split('.')[1].ToLower()`

### source-mvp-fixtures/<OperationName>/response.json · 163 files · NESTED encoding

| Sample | Match to OpenAPI? |
|---|---|
| `AttackSimulator_GetRecommendations/response.json` | → `attack_simulator.yml/AttackSimulator.GetRecommendations` |
| `CheckAppGovernanceOnboarding/response.json` | → `cloud_apps.yml/?` (need to check) |
| `Configuration_TenantContext/response.json` | → `configuration.yml/Configuration.TenantContext` |

**Heuristic**: Directory = `<PascalCaseCategory>_<PascalCaseOperation>` or `<OperationName>` alone (when unambiguous).

### Cross-source coverage gap

- 523 ACTIVE operations total
- ~159 + 163 = 322 live captures (with overlap)
- After de-duplication (Phase 0.4 NOT yet) · estimate ~250-280 unique live operations
- **~50% of operations have NO live capture yet** · Phase 2 surfaces these per-Operation · operator may capture in lab tenant as needed OR Phase 2 can use OpenAPI schema-based mock for offline replay

---

## Defender sub-portal architecture insight (Phase 1 ARM impact)

The 18 Postman sub-portal namespaces + matching auth-routing observations from prior iters mean Defender's `/apiproxy/*` layer fronts **multiple back-ends**:

- `/apiproxy/mtp/*` → primary MTP API (most operations)
- `/apiproxy/mcas/*` → MCAS/CloudApps endpoints (separate auth chain · proven 1710+ KMSI bench)
- `/apiproxy/mdi/*` → MDI/Identity endpoints (sub-portal proxy)
- `/apiproxy/mdc/*` → Defender for Cloud (less used in v0.1.0 Defender scope · likely empty during runtime)
- `/apiproxy/astgws/*` → Attack Simulator (read-side ACTIVE)
- ... etc.

**Phase 1 ARM implication**: Per-Operation `SubPortal` field in manifest entries · runtime URL builder constructs `https://security.microsoft.com/apiproxy/<SubPortal>/<rest-of-path>` for HttpClient base.

---

## Methodology applied (verify · never trust)

| Rule | Application |
|---|---|
| Discovery from RAW (rule 3) | ALL counts derived from parsing OpenAPI YAML files in `references/openapi/` |
| Never inherit (rule 3) | Prior "519 / 18 / 367" claims documented as DELTAs · not adopted |
| Provenance traced (rule 8) | Each operation provenance points back to: portal/category/file/line in operations.json |
| `references/live/` is truth (rule 9) | 322 captures preserved as-is · NO mutation · Phase 0.4 only reads structure |
| operation-tracker.json authoritative (rule 10) | Discovery output drives Phase 2 per-Operation atomic methodology |

---

## Next actions

**Phase 0.5** (next): Verify Phase 0 gate · all 5 sub-checks GREEN · transition to Phase 1.

**Phase 1.7** (later): Update PRIVACY.md L9 + TERMS.md L61 with `18 categories · 523 operations` actuals (currently say `19 / 519` · DELTA -1 / +4).

**Phase 2 per-Operation methodology** (later): Each of 523 operations gets:
- OpenAPI lookup → method · path · operationId · params · response schema
- Postman lookup → body · header · auth · variant detection (POST endpoints especially)
- Live capture lookup → operator's lab tenant truth · per-item field schema
- Combined → EndpointContract → manifest entry → DCR streamDeclaration → Pester replay test → 8/8 KQL gate

---

## Files produced by Phase 0.4

```
references/inventory/
├── DISCOVERY_REPORT.md            # this file
├── portals.json                   # root summary · 20 portals · 119 cats · 1941 ops
├── nodoc-defender-xdr/
│   ├── categories.json            # 21 categories list
│   ├── action_center.operations.json    # 11 operations
│   ├── advanced_hunting.operations.json # 27 (EXCLUDED)
│   ├── ... (21 .operations.json files)
│   └── vulnerability_management.operations.json
├── nodoc-entra-b2c/
│   └── ... (per-portal subdirs same pattern)
└── (20 portal subdirs total)
```

Total Phase 0.4 artifacts: 140 JSON files + 1 .md report.
