# Testing guide

The XdrLogRaider test matrix has **four quadrants** — organised around *when* you run them (pre-deploy vs post-deploy) and *where* they touch (local-only vs live Azure/portal).

| | **Local / offline** | **Online** |
|---|---|---|
| **Pre-deploy** | `all-offline` — 307 tests, zero external deps | `local-online` — real portal sign-in from laptop |
| **Post-deploy** | — | `e2e` — KQL verification of deployed workspace |

**No service principals. No app registrations. No stored Azure credentials in CI.** CI only runs the offline quadrant. You run online tests from your own laptop with your own `Connect-AzAccount` session.

---

## Prerequisites (install once)

```powershell
# PowerShell 7.4+
$PSVersionTable.PSVersion   # expect 7.4 or higher

# Pester + PSScriptAnalyzer
Install-Module Pester          -MinimumVersion 5.5.0 -Force -Scope CurrentUser
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck

# Az modules (only for e2e post-deploy verification)
Install-Module Az.Accounts          -Force -Scope CurrentUser
Install-Module Az.OperationalInsights -Force -Scope CurrentUser
Install-Module Az.Resources         -Force -Scope CurrentUser
```

---

## 1. `all-offline` — pre-deploy, local, always available

**Purpose**: prove the code compiles, modules import, public functions behave per contract, KQL parsers are well-formed, ARM templates are schema-valid.

**Needs**: zero external dependencies. Runs on any machine with PowerShell 7 + Pester.

**How**:
```powershell
cd C:\Users\akefa\Desktop\repos\xdrlograider
pwsh ./tests/Run-Tests.ps1 -Category all-offline
```

**Expected**: `307 passed, 0 failed, ~20s`.

What runs:
- `tests/unit/*` — public-function contract tests for all 3 modules + the Initialize helper (~250 tests)
- `tests/kql/Parsers.Tests.ps1` + `Parsers.Fixture.Tests.ps1` — 6 drift parsers × structural + fixture-driven (~30)
- `tests/arm/MainTemplate.Tests.ps1` — mainTemplate.json + createUiDefinition.json assertions (~27)

**This is also exactly what CI (`.github/workflows/ci.yml`) runs**. If it's green on your laptop, it's green in CI.

---

## 2. `local-online` — pre-deploy, online, confirms service-account works

**Purpose**: before running the ARM deployment, confirm your service account's credentials actually authenticate against `security.microsoft.com`. Catches expired passwords, wrong TOTP seeds, misassigned roles, CA blocks — BEFORE you create any Azure resources.

**Needs**:
- The Entra service account set up per [GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md)
- `Security Reader` + `Defender XDR Analyst` on the service account
- Base32 TOTP seed captured during enrolment
- `tests/.env.local` file populated (gitignored, never committed)

**Setup (one-time)**:
```powershell
cd C:\Users\akefa\Desktop\repos\xdrlograider
Copy-Item tests/.env.local.example tests/.env.local

# Open tests/.env.local in your editor and fill ONLY the method you'll use.
# For CredentialsTotp (recommended):
#   XDRLR_TEST_UPN=svc-xdrlr@yourtenant.onmicrosoft.com
#   XDRLR_TEST_AUTH_METHOD=CredentialsTotp
#   XDRLR_TEST_PASSWORD=<the service account's current password>
#   XDRLR_TEST_TOTP_SECRET=JBSWY3DPEHPK3PXP...   # Base32 from mysignins enrolment
#
# For Passkey:
#   XDRLR_TEST_UPN=svc-xdrlr@yourtenant.onmicrosoft.com
#   XDRLR_TEST_AUTH_METHOD=Passkey
#   XDRLR_TEST_PASSKEY_PATH=./my-passkey.json
#
# For DirectCookies (fastest; expires in ~1h):
#   XDRLR_TEST_UPN=svc-xdrlr@yourtenant.onmicrosoft.com
#   XDRLR_TEST_AUTH_METHOD=DirectCookies
#   XDRLR_TEST_SCCAUTH=<paste from Chrome DevTools>
#   XDRLR_TEST_XSRF_TOKEN=<paste from Chrome DevTools>
```

