# Tests

Four test categories, run via `./tests/Run-Tests.ps1`.

| Category | Latency | Network | Tenant | CI | Purpose |
|---|---|---|---|---|---|
| `unit` | <1 min | mocked | none | yes (3 OS) | Pure logic tests, fully mocked HTTP |
| `validate` | <30 s | none | none | yes | KQL syntax, JSON schema, ARM-TTK |
| `local-online` | ~2 min | live | your test tenant | no | Real auth chain + endpoint smoke from your laptop |
| `integration` | ~5 min | live | test tenant via FIC | manual workflow-dispatch | Same as local-online but FIC-backed in CI |
| `e2e` | ~30 min | live | test tenant + deployed RG | manual workflow-dispatch | Full deploy + ingest + workbook + analytic-rule pipeline |

## Prerequisites

```powershell
# Pester 5.5+
Install-Module -Name Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser -SkipPublisherCheck

# PSScriptAnalyzer
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
```

For validation tests only: Azure CLI + Bicep + ARM-TTK (see workflow files in `.github/workflows/` for CI reference).

## Running unit tests (fastest, no network)

```powershell
pwsh ./tests/Run-Tests.ps1 -Category unit
```

All tests in `./tests/unit/` run with fully mocked HTTP. Should complete in <1 minute. Covers:
- `Xdr.Portal.Auth` — TOTP generation, passkey signing, module surface, parameter validation
- `XdrLogRaider.Client` — 52 manifest-driven endpoints (each with positive + error paths)
- `XdrLogRaider.Ingest` — DCE batch writer, checkpoint logic, heartbeat
- `Initialize-XdrLogRaiderAuth.ps1` — KV interaction mocked, input paths

## Running static validation

```powershell
pwsh ./tests/Run-Tests.ps1 -Category validate
```

Covers:
- KQL parser syntax + semantics via Kusto.Language NuGet
- KQL parsers validated against fixture snapshots (drift scenarios)
- Workbook JSON schema validation
- Analytic rule JSON schema validation
- Hunting query YAML + KQL validation
- `mainTemplate.json` via ARM-TTK
- `createUiDefinition.json` schema validation
- Bicep compilation

## Running local-online tests (live auth against your tenant)

This runs the real auth chain against a real tenant using credentials you supply.
Your creds never leave your machine — no Key Vault, no CI secrets, no committed files.

### Step 1: Create service account (one-off, in your test tenant)

Create a dedicated service account in Entra:

1. New user `svc-xdrtest@your-tenant.onmicrosoft.com`
2. Assign Security Reader + Defender XDR analyst read roles (read-only)
3. Either:
   - Enroll Microsoft Authenticator (TOTP) — copy the Base32 secret shown during enrollment
   - Or generate a software passkey JSON externally (see [docs/BRING-YOUR-OWN-PASSKEY.md](../docs/BRING-YOUR-OWN-PASSKEY.md))

### Step 2: Create `tests/.env.local` (gitignored)

```powershell
Copy-Item tests/.env.local.example tests/.env.local
```

Pick ONE of the three auth methods and fill the matching section:

**DirectCookies (recommended for testing — no automation, works in 2 min)**
```
XDRLR_TEST_UPN=svc-xdrtest@your-tenant.onmicrosoft.com
XDRLR_TEST_AUTH_METHOD=DirectCookies
XDRLR_TEST_SCCAUTH=<paste sccauth value>
XDRLR_TEST_XSRF_TOKEN=<paste XSRF-TOKEN value>
```

How to capture sccauth + XSRF-TOKEN (one-time, 2 min):
1. Sign into https://security.microsoft.com in Chrome or Edge
2. Press **F12** to open DevTools
3. Click the **Application** tab
4. Left sidebar: **Storage** → **Cookies** → `https://security.microsoft.com`
5. Find the row where **Name = sccauth** — copy the **Value** column
6. Find the row where **Name = XSRF-TOKEN** — copy the **Value** column
7. Paste into `tests/.env.local`

Cookies expire in ~1 hour. Re-capture when they expire.

