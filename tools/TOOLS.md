# XdrLogRaider · tooling inventory (`tools/` + `dev-tools/`)

Two toolkits, both repo-only — **NEVER** bundled in the FA zip (`Build-FunctionAppZip.ps1` excludes both). They
exist for CI gates, the reference→manifest derivation engine, and operator workflows.

- **`tools/`** — runtime-adjacent: CI gates, build, deploy-sync, post-deploy verification, git hooks. **18 `.ps1`**.
- **`dev-tools/`** — the offline **reference → catalogue → manifest → schema** derivation engine. **10 `.ps1`** + a
  gitignored `.generated/` scratch area. Reads RAW `references/` sources; never touches Azure or runtime.

> Refreshed 2026-06-04: reconciled this file to the on-disk reality (verified by enumeration). Several entries that
> were marked "deferred / will be authored" already exist and are now marked **IMPLEMENTED**; tools that do **not**
> exist on disk were moved to "Not yet authored" so the inventory stops implying presence. The pre-push gate naming
> was corrected: **`Run-PrePushGauntlet.ps1` (38 axes) is THE gate** — the ONE offline entry point (the former Run-OfflineGauntlet subset was retired at WS3.2: duplicate harness with its own defect surface).

---

## dev-tools/ · reference→manifest derivation engine

The catalogue is the source of truth; manifests and per-category schemas are **generated artifacts** (never
hand-authored). Pipeline order: **Inventory → Discover → Build-Catalogue → Generate-Manifest → Build-PerCategorySchema**,
with Report/Tracker/Swap as auxiliaries.

| Tool | Role | Reads → Writes |
|---|---|---|
| `Inventory-References.ps1` | Scan `references/` (live · postman · openapi · xdrinternals · inventory) → per-Portal/Category/Operation coverage matrix. NEVER inherits a prior catalogue — derives from RAW at scan time. | `references/**` → `references/inventory/<portal>/categories.json` + per-Category `operations.json` + top-level `coverage-matrix.json` |
| `Discover-OperationFromRaw.ps1` | Per-Category candidate-Operation discovery + pilot ranking (live-row-count / method-simplicity / path-param / cadence / license weights). Honest gating — never fabricates behavioral fields. | `references/**` → ranked candidate list (stdout / pilot selection input) |
| `Build-EvidenceIndex.ps1` | Maps the consolidated live-capture corpus (`references/live/`) to catalogue OperationKeys → per-op evidence index (Fixture · ResponseShape · ItemsContainer · RowCount · SampleFields). The tier-1 SCHEMA feed that lifts ops to `LiveCaptured` with NO re-probe. | `references/live/` + inventory → `references/inventory/<portal>/evidence-index.json` |
| `Build-Catalogue.ps1` | v13 portal-GENERIC 6-stage engine (Extract → Classify → Dedupe → Depend → Decide → Map). Fresh-derives the catalogue from RAW for one group / one portal / all 20 portals. Handles heterogeneity (null OperationId → Method+Path key; per-category vs single inventory). | RAW (openapi x-tagGroups + inventory + live) → `references/inventory/<portalKey>/catalogue.json` |
| `Generate-Manifest.ps1` | v12 catalogue → per-GROUP manifest `.psd1` for `Status == Validated` Operations of a Category (runtime-consumed shape, incl. v12 `Subcategory`). Default output is a gitignored validation path; `-OutPath` lands into `manifests/` at P3. | `catalogue.json` → `manifests/<Portal>/<Category>.psd1` |
| `Build-PerCategorySchema.ps1` | Emits the per-Category workspace-table + DCR-stream schema JSON (envelope + typed columns) consumed by ARM injectors (table cols == DCR stream cols, set-equality enforced · axis 14). | catalogue / manifest → `deploy/per-category-schemas/<Portal>-<Category>.json` |
| `Report-Catalogue.ps1` | v13 coverage + mechanism-distribution report across all 20 catalogue.json (status coverage, pagination/timefilter/param shapes, telemetry-class split, v0.1/0.2/0.3 scope buckets). The references→functionality bridge. | all `catalogue.json` → report (stdout / `-WriteFile`) |
| `Update-OperationTracker.ps1` | Updates the gitignored operation-tracker (per-cycle status snapshot: PENDING/IN_PROGRESS/VERIFIED/REGRESSED, alpha-round, KQL row counts). | tracker state ↔ per-cycle status |

