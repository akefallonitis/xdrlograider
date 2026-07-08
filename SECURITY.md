# Security Policy · XdrLogRaider

**Maintainer**: Alex Kefallonitis · al.kefallonitis@gmail.com
**Repository**: https://github.com/akefallonitis/xdrlograider

## Supported versions

| Version | Supported |
|---|---|
| 0.1.0   | ✅ — security fixes |
| < 0.1.0 | ❌ |

XdrLogRaider follows semantic versioning. Security fixes land on the latest `0.1.x` line and are published as a signed GitHub release. A deployment runs the **version-pinned** package it was deployed with (`releases/download/v<connectorVersion>/function-app.zip`, derived from the template's `connectorVersion`); to adopt a fix, re-deploy the current release, or re-point the `functionAppPackageUri` app setting to the new tag and restart the Function App.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for a suspected vulnerability.

Open a private security advisory at **https://github.com/akefallonitis/xdrlograider/security/advisories/new** (the same channel referenced in [PRIVACY.md](PRIVACY.md)). Include the affected version, a description of the issue, and reproduction steps or a proof of concept where possible.

We follow coordinated, responsible disclosure: we will acknowledge your report, investigate, and work on a fix before any public disclosure. Please give us a reasonable window to remediate before disclosing publicly, and avoid accessing or modifying data that is not yours while testing.

## Security model (what to keep in mind)

- **Read-only by construction.** The connector polls Defender XDR portal-internal operations and writes the responses to Log Analytics. No manifest entry uses an action verb (no approve / isolate / delete / restart); the scope validator rejects them at build time.
- **Runs entirely within your own Azure subscription.** XdrLogRaider deploys as a self-hosted Azure Function App in your tenant and ingests into your Log Analytics workspace. No data leaves your subscription, and the maintainer has zero access to it (see [PRIVACY.md](PRIVACY.md)).
- **Portal-internal (undocumented) APIs.** The connector reads Defender XDR `security.microsoft.com/apiproxy/*` portal-internal endpoints read-only. These are unsupported by Microsoft and may change or break without notice — this is not a Microsoft product.
- **Credentials stay in Key Vault.** Service-account credentials are stored in your Key Vault and accessed only by the Function App's managed identity at runtime; the Storage account has shared-key access disabled.
- **Signed releases.** Release artifacts are keyless-signed with cosign/Sigstore and published with an SPDX SBOM and a `SHA256SUMS` checksum file; verify the chain before deploying (`tools/Verify-DeployedVersion.ps1`).