**Run**:
```powershell
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

**Expected**: `~10 passed, 0 failed, ~30s`. Exercises the full auth chain + a sample portal call.

**If this fails, DO NOT deploy yet** — fix the credential issue first. Most likely causes:
- Password expired → reset in Entra, update `tests/.env.local`
- TOTP seed typo → re-copy from `mysignins.microsoft.com`
- Service account missing a role → grant `Security Reader` + `Defender XDR Analyst`
- Conditional Access blocking the sign-in → add named-location exception OR carve out the service account

---

## 3. `e2e` — post-deploy, online, confirms deployment healthy

**Purpose**: after deploying via Deploy-to-Azure + running `Initialize-XdrLogRaiderAuth.ps1`, verify rows are actually landing in your workspace + the auth self-test is green + custom tables exist + Sentinel content was deployed.

**Needs**:
- A completed XdrLogRaider deployment
- Auth secrets uploaded via `Initialize-XdrLogRaiderAuth.ps1`
- At least 5 minutes elapsed since upload (for `MDE_AuthTestResult_CL`) or 1 hour (for first P0 rows)
- You (the runner) signed into Azure with at least `Log Analytics Reader` on the workspace

**Run**:
```powershell
Connect-AzAccount

$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_RG = 'xdrlr-prod-rg'             # the connector RG you deployed into
$env:XDRLR_TEST_WORKSPACE = 'sentinel-prod-ws'    # the workspace NAME (not ID)

pwsh ./tests/Run-Tests.ps1 -Category e2e
```

**Expected**: 3-block Pester run covering:
- **Resource group contains expected resources** — FA, KV, Storage, DCE, DCR all present
- **Ingestion signal** — `MDE_Heartbeat_CL` has recent rows; `MDE_AuthTestResult_CL.Success=true`; `MDE_AdvancedFeatures_CL` has at least one row; ≥3 of 5 sampled P0 streams have data
- **Sentinel content deployed** — parser functions registered (≥6); hunting queries registered (≥10); Compliance Dashboard workbook exists

If blocks fail:
- `Resource group ...` fails → check you provided the right RG + subscription
- `Ingestion signal ...` fails → auth self-test probably failed; check [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure)
- `Sentinel content ...` fails → workspace RG RBAC issue during deploy; check `sentinelContent-<uniq>` nested deployment in Azure Portal

---

## Recommended testing flow — end to end

```
  Day 0: you clone the repo
         ↓
  [ ALL-OFFLINE ]  pwsh ./tests/Run-Tests.ps1 -Category all-offline
         ↓ (green)
  Day 1: you set up the Entra service account + TOTP
         ↓
  [ LOCAL-ONLINE ] pwsh ./tests/Run-Tests.ps1 -Category local-online
         ↓ (green — credentials work)
  Day 2: click Deploy-to-Azure button
         ↓
         fill wizard (workspace ID + location + service-account UPN + auth method)
         ↓
         wait ~10 min
         ↓
         run Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-output>
         ↓
         wait 5 min for self-test
         ↓
  [ E2E ]          pwsh ./tests/Run-Tests.ps1 -Category e2e
         ↓ (green — deployment healthy)
         ↓
         tag v1.0.0, done
```

---

## CI (GitHub Actions)

`.github/workflows/ci.yml` runs **only `all-offline`** on every push + PR to `main`, on Ubuntu. No Azure credentials needed anywhere — CI doesn't touch Azure, ever.

`.github/workflows/release.yml` runs on `v*` tag push — gate tests + build artefacts + attach to GitHub Release. Still no Azure credentials (only `GITHUB_TOKEN`, auto-provided).

**There is no CI path that runs `local-online` or `e2e`** — by design. Both require live tenant credentials and would either (a) force a stored-secret workflow or (b) need an Entra app registration, neither of which fits the zero-trust model.

If you want nightly verification of a deployed instance, the pattern is:
1. Keep a persistent test deployment of XdrLogRaider in a non-prod subscription
2. From a scheduled job on YOUR infrastructure (not GitHub Actions), run `pwsh ./tests/Run-Tests.ps1 -Category e2e` using your own `Connect-AzAccount` session
3. Alert on failures via your usual monitoring stack

---

## Troubleshooting the test runner

| Symptom | Fix |
|---|---|
| `Pester 5.5.0+ not installed` | `Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser` |
| `Run-Tests.ps1: FailedCount property not found` | Old shell; close and reopen — the runner needs the `$cfg.Run.PassThru = $true` code path |
| `local-online requires XDRLR_TEST_UPN` | `tests/.env.local` missing or malformed — re-copy from `.env.local.example` |
| `e2e: XDRLR_TEST_RG not set` | Export the env var: `$env:XDRLR_TEST_RG = 'xdrlr-prod-rg'` |
| `Connect-AzAccount required` for e2e | Run `Connect-AzAccount` interactively first |
| Container failure at discovery in Parsers.Tests.ps1 | Known Pester 5.7 issue with `-ForEach` and null variables — already fixed; pull latest |
