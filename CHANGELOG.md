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

## [0.1.0-beta] - 2026-04-24

### Deploy blockers fixed (post-tag patches, same v0.1.0-beta tag)

#### Iteration 13 — Function App actually executes user code (Linux Consumption Legion managed-dependencies fix)

Iter 12 successfully shipped 3 deploy-blocker fixes (zip flatten, URL pin, GenericUI/2021-03-01-preview canonical pair). Connector card surfaced in Sentinel UI, all 14 ARM resources deployed, 47/47 custom tables created, 3/3 SAMI roles granted. But during the 14-phase post-deploy verification, **6 of 14 phases failed** — all tracing to ONE root cause + 2 verification-script bugs + 1 connector-card cosmetic gap.

**Critical fix (data-flow blocker)**:

- **Linux Consumption "Legion" runtime does NOT support Managed Dependencies.** App Insights captured 215 exceptions/h all with the same message: `"Failed to install function app dependencies. Error: 'Managed Dependencies is not supported in Linux Consumption on Legion. Please remove all module references from requirements.psd1 and include the function app dependencies with the function app content.'"` Every function load (heartbeat-5m, all 7 poll-* timers, validate-auth-selftest) fails at `ProcessFunctionLoadRequest` BEFORE user code runs. Confirmed via [Microsoft GitHub Issue #944](https://github.com/Azure/azure-functions-powershell-worker/issues/944) + [official guidance at https://aka.ms/functions-powershell-include-modules](https://aka.ms/functions-powershell-include-modules).

  **Cascading symptoms (all downstream of the same bug)**:
  - Heartbeat sporadic (3 of 24 5-min bins, should be 24/24)
  - MDE_AuthTestResult_CL has 0 rows (auth chain never runs)
  - 1 of 47 tables has rows (only Heartbeat partial; 46 empty)
  - Connector status "Disconnected" in Sentinel UI despite some heartbeats
  - 215 exceptions/h in App Insights

  **Fix** (3 files):
  - `src/requirements.psd1` — emptied (was: Az.Accounts 3.* / Az.KeyVault 6.* / Az.Storage 7.*)
  - `src/host.json` — `managedDependency.Enabled = true → false` (also bumped App Insights `maxTelemetryItemsPerSecond: 5 → 20` for better incident-response visibility)
  - `.github/workflows/release.yml` — added `Save-Module Az.Accounts/Az.KeyVault/Az.Storage` (MinimumVersion 5.0.0/6.0.0/7.0.0) into staged `Modules/` directory before zipping; added module-pruning step (saves ~30% size by removing docs/help/samples); added 10-100 MB zip size budget gate (catches Save-Module silent failure + unintended bloat); added bundled-modules assertion in post-build verification + requirements.psd1 module-free invariant gate.

  **Resulting zip**: 67 KB → 18 MB (compressed; raw Modules/ ~54 MB after pruning). Cold-start adds ~10s but cron tiers tolerate it. Same approach is required by Flex Consumption (Microsoft's strategic Y1 replacement, retiring Linux Consumption Sept 30 2028) — bundled-modules work carries forward to v0.2.0 unchanged.

**High-priority fixes**:

- **Connector card embedded `dataTypes` was 3 of 47.** Iter 11 shipped only Heartbeat + AuthTestResult + AdvancedFeatures in `mainTemplate.json` connectorUiConfig.dataTypes (the standalone `XdrLogRaider_DataConnector.json` already had all 47). Synced the 47-table list across mainTemplate + bicep. New validator gate: `dataConnector.dataTypes.Count == 47`.

- **`connectivityCriterias` query strengthened** to modern `summarize ... | project IsConnected = ...` pattern (per Trend Micro Vision One + AbnormalSecurity reference). Previous `| count | where Count > 0` form caused "Disconnected" status in Sentinel UI even when rows present. New validator gate locks the modern pattern.

- **`Post-DeploymentVerification.ps1` had 3 bugs that hid the real verification results**:
  - **P3 ARM token bug**: `Get-AzAccessToken` without `-ResourceUrl` returns Microsoft Graph token; Sentinel REST API rejects with 401. Plus Az.Accounts 5.x breaking change: `.Token` is now SecureString (caller passing it as a Bearer header value silently produces malformed auth header). Fix: new `Get-ArmPlainToken` helper handles both `-ResourceUrl 'https://management.azure.com/'` + SecureString-to-plain-text conversion via `[System.Net.NetworkCredential]::new('', $secure).Password`.
  - **P3.5 KV management-plane API eventual-consistency**: management-plane secret-list API may not show newly-uploaded secrets for several minutes. Fix: switched to data-plane `Get-AzKeyVaultSecret` (real-time) with management-plane fallback if RBAC denies. Also fixed strict-mode null-guard regression on `.Count` access.
  - **`ExpectedSolutionId` parameter default**: was `'xdrlograider'` (legacy unqualified) but iter 12 changed solutionId to `'community.xdrlograider'` (qualified per Microsoft `<publisher>.<solution-key>` convention). Updated default.

  After all 3 verification fixes: P3 + P3.5 + P12 all GREEN; P4/P5/P8/P9 still RED but those are downstream of the Legion bug — they auto-resolve once iter-13 deploys.

**Documentation + operator clarity**:

- All 9 `function.json` files now have a `description` field — Azure Portal "Function details" pane displays operator-friendly explanation of what each function does + cron cadence + tier purpose. Names stay terse (`poll-p0-compliance-1h`) to avoid checkpoint-table orphan + App Insights dashboard breakage; descriptions provide the context.

- `docs/TROUBLESHOOTING.md` — new entry "FA fails every invocation with 'Failed to install function app dependencies (Managed Dependencies / Legion)'" with cascade explanation + redeploy fix.

- `docs/PERMISSIONS.md` — new section "Audit / SRE service principal" documenting the 4 RBAC roles needed for full 14-phase Post-Deploy verification (Contributor on connector RG + Log Analytics Contributor + Microsoft Sentinel Reader + Key Vault Secrets User on workspace/KV) + one-shot `az role assignment create` snippet.

**New regression gates** (lock the iter-13 invariants):

- `tests/unit/FunctionAppZip.BundledModules.Tests.ps1` — NEW (13 Pester tests): requirements.psd1 module-free, host.json managedDependency=false, release.yml Save-Module Az.Accounts/Az.KeyVault/Az.Storage present, zip size budget gate present, bundled-modules assertion present, requirements.psd1 invariant gate present, prune-step present.
- `tools/Validate-ArmJson.ps1` — 4 new gates: requirements.psd1 module-free, host.json managedDependency=false, dataConnector.dataTypes.Count==47, connectivityCriterias query uses modern pattern.

Test count: 1184 + 13 (new bundled-modules) = 1197 tests. Validator: PASS with 4 new gates. PSScriptAnalyzer: 0 errors.

**Sentinel Content Hub UI fix (DEPRECATED tag + empty info panel)**:

After iter-12 deploy, operator screenshot showed two "XdrLogRaider" entries in Content Hub — both marked **DEPRECATED** with "Solutions marked as deprecated are no longer supported by their respective providers" banner; the right info panel was empty.

**Root cause investigation** (verified against [Microsoft's official ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.securityinsights/2023-04-01-preview/contentpackages) and [Sentinel Solution lifecycle docs](https://learn.microsoft.com/en-us/azure/sentinel/sentinel-solution-deprecation)):

1. **Two entries** = `contentPackages` resources live in the WORKSPACE RG, not the connector RG. Deleting the connector RG between iter-11 and iter-12 left the iter-11 Solution (`contentId='xdrlograider'`) in place; iter-12 added a SECOND Solution (`contentId='community.xdrlograider'` qualified). Sentinel's Content Hub auto-flags duplicate-displayName solutions as DEPRECATED to nudge cleanup.
2. **Empty info panel** = canonical schema requires plain `description` field; we only set `descriptionHtml` which the UI's detail panel doesn't read.
3. **Missing canonical fields**: `categories.verticals`, `isPreview`/`isNew` flags, `threatAnalysisTactics`/`threatAnalysisTechniques` arrays.

**Fix** (mainTemplate.json + bicep + Validate-ArmJson):
- Added plain `description` field (alongside existing `descriptionHtml` for backward compat)
- Added `categories.verticals: []` (empty array, but field present per canonical schema)
- Added `isPreview: 'true'` + `isNew: 'true'` (string flags per Microsoft schema)
- Added `threatAnalysisTactics` + `threatAnalysisTechniques` arrays (declares MITRE coverage at the Solution level)
- Bumped `lastPublishDate: 2026-04-26 → 2026-04-27`
- New Validate-ArmJson gate: `description` must be plain-text populated; `categories.verticals` must exist; `isPreview` should be set.

**Cleanup procedure documented** in `docs/TROUBLESHOOTING.md` — operator runs a REST DELETE loop against the workspace's `contentPackages` to remove stale entries before redeploying. Without this, the DEPRECATED-tagged duplicates will persist forever (deleting the connector RG doesn't remove workspace-side Solution resources).

**Permanent prevention** (lock-in for future version bumps):
- `contentId='community.xdrlograider'` is now STABLE — won't change between v0.1.0-beta → v0.1.0 GA → v1.0.0
- iter-13 forward, all version bumps use the same `contentId`; only `version` field updates → no duplicate-displayName regression

**Production-readiness verdict after iter 13 lands + redeploy**: 14/14 phases GREEN expected. No DEPRECATED tag. Info panel populated.

#### Iteration 12 — Function App boots + connector card surfaces (3 deploy-blockers fixed)

The first deployment landed every ARM resource cleanly but the Function App entered "Runtime: Error" state with 0 functions loaded, MDE_Heartbeat_CL stayed empty, and the connector card never surfaced in Sentinel → Data Connectors. Three confirmed root causes — all evidence-cited via live HTTP probe / zip extraction / Microsoft Learn cross-reference — fixed in iter 12.

- **Bug A — `function-app.zip` had a `functions/` wrapper directory.** Azure Functions PowerShell runtime walks the zip ROOT for subdirectories containing `function.json`. Previous `release.yml` build used `Push-Location ./src; Compress-Archive (Get-ChildItem)` which preserved the `src/functions/` parent → runtime found 0 function dirs at root → "Runtime: Error". Fixed by rewriting the build step to stage to a temp dir with the canonical flat layout (`heartbeat-5m/`, `poll-p0-compliance-1h/`, ...) at root, plus `Modules/` + `host.json` + `profile.ps1` + `requirements.psd1`. Validation gates now ASSERT NO `functions/` wrapper + all 9 expected timer dirs at root + no `local.settings.json*` stowaways. New offline Pester gate `tests/unit/FunctionAppZip.Structure.Tests.ps1` (13 tests) catches this in PR before tag/push.
- **Bug B — `functionAppZipVersion` default `'latest'` returns 404 for pre-release tags.** GitHub `/releases/latest/download/...` resolves only to non-pre-release tags by design. Live HTTP probe confirmed: `/releases/latest/download/function-app.zip` → 404; `/v0.1.0-beta/download/function-app.zip` → 200. The wizard default silently caused FA to download nothing. Fixed default in `mainTemplate.json` + `createUiDefinition.json` + `main.bicep` to explicit `0.1.0-beta`. New validator gate bans `'latest'` defaults across all three files.
- **Bug C — Connector card stayed hidden in Sentinel → Data Connectors blade (kind=StaticUI → GenericUI).** Iter 5 shipped `kind: StaticUI` + `apiVersion: 2023-04-01-preview`. StaticUI is documented for first-party Microsoft solutions (Defender XDR, MDE, Office 365); Sentinel's UI blade indexer treats StaticUI from non-Microsoft publishers differently after direct ARM deploy, leaving the card hidden. Trend Micro Vision One reference (community FA-based connector, last published 2024-07-16, still active in Azure-Sentinel master 2026-04-26) uses `kind: GenericUI` + `apiVersion: 2021-03-01-preview` — which Lookout (committed 2026-04-24) and Qualys VM (committed 2026-04-23) ALSO use. Migrated dataConnector to GenericUI + 2021-03-01-preview pair. Updated DataConnector metadata.parentId to use `extensionResourceId(workspace, 'Microsoft.SecurityInsights/dataConnectors', id)` form per Trend Micro reference (the hierarchical resourceId() form produces a different canonical ID string the indexer doesn't always chain back).
- **Microsoft deprecation audit (2026-04-26).** Verified: NO deprecation notice for `Microsoft.OperationalInsights/workspaces/providers/dataConnectors @ 2021-03-01-preview` for kind=GenericUI. The March 2026 retirement scoped explicitly to Source Control APIs only. HTTP Data Collector API retiring Sept 14 2026 — not affected (we use Logs Ingestion API). Codeless Connector Framework (CCF) is Microsoft's recommended path for new connectors but doesn't fit our custom-auth FA-based architecture; deferred to v0.2.0+ as future-compat.
- **Phase P3.5 added to `Post-DeploymentVerification.ps1`** — Key Vault structure validation (RBAC mode + expected secret names + SAMI Secrets User role). Total phases: 14 (was 13).
- **3 new validator gates** in `tools/Validate-ArmJson.ps1`: (a) latest-default ban for functionAppZipVersion across mainTemplate + createUiDefinition + bicep; (b) dataConnector canonical-shape lock (type + kind=GenericUI + apiVersion=2021-03-01-preview); (c) DataConnector metadata.parentId must use extensionResourceId() form.
- **3 new Pester gates** added to `tests/arm/MainTemplate.Tests.ps1` (functionAppZipVersion default not 'latest', dataConnector apiVersion 2021-03-01-preview, parentId extensionResourceId form) + 1 to `tests/arm/SentinelContent.Schema.Tests.ps1` (every metadata.parentId resolves to a content resource of the matching kind).

Test count: 1184 / 0 fail / 75 skip (was 1167; +17 new).

#### Iteration 6 — `extensionResourceId` → `resourceId` for hierarchical Solution refs

- **`InvalidTemplate` at template validation**: `Solution-xdrlograider` metadata's `parentId` used `extensionResourceId(workspaceScope, 'Microsoft.OperationalInsights/workspaces/providers/contentPackages', 2-names)` — Bicep's `.id` accessor on a hierarchical `workspaces/providers/<resource>` type emits `extensionResourceId` with the workspace passed as the *scope* (1st arg). ARM rejects: `the type 'Microsoft.OperationalInsights/workspaces/providers/contentPackages' requires '3' resource name argument(s)`. Same wrong shape was emitted for the `dataConnectors` metadata `parentId` and 3 `dependsOn` references. Replaced **all 5 occurrences** in `deploy/compiled/mainTemplate.json` with the canonical `resourceId('Microsoft.OperationalInsights/workspaces/providers/<resource>', workspaceName, 'Microsoft.SecurityInsights', <name>)` form.
- **Static check added** in `tools/Validate-ArmJson.ps1`: any `solution-*` nested deploy whose body contains `extensionResourceId(...)` against a `workspaces/providers/` type fails with a clear repro-ready error.
- **Pester regression test** added in `tests/arm/MainTemplate.Tests.ps1` (`inner template uses resourceId() (NOT extensionResourceId) for hierarchical workspaces/providers types`).

#### Iteration 5 — Sub-technique format + proper Sentinel Solution shape

- **`InvalidPayload` from analytic rules.** Sentinel API regex for `properties.techniques` is `^T\d+$` — sub-technique IDs (`T1562.001`, `T1562.006`) are rejected with `The technique 'T1562.001' is invalid. The expected format is 'T####'`. Fix: strip the `.NNN` suffix in `tools/Build-SentinelContent.ps1` (`-replace '\.\d+$', ''`) and apply the same to compiled `sentinelContent.json`. Sub-technique fidelity remains in the corresponding hunting query's `tags[]` (savedSearches accepts any string). New validator + Pester gates lock the regex.
- **Connector now appears in Sentinel Data Connectors blade.** v0.1.0-beta first deploys never showed XdrLogRaider in the Data Connectors UI alongside Microsoft Defender XDR / MDE / Office 365 — the bicep referenced a `data-connector` module but the compiled `mainTemplate.json` was hand-flattened and **dropped the entire module** (zero data-connector resources reached the workspace). Rebuilt the module + compiled emit using the same 4-resource shape Microsoft uses for first-party solutions:
  1. `Microsoft.OperationalInsights/workspaces/providers/contentPackages` — Solution package, surfaces in Content Hub.
  2. `Microsoft.OperationalInsights/workspaces/providers/metadata` (kind=Solution) — links the package to the workspace.
  3. `Microsoft.OperationalInsights/workspaces/providers/dataConnectors` (kind=`StaticUI`) — the connector card visible in Sentinel → Data Connectors. Status driven by `connectivityCriterias` (heartbeat in last 1h = Connected).
  4. `Microsoft.OperationalInsights/workspaces/providers/metadata` (kind=DataConnector) — links the connector instance to the Solution.
- **Architectural placement.** New `solution-{suffix}` cross-RG nested deploy, always runs (no `deploySentinelContent` condition), depends on `customTables-{suffix}`. Sentinel content (rules / hunting / workbooks / parsers) remains in `sentinelContent-{suffix}` and only deploys when the toggle is on.
- **8 new Pester tests + 4 new validator gates** covering: solution-* nested deploy presence + cross-RG scope, no condition (always deploys), customTables dependency, 4 canonical inner resources, contentKind=Solution, dataConnector kind=StaticUI, parentId back-links to contentPackages and dataConnectors, and (sentinel content) every technique matches `^T\d+$` plus T1595 → Reconnaissance MITRE-consistency check.
- **Dead code removed.** `data-connector.bicep` had a `projectPrefix` param flagged "unused after redesign; kept for caller compatibility" — now properly removed (caller signature updated). Stale "54 custom tables" references in `main.bicep` header + compiled `_metadata.comments` updated to the canonical "47 tables (45 data + Heartbeat + AuthTestResult)".

#### Iteration 4 — Sentinel content array shapes + UX consolidation

- **`InvalidPayload` on Sentinel content deploy.** `sentinelContent.json` emitted analytic-rule `tactics` and `techniques` as scalar strings (`"tactics": "DefenseEvasion"`); the Sentinel Analytics API requires JSON arrays (`AttackTactic[]`). Root cause was the simple YAML parser in `tools/Build-SentinelContent.ps1` flattening 1-item lists to scalars. Fix: wrap in `@(...)` at emit site (forces array shape for both 1-item and N-item cases). Also corrected `T1595` rule's tactic from `Discovery` → `Reconnaissance` (T1595 is Reconnaissance per MITRE).
- **`deploySentinelContent` toggle (default `true`).** New ARM bool param + `condition` on the cross-RG `sentinelContent-*` nested deploy. Wizard exposes "Deploy Sentinel content" Yes/No in the Advanced step. Flip to `No` for connector-only deploys (e.g. when workspace permissions don't allow Sentinel writes, or for re-deploys). Custom tables + Data Connector card still deploy regardless.
- **Wizard auth-secret upload (no script needed).** Three new optional `securestring` ARM params (`servicePassword`, `totpSeed`, `passkeyJson`). Wizard Authentication step now offers "Upload via wizard" vs "Upload via post-deploy script". Selecting wizard reveals conditional secure inputs based on auth method (password + TOTP for `credentials_totp`; passkey JSON for `passkey`). ARM writes them straight to Key Vault as `Microsoft.KeyVault/vaults/secrets` resources. The post-deploy `Initialize-XdrLogRaiderAuth.ps1` script remains supported for users who prefer that path.
- **Workspace warning trimmed.** The 8-line role-explanation infobox replaced with a 1-liner: "Required role on the workspace: Log Analytics Contributor (or generic Contributor / Owner). Microsoft Sentinel Contributor alone is NOT sufficient — does not grant workspaces/tables/write."
- **Deployment output is conditional.** When wizard uploaded all required secrets, the `postDeployCommand` output reads "Auth secrets uploaded by deploy. Self-test result expected within 5 minutes…". Otherwise it shows the original git-clone-and-run-script command.
- **6 new Pester tests** lock the new invariants: deploySentinelContent param presence + default, three secure params declared, sentinelContent nested deploy is conditional, KV secret resources unconditional vs conditional shape, and (compiled JSON) every alertRule's tactics + techniques are JSON arrays.

#### Iteration 3 — DCR creation race condition + multi-stream transform rule

- **`InvalidOutputTable` — DCR was racing the cross-RG customTables nested deploy.** The committed `mainTemplate.json` had been hand-flattened from the Bicep source, dropping the `dependsOn: [ customTables ]` declaration that `deploy/main.bicep:127-129` carries on the `dceDcr` module. Result: ARM ran the DCR PUT in parallel with the cross-RG table-creation deploy, and the DCR API's synchronous "do these tables exist?" check failed with `Table for output stream 'Custom-MDE_*_CL' is not available for destination 'la-destination'`. Fix: added `[concat('customTables-', variables('suffix'))]` (plain-name form, cross-RG dependsOn pattern) to the DCR resource's `dependsOn` array.
- **transformKql dropped from all 3 dataFlows.** Microsoft DCR documentation: *"If you use a transformation, the data flow should only use a single stream."* The previous `source | extend TimeGenerated = todatetime(TimeGenerated)` was redundant anyway since every `streamDeclaration` already declares `TimeGenerated` as `datetime`. Removed across bicep + compiled JSON.
- **Two new validator + Pester gates** (`tools/Validate-ArmJson.ps1`, `tests/arm/MainTemplate.Tests.ps1`):
  - DCR resource must have `customTables-*` in its `dependsOn` (catches the race condition in CI).
  - No dataFlow may combine multiple streams with a `transformKql` (catches the Microsoft-rule violation in CI).

#### Iteration 2 — DCR quota fix — final shape

- **DCR quota fix — final shape.** Azure enforces TWO interlocking DCR quotas at preflight: max 10 `dataFlows` per rule AND max 20 `streams` per dataFlow. Original compile (47 dataFlows × 1 stream each) tripped the first; first patch (1 dataFlow × 47 streams) tripped the second. Final shape splits the 47 streams across **3 tier-grouped dataFlows** — well under both limits with semantic clustering by collection tier:
  - **Flow 1 (P0 Compliance, 15 streams)** — antivirus / device-control / web-content / smartscreen / tenant-allow-block / detections / suppression
  - **Flow 2 (P1+P2+P3, 19 streams)** — pipeline (data-export / streaming / Intune / Purview), governance (RBAC / asset rules), exposure (XSPM / secure score / baselines)
  - **Flow 3 (P5+P6+P7+ops, 13 streams)** — identity (MDI), audit, metadata, Heartbeat, AuthTestResult
  - `outputStream` omitted on every flow so each `Custom-MDE_*_CL` input still routes by name to its like-named workspace table.
- **Static checks added** in `tools/Validate-ArmJson.ps1`: fails any DCR whose `dataFlows.Count > 10`, any individual `dataFlow.streams.Count > 20`, `destinations.Count > 10`, or any orphan `streamDeclaration` not referenced in some `dataFlow.streams`.
- **Pester regression tests** added in `tests/arm/MainTemplate.Tests.ps1` (`DCR — Azure service-quota gates` block, 6 tests) locking in the canonical 3-flow shape so future bicep edits can't accidentally re-explode (`>10` flows) OR re-collapse (`>20` streams in any flow).
- **Repo cleanup.** Removed two internal pre-release artifacts that had leaked into the public tree (`docs/LIVE-AUDIT-EVIDENCE-v0.1.0-beta.1.md` with broken hashtable serialization; `docs/DEPLOY-FLOW-AUDIT.md` internal audit). `docs/README.md` index updated to reference the kept docs (DEPLOY-METHODS, POSTDEPLOY-PLAYBOOK, OPERATIONS, UPGRADE, STREAMS-REMOVED). `.protection-restore.json` added to `.gitignore`.

### Production-hardening consolidation (Phases 1-6 of the v0.1.0-beta plan)

**Function-App consolidation (Phase 1)**
- **Timer boilerplate deduplication.** New `Invoke-TierPollWithHeartbeat` helper (`src/Modules/XdrLogRaider.Client/Public/`) consolidates the 7 `poll-*/run.ps1` bodies from ~45 LoC of copy-paste each into 2-line thin wrappers that call the helper. Net -315 LoC. Single source of truth for auth-gate + credential fetch + portal sign-in + tier poll + heartbeat + fatal-error handling + nested try + re-throw.
- **App Insights sampling tuned.** `host.json` `excludedTypes: "Request,Exception"` (retain Exception traces for incident response); `maxTelemetryItemsPerSecond: 5`; namespaced `logLevel: { "XdrLogRaider": "Information" }`.
- **Cold-start telemetry.** `profile.ps1` adds `$global:XdrLogRaiderColdStartUtc` + `$PSNativeCommandUseErrorActionPreference = $true` (PS 7.4 native-command errors now become terminating).
- **`Az.Monitor` dropped** from `requirements.psd1` (zero runtime references confirmed via grep). Saves ~40 MB cold-start module download per worker.
- **Kudu sidecar disabled.** `function-app.bicep` adds `WEBSITE_SKIP_RUNNING_KUDUAGENT=true` + `FUNCTIONS_WORKER_PROCESS_COUNT=1`.

**Code hardening (Phase 2)**
- **429 Retry-After honoured.** `Invoke-MDEPortalRequest` parses Retry-After (seconds + HTTP-date) with 100-500ms jitter, up to 3 retries. Prevents silent rate-limit data loss (Agent A's #1 production-ready blocker). Cumulative `$script:Rate429Count` exposed via `Get/Reset-XdrPortalRate429Count`. Surfaced to `MDE_Heartbeat_CL.Notes.rate429Count`.
- **Session TTL refresh.** Proactive 3h30m refresh defends against the undocumented ~4h portal sccauth cap.
- **Per-call jitter.** `Invoke-MDETierPoll` sleeps 80-320ms between streams to spread load off portal burst detection.
- **DCE gzip compression.** `Send-ToLogAnalytics` gzip-compresses the POST body with `Content-Encoding: gzip`. Typical 5-10× bandwidth reduction on log payloads. `GzipBytes` returned + aggregated into heartbeat.
- **413 split-and-retry.** Oversized batches are halved + recursed up to depth 3 instead of terminal-failing.
- **Typed exception pattern.** 429-exhausted throws `[MDERateLimited]`-prefixed message callers can regex-match for distinct heartbeat signalling.

**Manifest live-reclassification (Phase 3 — against user's full-access admin account, 2026-04-24)**
- **Baseline**: 26 of 45 streams returned 200 OK.
- **Regression detected**: `MDE_XspmChokePoints_CL` + `MDE_XspmTopTargets_CL` returned 400 (were 200 in v0.1.0-beta.1) — portal-side XSPM query schema has drifted. Both demoted from `live` to `tenant-gated` pending fresh hypothesis cycle.
- Tenant-feature-gated confirmed for 9 streams returning 404 with "Unknown api endpoint" (feature genuinely not provisioned on test tenant: MDI, Intune connector, PUA, Streaming API, Purview, MTO, License Report).
- Role-gated confirmed for 2 streams returning 403 with admin account (MDE_CustomCollection_CL, MDE_CloudAppsConfig_CL) — these genuinely need Defender XDR Operator / MCAS Admin elevation respectively.
- Evidence: `tests/results/endpoint-audit-20260424-104741.{md,csv}`.

**Sentinel Solution + Content Hub compliance (Phase 4)**
- **Data Connector card** now lists all 47 tables in `dataTypes` (was 3). Blocker for Content Hub submission removed.
- **All 14 analytic rules** ship `enabled: false` (Microsoft Sentinel best practice — customer enables selectively after reviewing query + threshold). Prevents alert-fatigue on install.
- **BUG #4 fixed** — `sentinel/hunting-queries/ConfigChangesByUpn.yaml` rewritten: previous query joined `drift.EntityId` (UUID) to `AuditLogs.TargetResources[0].displayName` (string) producing empty / false-positive results. New query correlates by time proximity + AuditLogs category filter; summarises by actor UPN.
- **9 hunting queries** gained `author` + `version` + `tags` metadata (Content Hub hygiene).
- **Custom tables** `plan: 'Analytics'` explicit in Bicep (prevents accidental Basic-plan downgrade that blocks analytic rules).

**Forward-scalable architecture (J2)**
- Manifest `Defaults.Portal = 'security.microsoft.com'` applied at load time. Every entry inherits unless overridden. `Invoke-TierPollWithHeartbeat` accepts optional `-Portal` (defaults security). v0.2.0+ can add `admin.microsoft.com` / `entra.microsoft.com` / other portal entries without touching auth module, ingest module, or timer helper.

**Infrastructure**
- New `tools/Preflight-Deployment.ps1` — single entrypoint production-readiness gate covering 8 sections: offline Pester, PSScriptAnalyzer, ARM+Solution validators, credential hygiene scan, Content Hub compliance, schema consistency, live endpoint audit, deploy-flow integrity. Emits structured markdown + JSON + non-zero exit on any failure.

**Docs**
- CHANGELOG + README + analytic-rules count-asserts + build script all updated from stale "52 streams" / "53 streams" / "15 rules" / "10 hunting" references to current "45 streams / 14 rules / 9 hunting".

**Test suite**: 1034 passed / 0 failed / 17 skipped offline. Live endpoint audit against admin account: 26/45 returned 2xx. CI gates unchanged (removed-stream grep-gate, PSSA, ARM validators).

### Breaking changes from v0.1.0-beta.1

- `XspmChokePoints` + `XspmTopTargets` no longer return rows (API drift; demoted to tenant-gated). Operators should expect zero rows in those two streams until a future release ships corrected bodies.
- Timer function bodies are now 2-line thin wrappers calling `Invoke-TierPollWithHeartbeat`; if you were AST-parsing `poll-*/run.ps1` directly, switch to parsing the helper file.
- `Rate429Count` + `GzipBytes` now appear in `MDE_Heartbeat_CL.Notes` as JSON fields (parse via `parse_json(Notes)`). Not first-class columns by design — avoids DCR schema migration.

### Upgrade notes

Redeploy via the new mainTemplate.json — no manual migration needed. Existing custom tables retain their data; new `plan: 'Analytics'` explicit declaration is a no-op for workspaces already on the default plan. Re-run `Initialize-XdrLogRaiderAuth.ps1` is **not** required (secret-name schema unchanged). See `docs/UPGRADE.md` for full guidance.

## [0.1.0-beta.1] - 2026-04-23

### Architectural cleanup

- **Availability tag replaces Deferred flag.** Manifest entries no longer carry `Deferred=$true` / `DeferReason`. Every entry now has one of three `Availability` values: `live` (28 — returns 200 on a Security Reader tenant today), `tenant-gated` (15 — 4xx because feature not provisioned; activates automatically), `role-gated` (2 — 403 because service account lacks higher role). Per-tenant zero-row outcomes are tenant-state, not connector bugs.
- **Manifest extended with `Headers` + `UnwrapProperty` fields.** `Headers` supports custom HTTP headers with template-token `{TenantId}` resolved at dispatch time (required by XSPM endpoints for `x-tid` + `x-ms-scenario-name`). `UnwrapProperty` tells `Expand-MDEResponse` to unwrap wrapper objects like `{ServiceAccounts:[...]}` before flattening.
- **Drift stays on the KQL side** (user-confirmed design). RawJson remains `dynamic`; DCR is thin passthrough; drift is computed via `hash(RawJson)` at query time in `MDE_Drift_P*.kql` parsers. Schema is schema-agnostic — re-parseable as response shapes evolve.
- **End-to-end deploy-flow audit** verifies 10 hops from operator-click → first row in LA: ARM dependencies, SAMI role scopes, envvar ↔ appSettings mapping, KV secret-name 1:1 consistency, cross-RG nested deployment params, Sentinel Solution zip structure, `host.json` production tuning, `requirements.psd1` version pinning.

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
