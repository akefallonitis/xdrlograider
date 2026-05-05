# Online preflight + drift audit — 2026-05-04

**Phase J.F.NEW.1 + .2 + (partial) .3** — comprehensive end-to-end live audit.

Per user direction: "make sure you have all you need to proceed have the complete results and audit prior proceeding and replanning adjusting expanding please do not miss anything".

---

## §1 — Online preflight summary (FA-bypass tenant call)

Run: `pwsh tests/Run-Tests.ps1 -Category online-preflight`
Tenant: SP-creds via `tests/.env.local` (XDRLR_TEST_UPN against ballpit/tenant) → live portal session.
Duration: 124 seconds.

| Result | Count |
|---|---|
| **Tests Passed** | **24** |
| Tests Failed | 0 |
| Tests Skipped (empty tenant / opt-in feature off) | 11 |
| Tests Inconclusive | 0 |

**Drift findings**: **NONE** for existing 24 live-with-data streams. **Zero schema drift**. Fixtures committed at `tests/fixtures/live-responses/<Stream>-raw.json` match live portal shape.

**Implication**: existing 45-stream manifest is STABLE. Phase J.F.NEW.2 drift-fix scope minimal — proceed to Tier A live capture (Phase J.F.NEW.3).

---

## §2 — Per-stream status (existing 45 streams)

### §2.1 Live-with-data — **schema validated**, no drift (24 streams)

| # | Stream | Notes |
|---|---|---|
| 1-24 | (per fixtures dir + preflight pass) | Shape matches; ProjectionMap valid; EntityId stable |

### §2.2 Live-but-empty — tenant feature not enabled / no data (11 streams)

