# Tests

Quick reference. The full walkthrough lives in [`docs/TESTING.md`](../docs/TESTING.md).

## Four-quadrant model

|                 | **Offline (local / CI)** | **Online (live, laptop-only)** |
|---              |---                        |---                              |
| **Pre-deploy**  | `all-offline` — 307 tests | `local-online` — real portal sign-in from laptop |
| **Post-deploy** | —                         | `e2e` — KQL verification of a deployed workspace |

**No CI Azure credentials.** All online tests run from your laptop against your own test tenant.

## Categories

| Category | Latency | Network | CI? | Purpose |
|---|---|---|---|---|
| `unit` | <1 min | mocked | ✓ | Pure logic — all 3 modules, fully mocked HTTP |
| `validate` | <30 s | none | ✓ | KQL parsers + ARM template schema |
| `all-offline` | <30 s | none | ✓ | `unit` + `validate` (the CI default) |
| `local-online` | ~30 s | live portal | — | Real auth chain from your laptop |
| `e2e` | <2 min | live workspace | — | KQL checks post-deploy via `Connect-AzAccount` |

## Prerequisites

```powershell
Install-Module -Name Pester          -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
# For e2e only:
Install-Module -Name Az.Accounts          -Force -Scope CurrentUser
Install-Module -Name Az.OperationalInsights -Force -Scope CurrentUser
Install-Module -Name Az.Resources         -Force -Scope CurrentUser
```

## Pre-deploy: offline tests

```powershell
pwsh ./tests/Run-Tests.ps1 -Category all-offline
```

Expect `307 passed, 0 failed, ~20s`. What runs:
- `tests/unit/*` — module surface + dispatcher + tier-poller + auth chain + ingest
- `tests/kql/Parsers.Tests.ps1` + `Parsers.Fixture.Tests.ps1` — parser structure + fixture drift scenarios
- `tests/arm/MainTemplate.Tests.ps1` — mainTemplate + createUiDefinition assertions

## Pre-deploy: online credential check

Prove your service-account credentials work against the live portal BEFORE deploying to Azure.

```powershell
Copy-Item tests/.env.local.example tests/.env.local
# Edit tests/.env.local — fill in XDRLR_TEST_UPN + password + TOTP seed (or passkey)
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

Detailed `.env.local` format is in [`.env.local.example`](.env.local.example). Full permission + capture walkthrough in [`docs/GETTING-AUTH-MATERIAL.md`](../docs/GETTING-AUTH-MATERIAL.md).

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
