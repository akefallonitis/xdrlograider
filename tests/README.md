# Tests

Quick reference. The full walkthrough lives in [`docs/TESTING.md`](../docs/TESTING.md).

## Four-quadrant model

|                 | **Offline (local / CI)** | **Online (live, laptop-only)** |
|---              |---                        |---                              |
| **Pre-deploy**  | `all-offline` — 1184 tests (v0.1.0-beta iter 12) | `local-online` — real portal sign-in from laptop |
| **Post-deploy** | —                         | `e2e` — KQL verification of a deployed workspace |

**No CI Azure credentials.** All online tests run from your laptop against your own test tenant.

## Categories

| Category | Latency | Network | CI? | Purpose |
|---|---|---|---|---|
| `unit` | <1 min | mocked | ✓ | Pure logic — all 3 modules, fully mocked HTTP |
| `validate` | <30 s | none | ✓ | KQL parsers + ARM template schema |
| `all-offline` | <30 s | none | ✓ | `unit` + `validate` (the CI default) |
| `local-online` | ~30 s | live portal | — | Real auth chain from your laptop |
| `whatif` | ~1 min | live ARM RP | ✓ (gated) | `az deployment group what-if` validation against the compiled ARM template. Catches deploy-time bugs (`InvalidTemplate`, `Conflict`, `Failed` change ops) before they reach the operator. SP-creds-driven; self-skips offline. |
| `e2e` | <2 min | live workspace | — | KQL checks post-deploy via `Connect-AzAccount` |

## Prerequisites

```powershell
Install-Module -Name Pester          -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
# For whatif (deploy-time validation) + e2e (KQL post-deploy):
Install-Module -Name Az.Accounts          -Force -Scope CurrentUser
Install-Module -Name Az.Resources         -Force -Scope CurrentUser
# For e2e only:
Install-Module -Name Az.OperationalInsights -Force -Scope CurrentUser
```

## Pre-deploy: offline tests

```powershell
pwsh ./tests/Run-Tests.ps1 -Category all-offline
```

Expect `1097 passed, 0 failed, 17 skipped, ~60s`. What runs (v0.1.0-beta.1):

