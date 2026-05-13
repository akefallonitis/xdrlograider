# Contributing

This is operator + contributor documentation. For end-user "how do I deploy", see [README.md](README.md).

## Local dev quick-start

```powershell
# Run the full offline gate (mirrors what CI runs)
pwsh ./tests/Run-Tests.ps1 -Category all-offline      # 165 mocked Pester tests · 20% coverage gate

# Run the 5 generators (deterministic — must produce byte-identical output)
pwsh ./tools/Build-Manifest.ps1
pwsh ./tools/Build-DcrJson.ps1
pwsh ./tools/Build-FunctionApp.ps1                     # verifier (4 Durable dirs are hand-authored)
pwsh ./tools/Build-ArmTemplate.ps1
pwsh ./tools/Build-SentinelSolution.ps1
pwsh ./tools/Test-Determinism.ps1                      # all 5 byte-identical across two runs

# Lint + validate
pwsh ./tools/Validate-Manifest.ps1                     # 493 entries · 18 sub-areas
pwsh ./tools/Validate-ArmJson.ps1                      # 19 DCRs · 3 RAs · resource count

# Coverage gap analysis (per-file uncovered counts)
pwsh ./tools/Show-CoverageGaps.ps1
```

## CI workflows

### `ci.yml` — quality gate on every push + PR

Triggers: push to `main`, PR to `main`, manual `workflow_dispatch`.

| Job | What it does |
|---|---|
| `gitleaks` | Secret scan; allowlist in [`.gitleaks.toml`](.gitleaks.toml) (Azure role GUIDs are public-knowledge; references/_phase0_archive/) |
| `psscript-analyzer` | PowerShell lint via PSScriptAnalyzer + repo settings ([`.config/PSScriptAnalyzerSettings.psd1`](.config/PSScriptAnalyzerSettings.psd1)) |
| `unit-tests` | Pester 5.5+ runs all 3 test categories: `unit/`, `arm/`, `kql/`. 165 tests · 24.11% coverage > 20% gate (hard-fail per Rule 18) |
| `static-validate` | ARM-TTK lint (warning-only for v0.1.0 — see below) + `Validate-ArmJson.ps1` + `Validate-Manifest.ps1` (both hard-fail) |
| `auto-regenerate-gate` | Runs the 5 generators on the runner + `git diff` against committed files. Hard-fail on any byte drift (catches non-deterministic generators + missed regenerations) |
| `summary` | Aggregates per-job results; fails the run if any of the above failed |

#### ARM-TTK known-state

ARM-TTK is configured **warning-only** for v0.1.0 (`Test-AzTemplate` calls are wrapped in `try/catch`; non-passing tests are surfaced via `Write-Warning`, not `throw`). Substantive deploy correctness is covered by `Validate-ArmJson.ps1` + the `tests/arm/` Pester suite, both hard-fail.

Two ARM-TTK tests are explicitly `-Skip`-ed because they cannot pass on this codebase without a Microsoft API change:

| Skipped test | Reason |
|---|---|
| `apiVersions Should Be Recent` | `Microsoft.Insights/dataCollectionRules` + `dataCollectionEndpoints` have no stable API version newer than `2023-03-11`. The 730-day rule will increasingly fail on these types until Microsoft ships a newer stable. |
| `apiVersions Should Be Recent In Reference Functions` | Same root cause, applied to inline `reference()` / `listKeys()` calls in `appSettings`. |

Other ARM-TTK findings remain (e.g. `Depends On Must not start with [concat(` on the customTables nested deployment) — tracked for v0.1.x incremental cleanup; not blocking the v0.1.0 release.

### `release.yml` — build, sign, publish on tag

Two trigger paths:

| Trigger | How to use |
|---|---|
| **Push a `v*` tag** | `git tag v0.1.1 -m "v0.1.1" && git push origin v0.1.1` |
| **GitHub Actions UI** (`workflow_dispatch`) | Repo → Actions → release → Run workflow → enter `version: v0.1.1` (and optional `ref:`, default `main`). Workflow creates the tag, then runs the same build path. |

Job steps:

1. Checkout the ref (manual dispatch can override default `main`)
2. Resolve version + (manual path only) create + push the tag
3. Install pinned Az modules into `src/Modules/` (`Az.Accounts 5.4.0` · `Az.KeyVault 6.4.3` · `Az.Storage 7.5.0`) — Linux Consumption Y1 does not support `requirements.psd1` managed dependencies, so modules ship inside the zip
4. Build all 5 generators (manifest · DCRs · ARM · function-app verify · sentinel solution)
5. Package `function-app.zip` from `src/` (hard-fail at >200 MB; FA SKU limit)
6. Stage ARM artifacts (`mainTemplate.json` · `createUiDefinition.json` · `parameters.json` · `sentinelContent.json`) into `dist/`
7. Generate SBOM (SPDX) via `anchore/sbom-action`
8. **Cosign keyless OIDC sign** each artifact via the runner's built-in OIDC token → Sigstore Fulcio short-lived cert + Rekor transparency log entry. No Service Principal, no Entra federated cred, no Key Vault, **zero operator setup**
9. Publish GitHub Release with 16 assets: `function-app.zip` · `mainTemplate.json` · `createUiDefinition.json` · `parameters.json` · `sentinelContent.json` · `sbom.spdx.json` + `.sig` + `.cert` for each (except parameters.json which is reproducible from the template)

Verify any released artifact:

```bash
cosign verify-blob --certificate <file>.cert --signature <file>.sig <file>
```

### `validate-solution.yml` — Sentinel V2 schema guard

Triggers: PR touching `deploy/sentinelContent.json` · `deploy/solution/**` · `tools/Build-SentinelSolution.ps1` · manual dispatch.

Single job runs `tests/arm/SentinelContent.MinimalLock.Tests.ps1` which locks the **Phase 1 ship shape** of the Sentinel solution:

- Exactly 1 `contentPackage` resource (`community.xdrlograider`, version `0.1.0`)
- Exactly 1 `dataConnector` resource (kind `GenericUI`, title `XdrLogRaider`)
- **No** analytic rules · workbooks · hunting queries · parsers (deferred v0.3.0)
- 19 `dataTypes` (18 `Defender_<Sub>_CL` + 1 `XdrConnectorHealth_CL`)
- `connectivityCriteria` is the freshness-signal KQL (`XdrConnectorHealth_CL | where TimeGenerated > ago(15m) | take 1`), **not** a `CardState`-column filter
- ≥ 5 sample queries with description + query body
- File ≤ 30 KB

## Releasing a new version

1. Make sure `main` is green (CI passes on the head commit you want to release).
2. Pick a version: SemVer, prefixed `v` (e.g. `v0.1.1`).
3. **Option A — UI:** Repo → Actions → release → Run workflow → version: `v0.1.1` → Run. The workflow creates the tag and publishes the release.
4. **Option B — CLI:**
   ```bash
   git tag -a v0.1.1 -m "v0.1.1"
   git push origin v0.1.1
   ```
   The tag push fires `release.yml` automatically.
5. Watch the run on the Actions tab. ~3 minutes end-to-end. Resulting GitHub Release shows up under `Releases`.

The `Deploy to Azure` button in [README](README.md) always points at `main`'s `mainTemplate.json` + `createUiDefinition.json` and uses `releaseTag=latest` by default — operators get the most recent published release.

## Sentinel Content Hub submission (deferred)

`deploy/sentinelContent.json` is the ARM `dataConnector` definition deployed on the operator's workspace. It is **not** a Content Hub catalog listing. Catalog inclusion is a separate maintainer workflow:

1. Build a Content Hub solution package (different file layout — uses Microsoft's `createSolutionV3.ps1` against an inputs JSON)
2. Open a PR to [`Azure/Azure-Sentinel`](https://github.com/Azure/Azure-Sentinel) under `Solutions/XdrLogRaider/`
3. Microsoft reviews + merges + publishes to Sentinel Content Hub

On the roadmap (v0.4.0 — operator docs phase). Operators today install directly via the `Deploy to Azure` button.

## Style + invariants

- No `V2` / `ClientV2` / `AuthV2` suffixes anywhere in shipped artifacts
- No AI / "Generated with" attribution
- Deterministic generators (CI's `auto-regenerate-gate` enforces this)
- Memory rules + plan + decisions are in `references/PHASE_0.md` + `.claude/plans/`

## Pull requests

PRs to `main` must pass `ci.yml` (6 jobs, all green) and — if they touch the Sentinel solution — `validate-solution.yml`. Branch protection on `main` is **off** right now; flipping back on is a maintainer decision.
