# Onboarding Runbook — one Category/Operation, end to end

Operator-facing checklist to onboard **ONE** Defender Category/Operation from scope-pick through
sustained verification. Worked example uses the live pilot: **Portal `Defender` · Category
`Operations` · Operation `GetHistory`** (table `Defender_Operations_CL`). Substitute your own
Category/Operation as needed.

All commands are run from the repo root with `pwsh`. The catalogue/manifest/schema are GENERATED
artifacts — never hand-edit them; re-run the generator. The 38-axis gauntlet (`tools/Run-PrePushGauntlet.ps1`)
is the single source of truth for "ready to push"; CI (`.github/workflows/ci.yml`) mirrors its
offline-provable subset (incl. the axis-28 regen→diff gate).

## Guardrails (read first — these override convenience)

- `az group delete` is **BANNED**. Never delete a resource group.
- `--no-wait` on destructive ops is **BANNED** (defeats interrupt). `--no-verify` / `--no-gpg-sign` /
  bare `--force` are **never** used.
- Push is **always** `git push --force-with-lease` (never bare `--force`).
- `AuthorizationFailed` is a **STOP**, not a retry.
- **Deploy / Path-2 sync / cache-bust steps (Phase 9+) require an explicit operator GO.** Phases 1-8
  (catalogue → push → CI) are repo-only and self-serviceable; nothing touches Azure until Phase 9.
- One commit per onboarded Category. HEREDOC commit message, **no AI-assistant attribution** (axis 8
  and the ci.yml anti-attribution gate block AI-vendor / co-author trailer strings in tracked files).

---

## Phase 0 — scope-pick

Pick exactly one Category (an OpenAPI `x-tagGroups` group) and the Operation(s) inside it. Confirm the
Operation is **portal-internal, read-only, no path-param** (the Filter 19/20/21 rules enforced later by
`tools/Validate-Scope.ps1`). The locked exclusions (Advanced Hunting · Alerts · Incidents · Live
Response) are never reverse-included.

- [ ] Category + Operation chosen, in scope, not on the exclusion list.

## Phase 1 — live-probe (capture the evidence that makes an Op `Validated`)

Behavioral fields (IngestionMode/Cadence/CursorField/NaturalKey/ProjectionMap) are emitted **only**
where a live fixture exists — otherwise the Op is `OpenApiDerived`/`StructuralOnly` and won't ship.
Capture a raw response from the portal's internal endpoint into
`references/live/source-xdrlograider-raw/` and register it in
`references/inventory/nodoc-defender-xdr/live-evidence.json` (keyed by OperationId, e.g.
`Operations.GetHistory`, with `Fixture`, optional `CursorField`/`NaturalKey`/`PageIndexStart`).

Optional helper to scaffold an Op record from a raw capture:

```powershell
pwsh dev-tools/Discover-OperationFromRaw.ps1   # inspect a raw fixture → proposed Op fields
```

- [ ] Raw fixture placed under `references/live/...` (the operator-local INTERNAL layer — untracked; never in the public tree) and wired into `live-evidence.json`. Tests/CI consume sanitized copies under `tests/fixtures/live/`.

## Phase 2 — catalogue (the source of truth)

Re-derive the catalogue from RAW (openapi x-tagGroups + inventory + live fixtures + live-evidence) for
the portal. The Op should land as **`Validated`** (live fixture present).

> Tier-1 schema also comes from the consolidated live-capture corpus: `dev-tools/Build-EvidenceIndex.ps1`
> maps `references/live/` → `evidence-index.json`, lifting captured ops to **`LiveCaptured`** (true schema from
> the real response · NO re-probe). `live-evidence.json` is the narrower behavioral-proof source that promotes
> the one chain-proven Op to `Validated`. Status precedence: `Validated` > `LiveCaptured` > `OpenApiDerived` > `StructuralOnly` (`Excluded` overrides).

