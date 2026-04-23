# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-04-23

### Changed — production-readiness sweep

- **Manifest cleanup**: 52 streams → **47** (25 active + 22 deferred). Removed 5 streams with
  no public portal API (`MDE_AsrRulesConfig_CL`, `MDE_AntiRansomwareConfig_CL`,
  `MDE_ControlledFolderAccess_CL`, `MDE_NetworkProtectionConfig_CL`,
  `MDE_ApprovalAssignments_CL`) — these features are only accessible via Intune / Graph
  `deviceManagement` APIs, which is out of scope for this connector. Source audit: nodoc
  (576 paths) + XDRInternals (150 paths) + DefenderHarvester (12 paths) + live audit
  2026-04-23 against the tenant.
- **Path fixes**: `MDE_CriticalAssets_CL` + `MDE_DeviceCriticality_CL` now point to the correct
  NDR endpoints (`/apiproxy/mtp/ndr/machines/criticalityLevel` +
  `/apiproxy/mtp/ndr/machines/assetValues`) per XDRInternals lines 68–69. Both remain
  DEFERRED until the POST body schema is HAR-captured (v1.1 scope).
- **Re-deferrals based on live audit**: `MDE_TenantWorkloadStatus_CL` (400 on single-tenant,
  requires MTO), `MDE_IdentityServiceAccounts_CL` (415, POST body unknown),
  `MDE_MtoTenants_CL` (400 on single-tenant). All moved from ACTIVE to DEFERRED with
  evidence-backed DeferReason tags.
- **Heartbeat schema extended to 9 columns** (BUG #1): was 4-col baseline silently dropping
  `FunctionName`, `Tier`, `StreamsAttempted`, `StreamsSucceeded`, `RowsIngested`,
  `LatencyMs`, `HostName`, `Notes`. Now DCR + workspace table declare all 9 so every
  `MDE_Drift_*` / compliance workbook query returns real data.
- **AuthTestResult schema extended to 12 columns** to match `Write-AuthTestResult`
  emission (`Method`, `PortalHost`, `Upn`, `Success`, `Stage`, `FailureReason`, `EstsMs`,
  `SccauthMs`, `SampleCallHttpCode`, `SampleCallLatencyMs`, `SccauthAcquiredUtc`,
  `TimeGenerated`).
- **P3 drift parser column alignment**: added `SnapshotCurrent` + `SnapshotPrevious` so all
  6 tier parsers project the same 9-column drift schema. Analytic rules + workbooks that
  query either now behave consistently.
- **Timer functions wrapped in top-level try/catch**: all 7 `poll-p*/run.ps1` now emit a
  failure heartbeat with `Notes.fatalError = <exception message>` before re-throwing, so
  operator sees breakage in `MDE_Heartbeat_CL` instead of silence.
- **Coverage glob honesty**: `src/functions/**/*.ps1` excluded from line-coverage (verified
  via AST + execution tests instead). Real module coverage metric rises to ~41.7% from the
  misleading 36.8%. See `tests/unit/TimerFunctions.Shape.Tests.ps1` +
  `TimerFunctions.Execution.Tests.ps1`.

### Added — production verification

- **tools/Capture-EndpointSchemas.ps1**: captures live portal responses into
  `tests/fixtures/live-responses/` for every active stream. Automatic PII redaction
  (GUIDs, UPNs, IPs, bearer tokens, tenant name) keeps fixtures safe to commit.
- **25 live fixtures** (raw + ingest pairs) captured 2026-04-23 from a real tenant,
  forming the single source of truth for every downstream offline test.
- **tests/unit/FA.ParsingPipeline.Tests.ps1** (164 assertions): each ACTIVE stream's
  `Expand-MDEResponse` + `ConvertTo-MDEIngestRow` output verified against fixtures —
  catches IdProperty misconfig, JSON-shape changes, RawJson round-trip bugs.
- **tests/unit/DCR.SchemaConsistency.Tests.ps1** (49 assertions): every ingest-row column
  set cross-checked against the DCR streamDeclaration in `deploy/compiled/mainTemplate.json`
  — guarantees no silent-drop columns and no forever-null columns.
- **tests/kql/AnalyticRules.Tests.ps1** (70 assertions × 14 rules): every rule's query
  verified — no references to removed streams, all stream names in manifest, all parser
  calls point at existing parsers, parens balanced.
- **tests/kql/HuntingQueries.Tests.ps1** (45 assertions × 9 queries): same invariants.
- **tests/kql/Workbooks.Tests.ps1** (36 assertions × 6 workbooks): walks `items[].content.query`
  tree, applies the same rules.
- **tests/unit/TimerFunctions.Execution.Tests.ps1** (42 assertions × 7 timers): AST-level
  verification that each timer's catch block captures `$_.Exception.Message`, emits a
  `fatalError`-tagged heartbeat, and re-throws.
- **.github/workflows/capture-schemas.yml**: manual-dispatch workflow for operators to
  refresh fixtures against their tenant (gated on `XDRLR_CAPTURE=true`).

### Removed

- 5 streams with no public portal API — see Manifest cleanup above.
- `sentinel/analytic-rules/AsrRuleDowngrade.yaml` — depended on removed stream.
- `sentinel/hunting-queries/AsrRuleStateTransitions.yaml` — depended on removed stream.
- `tests/fixtures/sample-snapshots/MDE_AsrRulesConfig_drift_scenario.json` — obsolete.
- ASR rule modes tile in `sentinel/workbooks/MDE_ComplianceDashboard.json`.

### Counts (post-cleanup)

| Layer | v1.0.1 | v1.0.2 |
|---|---|---|
| Manifest streams | 52 | **47** |
| Active on Security Reader tenant | 26 | **25** |
| Deferred | 26 | **22** |
| DCR streamDeclarations | 54 | **49** (47 data + 2 system) |
| Custom tables | 54 | **49** |
| Analytic rules | 15 | **14** |
| Hunting queries | 10 | **9** |
| Offline tests passing | 620 | **1075** |

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
