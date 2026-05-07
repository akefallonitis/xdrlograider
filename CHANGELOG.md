# Changelog

All notable changes to this project are documented in this file.

This project adheres to [Semantic Versioning 2.0.0](https://semver.org/) and the format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Section R++ (2026-05-07) — comprehensive consolidation post-live-deploy reaudit. Pending tag once Phase H-I local gates green + 7-day live observation post-cadence-revert.

### Changed (Section R++)

- **Truth-signal restoration** — `Invoke-MDEEndpoint` now exposes a 4-state `SuccessKind` (`live` / `live-empty` / `tenant-gated` / `error`) via the new `Get-MDEEndpointLastResult` accessor; the legacy `,@()` return contract is preserved so existing callers don't break. Activity (`Xdr-PollStream`) reads this side-channel and writes `Reason` + `HttpStatus` columns to `XdrTierState` so `Connector-Heartbeat` aggregator + connector card can distinguish "tenant doesn't have feature" from "real failure" from "live but no rows this poll".
- **Schema integrity** — `Defender_ThreatAnalytics_CL` workspace table extended with TopThreats typed cols (TotalActiveThreats, ThreatsExposure, TotalThreatRequiresAction, ThreatExposureCalculationStatus, CurrentAlertsCount); previously these landed via DCR but were silently dropped at the workspace-table layer.
- **Manifest** — added `IdProperty=@('__synthetic__')` + `SyntheticEntityId='<stream>-singleton'` for SingleObjectAsRow streams without natural id (`MDE_ThreatAnalyticsTopThreats_CL`, `MDE_UserPreferences_CL`, `MDE_CloudAppsConfig_CL`); added `IdProperty` for `MDE_DCCoverage_CL` + `MDE_RemediationAccounts_CL`; added forward-compat `RequiresLicense` + `TenantContextProbe` schema fields; reclassified `MDE_UserPreferences_CL` to `Availability='requires-delegated-auth'`; `MDE_CloudAppsConfig_CL` switched to `SingleObjectAsRow=$true`.
- **Detection rules** — `MdiDcSensorDown.yaml` realigned: queryFrequency 15m→4h, queryPeriod 2h→P2D (matches Inventory cadence); FieldName "hasSensor" → "IsActive" (matches manifest typed col).
- **Hunting queries** — `ConfigChangesByUpn.yaml` join switched from exact-equality `==` to 5-min `bin()` bucket (sub-second equality never matched).
- **Workbooks** — `MDE_DriftReport.json` window args aligned to tier cadence (Inventory 1d, Configuration 6h) instead of 1h/30m which missed 23/24+ of poll cycles.
- **Drift parsers** — all 4 (Configuration / Inventory / Exposure / Maintenance) — corrected `ChangeType` classification: previously the "Removed" branch was unreachable (`isnull(TypedBag[field])` false for current-snapshot fields). Replaced with explicit `set_has_element` + `case()` so Added/Removed/Modified classify correctly.
- **Orchestrator** — `Xdr-PollOrchestrator` now filters `Availability='deprecated'` streams (e.g. `MDE_StreamingApiConfig_CL`) — saves auth-call budget + removes 4xx noise from AppExceptions.
- **Connector card UX** — Sentinel UI graphQueries now show `sum(RowsIngested)` over 7d + `max(StreamsSucceeded)` per tier instead of a single AppInsights customEvents counter (the prior chart label "21" was misread as "21 rows landed").

### Added

- New module export `Get-MDEEndpointLastResult` (truth-signal accessor).
- Per-stream AppMetrics emit `xdr.stream.rows_emitted` + `xdr.stream.poll_duration_ms` (regression — was lost when Section R replaced Invoke-MDETierPoll).
- Manifest schema fields `RequiresLicense` (string[]) + `TenantContextProbe` (string) for forward-compat tenant-license short-circuit.
- Manifest schema fields `SyntheticEntityId` (string) for SingleObjectAsRow streams without natural id.
- Operator tool `tools/Update-LiveConnectorResource.ps1` — surgical PUT of corrected `connectorUiConfig` to live Sentinel resource (existing deployments don't auto-update from ARM).
- Operator tool `tools/Verify-EndToEndProduction.ps1` — consolidated 20-signal post-deploy verifier covering Provisioning / Wiring / Liveness / Coverage / Quality / Risk dimensions.
- Operator tool `tools/Audit-TimeFilterCoverage.ps1` — flags any unbounded workspace-table query in sentinel/ yaml.

### Fixed

- Connector card `connectivityCriteria` (was misspelled `connectivityCriterias` plural — Sentinel UI silently ignored).
- Connector card `dataTypes[]` (was MDE_*_CL DCR streamDecl identifiers — fixed to 11 live `Defender_<Category>_CL` workspace tables).
- 17 detection/hunting yaml files with malformed `where StreamName == "Defender_X_CL | where SourceName == 'MDE_Y_CL'"` filter (literal pipe inside string never matched).
- `Get-XdrTierStateAggregate` strict-mode crash on `__schedule__` rows lacking `TimestampUtc` (server-side OData filter `RowKey ne '__schedule__'` + per-property null-guards).
- `Invoke-XdrStorageTableEntity` `$base?` variable-token parse error under `Set-StrictMode -Version Latest` (used `${base}?` delimiter).
- Workbook ConnectorHealth Panel 1 — case() arms moved from FunctionName (always 'Connector-Heartbeat' post-Section R) to Portal+Tier.
- Workbook ComplianceDashboard — Tier filter from legacy 'P0' to live ValidateSet.
- Manifest projection corrections for AssetClassificationSchema (IdProperty=@('assetType')) + PreviewFeatures (SingleObjectAsRow) + PurviewSharing (UnwrapProperty='value') + DeviceTimeline (Tier ActionCenter for security-event 10-min cadence per operator directive).

### Internal

- Plan file `.claude/plans/immutable-splashing-waffle.md` Section R++ added documenting the 12 BLOCKING + 14 WARN + 8 INFO consolidated audit findings + 13-phase remediation + 24-box DoD.