**tests/unit/**
- `XdrLogRaider.Client.Tests.ps1` — module exports + manifest contract (45 streams, 33 live + 10 tenant-feature-gated + 2 role-gated per v0.1.0-beta live capture)
- `XdrLogRaider.Ingest.Tests.ps1` — Send-ToLogAnalytics, retry, batching
- `Xdr.Portal.Auth.*.Tests.ps1` — full Entra auth chain (CredentialsTotp + Passkey + DirectCookies)
- `Ingest.Extended.Tests.ps1` + `ModuleCoverage.Extended.Tests.ps1` — edge cases
- `Checkpoint.RoundTrip.Tests.ps1` — Storage Table checkpoint shape
- `Initialize-XdrLogRaiderAuth.Tests.ps1` — helper script
- `Manifest.DcrConsistency.Tests.ps1` — **cross-layer drift guard** (manifest ↔ DCR ↔ custom-tables)
- `Profile.EnvVars.Tests.ps1` — profile.ps1 envvar validation
- **`FA.ParsingPipeline.Tests.ps1`** (v1.0.2) — 177 assertions: Expand-MDEResponse + ConvertTo-MDEIngestRow against the 25 live fixtures
- **`DCR.SchemaConsistency.Tests.ps1`** (v1.0.2) — 53 assertions: ingest-row columns match DCR streamDeclaration columns exactly (no silent drops, no NULL-forever)
- `TimerFunctions.Shape.Tests.ps1` — AST verification of all 7 timer-function bodies (canonical shape + try/catch + Write-Heartbeat calls)
- **`TimerFunctions.Execution.Tests.ps1`** (v1.0.2) — AST verification of fatal-error catch-block semantics (`fatalError` note, correct `-Tier`, nested try, `throw`)
- `ApiErrorHandling.Tests.ps1` — HTTP 401/403/500/503/429 retry paths

**tests/kql/**
- `Parsers.Tests.ps1` + `Parsers.Fixture.Tests.ps1` — parser structure + 9-column drift schema + tier coverage + 5 REMOVED streams not referenced
- **`AnalyticRules.Tests.ps1`** (v1.0.2) — 70 assertions: every rule's query verifies manifest streams, parser calls, no REMOVED-stream refs, balanced parens
- **`HuntingQueries.Tests.ps1`** (v1.0.2) — same invariants for 9 hunting queries
- **`Workbooks.Tests.ps1`** (v1.0.2) — walks workbook JSON tree, verifies every `items[].content.query` string

**tests/arm/**
- `MainTemplate.Tests.ps1` — mainTemplate.json schema + DCR stream count + deployment topology

**Fixtures**
- `tests/fixtures/live-responses/<Stream>-raw.json` + `-ingest.json` — captured from live portal via `tools/Capture-EndpointSchemas.ps1` (2026-04-23). 25 pairs covering all ACTIVE streams. Redacted of GUIDs, UPNs, IPs, bearer tokens, and tenant name.
- `tests/fixtures/sample-snapshots/` — hand-crafted drift scenarios for parser-scenario tests.

## Pre-deploy: online credential check

Prove your service-account credentials work against the live portal BEFORE deploying to Azure.

```powershell
Copy-Item tests/.env.local.example tests/.env.local
# Edit tests/.env.local — fill in XDRLR_TEST_UPN + password + TOTP seed (or passkey)
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

Detailed `.env.local` format is in [`.env.local.example`](.env.local.example). Full permission + capture walkthrough in [`docs/GETTING-AUTH-MATERIAL.md`](../docs/GETTING-AUTH-MATERIAL.md).

## Pre-deploy: ARM template what-if

Validate the compiled ARM template against the live Azure RP — catches deploy-time bugs that static ARM-TTK + Pester schema tests miss (e.g. `InvalidTransformOutput` from a DCR `dataFlow` that references a missing `streamDeclaration`, role-assignment principal-id mismatch, KV name uniqueness, etc).

```powershell
# tests/.env.local must contain:
#   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, XDRLR_SUBSCRIPTION_ID,
#   XDRLR_WORKSPACE_RG, XDRLR_WORKSPACE_NAME
pwsh ./tests/Run-Tests.ps1 -Category whatif
```

The test:
- Logs in as the SP, picks a target RG (synthetic > `XDRLR_WHATIF_RG` > `XDRLR_CONNECTOR_RG`).
- Runs `Get-AzResourceGroupDeploymentWhatIfResult` against `deploy/compiled/mainTemplate.json`.
- Asserts no `Failed` change-set entries and no `InvalidTemplate` / `InvalidTransformOutput` / `Conflict` / `BadRequest` errors.
- If the SP lacks `Microsoft.Authorization/roleAssignments/write`, transparently retries with role-assignments stripped (so the rest of the template still gets validated). Grant the SP **User Access Administrator** on the target RG for full coverage.
- Cleans up only RGs the test created.

Self-skips offline / when SP creds are absent — no manual gating required.

## Post-deploy: e2e verification

After deploying + uploading auth secrets, verify everything is healthy:

```powershell
Connect-AzAccount
$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_RG = 'xdrlr-prod-rg'          # connector RG you deployed into
$env:XDRLR_TEST_WORKSPACE = 'your-workspace'   # workspace NAME (not resource ID)
pwsh ./tests/Run-Tests.ps1 -Category e2e
```

Your Azure account needs `Log Analytics Reader` on the workspace. No SP / no stored creds.

## Writing new tests

### Unit test template

```powershell
#Requires -Modules Pester

BeforeAll {
    Import-Module "$PSScriptRoot/../../src/Modules/MyModule/MyModule.psd1" -Force
}

AfterAll {
    Remove-Module MyModule -Force -ErrorAction SilentlyContinue
}

Describe 'My function' {
    It 'does the right thing' {
        InModuleScope MyModule {
            Mock Some-Dependency { return 'mocked' }
            My-Function -Input 'x' | Should -Be 'expected'
            Should -Invoke Some-Dependency -Times 1 -Exactly
        }
    }
}
```

### Fixture pattern (drift parser tests)

Store canned portal responses in `tests/fixtures/sample-snapshots/<stream>.json` and consume them in `tests/kql/Parsers.Fixture.Tests.ps1`.

### Test artefacts

JUnit XML → `tests/results/<category>.xml`. Code coverage (offline only) → `tests/results/coverage-<category>.xml`.

## CI

- `.github/workflows/ci.yml` — runs `all-offline` + gitleaks + PSScriptAnalyzer on every push/PR to `main`. Ubuntu-only.
- `.github/workflows/release.yml` — on `v*` tag: gate tests + build 5 artefacts + SBOM + GitHub Release.
- `.github/workflows/validate-solution.yml` — deep Sentinel-Solution format validation.

**No CI workflow runs online tests.** By design. See [`docs/TESTING.md`](../docs/TESTING.md) for rationale.

## Coverage targets

| Component | Target |
|---|---|
| `Xdr.Portal.Auth` | ≥95% |
| `XdrLogRaider.Client` | ≥80% |
| `XdrLogRaider.Ingest` | ≥90% |
| `Initialize-XdrLogRaiderAuth.ps1` | ≥90% |
| Timer function bodies | ≥70% |
| KQL parsers | Every parser + every drift scenario |
