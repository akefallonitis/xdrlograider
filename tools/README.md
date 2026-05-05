# tools/ — Operator-facing + CI tooling

This directory contains **operator-facing tools** and **CI / build tools** that ship with XdrLogRaider releases. All scripts here are transparent + auditable for security review.

> **Internal dev tooling** (ad-hoc audit scripts, local test drivers, post-deploy verification, test SP setup) lives in `.internal/tools/` — gitignored + `export-ignore` per `.gitattributes`. See `docs/RELEASE-PROCESS.md` for the separation-of-concerns rationale.

---

## Operator-facing tools (post-deploy)

| Tool | When to run | Purpose |
|---|---|---|
| **Initialize-XdrLogRaiderAuth.ps1** | One-time, post-deploy | Upload Defender XDR auth (credentials+TOTP or passkey JSON) to Key Vault for the Function App. Interactive prompts. |
| **Test-ConnectorHealth.ps1** | Daily / on-demand | Single-command HEALTHY / DEGRADED / FAILED verdict — heartbeat freshness, auth diagnostics, per-tier coverage, KV cred expiry. Structured object output. |

Both tools require:
- Az PowerShell context (`Connect-AzAccount`)
- KV access (KV Secrets Officer or KV Reader)
- Workspace access for `Test-ConnectorHealth` (Log Analytics Reader)

---

## CI / build tools

| Tool | Used by | Purpose |
|---|---|---|
| **Build-SentinelContent.ps1** | release.yml + ci.yml + local | Reads `sentinel/` source (workbooks, rules, parsers, hunting queries); emits `deploy/compiled/sentinelContent.json` (linked ARM nested template). |
| **Build-SentinelSolution.ps1** | release.yml | Reads `sentinel/` + `deploy/solution/`; builds `xdrlograider-solution-X.Y.Z.zip` for Microsoft Sentinel Solution Gallery / Content Hub. |
| **Capture-EndpointSchemas.ps1** | online-preflight.yml + capture-schemas.yml + manual | Hits live `security.microsoft.com` portal; refreshes `tests/fixtures/live-responses/*.json`. PII-safe (UUID filtering). |
| **Validate-ArmJson.ps1** | release.yml + ci.yml | Enhanced ARM semantic validation (cross-RG dependsOn scope, parameter usage, dangling dependsOn) beyond JSON schema. |
| **Preflight-Deployment.ps1** | release.yml + manual | Pre-deploy validation: manifest consistency, DCR shape, removed-stream grep gate. Aliased as the `PRE-DEPLOY READY` gate in `docs/RELEASE-PROCESS.md`. |
| **Install-GitHooks.ps1** | Local maintainer setup | Installs git hooks under `tools/git-hooks/` (commit-msg, pre-commit) for repo hygiene. |

---

## Internal-only tools (NOT in this directory)

The following tools live in `.internal/tools/` and are excluded from releases via `.gitignore` + `.gitattributes` `export-ignore`:

- **Post-DeploymentVerification.ps1** — full P1-P14 post-deploy live-workspace verification (used by the GA tag gate per Phase G2.9)
- **Initialize-XdrLogRaiderSP.ps1** — test SP setup for verification subscription
- **Run-LocalTests.ps1** — local test driver wrapping `tests/Run-Tests.ps1`
- **`_audit-*.ps1`** — ad-hoc per-stream / storage-table / typed-col audit scripts
- **`_check-*.ps1`** — ad-hoc FA state / appsettings / heartbeat / exception / status diagnostics
- **`_diag-*.ps1`** — ad-hoc 404 / typed-col diagnostic drilldowns
- **`_phase-*.ps1`** — phase-specific operational scripts (Stop+Start, projection audit, etc.)

These are maintainer-only and intentionally NOT released. If an operator needs the equivalent functionality, use:
- `Test-ConnectorHealth.ps1` (operator-facing health summary)
- Sentinel ConnectorHealth workbook (operator-facing visualization)
- Az CLI / portal blade (operator-facing FA management)

---

## Cross-references

- `docs/RELEASE-PROCESS.md` — full release supply-chain checklist + branch protection
- `docs/SECURITY-NOTES.md` — security review surface + cosign verify-blob examples
- `docs/CONTRIBUTING.md` — internal/external phasing separation rationale
- `.gitignore` — what's excluded from version control
- `.gitattributes` — what's excluded from `git archive` / release tarballs