```powershell
# Preview (stdout) for one group:
pwsh dev-tools/Build-Catalogue.ps1 -Portal Defender -Group Operations

# Write the catalogue.json for the whole portal (all groups):
pwsh dev-tools/Build-Catalogue.ps1 -Portal Defender -WriteFile
```

Writes `references/inventory/nodoc-defender-xdr/catalogue.json`. The summary line prints
`V=<validated> O=<openapi> S=<structural> X=<excluded>` — confirm your Op is in `V`. Optional report:
`pwsh dev-tools/Report-Catalogue.ps1`.

- [ ] `catalogue.json` regenerated · target Op shows Status `Validated`.

## Phase 3 — generate (manifest → per-Category schema → ARM injection)

These three are **generated** from the catalogue/manifest. `Generate-Manifest` keys on `-Group`; the
schema/ARM tools key on `-Category` (same value, e.g. `Operations`).

```powershell
# 3a · manifest (catalogue → manifests/Defender/Operations.psd1)
pwsh dev-tools/Generate-Manifest.ps1 -Portal Defender -Group Operations `
    -OutPath manifests/Defender/Operations.psd1

# 3b · per-Category DCR + workspace-table schema + nested-deployment ARM block
pwsh dev-tools/Build-PerCategorySchema.ps1 -Portal Defender -Category Operations -OutputMode Both
#   → deploy/per-category-schemas/Defender-Operations.json
#   → deploy/per-category-schemas/Defender-Operations-nested-deployment.json

# 3c · assemble deploy/mainTemplate.json from foundation.json + ALL per-category-schema artifacts (the SOLE writer ·
#      idempotent byte-stable rebuild). Emits, per shipped category: the workspace table + DCR + scoped Monitoring
#      Metrics Publisher role (FA SAMI -> DCR) + connector card + FA appSetting.
#      NOTE: ALWAYS regenerate via Build-MainTemplate — it is the SOLE writer and emits the per-DCR role (an earlier
#      per-category injector pattern omitted it, so a 2nd category's DCR 403'd the FA SAMI -> silent 0 rows). Gauntlet
#      axis 36 enforces deploy/mainTemplate.json == a fresh Build-MainTemplate rebuild.
pwsh dev-tools/Build-MainTemplate.ps1
#   → deploy/mainTemplate.json  (rebuilt from foundation.json + every deploy/per-category-schemas/<Portal>-<Category>.json)
```

- [ ] `manifests/Defender/Operations.psd1` regenerated (NOT hand-edited).
- [ ] per-Category schema JSON + nested-deployment JSON written.
- [ ] `mainTemplate.json` extended with the Category's nested deployment.

## Phase 4 — validate (manifest schema + scope filters)

```powershell
pwsh tools/Validate-Manifests.ps1     # §4.17 evidence pipeline · exit 0 = all Validated/Stub · 1 = Inactive (blocks)
pwsh tools/Validate-Scope.ps1 -Portal Defender -Category Operations   # Filter 19/20/21 · exit 0 = all IN scope
```

- [ ] `Validate-Manifests` exit 0 · ≥1 Validated · 0 Inactive.
- [ ] `Validate-Scope` exit 0 · 0 BLOCKING.

## Phase 5 — 38-axis pre-push gauntlet (BLOCKING)

The full local gate. Axis 28 is the **regen→diff keystone**: it re-runs `Generate-Manifest` from the
committed catalogue and asserts the result equals the committed `manifests/Defender/Operations.psd1`
(line-ending-normalized) — proving the manifest was generated, not hand-edited. Axis 30 mirrors it for the
per-Category schema (Build-PerCategorySchema regen→diff). Axis 29 is the exactly-once OFFLINE replay (parsed
live fixture rows == distinct ActionId). Axis 14 enforces DCR↔table↔per-Category-schema set-equality; axes
4/15 mirror the Pester + PSScriptAnalyzer CI steps.

```powershell
pwsh tools/Run-PrePushGauntlet.ps1    # prints "=== PRE-PUSH GAUNTLET · N passed · M failed of 38 axes ===" · exit = M
```

- [ ] Gauntlet exits **0** (all 38 axes pass). If axis 28 fails → manifest drifted from catalogue:
      re-run Phase 3a, do not hand-edit.

## Phase 6 — ONE commit (HEREDOC · no attribution)

Branch off `main` first if not already on a feature branch. Stage the catalogue + manifest + schema +
ARM + any reference fixtures, and commit with a single HEREDOC message (no AI-assistant attribution /
no co-author trailer line).

```bash
git checkout -b onboard-operations    # if not already on a working branch
git add references/ manifests/ deploy/ docs/
git commit -F - <<'MSG'
Onboard Defender/Operations (GetHistory) end-to-end