**Credentials + TOTP (full automation once implementation complete)**
```
XDRLR_TEST_UPN=svc-xdrtest@your-tenant.onmicrosoft.com
XDRLR_TEST_AUTH_METHOD=CredentialsTotp
XDRLR_TEST_PASSWORD=your-account-password
XDRLR_TEST_TOTP_SECRET=JBSWY3DPEHPK3PXPJBSWY3DPEHPK
```

> Note: the full ROPC-to-MFA login chain in `Get-EstsCookie.ps1` has placeholder fields for Entra's intermediate `flowToken`/`Ctx` values. These need to be parsed from actual login response HTML. Use DirectCookies for now; CredentialsTotp full flow is a v1.1 deliverable. See `docs/AUTH.md`.

**Passkey (requires software passkey JSON)**
```
XDRLR_TEST_UPN=svc-xdrtest@your-tenant.onmicrosoft.com
XDRLR_TEST_AUTH_METHOD=Passkey
XDRLR_TEST_PASSKEY_PATH=./my-passkey.json
```

See [docs/BRING-YOUR-OWN-PASSKEY.md](../docs/BRING-YOUR-OWN-PASSKEY.md) for passkey generation.

### Step 3: Run

```powershell
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

This runs `tests/integration/Auth-Chain-Live.Tests.ps1`:
- Connects via your chosen method
- Verifies sccauth + XSRF acquisition
- Calls `/api/settings/GetAdvancedFeaturesSetting` as a real probe
- Verifies session caching works
- Verifies XSRF rotation

Expected output:
```
Tests Passed: 5, Failed: 0, Skipped: 0
```

### Security

- `tests/.env.local` is in `.gitignore` — it cannot be committed by accident
- Credentials are passed to the test runner only; never logged or persisted
- The test doesn't write credentials anywhere on disk
- The test account should be dedicated, read-only, ideally in a sandbox tenant

### Troubleshooting local-online

**Auth chain fails at `ests-cookie` stage**
- Verify your password and TOTP secret are correct
- Try logging in manually at `login.microsoftonline.com` to confirm the account works
- Check if Conditional Access is blocking sign-ins from your location

**Auth succeeds but `sample-call` returns 403**
- The service account needs Security Reader + MDE analyst read roles at minimum
- Try manually navigating to `security.microsoft.com` as that user

**Passkey authenticator verification fails**
- Verify your passkey JSON has `upn`, `credentialId`, `privateKeyPem`, `rpId` fields
- Verify the credential was registered in Entra for that UPN (check My Sign-Ins → Security info)
- The `rpId` should match what Entra used during registration (`login.microsoft.com` is the default)

## Running integration/e2e tests (CI-backed)

These are designed for CI with federated identity credentials. Not intended for local run.

```powershell
# In CI — workflow_dispatch run
# Uses vars.AZURE_CLIENT_ID + OIDC token, no stored secrets
```

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

### Fixture snapshot pattern (for drift parser tests)

Store canned portal responses in `tests/fixtures/portal-responses/<stream>.json` and consume them in `tests/kql/Parsers.Tests.ps1`.

### Test result artifacts

All test runs write JUnitXml to `tests/results/<category>.xml` and code coverage (offline runs) to `tests/results/coverage-<category>.xml`.

## CI integration

- `.github/workflows/ci.yml` runs `unit` + `validate` on every push/PR across ubuntu/windows/macos
- `.github/workflows/validate-solution.yml` runs deep JSON/schema validation on ARM/workbook/rule changes
- `.github/workflows/integration.yml` runs `integration` and `e2e` via manual workflow-dispatch, FIC-authenticated to test tenant

See `.github/workflows/*.yml` for current CI definitions.

## Coverage targets (v1.0)

| Component | Target |
|---|---|
| `Xdr.Portal.Auth` | ≥95% |
| `XdrLogRaider.Client` | ≥80% |
| `XdrLogRaider.Ingest` | ≥90% |
| `Initialize-XdrLogRaiderAuth.ps1` | ≥90% |
| Timer function bodies | ≥70% |
| KQL parsers | Every parser + every drift scenario |
