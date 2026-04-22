# XdrLogRaider

**A Microsoft Sentinel Solution that ingests Defender XDR portal-only telemetry — configuration, compliance, drift, exposure, governance — that is not exposed by public Graph Security, Defender XDR, or MDE public APIs.**

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2Fcompiled%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2Fcompiled%2FcreateUiDefinition.json)
[![CI](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml/badge.svg)](https://github.com/akefallonitis/xdrlograider/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

| Feature | Detail |
|---|---|
| Platform | Azure Functions (PowerShell 7.4), Log Analytics, Sentinel |
| Auth | Two unattended auto-refreshing methods: Credentials+TOTP, Software Passkey |
| Scope | Defender XDR portal (`security.microsoft.com`) — 55 streams across 8 compliance tiers |
| Deployment | One-click **Deploy to Azure** (button above) + one `./tools/Initialize-XdrLogRaiderAuth.ps1` run post-deploy |
| Content | 6 workbooks · 15 analytic rules · 10 hunting queries · 6 KQL drift parsers (all auto-deployed via nested ARM) |
| License | MIT |

XdrLogRaider ingests the tenant-configuration surface that Microsoft's first-party APIs don't expose: ASR rule state drift, exclusion list changes, data export destination adds, Live Response policy relaxations, XSPM attack paths, MDI sensor coverage, Action Center approval history, and 48 more streams. Drift is computed in pure KQL at query time — 6 category-scoped parsers feed 6 workbooks and analytic rules.

## Quick start

### 1. Click **Deploy to Azure** (badge above)

The button resolves to an Azure Portal wizard that:
- Prompts for region, project prefix, service account UPN, auth method, Log Analytics workspace
- Provisions Function App + Key Vault + Storage + DCE + DCR + App Insights
- Deploys the Sentinel content pack (6 parsers · 6 workbooks · 15 analytic rules · 10 hunting queries) via a nested ARM deployment — **no manual Sentinel-content install needed**
- Outputs `KeyVaultName` and `DceEndpoint` for the helper script

> **Private repository note:** the Deploy button uses `raw.githubusercontent.com` URLs and requires the repo to be public for Azure Portal to fetch the templates. For private-repo deployment: use Azure Portal → **Deploy a custom template** → **Load template from file** with the JSONs in `deploy/compiled/` (or from the GitHub Release assets).

### 2. Upload auth material to Key Vault

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <KeyVaultName from step 1>
```

See [docs/GETTING-AUTH-MATERIAL.md](docs/GETTING-AUTH-MATERIAL.md) for how to obtain the TOTP Base32 secret / software passkey / cookies for the service account.

### 3. Verify ingestion

Within 5 minutes the Function App self-test timer writes the first row to `MDE_AuthTestResult_CL`:

```kql
MDE_AuthTestResult_CL | order by TimeGenerated desc | take 1
// Expected: Success = true, Stage = complete
```

Production polling timers activate automatically once the self-test passes. Within one hour the P0 tier streams (`MDE_AdvancedFeatures_CL`, `MDE_PUAConfig_CL`, `MDE_AsrRulesConfig_CL`, ...) begin emitting rows.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — components, data flow, trust boundaries
- [Deployment](docs/DEPLOYMENT.md) — step-by-step walkthrough
- [Auth](docs/AUTH.md) — both methods explained, CA compatibility, rotation
- [Bring Your Own Passkey](docs/BRING-YOUR-OWN-PASSKEY.md) — generating a software passkey JSON
- [Streams](docs/STREAMS.md) — full catalogue of 55 telemetry streams
- [Workbooks](docs/WORKBOOKS.md) — what each dashboard shows
- [Drift](docs/DRIFT.md) — pure-KQL drift model explained
- [Runbook](docs/RUNBOOK.md) — daily ops, incidents, rotation
- [Troubleshooting](docs/TROUBLESHOOTING.md) — symptom → fix
- [Cost](docs/COST.md) — monthly estimate + tuning levers
- [References](docs/REFERENCES.md) — all sources cited

## Contributing

Community-driven. See [CONTRIBUTING.md](CONTRIBUTING.md) and the `good-first-issue` label.

Issue templates:
- Bug report
- Feature request
- **Portal endpoint broken** — specific template for reporting when Microsoft hardens an endpoint we depend on
- New stream request

## License

MIT — see [LICENSE](LICENSE).

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure.

Authentication patterns used in this project are based on publicly documented specifications (RFC 6238 TOTP, W3C WebAuthn) and publicly researched portal-cookie behavior. Microsoft's sccauth cookie-based Conditional-Access-bypass category has been disclosed and classified as moderate-severity, not-immediate-servicing — see [CloudBrothers April 2026 finding](https://cloudbrothers.info/en/avoid-entra-conditional-access-sccauth/).

This project is authorized research — MIT licensed, used only within tenants owned by the operator, with proper authorization. See [DISCLAIMER.md](DISCLAIMER.md).
