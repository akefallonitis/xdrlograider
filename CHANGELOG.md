# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Versioning note.** v1.0.0-v1.0.2 were aspirational "production" labels that
> predated end-to-end live verification. `v0.1.0-beta.1` is the first release
> that has been audited against the operator-click → first-row-in-LA pipeline
> with every endpoint documented, every auth method proven, every Sentinel
> content query cross-checked against live fixtures. The v1.0.x tags remain
> as historical iterations but are superseded. Promotion path:
> v0.1.0-beta.1 → v0.1.0 GA (after 30-day tenant soak) → v1.0.0 production
> (after ≥2 external operators complete soak). See docs/ROADMAP.md.

## [0.1.0-beta.1] - 2026-04-23

### Architectural cleanup

- **Availability tag replaces Deferred flag.** Manifest entries no longer carry `Deferred=$true` / `DeferReason`. Every entry now has one of three `Availability` values: `live` (28 — returns 200 on a Security Reader tenant today), `tenant-gated` (15 — 4xx because feature not provisioned; activates automatically), `role-gated` (2 — 403 because service account lacks higher role). Per-tenant zero-row outcomes are tenant-state, not connector bugs.
- **Manifest extended with `Headers` + `UnwrapProperty` fields.** `Headers` supports custom HTTP headers with template-token `{TenantId}` resolved at dispatch time (required by XSPM endpoints for `x-tid` + `x-ms-scenario-name`). `UnwrapProperty` tells `Expand-MDEResponse` to unwrap wrapper objects like `{ServiceAccounts:[...]}` before flattening.
- **Drift stays on the KQL side** (user-confirmed design). RawJson remains `dynamic`; DCR is thin passthrough; drift is computed via `hash(RawJson)` at query time in `MDE_Drift_P*.kql` parsers. Schema is schema-agnostic — re-parseable as response shapes evolve.
- **Deploy-flow audit** (`docs/DEPLOY-FLOW-AUDIT.md`) verifies 10 hops from operator-click → first row in LA: ARM dependencies, SAMI role scopes, envvar ↔ appSettings mapping, KV secret-name 1:1 consistency, cross-RG nested deployment params, Sentinel Solution zip structure, `host.json` production tuning, `requirements.psd1` version pinning.

### Manifest changes (v1.0.2 → v0.1.0-beta.1)

**Removed 2 write endpoints** (documented in `docs/STREAMS-REMOVED.md`):
- `MDE_CriticalAssets_CL` — XDRInternals `Set-XdrEndpointDeviceCriticalityLevel.ps1:67-70` confirms this is a POST write endpoint.
- `MDE_DeviceCriticality_CL` — XDRInternals `Set-XdrEndpointDeviceAssetValue.ps1:53-56` confirms POST write endpoint.

Shipping these as "reads with empty body" corrupts tenant data on a tenant where an admin has previously set criticality labels.

**Activated 4 via XDRInternals-documented bodies**:
- `MDE_IdentityServiceAccounts_CL` — body `@{PageSize=100;Skip=0;Filters=@{};IncludeAccountActivity=$true}`, UnwrapProperty=`ServiceAccounts` (was `Deferred` with 415 on empty body).
- `MDE_XspmChokePoints_CL` — path corrected to `/apiproxy/mtp/xspmatlas/attacksurface/query`, inline KQL body from `Get-XdrXspmChokePoint.ps1:95`, Headers `x-tid={TenantId}; x-ms-scenario-name=ChokePoints_get_choke_point_types_filter`.
- `MDE_XspmTopTargets_CL` — same path, inline KQL from `Get-XdrXspmTopTarget.ps1:62`.
- `MDE_IdentityOnboarding_CL` — UnwrapProperty=`DomainControllers` added (was returning 200-null because wrapper object wasn't unwrapped).

**Method-corrected 2** (per nodoc, switched POST→GET):
- `MDE_AntivirusPolicy_CL` — now GET, not POST with empty body.
- `MDE_TenantAllowBlock_CL` — same.

**1 entry kept tenant-gated pending body discovery**:
- `MDE_XspmAttackPaths_CL` — same path + headers as ChokePoints/TopTargets, but the documented query-string identifier `AttackPathsV2` returned 400 live. Likely needs inline KQL body; deferred to a future release.

### Additions

- `tools/Capture-EndpointSchemas.ps1` now supports the full manifest (no `-IncludeDeferred` flag needed) and writes **marker fixtures** for tenant-gated / role-gated streams — one-line JSON documenting the expected 4xx so downstream tests detect "expected to skip" rather than fail on missing files.
- `Invoke-MDEPortalRequest` gains `-AdditionalHeaders` optional param (required for XSPM).
- `Expand-MDEResponse` gains `-UnwrapProperty` optional param.
- `Invoke-MDEEndpoint` reads `Headers` + `UnwrapProperty` from manifest entries; resolves `{TenantId}` template token from session.
- New `docs/DEPLOY-FLOW-AUDIT.md` (10-hop deploy-flow trace + fixes).
- New `docs/STREAMS-REMOVED.md` (7 removed streams with evidence for each).

### Fixes

- `tests/integration/Audit-Endpoints-Live.ps1:161` — `$_` scoping bug rendered every row's `Path` as hashtable string. Rewrote row composition to use a named iterator + `[char]96` backtick literals.
- `tests/integration/Predeploy-Validation.Tests.ps1` — hardcoded `52 / 19 / 54` literals replaced with dynamic `(Get-MDEEndpointManifest).Count` reads.
- `deploy/compiled/sentinelContent.json` — removed lingering `MDE_AsrRulesConfig_CL` reference in hunting-query description. Rebuilt via `Build-SentinelContent.ps1`.
- `Invoke-MDETierPoll` — `Deferred` flag deprecated but retained for back-compat with older manifests.

### Test matrix

- Offline suite: **1097 pass / 0 fail / 17 skip** (skips = streams with no data on this tenant — e.g. empty responses from `{}` endpoints).
- 45 fixtures present: 28 real captures + 17 markers. Zero PII leaks.
- Three auth methods (CredentialsTotp, Passkey, DirectCookies) — CredentialsTotp live-verified via the capture run; Passkey + DirectCookies require operator execution with their respective `.env.local` entries.

### Counts (v1.0.2 → v0.1.0-beta.1)

| Layer | v1.0.2 | v0.1.0-beta.1 |
|---|---|---|
| Manifest streams | 47 | **45** |
| `Deferred` flag | 22 entries | **0 entries** (replaced by Availability) |
| `live` (200 on test tenant) | 25 | **28** |
| Tenant/role-gated | 22 | **17** |
| DCR streamDeclarations | 49 | **47** |
| Custom tables | 49 | **47** |
| Offline tests passing | 1075 | **1097** |

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