Catalogue-derived manifest + per-Category DCR/table schema + mainTemplate
nested deployment. Validated via 38-axis gauntlet (incl. axis-28 manifest + axis-30 schema regen->diff).
MSG
```

- [ ] Exactly one commit · no attribution strings.

## Phase 7 — push --force-with-lease + retag

```bash
git push --force-with-lease origin onboard-operations    # NEVER bare --force
```

If cutting a pre-GA release for the deploy phase, (re)tag and push the tag — release.yml triggers on
`v[0-9]+.[0-9]+.[0-9]+*`. Pre-GA tags contain a hyphen (e.g. `v0.1.0-alpha-3`) and are published as
**prerelease** (the `/releases/latest/` pointer stays reserved for GA):

```bash
git tag -f v0.1.0-alpha-3 && git push --force-with-lease origin v0.1.0-alpha-3
```

- [ ] Branch pushed with `--force-with-lease`.
- [ ] (If releasing) tag pushed.

## Phase 8 — CI green

- **`ci.yml`** (`offline-gauntlet` job): L1 parse · gitleaks · PSScriptAnalyzer · Pester (Tier-1) ·
  Validate-Manifests · ARM-TTK · Build-FA · anti-attribution · anti-bloat · **regen-gate** (mirrors
  pre-push axis 28: regenerates `manifests/Defender/Operations.psd1` from the committed catalogue and
  fails on drift).
- **`release.yml`** (on tag): Build-FA + Build-SolutionPackage + SBOM + cosign + SHA256SUMS + GitHub
  release (prerelease for hyphen tags).

- [ ] `ci.yml` green on the PR/branch.
- [ ] (If releasing) `release.yml` green · release assets published for the tag.

> **STOP — everything below touches Azure. Get explicit operator GO before proceeding.**

## Phase 9 — Path-2 incremental sync + cache-bust  *(operator GO required)*

Non-destructive incremental ARM deploy that adds **only** the new Category's nested block (table + DCR +
connector metadata), then pins the FA at the new release zip and restarts it. Needs
`parameters.local.json` (gitignored) + `.env.local` SP creds + the connector RG.

```powershell
# Dry run first (no Azure changes):
pwsh tools/Sync-IncrementalCategory.ps1 -Category Operations -ResourceGroup xdrlograider `
    -ReleaseTag v0.1.0-alpha-3 -WhatIfMode

# Live sync (az deployment group create --mode Incremental · appsettings WEBSITE_RUN_FROM_PACKAGE · restart · confirm state=Running · checkpoint-reset marker):
pwsh tools/Sync-IncrementalCategory.ps1 -Category Operations -ResourceGroup xdrlograider `
    -ReleaseTag v0.1.0-alpha-3
