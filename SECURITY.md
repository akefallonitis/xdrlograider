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
- ARM/Bicep deployment templates (`deploy/*`)
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

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |
| < 1.0   | No (pre-release) |

## Security Updates

Security updates are released as patch versions (`1.0.x`) and announced via GitHub Releases with the `security` tag.