`dev-tools/.generated/` (e.g. `Operations.psd1`) is a gitignored scratch/validation output — not a runtime artifact.

> Note: `Update-OperationTracker.ps1` carries a stale `# tools/…` path comment in its header but physically lives in `dev-tools/`.

---

## tools/ · IMPLEMENTED (present in repo · verified)

### Pre-push / CI gates

| Tool | Purpose | Caller |
|---|---|---|
| `Run-PrePushGauntlet.ps1` | **THE pre-push gate · 38 axes.** All 38 offline-provable (parse/JSON/YAML/Analyzer/Pester/manifest/ARM/build/manifest+schema regen→diff/exactly-once replay) · NO deployed FA / Azure / network. Post-deploy KQL landing is a separate tool (`Verify-OperationLanding.ps1`). Non-zero exit on any axis BLOCKS push. | operator pre-push · CI |
| `Validate-Manifests.ps1` | Per-Operation §4.17 combined-evidence validation (schema + canonical naming + Provenance + JSONPath-resolves-against-lab-fixture). Emits Validated / Stub / Inactive; Inactive BLOCKS push. | CI · operator |
| `Validate-Scope.ps1` | Enforce active/excluded Category boundaries (advanced_hunting · alerts_incidents · live_response stay OUT). | CI · operator |
| `Validate-ArmCrossReferences.ps1` | Validate ARM template cross-references (stream ↔ table ↔ DCR ↔ appsetting wiring). | CI · operator |
| `hooks/Hook-PreCommit.ps1` | Git pre-commit · L1+L11+L12+L13 enforcement. | git hook |

### Build / package

| Tool | Purpose | Caller |
|---|---|---|
| `Build-FunctionAppZip.ps1` | Deterministic zip of `src/` + `manifests/` → `function-app.zip` (excludes `tools/` + `dev-tools/`). | CI · operator |
| `Build-SolutionPackage.ps1` | Sentinel V3 contentPackage zip for marketplace. | operator |

### Deploy-sync (Path-2 · incremental · non-destructive)

| Tool | Purpose | Caller |
|---|---|---|
| `Sync-ExistingDeployment.ps1` | **IMPLEMENTED.** Path-2 incremental ARM sync into the operator's EXISTING RG (non-destructive · cache-bust + incremental dependency chain · no FA bounce). Discipline: never `az group delete`, never `--no-wait` on destructive ops. | operator |
| `Sync-IncrementalCategory.ps1` | Phase E.4 autonomous Path-2 incremental per-Category onboard orchestrator (delegates to Sync-ExistingDeployment for the ARM incremental sync + post-onboard force-burst; the template is pre-assembled by Build-MainTemplate via Onboard-NextCategory). | operator · autonomous loop |
| `Onboard-NextCategory.ps1` | Per-Category onboarding orchestrator (evidence scoring → schema → ARM injection → verify). | operator · autonomous loop |

### Post-deploy verification

