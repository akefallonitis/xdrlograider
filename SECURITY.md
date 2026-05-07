# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it privately via GitHub Security Advisories:

1. Go to the repository's **Security** tab
2. Click **Report a vulnerability**
3. Provide a detailed description, reproduction steps, and impact assessment

We aim to acknowledge reports within 48 hours and provide a remediation timeline within 7 days.

## Scope

In scope:
- PowerShell modules (`src/Modules/*`)
- Azure Functions (`src/functions/*`)
- Helper script (`tools/Initialize-XdrLogRaiderAuth.ps1`)
- ARM deployment templates (`deploy/*`)
- Sentinel content (parsers, workbooks, analytic rules)

Out of scope:
- Undocumented Microsoft portal API behavior (report to MSRC)
- Conditional Access policy bypass patterns (already disclosed by third parties — see [CloudBrothers April 2026](https://cloudbrothers.info/en/avoid-entra-conditional-access-sccauth/))

## Secure Deployment Practices

This project follows these practices by design:

1. **No secrets in code** — all auth material lives in Azure Key Vault
2. **No secrets in deployment payload** — wizard collects only non-sensitive params; secrets uploaded post-deploy via Key Vault CLI
3. **Managed Identity for Azure plumbing** — Function App reads KV, writes DCE, checkpoints to Storage via MI — no stored credentials
4. **Principle of least privilege** — service account for portal auth has Security Reader + Defender Analyst read only
5. **Audit logging** — Key Vault access logs, Function App App Insights, Log Analytics diagnostic logs all enabled by default
6. **CI secrets handling** — GitHub Actions live tests use federated identity credential (FIC), never stored secrets; CI on forks is offline-only

## Service-account credential rotation (v0.1.0 GA — operator runbook)

The Defender XDR portal service account is the **single security boundary** for the connector. SAMI handles all Azure plumbing (KV reads / Storage writes / DCE ingest) and is auto-managed by Azure (no rotation needed).

For the SA itself:

- **Cadence**: rotate the SA password manually only if compromise is suspected (e.g. `XdrOps-AuthChainFailure.yaml` analytic rule fires persistently). No proactive rotation cadence required for v0.1.0 GA.
- **Procedure**:
  1. Generate a new SA password in your Entra tenant (Entra ID → Users → service account → Reset password).
  2. Re-run `pwsh tools/Initialize-XdrLogRaiderAuth.ps1` against your Key Vault to seed the new credential (the script wipes + writes the `mde-portal-password` secret, preserving prior versions for rollback).
  3. Restart the Function App: Azure Portal → Function App → Stop → Start. Cold-start (~5 min) reads the new secret on first poll.
  4. Verify auth chain via `XdrConnectorHealth_CL.AuthChainStatus` in the workspace OR App Insights `customEvents | where name == 'AuthChain.Completed'`.
- **TOTP / Software Passkey rotation**: same pattern — regenerate in Entra, write to KV via Initialize-XdrLogRaiderAuth.ps1, restart FA.

Pre-existing analytic rule `XdrOps-AuthChainFailure.yaml` (ships `enabled:false`) alerts operators on repeated auth-chain failures so they know when to investigate. Enable it via the Sentinel UI after operator review.

## Manifest changes — Function App restart required

Adding/removing/reconfiguring streams in `endpoints.manifest.psd1` requires a **Function App restart** — the manifest is loaded at module-import time (cold-start) and not hot-reloaded. After redeploying via `release.yml` (which uploads the new `function-app.zip` to `/releases/latest/download/`), Stop+Start the FA to force a fresh package fetch + manifest reload. No ARM redeploy needed for FA-package-only changes (per Section R++++++ live-override flow).

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes (current GA series) |
| < 0.1.0 | No (pre-release) |

## Security Updates

Security updates are released as patch versions (`0.1.x`) and announced via GitHub Releases with the `security` tag.