```

Optionally force the first burst so the new Op fires immediately instead of waiting for natural cadence:

```powershell
pwsh tools/Force-XdrFullCycle.ps1 -ResourceGroup xdrlograider -OperationKey GetHistory
```

- [ ] WhatIf preview reviewed.
- [ ] Incremental sync succeeded · FA `state=Running` confirmed (no `--no-wait`).

## Phase 10 — post-deploy verify (content gates + exactly-once)  *(operator GO required)*

Run the **Cold** window first (data lands), then **FirstIteration** after a forced burst. The
FirstIteration/Sustain windows include the D8 content sub-gates — **D8c** (5 envelope cols populated),
**D8f** (every typed ProjectionMap col has ≥1 non-null row — the keystone "actual events per
requirements" gate), **D8g** (LA-reserved rewrite e.g. `EndTime→EndTime_x` fires), **D8h** (serialized
non-scalars `RelatedEntitiesJson`/`AdditionalFieldsJson` parse as JSON).

```powershell
# Cold window (≥1 row · D2/D6/D9 · no empties):
pwsh tools/Verify-DeployedConnector.ps1 -WorkspaceId <customerId-or-ARM-id> `
    -Portal Defender -Category Operations -Window Cold

# After Force-XdrFullCycle · strict per-Op first-iteration (incl D8c/D8f/D8g/D8h + CorrelationId):
pwsh tools/Verify-DeployedConnector.ps1 -WorkspaceId <customerId-or-ARM-id> `
    -WorkspaceResourceId <workspace-ARM-id> `
    -Portal Defender -Category Operations -Window FirstIteration
#   exit 0=GREEN · 1=advisory · 2=BLOCKING (data integrity) · 3=tool error

# Per-Operation 8-axis landing gate (table/rows/typed-cols/RawJson/CorrelationId/poll/cycle/checkpoint):
pwsh tools/Verify-OperationLanding.ps1 -WorkspaceId <customerId> `
    -Portal Defender -Category Operations -OperationKey GetHistory
```

**Exactly-once** is verified two ways: (1) the committed T1 contract test
`tests/unit/Xdr.Common.Runtime/ExactlyOnce.Tests.ps1` + replay
`tests/replay/Defender/Operations/GetHistory.Tests.ps1` (run by Pester in axis 4 / ci.yml), proving the
client-side high-water + boundary natural-key (`ActionId`) set produces no rewind/overlap; and (2)
post-deploy gate **D1** (`sum(ItemCount) == count(rows)` per (Op,CId)) + **D3** (exactly 1
Started + 1 Succeeded|Failed per poll) in the Hour/Sustain windows.

- [ ] Cold window GREEN (≥1 row · D2/D6/D9 pass).
- [ ] FirstIteration GREEN — **D8c/D8f/D8g/D8h** pass, CorrelationId populated.
- [ ] D1 + D3 pass (exactly-once at the data plane).

## Phase 11 — sustain windows  *(operator GO required)*

Let it run and re-verify at widening windows. GA-readiness needs **≥3 consecutive Sustain passes**.

```powershell
pwsh tools/Verify-DeployedConnector.ps1 -WorkspaceId <customerId> -WorkspaceResourceId <ws-arm-id> `
    -Portal Defender -Category Operations -Window Hour
pwsh tools/Verify-DeployedConnector.ps1 -WorkspaceId <customerId> -WorkspaceResourceId <ws-arm-id> `
    -Portal Defender -Category Operations -Window Sustain        # DLQ=0 · AppExceptions=0 · cadence stable
pwsh tools/Verify-DeployedConnector.ps1 -WorkspaceId <customerId> -WorkspaceResourceId <ws-arm-id> `
    -Portal Defender -Category Operations -Window ConsecutiveSustain   # GA gate (≥3 Sustain passes)
```

- [ ] Hour window GREEN.
- [ ] ≥3 consecutive Sustain windows GREEN (cadence stable · DLQ=0 · AppExceptions=0).

## Phase 12 — next

Return to Phase 0 for the next Category/Operation. Re-running `Build-Catalogue -WriteFile` +
`Generate-Manifest` keeps every prior Category intact (the catalogue is whole-portal; the manifest is
per-group). The 38-axis gauntlet + the ci.yml regen-gate guarantee no Category drifts from its
catalogue source as you add more.

- [ ] Next Category selected · repeat from Phase 0.