| Tool | Purpose | Caller |
|---|---|---|
| `Verify-OperationLanding.ps1` | **IMPLEMENTED.** 8-axis KQL gate for ONE Operation post-deploy (table exists · rows>0/1h · typed cols populated · RawJson valid · CorrelationId · Entry.Poll.Succeeded · Cycle.Completed · checkpoint row). | operator |
| `Verify-DeployedConnector.ps1` | Full deployed-connector KQL verification (per-Category typed-column population, LA-reserved rewrites, connector-definition presence). | operator · CI |
| `Test-GaReadiness.ps1` | **IMPLEMENTED.** Phase F GA-readiness gate · 9 explicit auto-conditions (plan §18.4) → GA-CANDIDATE; the 10th gate (operator "GA" word) is reported as awaiting confirmation. | operator |
| `Probe-FullChain-Local.ps1` | Local full-chain probe · `Invoke-XdrEntryPoll` on a manifest entry (real Defender poll + parse + DCE ingest) for end-to-end local validation. | operator |

---

## tools/ · NOT yet authored (referenced by plan · absent on disk)

These appear in the canonical plan but have **no file in the repo** as of 2026-06-04. Listed so the inventory does
not imply they exist; they will be authored when the per-Operation / per-Portal work surfaces the need.

| Tool | Phase | Purpose |
|---|---|---|
| `Validate-MarketplaceAssets.ps1` | 2 | Logo + SolutionMetadata + manifest validation. |
| `Verify-DeployedVersion.ps1` | 1.7+ | 3-layer HEAD = VFS = AppTraces SHA match. |
| `hooks/Hook-PrePush.ps1` | 1.7 | Git pre-push wrapper · runs the gauntlet. |
| `hooks/Lib-Hook-Common.ps1` | 1.7 | Shared hook helpers (path resolution · git state). |
| `Probe-DefenderAuth-Local.ps1` | 1 | Operator one-shot interactive Gate 1 KMSI seed (Defender). |
| `Probe-EntraAuth-Local.ps1` | v0.2 | Per-Entra KMSI seed (mirror of Defender pattern). |
| `Probe-IntuneAuth-Local.ps1` | v0.2 | Per-Intune KMSI seed. |
| `Probe-PurviewAuth-Local.ps1` | v0.2 | Per-Purview KMSI seed. |
| `Probe-SecurityCopilotAuth-Local.ps1` | v0.2 | Per-SecurityCopilot KMSI seed. |

---

## Methodology

Discipline rule (tools/runtime separation): tooling is SEPARATE from runtime. It:
- NEVER runs inside the Function App
- NEVER ships in `function-app.zip` (`Build-FunctionAppZip` excludes `tools/` and `dev-tools/`)
- Runs via operator CLI OR CI workflow
- Uses `.env.local` for credentials + estate (gitignored)

### `.env.local` estate variables (resolved when the matching flag is omitted)

The post-deploy + reset tools (`Run-PostDeployAudit`, `Run-PostDeployVerify`, `Confirm-PostDeploy`, `Save-XdrCheckpointReset`, …) self-resolve the estate from `.env.local` so the D-gates run with no manual flag. `.env.local` is gitignored — never commit a value.

| Variable | Resolves the flag | Used by |
| --- | --- | --- |
| `XDRLR_CONNECTOR_RG` | `-ResourceGroup` | all estate tools |
| `XDRLR_FUNCTION_APP` | `-FunctionApp` | deploy + verify + audit |
| `XDRLR_STORAGE_ACCOUNT` | `-StorageAccount` | checkpoint reset + the B3 cold-emit + the B9/B10 reset-row read |
| `XDRLR_WORKSPACE_ID` | `-WorkspaceId` (customerId GUID) | the B9-B11 KQL + the verify chain |
| `XDRLR_WORKSPACE_RESOURCE_ID` | `-WorkspaceResourceId` (ARM full resource id) | the **B6 D-gates** (`Run-PostDeployVerify`) + estate reconcile · resolving it is what un-blocks the B6 INCONCLUSIVE |

Per binding rule 5: NO new functions are added for variation. Tools wrap existing manifest/contract derivation
logic · they DO NOT introduce parallel implementation paths.

Per binding rule 8: every tool documents its provenance trace (which raw sources it reads · which outputs it
produces · which Phase introduced it).
