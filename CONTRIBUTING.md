# Contributing to XdrLogRaider

Thank you for your interest in extending XdrLogRaider. This is a purple-team /
detection-engineering tool: an open-source Microsoft Sentinel data connector for the
Microsoft Defender XDR portal-internal `/apiproxy/*` surface. Contributions are expected
to stay inside that authorized, read-only, audit-and-reporting frame.

The single most important thing to understand before you start:

> **Coverage is data, not code.** Adding an operation, a category, or an entire portal
> means editing the `references/` corpus and the curation metadata, then **regenerating**
> the manifests, schemas, and ARM template with the derivation engine. The runtime engine
> in `src/` is portal-agnostic and almost never changes. If you find yourself editing
> `src/` to add coverage, stop — you are probably fighting the design.

---

## Table of contents

- [Prerequisites](#prerequisites)
- [The public / internal firewall](#the-public--internal-firewall)
- [The derivation engine pipeline](#the-derivation-engine-pipeline)
- [The pre-push gauntlet (38 axes)](#the-pre-push-gauntlet-38-axes)
- [Three scopes of contribution](#three-scopes-of-contribution)
  - [A. Add a stream](#a-add-a-stream-a-new-operation-in-an-existing-category)
  - [B. Add a category](#b-add-a-category-a-defender-x-taggroup)
  - [C. Add a portal](#c-add-a-portal-the-expansion-surface)
- [Public vs internal toolkit](#public-vs-internal-toolkit)
- [House rules](#house-rules)

---

## Prerequisites

Install once:

- **PowerShell 7.4+** (the connector targets PowerShell 7.4 on Linux Consumption; the
  tooling runs cross-platform).
- **Pester 5** — the offline test tier.
- **ARM-TTK** — Azure Resource Manager template validation.
- **Az PowerShell** / **Azure CLI** — only for the live-verify steps (deploy + KQL landing).
- The Git hooks: `pwsh -File tools/hooks/Install-GitHooks.ps1`.

For any step that touches a live tenant (onboarding, landing verification), copy the
environment template and fill in your **own** lab values:

```bash
cp .env.local.example .env.local     # gitignored — never commit
```

All coverage development up to the pre-push gauntlet is **fully offline**. You only need a
tenant for the final "prove it lands" step.

> **File encoding (repo lock):** every `.ps1` file must be saved as **UTF-8 with BOM**.
> PowerShell 5's `ParseFile` mis-handles BOM-less scripts on Linux/macOS, and the gauntlet
> will reject a BOM-less script. Markdown, JSON, and YAML are plain UTF-8 (no BOM).

---

## The public / internal firewall

This is a **single repository with a deny-by-default public allowlist**
(`tools/public-allowlist.txt`, gauntlet axis 35). Every git-tracked path must match an
entry in that allowlist, or the push fails.

```
An entry ending in '/' allows the whole subtree; otherwise it allows exactly that file.
Anything not listed is structurally impossible to commit to the public tree.
```

Practical consequence: **when you add a new tracked path, you add it to the allowlist in
the same commit**, or the gauntlet blocks the push. This keeps operator scratch, live tenant
captures, and the internal decision record out of the public repository by construction —
not by remembering to `.gitignore` them.

See [Public vs internal toolkit](#public-vs-internal-toolkit) for exactly what lives on
each side of the firewall.

---

## The derivation engine pipeline

The catalogue is the single source of truth. Manifests, per-category schemas, and the ARM
template are **generated artifacts** — never hand-authored. The engine lives in `dev-tools/`
and reads only the `references/` corpus; it never touches Azure or the runtime.

The core pipeline, in order:

```
Build-EvidenceIndex  →  Build-Catalogue  →  Generate-Manifest  →  Build-PerCategorySchema  →  Build-MainTemplate
```

| Stage | Script | Reads → Writes |
|---|---|---|
| **Evidence index** | `dev-tools/Build-EvidenceIndex.ps1` | Maps the live-capture corpus (`references/live/`, internal) + inventory to catalogue operation keys → per-op evidence index (response shape, item container, row count, sample fields). The schema feed that lifts ops to `LiveCaptured` with no re-probe. |
| **Catalogue** | `dev-tools/Build-Catalogue.ps1` | Portal-generic 6-stage engine (Extract → Classify → Dedupe → Depend → Decide → Map). Fresh-derives `references/inventory/<portal>/catalogue.json` from RAW OpenAPI `x-tagGroups` + inventory + evidence. Never inherits a prior catalogue. |
| **Manifest** | `dev-tools/Generate-Manifest.ps1` | catalogue.json → per-category runtime manifest `manifests/<Portal>/<Category>.psd1` (only `Validated` operations). |
| **Schema** | `dev-tools/Build-PerCategorySchema.ps1` | catalogue / manifest → `deploy/per-category-schemas/<Portal>-<Category>.json` (workspace-table + DCR-stream schema: 9-column envelope + typed columns; table columns == stream columns, set-equality enforced). |
| **ARM template** | `dev-tools/Build-MainTemplate.ps1` | `deploy/foundation.json` + per-category schemas → regenerates `deploy/mainTemplate.json`. **Never hand-edit `mainTemplate.json`** — the gauntlet enforces `foundation ↔ mainTemplate` equality. |

Upstream feeders (run when you add raw sources): `dev-tools/Inventory-References.ps1`
(scans `references/**` → coverage matrix + `operations.json`) and
`dev-tools/Discover-OperationFromRaw.ps1` (candidate discovery + pilot ranking).

Because everything downstream of the catalogue is generated, the golden rule is: **edit the
inputs, run the pipeline, review the diff.** Never hand-edit a generated `.psd1`, schema
JSON, or `mainTemplate.json`.

---

## The pre-push gauntlet (38 axes)

`tools/Run-PrePushGauntlet.ps1` is **the** pre-push gate. All 38 axes are offline-provable —
no deployed Function App, no Azure, no network — and any failure returns a non-zero exit and
blocks the push. Run it before every push:

```powershell
pwsh -File tools/Run-PrePushGauntlet.ps1
```

The axes cover, among others: PowerShell parse, JSON/YAML parse, PSScriptAnalyzer, the Tier-1
Pester suite, ARM structural validation (dynamically scaled to the shipped category count —
never a hardcoded number), manifest ↔ schema regen-and-diff, exactly-once replay, and the
**public-allowlist enforcement (axis 35)**. The gauntlet is where "I regenerated correctly"
becomes provable: it regenerates artifacts and diffs them against what you committed, so a
stale generated file fails the push.

Post-deploy KQL landing is deliberately **not** in the gauntlet — it needs a live tenant and
is a separate step (`tools/Verify-OperationLanding.ps1` / `tools/Verify-DeployedConnector.ps1`).

---

## Three scopes of contribution

Everything you might add falls into one of three scopes, from smallest to largest. Each is a
strict superset of the one before it.

### A. Add a stream (a new operation in an existing category)

A "stream" is one Defender operation that lands rows into an existing category's Log
Analytics table.

1. **Confirm the operation exists in the corpus.** It must be present in
   `references/openapi/nodoc-defender-xdr/specification/<category>.yml` (and, ideally, backed
   by a live capture). Operations are never invented — they are derived from the nodoc corpus.
2. **Refresh inventory:** `dev-tools/Inventory-References.ps1` → updates `operations.json` +
   the coverage matrix. Run `dev-tools/Build-EvidenceIndex.ps1` if you added a live capture.
3. **Curate:** set the operation's `valueClass`, `cadence`, and ship/hold decision in the
   curation metadata that `Build-Catalogue` reads.
4. **Rebuild the catalogue:** `dev-tools/Build-Catalogue.ps1 -Portal Defender` → review the
   catalogue diff for exactly the operation you expect.
5. **Regenerate:** `dev-tools/Generate-Manifest.ps1` + `dev-tools/Build-PerCategorySchema.ps1`
   → the category `.psd1` and schema pick up the new stream. If columns changed, the schema
   diff shows the new typed columns.
6. **Gauntlet green:** `pwsh -File tools/Run-PrePushGauntlet.ps1`.
7. **Prove it lands (live):** `tools/Onboard-CategorySurgical.ps1` for the affected category,
   then `tools/Verify-OperationLanding.ps1` — confirm rows > 0 with typed columns — then
   human-read the sample. **One consolidated commit** for the deliverable.

### B. Add a category (a Defender `x-tagGroup`)

A category is always a nodoc `x-tagGroups` group — never invented. It gets its own
`Defender_<Category>_CL` table, DCR stream, and ARM wiring.

1. Ensure the category's operations are in the corpus and curated (as in scope A).
2. `dev-tools/Build-Catalogue.ps1 -Portal Defender` → the new category appears in
   `catalogue.json`.
3. `tools/Onboard-NextCategory.ps1 -Portal Defender -Category <Category>` — emits the
   manifest, the per-category schema, the nested deployment, the `XDRLR_DCR_DEFENDER_<CATEGORY>`
   wiring, and the replay scaffold. `Build-MainTemplate.ps1` re-assembles `mainTemplate.json`
   with the new category as an additional top-level resource.
4. Full **gauntlet + Pester** green.
5. **Surgical onboard + verify (live):** `tools/Onboard-CategorySurgical.ps1` →
   `tools/Verify-DeployedConnector.ps1 -AllOps` — every operation POPULATED per op — then
   human-read.
6. **One consolidated commit.** Add the new manifest/schema paths to the allowlist in the
   same commit if they fall outside an already-allowed subtree.

> **Excluded categories stay out.** `advanced_hunting`, `alerts_incidents`, and
> `live_response` are intentionally excluded (they have supported public APIs and/or are
> out of scope). `tools/Validate-Scope.ps1` enforces this boundary — do not re-add them.

### C. Add a portal (the expansion surface)

The runtime engine is portal-agnostic. Any portal whose behavior the engine already
supports — the same `/apiproxy`-style HTTP surface, the same pagination / time-filter /
capability-gating mechanisms — can be added as **pure data**. The research corpus for a
range of non-Defender portals already lives under `references/` as the expansion surface
(see [docs/ROADMAP.md](docs/ROADMAP.md)).

1. **Drop the raw sources** under `references/` for the new portal: the nodoc OpenAPI
   specification, the Postman collection, and the curation metadata. Keep any live captures
   in the **internal** layer (`references/live/`, gitignored).
2. `dev-tools/Inventory-References.ps1` → `dev-tools/Build-Catalogue.ps1 -Portal <Portal>`
   derives the portal's `catalogue.json`.
3. Register the portal in `references/inventory/portals.json` **and** add its public paths to
   `tools/public-allowlist.txt` (axis 35 gates it).
4. **Wire a per-portal auth seed.** Each portal authenticates through its own portal host;
   the auth modules (`Xdr.<Portal>.Auth`) follow the existing Defender auth pattern.
5. Then proceed **per category** exactly as in scope B, one category at a time, each a
   separate proven deliverable.

Adding a portal is the largest scope and the most valuable contribution. Open an issue first
so the direction can be discussed before you invest in a full portal.

---

## Public vs internal toolkit

The repository is a single tree split by the public allowlist. The **public** side is the
derivation / build / deploy / verify engine plus the portal research corpus — everything a
contributor needs to add coverage and prove it. The **internal** side (gitignored, never
tracked) is operator scratch, live tenant captures, and the private decision record.

| | **Public** (tracked, shipped) | **Internal** (gitignored, never tracked) |
|---|---|---|
| **Derivation engine** | `dev-tools/` — `Build-EvidenceIndex`, `Build-Catalogue`, `Generate-Manifest`, `Build-PerCategorySchema`, `Build-MainTemplate` (+ `Inventory-References`, `Discover-OperationFromRaw`, `Report-Catalogue`) | `dev-tools/.generated/` scratch/validation output |
| **Build / deploy / verify** | `tools/` — `Run-PrePushGauntlet`, `Onboard-CategorySurgical`, `Onboard-NextCategory`, `Verify-DeployedConnector`, `Verify-OperationLanding`, `Build-FunctionAppZip`, `Build-SolutionPackage`, validators, git hooks | `*-Local` probe scripts (e.g. `Probe-*-Local.ps1`) — operator investigation probes |
| **Research corpus** | `references/openapi/`, `references/postman/`, `references/inventory/`, `references/cross-source/` — derived + upstream-sourced specs for Defender **and** the roadmap portals | `references/live/` — live tenant captures (raw responses from a real tenant) |
| **Docs** | `README.md`, `CONTRIBUTING.md`, `docs/ROADMAP.md`, operator/contributor runbooks under `docs/` | `docs/DECISION-LEDGER.md`, `docs/CATALOGUE-REVIEW-*.md`, `PHASE_*` / `*_GATE_*` records — the internal dev record |
| **Config / secrets** | `.env.local.example` (template) | `.env.local`, `parameters.local.json`, operator scratch, root build logs |

The `references/live/` capture corpus is what feeds `Build-EvidenceIndex`, but the raw
tenant responses themselves stay internal — the **derived** schema and catalogue that come
out of them are what ship.

---

## House rules

- **One consolidated commit per deliverable.** A stream, a category, or a portal-category is
  one reviewable unit: corpus edit + regenerated artifacts + allowlist entry + proof.
- **No AI attribution in commits or authorship.** Author metadata is a person, not a tool.
- **Verify, don't assume.** A "0 rows" result on your lab tenant may mean the product isn't
  licensed there (capability-gated), not that the operation is broken — confirm before you
  change anything. Cross-check your own conclusions against the source.
- **Read-only by design.** XdrLogRaider only reads (`GET`) audit/reporting/posture surfaces.
  Do not add write, mutate, or response actions.
- **Stay in scope.** This is authorized purple-team / detection tooling for owned or
  explicitly-authorized tenants. Keep contributions inside that frame.

Questions or a larger proposal? Open an issue before writing code.
