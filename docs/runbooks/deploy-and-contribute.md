# Runbook · Deploy + Contribute (the two-path model)

## Path A · PUBLIC one-click (customers / fresh installs)
README **Deploy to Azure** button → signed `deploy/mainTemplate.json` + `deploy/createUiDefinition.json`.
Creates everything: FA (Y1, SAMI, PS 7.4) · Key Vault · Storage (state tables pre-provisioned — the runtime
never creates storage) · DCE · per-category DCR + workspace table · Sentinel V3 connector card · ALL role
assignments (roles exist ONLY here — no tool ever creates or deletes them ad-hoc). The form collects the
service-account UPN + TOTP seed or Passkey PEM (straight into KV). Verify after: connector card connected +
`tools/Verify-DeployedConnector.ps1 -AllOps`.

## Path B · INTERNAL iteration (this repo's loop · NEVER full-redeploy)
Update/override/sync only the changed component:
| Changed | Tool | Touches | Never touches |
|---|---|---|---|
| FA code (LAB-ONLY) | `tools/Deploy-FaPackageLocal.ps1` (blob+SAS repoint) — a fast dev/lab iteration aid ONLY | RUN_FROM_PACKAGE, XDRLR_GIT_COMMIT_SHA | KV, ARM, roles, other settings |
| FA code (SHIP) | `tools/Sync-IncrementalCategory.ps1 -SkipArm` — repoints `WEBSITE_RUN_FROM_PACKAGE` to the **signed GitHub release** asset (provenance = live build == signed asset == HEAD). The PUSH-FIRST lock forbids side-loaded blob-SAS for anything shipped. | RUN_FROM_PACKAGE→release, XDRLR_GIT_COMMIT_SHA | KV, ARM, roles, other settings |
| Table/DCR schema | `tools/Onboard-CategorySurgical.ps1` (what-if hard-asserts ZERO KV/FA changes → ARM Incremental) | category table+DCR (+its role at first create), appsetting MERGE post-deploy | foundation, existing categories |
| Release-pointed sync | `tools/Sync-IncrementalCategory.ps1` → `Sync-ExistingDeployment.ps1` | ARM incremental + RUN_FROM_PACKAGE → release zip + checkpoint reset | KV, foundation |
| Estate drift | `tools/Sync-LiveEstate.ps1` (WS4) — schema-delta via `Assert-LiveSchemaParity` BLOCKING + stale-component report | additive fixes via surgical path | deletes (operator word only), roles (never) |

Appsettings are always **merged** (`az functionapp config appsettings set`), never ARM-replaced (ARM PUT
replaces the whole collection — multi-category state would be lost).

### Re-baseline decision (A7 · checkpoint vs table state — run at every redeploy that touches state)
Exactly-once across a deploy holds **only** when the checkpoint matches the table. Decide BEFORE starting the FA:
| State after the deploy | Action |
|---|---|
| Checkpoints SURVIVED (code-only `-SkipArm` sync) | Nothing — the live frontier continues exactly-once (the normal SHIP path). |
| Checkpoints ABSENT/reset · table NON-EMPTY · rows are GOOD | **Frontier-seed**: `tools/Sync-LiveEstate.ps1 -Apply` — adopts max(EventTime) per op from KQL as the cursor; forward-only, no re-ingest. (The runtime canonicalises any parseable seed shape at read — `99ec4d6`.) |
| Table rows are BAD/duplicated (re-baseline after a data-integrity fix) | **Purge-first**: stop FA → LA purge of the category table (rollback runbook) → `tools/Save-XdrCheckpointReset.ps1` → start FA → clean re-ingest. NEVER cold-start over a non-empty table (full re-emit = mass duplicates). |

Post-cutover burst: `tools/Force-XdrFullCycle.ps1` (clears `LastUpdatedUtc` only — force-without-rewind; the
frontier is never touched) → verify `Entry.CadenceNotDue.Skipped` is absent for the forced op(s).

## Adding a category (the contributor model — coverage is DATA, zero engine edits)
1. Curate: edit `references/inventory/<portal>/curation.json` (valueClass / shipHold / cadence tiers). Categories
   are ALWAYS the nodoc `x-tagGroups` — never invented, never overridden (operator-locked 2026-06-11).
2. Regen (OPERATOR-RUN, never CI): `dev-tools/Build-Catalogue.ps1 -Portal <p> -WriteFile` → review the diff
   (catalogue is the SSOT; gauntlet axes 28/30/32 prove regen determinism).
3. Onboard: `tools/Onboard-NextCategory.ps1 -Portal Defender -Category <C>` — emits the manifest, the
   per-category schema, injects the nested deployment + `XDRLR_DCR_DEFENDER_<C>` appsetting wiring, and the
   replay-test scaffold. Category names in curation must be space-free (table/manifest naming).
4. Gates: full gauntlet (38 axes) + Pester green → surgical deploy → `Assert-LiveSchemaParity` →
   `Verify-DeployedConnector -AllOps` POPULATED per op → human reads rows vs the corpus reference.
5. Evidence rules: behavioral fields derive from the corpus waterfall (live > postman > openapi, EvidenceTier
   recorded, ZERO fabrication). An evidence-poor op ships envelope+RawJson and self-heals: its first landed
   RawJson IS the live evidence → extract fixture → regen → surgical schema-delta adds typed columns.
6. `references/live/` is the operator-local INTERNAL layer (untracked). Tests/CI consume sanitized fixtures
   under `tests/fixtures/live/`. Anything tracked must match `tools/public-allowlist.txt` (axis 35).

## Releases (WS6+)
Semver tag push → `release.yml` → 8 cosign-signed artifacts (function-app.zip, solution zip, SBOM, SHA256SUMS,
each + .cosign.bundle). GA: the one-click ARM default derives the version-pinned `releases/download/v<connectorVersion>/function-app.zip`; sync an existing FA to a specific build via `Sync-ExistingDeployment.ps1`. Verify chain:
artifact SHA == `Boot.VersionProbe` == HEAD (`tools/Verify-DeployedVersion.ps1`).