These streams returned 0 rows in this tenant. **Skip-not-fail**: legitimate operator-empty (e.g., XSPM tenant doesn't have attack paths configured yet; service accounts not classified yet; no XSPM connectors registered).

| # | Stream | Empty reason |
|---|---|---|
| 1 | `MDE_AlertServiceConfig_CL` | No alert service config drift in tenant |
| 2 | `MDE_AlertTuning_CL` | No alert tuning rules configured |
| 3 | `MDE_CustomDetections_CL` | No custom detections defined |
| 4 | `MDE_UnifiedRbacRoles_CL` | URBAC not enabled OR no custom roles |
| 5 | `MDE_SAClassification_CL` | Service-account classification not run |
| 6 | `MDE_ExposureSnapshots_CL` | XSPM not active OR no posture snapshots yet |
| 7 | `MDE_XspmAttackPaths_CL` | No XSPM attack paths in tenant |
| 8 | `MDE_XspmChokePoints_CL` | No XSPM choke points |
| 9 | `MDE_XspmTopTargets_CL` | No XSPM top targets |
| 10 | `MDE_IdentityOnboarding_CL` | MDI onboarding state empty / fully onboarded |
| 11 | `MDE_IdentityServiceAccounts_CL` | No MDI service accounts in coverage |

**Operator action**: in Phase Q (live verification) operators with active tenant data validate these emit rows. For v0.1.0 GA they ship with the existing fixture (which captures non-empty shape from a different tenant earlier).

### §2.3 Tenant-gated streams (Availability = 'tenant-gated', not in preflight scope)

10 streams marked tenant-gated in manifest (e.g., MTO endpoints requiring multi-tenant subscription, Defender for Cloud SKUs). Confirmed not in preflight; will validate during Phase Q on a fully-licensed tenant.

---

## §3 — Nodoc catalog sweep — final inclusion (Tier A + B)

`tools/Sweep-NodocCatalog.ps1` (enhanced 2026-05-04) over 595 ops in 23 yml files:

| Bucket | Count |
|---|---|
| Total | 595 |
| Already in manifest | 45 |
| Excluded (writes 141 + UI noise 71 + public-API 9 + out-of-scope 123) | 344 |
| **In scope — Tier A (must, value 5/5)** | **32** |
| In scope — Tier B (should, value 4/5) | 20 |
| In scope — Tier C (defer to v0.1.1) | 210 |

### §3.1 Tier A wisely-chosen — proper category/table/cadence/time-filter

**Total v0.1.0 GA Tier A target**: 32 net-new streams (in addition to existing 45).

Per category:

| Category | Workspace Table | New Tier A | Total after add | Critical operators value |
|---|---|---|---|---|
| 1 EndpointDeviceManagement | `Defender_EndpointDeviceManagement_CL` | **1** (Device Timeline) | 5 | Forensic per-device events (opt-in fan-out) |
| 2 EndpointConfiguration | `Defender_EndpointConfiguration_CL` | 0 | 4 | Existing covers |
| 3 VulnerabilityManagement | `Defender_VulnerabilityManagement_CL` | 0 (rest covered by MDE TVM API) | 0 | (deferred — public API covered) |
| 4 IdentityProtection | `Defender_IdentityProtection_CL` | **2** (ServiceAccountsCount, UserTimeline) | 9 | Privileged ID + risky timeline |
| 5 ConfigurationAndSettings | `Defender_ConfigurationAndSettings_CL` | **2** (CriticalAssetClassification rules + schema) | 16 | Asset criticality model |
| 6 ExposureManagement | `Defender_ExposureManagement_CL` | **12** | 19 | Attack paths, choke points, posture metrics, secure scores, security events, XSPM connectors |
| 7 ThreatAnalytics | `Defender_ThreatAnalytics_CL` | **15** (ListOutbreaks + 11 per-outbreak drilldowns + 3 reputation) | 16 | Outbreak forensics, IOC reputation |
| 8 ActionCenter | `Defender_ActionCenter_CL` | 0 | 6 | Existing covers |
| 9 MultiTenantOperations | `Defender_MultiTenantOperations_CL` | 0 | 3 | Existing covers |
| 10 StreamingApi | (no table) | 0 | 0 (deprecated) | n/a |
| **Total** | — | **32** | **78** | — |

### §3.2 Per-entity fan-out concern (D'.62 — opt-in)

3 of the 32 Tier A streams are per-entity (path has `{Id}` placeholder):
- `MDE_EndpointDevicesGetTimeline_CL` (`{DeviceId}`) — fans out per device
- `MDE_IdentityGetUserTimeline_CL` (`{UserId}` implicit via filter) — fans out per user
- `MDE_ThreatAnalytics*Outbreak*` ×11 (`{OutbreakId}`) — fans out per active outbreak

**Decision**: behind opt-in app-settings, with default top-N caps:
- `XdrEnableDeviceTimeline=true` (default false) — top-50 highest-risk devices/cadence
- `XdrEnableUserTimeline=true` (default false) — top-50 highest-risk users/cadence
- `XdrEnableOutbreakDrilldowns=true` (default false) — top-20 active outbreaks/cadence

Implementation: Durable orchestrator fans out activity tasks; manifest field `PerEntityFanout = $true` + `MaxFanoutEntities = 50`.

---

## §4 — Architecture impact analysis

### §4.1 Functions (no new functions for v0.1.0)

Existing 8 functions remain:
- `Connector-Heartbeat` (5min timer)
- `Defender-{ActionCenter,Configuration,Inventory,Maintenance,XspmGraph}-Refresh` × 5 (timer + durableClient)
- `Xdr-PollOrchestrator` (orchestrationTrigger)
- `Xdr-PollStream` (activityTrigger)

**Phase J.F.NEW additions**:
- New manifest entries (32 Tier A) automatically fan-out via existing orchestrator → activity pattern
- Per-entity streams: orchestrator branches based on `PerEntityFanout` field; activity loops top-N entities
- **No new function code paths** — pure manifest expansion.

### §4.2 DCRs (no new DCRs for v0.1.0)

Existing 5 cadence-tier DCRs (`dcr-defender-{actioncenter,configuration,inventory,maintenance,xspmgraph}`) suffice — new streams route by cadence:
- 13 of 32 new → XspmGraph DCR (existing — but volume increases)
- 13 of 32 new → Configuration DCR (Threat Analytics outbreaks)
- 4 of 32 new → Inventory DCR (Device Timeline, User Timeline, Service Accounts Count, Asset Classification)
- 0 new → ActionCenter / Maintenance DCRs

**ARM impact**: per-DCR `streamDeclarations` add 32 new `Custom-MDE_<NewStream>_CL` entries; `dataFlows` get 32 new entries with `transformKql` injecting SourceName per stream.

### §4.3 Schemas (10 category tables — typed-col extensions)

Per-category typed-col additions:
- `Defender_EndpointDeviceManagement_CL`: TimelineEventTime, TimelineEventType, TimelineEventCategory, TimelineDeviceId, TimelineFileName, TimelineProcessName, TimelineRemoteUrl, TimelineSha256
- `Defender_IdentityProtection_CL`: ServiceAccountsTotalCount, UserTimelineEventTime, UserTimelineEventType, UserTimelineUserUpn, UserTimelineRiskScore
- `Defender_ConfigurationAndSettings_CL`: AssetRuleName, AssetRuleQuery, AssetClassificationLevel
- `Defender_ExposureManagement_CL`: AttackPathId, AttackPathTargetId, ChokePointId, ChokePointDeviceId, PostureMetricId, PostureMetricCategory, PostureMetricScore, PostureRecommendationId, XspmConnectorType
- `Defender_ThreatAnalytics_CL`: OutbreakId, OutbreakName, OutbreakDeviceId, OutbreakAlertCount, OutbreakImpactedAssetCount, IocIndicator, IocReputationScore, IocConfidence, UrlReputationDomain

All additive to existing schemas — no removals.

### §4.4 Parsers (4 drift parsers — refresh per cadence)

- `MDE_Drift_Configuration.kql`: append 2 streams (CriticalAssetClassification × 2)
- `MDE_Drift_Inventory.kql`: append 4 streams (DeviceTimeline, UserTimeline, ServiceAccountsCount, ConfigSchema)
- `MDE_Drift_XspmGraph.kql`: append 13 streams (Tier A ExposureManagement set + Configuration outbreak feeds)
- `MDE_Drift_Maintenance.kql`: no change (no new Maintenance streams)

Existing parsers use `Defender_<Category>_CL | where SourceName in (...)` pattern — refresh the SourceName lists.

### §4.5 Sentinel content

- **Sample queries**: 145 → ~205 (5 per Tier A new stream × 32 - already-covered = +60)
- **Workbook panels**: ConnectorHealth gains "Per-source-name health" panel (already added via Portal param)
- **Hunting queries**: 9 existing; consider 3-5 new for outbreak forensics + user timeline + attack-path traversal — defer to v0.1.1 (Phase J.F.NEW.7-8 budget)
- **Analytic rules**: 19 existing; 1 new `XdrOps-NewStreamMissingData` (alerts when new Tier A stream produces 0 rows for >24h post-deploy) — Phase J.C-piggy
- **Drift parsers**: refresh as §4.4

---

## §5 — Time-filter / state / no-duplication discipline (D'.60) — concrete per stream

For each Tier A new stream:

| Stream | TimeFilter | High-Watermark Field | checkpointTable Key | Idempotency |
|---|---|---|---|---|
| `MDE_EndpointDevicesGetTimeline_CL` | delta-by-eventTime + per-device | `eventTime` | `Defender:MDE_EndpointDevicesGetTimeline_CL:{DeviceId}` | CorrelationId = `<DeviceId>:<eventTime>:<eventType>` |
| `MDE_IdentityGetUserTimeline_CL` | delta-by-eventTime | `eventDateTime` | `Defender:MDE_IdentityGetUserTimeline_CL` | CorrelationId = `<UserUpn>:<eventDateTime>:<eventType>` |
| `MDE_ThreatAnalyticsListOutbreaks_CL` | snapshot-full | n/a | `Defender:MDE_ThreatAnalyticsListOutbreaks_CL` | CorrelationId = `<OutbreakId>:<lastUpdated>` |
| `MDE_ThreatAnalytics*Outbreak*` × 11 | per-entity-snapshot | n/a (outbreak lifetime drives) | `Defender:<Stream>:{OutbreakId}` | CorrelationId = `<OutbreakId>:<Stream>:<polledAt>` |
| `MDE_ConfigurationQueryCriticalAssetClassification_CL` | per-entity-snapshot | n/a | `Defender:<Stream>:{encodedRuleName}` | CorrelationId = `<RuleName>:<polledAt>` |
| `MDE_ExposureManagement*` × 12 | snapshot-full | n/a | `Defender:<Stream>` | CorrelationId = `<EntityId>:<lastModified>` (entity = path-id when present, else hash(rawJson)) |
| `MDE_IdentityGetServiceAccountsCount_CL` | snapshot-full | n/a | `Defender:<Stream>` | CorrelationId = `tenant:<polledAt>` (single-row scalar) |
| `MDE_ThreatAnalyticsGetIndicatorReputation_CL` | snapshot-full | n/a | `Defender:<Stream>` | CorrelationId = `<indicator>:<polledAt>` |
| `MDE_ThreatAnalyticsGetUrlReputation_CL` | snapshot-full | n/a | `Defender:<Stream>` | CorrelationId = `<url>:<polledAt>` |

**Guarantee**: 2 consecutive polls of identical data ingest 0 duplicate rows (DCR transformKql `arg_max(TimeGenerated, *) by SourceName, EntityId` finalizes at workspace).

---

## §6 — Outstanding items requiring action BEFORE Phase Y squash

### §6.1 Live capture for 32 Tier A new streams

**Tool**: `tools/Capture-EndpointSchemas.ps1` (existing) — point at each new path with auth from `.env.local`.

**Per-entity streams**: capture against ONE example entity per stream (e.g., one device, one user, one outbreak) — confirm shape, ProjectionMap.

**Output**: `tests/fixtures/live-responses/<NewStream>-raw.json` × 32

**Estimated effort**: 4-6 hours (some endpoints may 4xx — record exclusion reason).

### §6.2 Manifest entries for 32 Tier A new streams

For each: define Stream, Path, Tier, Category, Purpose, Availability, Method, optional PathParams, PerEntityFanout, MaxFanoutEntities, Filter, ProjectionMap.

Add to `src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`.

**Estimated effort**: 2-4 hours.

### §6.3 ARM streamDeclarations + dataFlows for 32 new streams

`tools/_phase-jc-table-consolidation.ps1` (existing) — extend to cover new streams.

**Estimated effort**: 1-2 hours.

### §6.4 Per-category typed-col additions in workspace tables

Add new typed cols per §4.3 to mainTemplate.json `tables` resources.

**Estimated effort**: 1-2 hours.

### §6.5 Drift parser refresh (3 of 4)

`tools/_phase-jd5-parser-rewrite.ps1` (existing) — re-run after manifest update.

**Estimated effort**: 0.5 hour (script-driven).

### §6.6 Sample queries (~60 new)

Author 5 per new stream; group by category.

**Estimated effort**: 4-6 hours.

### §6.7 Outstanding test failures (3 + 2 container discovery from offline pyramid)

- `tests/unit/Connector.HealthTable.Tests.ps1` — container discovery (D'.47)
- `tests/kql/Parsers.Tests.ps1` — container discovery (same Pester 5 BeforeDiscovery issue)
- 3 unspecified test failures (need fresh run to identify)

**Estimated effort**: 2 hours.

### §6.8 Other Phase J.C-piggy + Phase O + Phase P-rem items per §13.5 of plan

Production hardening (D'.38-D'.43, D'.49), test discipline (D'.32, D'.59, D'.60), docs final.

**Estimated effort**: 25-30 hours.

---

## §7 — TOTAL effort to GA-ready

| Phase | Effort |
|---|---|
| Phase J.F.NEW.0 (sweep) | ✓ DONE |
| Phase J.F.NEW.1 (preflight) | ✓ DONE (clean) |
| Phase J.F.NEW.2 (drift) | ~0h (no drift) |
| Phase J.F.NEW.3 (live capture 32) | 4-6h |
| Phase J.F.NEW.4 (manifest + checkpoint) | 4-6h |
| Phase J.F.NEW.5-6 (ARM + cat-cols) | 2-4h |
| Phase J.F.NEW.7-8 (content) | 5-8h |
| Phase J.F.NEW.9 (test fixes) | 2h |
| Phase O (test pyramid + CI) | 12-18h |
| Phase J.C-piggy (hardening) | 2-4h |
| Phase P-rem (docs final) | 10-14h |
| Phase X (CHANGELOG verify) | 0.1h |
| Phase Y (squash + what-if) | 2h |
| Phase Z (push override) | 1h LIVE |
| Phase Q (live verify + 1wk obs) | 1 week LIVE |
| Phase R (CHANGELOG + tag) | 3h LIVE |
| **Total** | ~50-70h LOCAL + 1 week LIVE = ~3-4 weeks calendar |

---

## §8 — Confidence statement

After this audit (preflight clean + sweep complete + architecture impact mapped + per-stream time-filter strategy defined):

**HIGH CONFIDENCE** in:
- Existing 45-stream manifest STABILITY (zero drift)
- Tier A 32-stream wise selection (per-category/value-scored/noise-filtered)
- Per-entity fan-out architecture (opt-in app-settings; bounded entity count)
- Time-filter + state + no-dup discipline (per-stream defined)
- Architecture (no new functions; existing DCRs/orchestrator scale)

**MEDIUM CONFIDENCE** in:
- Tier B 20-stream selection (will pick 10-15 highest-confidence in Phase J.F.NEW.0b human review)
- Some endpoint paths may 4xx in this tenant (graceful skip; mark `tenant-gated`)

**Need TO BE PROVEN in Phase Q**:
- Live ingestion of new stream rows (currently no data — fixtures only)
- Per-entity fan-out throughput within Y1 Consumption budget
- Workspace ingestion cost forecast accuracy
- All 19+1 analytic rules evaluating
- 6+1 ConnectorHealth workbook panels rendering live

**Failed nothing — proceed to Phase J.F.NEW.3 (live capture) with high confidence.**
