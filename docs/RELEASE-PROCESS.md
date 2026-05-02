# Release process

How v1.x releases are cut.

## Pre-release checklist

- [ ] **All offline tests pass** — `pwsh ./tests/Run-Tests.ps1 -Category all-offline` returns the current pass count (1450+ as of v0.1.0-beta) with 0 fail
- [ ] **PSScriptAnalyzer 0 errors** — `Invoke-ScriptAnalyzer -Path ./src, ./tools, ./tests -Recurse -Settings ./.config/PSScriptAnalyzerSettings.psd1 | Where-Object Severity -eq 'Error'` is empty
- [ ] **ARM validate PASS** — `pwsh ./tools/Validate-ArmJson.ps1`
- [ ] **Preflight PASS** — `pwsh ./tools/Preflight-Deployment.ps1 -SkipOnline` reports `PRE-DEPLOY READY: YES`
- [ ] **what-if green** — `pwsh -Command "Invoke-Pester -Path tests/integration/Deployment-WhatIf.Tests.ps1"` reports 1/0 (preventive Azure RP semantic gate; needs SP creds in `tests/.env.local`)
- [ ] **CI green on `main`** — the latest `ci.yml` run is ✓
- [ ] **ARM is single source of truth** — `deploy/compiled/mainTemplate.json` is hand-authored; no Bicep compile or auto-generation. Bicep reference (if used during dev) lives gitignored at `.internal/bicep-reference/`.
- [ ] **Sentinel content rebuilt** — `pwsh ./tools/Build-SentinelContent.ps1` produces the committed `sentinelContent.json` deterministically
- [ ] **CHANGELOG.md** — the `[Unreleased]` section is populated with the changes in this release
- [ ] **Docs up-to-date** — no TODO markers; no references to deleted paths
- [ ] **No portal-endpoint-broken open issues** tagged as blocking
- [ ] **(Recommended)** Pre-deploy local-online test green against your own test tenant — `pwsh ./tests/Run-Tests.ps1 -Category local-online`

## Cut release

1. Update `CHANGELOG.md`: rename the `[Unreleased]` header to `[X.Y.Z] — YYYY-MM-DD`
2. Commit the changelog bump: `git commit -am "chore: prepare vX.Y.Z"`
3. Tag + push: `git tag vX.Y.Z && git push && git push origin vX.Y.Z`
4. **`.github/workflows/release.yml` fires automatically** on the tag push:
   - Runs PSScriptAnalyzer + Pester gate (same as CI)
   - Runs `tools/Validate-ArmJson.ps1` (the hand-authored ARM is the artefact — no Bicep compile)
   - Runs `tools/Build-SentinelContent.ps1` → fresh `sentinelContent.json`
   - Runs `tools/Build-SentinelSolution.ps1 -Version X.Y.Z` → `xdrlograider-solution-X.Y.Z.zip`
   - Packs `src/` → `function-app.zip`
   - Creates GitHub Release with **5 attached artefacts**:
     - `function-app.zip`
     - `mainTemplate.json`
     - `sentinelContent.json`
     - `createUiDefinition.json`
     - `xdrlograider-solution-X.Y.Z.zip`
   - Generates SBOM and attaches as `xdrlograider-sbom-X.Y.Z.spdx.json`
   - Release body includes the Deploy-to-Azure badge pinned to the release URLs

## Post-release

1. **Verify Release page** shows all 6 assets with correct sizes
2. **Test Deploy-to-Azure button** on a clean non-prod subscription with a real Sentinel workspace
3. **Run the helper**: `./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-output>`
4. **Wait 5 min**, verify `App Insights customEvents.Success=true`
5. **Run post-deploy e2e** from your laptop:
   ```powershell
   Connect-AzAccount
   $env:XDRLR_ONLINE = 'true'
   $env:XDRLR_TEST_RG = 'xdrlr-prod-rg'
   $env:XDRLR_TEST_WORKSPACE = 'your-workspace-name'
   pwsh ./tests/Run-Tests.ps1 -Category e2e
   ```
6. **Update Discussions / announcement channels** with release notes + feedback request

## Hotfixes

For urgent security fixes:

1. Branch from the latest tag: `git checkout -b hotfix/vX.Y.Z+1 vX.Y.Z`
2. Fix + commit
3. Merge to `main` via PR
4. Tag `vX.Y.Z+1` from `main`
5. CI releases the patch

## Versioning policy (semver)

- **Major (X.0.0)**: breaking changes — schema, auth, deployment topology, dropped streams
- **Minor (X.Y.0)**: new streams, new workbooks, new auth paths (backwards-compatible)
- **Patch (X.Y.Z)**: bug fixes, security patches, docs

## CI matrix

The `ci.yml` workflow runs on **Ubuntu-only** (production-parity with the Linux-based Function App Consumption plan). Cross-platform support is not required for a server-side Sentinel connector. If a Linux-specific regression is ever suspected, re-enable the matrix via `workflow_dispatch` — the template is preserved in git history.
