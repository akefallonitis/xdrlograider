# Contributing to XdrLogRaider

Thanks for your interest in contributing. This project is community-driven and open to PRs of any size from day one.

## Architecture: ARM-only single source of truth

XdrLogRaider ships `deploy/compiled/mainTemplate.json` as the canonical, hand-authored ARM template.

- The Deploy-to-Azure URL pulls this file directly.
- There is no Bicep auto-compilation. ARM is the only deployment artefact.
- When fixing bugs or adding features, edit `mainTemplate.json` directly.
- This pattern matches Microsoft's own `Azure/Azure-Sentinel/Solutions/` repository.

## Quick links

- [Good first issues](https://github.com/akefallonitis/xdrlograider/labels/good%20first%20issue) — curated starter tasks
- [README — per-version table](README.md#-roadmap) — v0.2.0+ scope at a glance
- [References](docs/REFERENCES.md) — background reading before diving in
- [Architecture](docs/ARCHITECTURE.md) — high-level component overview

## Development setup

### Prerequisites

- PowerShell 7.4+ (Windows, Linux, or macOS)
- Azure CLI 2.50+ or `Az.Resources` PowerShell module (for ARM template what-if + deploy testing)
- [Pester](https://pester.dev/) 5.0+ (`Install-Module Pester -Force -Scope CurrentUser`)
- [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) (`Install-Module PSScriptAnalyzer -Force -Scope CurrentUser`)

### Clone and bootstrap

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
pwsh tools/Install-GitHooks.ps1   # installs commit-msg + pre-commit hooks (BINDING per Section R)
./tests/Run-Tests.ps1 -Category unit
```

All unit tests should pass. If not, open an issue with the failing output.

> **Hooks installed by `Install-GitHooks.ps1`**:
> - **commit-msg** — appends AI-attribution block when applicable
> - **pre-commit** — runs `tools/Pre-Commit-Check.ps1` (chains pyramid + WiringAudit + Validate-ArmJson + Validate-Manifest + Audit-DcrSchema + PSScriptAnalyzer; runtime ~6-8 min). Identical gates as CI server-side; eliminates "passes locally / fails in CI" cycles.

## Local test loop

```powershell
# Fast: unit tests only (<1 min, fully mocked)
./tests/Run-Tests.ps1 -Category unit

# Static validation: KQL + workbooks + ARM (<30s)
./tests/Run-Tests.ps1 -Category validate

# Everything offline (what CI runs)
./tests/Run-Tests.ps1 -Category all-offline

# Live integration (requires test tenant + env vars)
$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_KV = 'test-kv-name'
./tests/Run-Tests.ps1 -Category integration
```

## Coding standards

### PowerShell

- PowerShell 7+ only — no Windows PowerShell 5.1 compatibility required
- Cmdlet names use approved verbs (`Get-Verb` to check)
- Every public function has comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`)
- Use `$script:` scope for module state, never global variables
- No `Write-Host` in module code — use `Write-Verbose`, `Write-Warning`, `Write-Error`
- Structured errors: `Write-Error -ErrorRecord $_` or `throw [System.Exception]::new(...)`

### Naming

- Modules: `Xdr.Portal.Auth`, `XdrLogRaider.<Component>`
- Tables (Log Analytics): `MDE_<Category>_CL` (all portal-only telemetry)
- Heartbeat/diagnostic tables: `XdrConnectorHealth_CL`, `MDE_AuthTestResult_CL`
- KQL parsers (functions): `MDE_Drift_P<N><Category>`
- Workbooks: `MDE_<Purpose>Dashboard.json`
- Analytic rules: `MDE_<Event>_Detection.json`

### KQL

- Parsers as `.kql` files in `sentinel/parsers/` — one parser per file
- Always test against fixture snapshots in `tests/fixtures/sample-snapshots/`
- Include a `// SYNOPSIS:` comment at the top of each file
- Default time windows: 24h for workbook defaults, explicit `ago()` for rules

### ARM template

- `deploy/compiled/mainTemplate.json` is hand-authored (single source of truth)
- Parameterize everything — no hard-coded names, sizes, or regions
- Always provide parameter `metadata.description` strings
- Use `allowedValues` for enumerated values
- ARM `outputs` expose post-deploy values operators need (KV name, DCE endpoint, DCR immutable IDs, postDeployCommand)
- Cross-RG / cross-subscription nested deployments via `Microsoft.Resources/deployments` with explicit `subscriptionId` + `resourceGroup`

## Adding a new telemetry stream

Follow this checklist when proposing a new `MDE_*_CL` stream:

1. **Research & justify** — file a `new_stream_request` issue first with:
   - Endpoint path (e.g., `/api/ine/...`)
   - Why public Graph/Defender/MDE APIs don't cover it
   - Sample response JSON (redacted)
   - Proposed table name + schema
   - Proposed cadence tier (P0-P7)
2. **Add endpoint wrapper** in `src/Modules/XdrLogRaider.Client/Endpoints/`
3. **Add table schema** in `schemas/tables/`
4. **Add DCR stream** to `schemas/dcr-streams.json`
5. **Add custom-table resource** in `deploy/compiled/mainTemplate.json` under the `customTables-*` nested deployment (template.resources, alongside the existing `Microsoft.OperationalInsights/workspaces/tables` entries — preserve schema shape: `name = [concat(parameters('workspaceName'), '/MDE_X_CL')]`, `properties.plan = 'Analytics'`, `properties.schema.columns[]` typed)
6. **Register in tier poller** — add to `src/functions/poll-<tier>/run.ps1` endpoint list
7. **Add fixture snapshot** for drift testing in `tests/fixtures/sample-snapshots/`
8. **Add drift-parser coverage** if compliance-relevant
9. **Document** in `docs/STREAMS.md` (full entry: endpoint, schema, cadence, sample data, meaning)
10. **Unit test** the endpoint wrapper — positive + error paths

## Pull request flow

1. Fork and branch — `feature/my-change`, `fix/bug-name`, `docs/updates`
2. Make changes following coding standards above
3. Run `./tests/Run-Tests.ps1 -Category all-offline` locally — must pass
4. Run `./tools/Run-WiringAudit.ps1` if you touched manifest, ARM, or sentinel/ — must exit 0
5. Commit with conventional-commit-style message (`feat:`, `fix:`, `docs:`, `test:`, `chore:`)
6. Open PR using the template — fill in every section
7. CI must pass on all 3 OS (8 jobs: secret-scan / lint / unit-tests / static-validate / deploy-whatif / auto-recompile-gate / auto-rezip-gate / coverage-gate)
8. One approving review required
9. Squash-merge preferred; rebase-merge OK for multi-commit features

## SemVer

XdrLogRaider follows [Semantic Versioning 2.0.0](https://semver.org/) strictly. The version is the operator-facing contract — operators rely on the cadence to know what's safe to upgrade in place vs. what needs a breaking-change review.

| Bump | When | Examples |
|---|---|---|
| **MAJOR** (`X.y.z`) | Breaking change to operator interface — workspace table schema change, removed manifest stream, changed deploy parameter, removed/renamed module export | `v0.1.0 → v0.2.0` (multi-portal stubs reintroduced with body), `v1.0.0 → v2.0.0` (workspace table consolidation) |
| **MINOR** (`x.Y.z`) | New stream / new analytic rule / new workbook panel / new ARM resource — additive only, no operator-side migration required | `v0.1.0 → v0.1.1` (5 new XSPM streams added), `v0.1.0 → v0.2.0` (FA multi-tenancy) |
| **PATCH** (`x.y.Z`) | Bug fix / docs / test / non-functional change — operator can upgrade in place with zero attention | `v0.1.0 → v0.1.0.1` (Phase 5 coverage gate), `v0.1.0 → v0.1.0.2` (parser KQL bug fix) |

**Pre-release suffixes** (`X.Y.Z-beta`, `X.Y.Z-rc.N`) follow PEP 440 / SemVer pre-release semantics.

**Tag format**: `vX.Y.Z` (e.g., `v0.1.0`). The leading `v` is mandatory — release.yml uses `${{ github.ref_name }}` directly in URLs and SBOM names.

**Deprecation policy**: a stream marked `Availability = 'deprecated'` in the manifest stays in the codebase for ONE major version; it's removed entirely at the next major bump. Analytic rules / hunting queries / drift parsers stop referencing deprecated streams (so KQL stays clean) and the manifest's `Purpose` field documents the deprecation reason.

## Conventional Commits

Every commit message follows [Conventional Commits 1.0.0](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types** (in order of frequency in this repo):

| Type | When |
|---|---|
| `feat` | New stream / new ARM resource / new analytic rule / new docs section |
| `fix` | Bug fix in code, tests, ARM, or sentinel content |
| `docs` | Pure documentation update (no code changes) |
| `test` | New tests or test fixes (no production code changes) |
| `refactor` | Code reorganisation that doesn't change behaviour |
| `chore` | Tooling / CI / dependency updates |
| `release` | Release commit that bumps version + tags |

**Scope** (optional but recommended):
- `manifest` — endpoints.manifest.psd1 changes
- `arm` — mainTemplate.json or createUiDefinition.json
- `parsers` — sentinel/parsers/*.kql
- `workbooks` — sentinel/workbooks/*.json
- `rules` — sentinel/analytic-rules/*.yaml
- `hunting` — sentinel/hunting-queries/*.yaml
- `auth` — Xdr.Common.Auth, Xdr.Defender.Auth modules
- `client` — Xdr.Defender.Client (manifest dispatcher)
- `ingest` — Xdr.Sentinel.Ingest (DCR sender)
- `orch` — Xdr.Connector.Orchestrator (Durable Functions wiring)
- `ci` — .github/workflows/

**Examples**:

```
feat(manifest): add MDE_PostureMetrics_CL Tier A stream

Captures posture-management metric-catalog snapshots hourly. Live-captured
2026-05-04 from /apiproxy/mtp/posture/oversight/metrics. Maps to
Defender_ExposureManagement_CL with 5 typed columns + RawJson fallback.

D'.49 cost-budget gate: <500 KB/day at projected operator scale.
```

```
fix(parsers): MDE_Drift_Configuration drops stale Threat Analytics streams

Phase 3 reaudit (2026-05-05): parser referenced 3 streams that don't exist
in the manifest (MDE_IndicatorReputation_CL / OutbreaksList / UrlReputation).
Removed from the SourceName filter to keep parser column-shape stable.

Refs: tests/kql/Parsers.Fixture.Tests.ps1 — was failing in pyramid.
```

```
docs(architecture): v0.1.0 GA separation-of-concerns refresh

Workspace = operator surface (Defender_<Cat>_CL + XdrConnectorHealth_CL).
AppInsights = SRE surface (AppRequests / AppDependencies / AppExceptions /
AppTraces / AppEvents / AppMetrics).
XdrOps-* analytic rules = bridge — read AppInsights, fire operator-visible
Sentinel alerts.

```

**Footer**: `Refs:`, `Closes #N`, `Co-Authored-By:` are recognised. Breaking changes use `BREAKING CHANGE:` prefix in the body — they trigger a MAJOR bump per SemVer.

## Reporting a portal endpoint breakage

When Microsoft hardens an endpoint we use, use the **Portal endpoint broken** issue template. Include:

- Stream name affected (e.g., `MDE_DataExportSettings_CL`)
- Endpoint path (from `src/Modules/XdrLogRaider.Client/Endpoints/`)
- Last known working date
- Current error (from App Insights or a live test)
- Any observed Microsoft communication (MSRC, release notes, etc.)

We aim to remove or rework broken endpoints within 14 days of a confirmed break.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure.

## License

By contributing, you agree your contributions are licensed under the MIT License (see [LICENSE](LICENSE)).
