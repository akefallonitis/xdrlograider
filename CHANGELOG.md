# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Deployment topology**: `existingWorkspaceId` + `workspaceLocation` are now REQUIRED parameters. The template no longer creates a new Log Analytics workspace — customers must have a Sentinel-enabled workspace up front. This matches reality (most orgs already operate Sentinel centrally) and eliminates a class of broken-by-default scenarios.
- **Cross-RG / cross-subscription workspace**: custom tables (54) + Sentinel content (parsers/workbooks/rules/hunting queries) are deployed via nested `Microsoft.Resources/deployments` with `subscriptionId` + `resourceGroup` scope pointing at the workspace's RG. Supports enterprise "central Sentinel RG" topologies.
- **Regional correctness**: DCE + DCR now created in `workspaceLocation` (was `connectorLocation`). Azure Monitor's hard constraint — DCE/DCR must share region with destination workspace — now enforced by the template.
- **Function App envvar validation**: `src/profile.ps1` validates all 8 required envvars at cold start with a fatal, human-readable error if any are missing (was silent failure).
- **Resource tags**: every Azure resource now carries `workload=XdrLogRaider`, `environment=<env>`, `managedBy=ARM` tags for FinOps tracking.
- **DCE `kind: 'Linux'` removed**: it was an AMA-era label with no effect on our HTTP Logs Ingestion API path.
- **3rd role assignment**: `Monitoring Metrics Publisher` on the DCR is now explicitly granted to the FA's Managed Identity (was missing from the committed ARM before).
- Docs + manifest updated to reflect 52 telemetry streams + 2 operational streams (Heartbeat + AuthTestResult) = 54 total custom LA tables.
- CI matrix reduced to Ubuntu-only (production parity). Windows + macOS runners removed; can be added back via workflow_dispatch if a platform-specific regression ever surfaces.

### Added
- **docs/PERMISSIONS.md** — consolidated permissions reference (setup + runtime + cross-RG scenarios + rotation).
- **docs/DEPLOYMENT.md** — full 8-step walkthrough with deployment-topology diagram + workspace-resource-ID capture instructions.
- **docs/RUNBOOK.md** — new "Auth self-test failure" diagnostic section with per-stage cause/action table.
- **workspaceLocation** dropdown in wizard (29 Azure regions) — prevents DCR/workspace region mismatch.
- **githubRepo** field in wizard Advanced tab — supports forks without Bicep changes.

### Removed
- `deploy/modules/log-analytics.bicep` — no longer used. Workspace is always external.
- "Create new workspace" code paths in `main.bicep` and `mainTemplate.json`.

## [1.0.0] — TBD

First production release.

### Features
- **52 portal-only telemetry streams** across 7 compliance tiers (P0 config · P1 pipeline · P2 governance · P3 exposure · P5 identity · P6 audit · P7 metadata).
- **Two unattended auto-refreshing authentication methods**: Credentials+TOTP (RFC 6238) and Software Passkey (WebAuthn ECDSA-P256). DirectCookies mode available for test/lab use.
- **Manifest-driven client module**: single `endpoints.manifest.psd1` catalogues every stream; one `Invoke-MDEEndpoint` dispatcher; one `Invoke-MDETierPoll` per-tier loop. No per-endpoint wrappers.
- **9 Azure Functions** (all timer-triggered): heartbeat, auth-self-test, and 7 per-tier pollers.
- **Sentinel content auto-deployed** via nested ARM: 6 KQL drift parsers, 6 workbooks, 15 analytic rules, 10 hunting queries (37 resources total).
- **One-click Deploy-to-Azure** via `mainTemplate.json` + `createUiDefinition.json`. Bicep sources included for custom forks.
- **Content Hub solution package** produced by `tools/Build-SentinelSolution.ps1`.

### Scope
- Read-only: every manifest entry is an HTTP GET. No action-triggering endpoints.
- Research basis: XDRInternals, DefenderHarvester (nodoc), CloudBrothers April-2026 sccauth disclosure.

### Verification
- 296 offline Pester tests · 100% public-function coverage across 3 modules.
- 0 PSScriptAnalyzer errors.
- 3-OS local test run; CI runs Ubuntu-only for cost + speed (production parity).

[Unreleased]: https://github.com/akefallonitis/xdrlograider/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/akefallonitis/xdrlograider/releases/tag/v1.0.0
