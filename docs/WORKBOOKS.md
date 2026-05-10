# Workbooks

Ten Sentinel workbooks ship with XdrLogRaider — seven SOC-analyst dashboards (per-functional-area), two operator dashboards (connector observability), and one cross-table device drilldown.

> **Cross-table join model (Architecture J)**: every workbook keys panels on canonical Sentinel Entity Type cols (`HostMdatpId`, `HostFullName`, `HostAadId`, `AccountUPNSuffix`, `IpAddress`, `CveId`, `MachineGroupId`). Operators KQL-pivot directly without `parse_json(RawJson)` in normal use.

## 1. MDE Compliance Dashboard
**File**: `sentinel/workbooks/MDE_ComplianceDashboard.json`
**Audience**: SOC lead, compliance
**Shows**:
- Connector health (last hour)
- P0 drift events over 24h (time chart)
- Current ASR rule modes (table with red/amber/green)
- Live Response config (unsigned-scripts state)
- Recent changes with attribution (join with AuditLogs)

## 2. MDE Drift Report
**File**: `sentinel/workbooks/MDE_DriftReport.json`
**Audience**: change-management, auditor
**Shows**:
- Drift events per category, time chart
- Full drift event log, enriched with audit attribution

## 3. MDE Governance Scorecard
**File**: `sentinel/workbooks/MDE_GovernanceScorecard.json`
**Audience**: IAM lead, asset owner
**Shows**:
- RBAC machine groups snapshot
- P2 governance drift pie chart

## 4. MDE Exposure Map
**File**: `sentinel/workbooks/MDE_ExposureMap.json`
**Audience**: threat-intel, exposure mgmt
**Shows**:
- Current XSPM attack paths (entry → target with hop count)
- Exposure score trend over 30 days

## 5. MDE Identity Posture
**File**: `sentinel/workbooks/MDE_IdentityPosture.json`
**Audience**: identity ops
**Shows**:
- MDI DC sensor coverage percentage
- P5 identity drift over 30 days

## 6. MDE Response Audit
**File**: `sentinel/workbooks/MDE_ResponseAudit.json`
**Audience**: IR, audit
**Shows**:
- Action Center events by type + status (bar chart)
- Time-to-action per action (table)

## 7. MDE Action Center
**File**: `sentinel/workbooks/MDE_ActionCenter.json`
**Audience**: IR, SOC analyst
**Shows**:
- Action Center summary by status (bar chart)
- Per-device timeline events (table, last 200)
- Machine actions detail with Live Response output and AIR linkage

## 8. MDE Device Inventory (Unified) — Hot-Fix 14 (2026-05-10)
**File**: `sentinel/workbooks/MDE_DeviceInventory_Unified.json`
**Audience**: SOC analyst, IR, vulnerability mgmt
**Shows**:
- Top 50 devices — risk + exposure posture (selectable filters: Platform / ExposureLevel / DeviceFilter)
- Per-device CVE drilldown (cross-table HostMdatpId join)
- Endpoint security policies applied per platform (TemplateFamily breakdown — ASR / AV / Firewall / EDR / Account Protection / Disk Encryption / Web Protection)
- Recent drift events cross-tier (Inventory + Configuration drift parsers)
- Response actions per device (ActionCenter)
- Inactive devices (>7d no heartbeat)
- Onboarding + management state distribution
- Device classification breakdown (DeviceCategory × DeviceType × OsPlatform)

Built ON TOP of Hot-Fix 11 expanded `MDE_Machines_CL` ProjectionMap (50+ typed cols) + Hot-Fix 13 ARM cascading update + Hot-Fix 9 `MDE_SecurityPolicies_CL` Intune schema + Hot-Fix 5 drift parser cardinality refinement.

## 9. XdrLogRaider Connector Health (operator dashboard)
**File**: `sentinel/workbooks/XdrLogRaider_ConnectorHealth.json`
**Audience**: operator, on-call SOC, capacity planning
**Shows**:
- Per-tier last-fresh poll markers (5 cadence tiers + heartbeat)
- Auth chain failures last 24h (AppExceptions filtered to AuthChain.*)
- DLQ depth and oldest-entry age
- Freshness SLI per consolidated category
- Per-row partial-success rate per stream
- Service account sign-in anomaly summary (uses `$(SERVICE_ACCOUNT_UPN)` deployment parameter)
- Per-stream freshness (workspace-side last row per SourceName across 10 category tables)

Daily SOC stand-up + on-call runbook + capacity planning + cost monitoring + service account governance.

## 10. XdrLogRaider Connector Ops — Hot-Fix 17 (2026-05-10)
**File**: `sentinel/workbooks/XdrLogRaider_ConnectorOps.json`
**Audience**: operator, capacity planner, incident triage
**Shows**:
- Ingestion velocity per category (rows/15min time-series)
- DLQ depth + oldest-entry age trending
- Auth chain failure breakdown (AADSTS code histogram + Stage breakdown)
- Stream-level health velocity matrix (24h vs prior-24h baseline delta — identifies gradually-dying streams BEFORE they go fully dry)
- Rate-limit (429) storms per host (with Retry-After distribution)
- Function App invocation success rate (4 functions + p50/p95/p99 latency)
- Per-stream Hot-Fix 7 truncation events (`Ingest.RowTruncated` AppEvents — preserves data for AssetRules-class oversized rows)
- Cost-budget gate trip events (`RowVolumeSpike` + `RowDroppedAfterTruncate`)

Complements `XdrLogRaider_ConnectorHealth` (binary checks) with VELOCITY + DEPTH + RATE telemetry SOC operators need for capacity planning + incident triage.

## Customizing

Each workbook is JSON following the Microsoft Application Insights Workbooks schema. Edit the `.json` file, redeploy the solution, and Sentinel reconciles.

## Adding a new workbook

1. Create `sentinel/workbooks/MDE_<Name>.json`
2. Use existing workbooks as templates
3. Add a corresponding YAML sidecar if submitting to Content Hub
4. Add to `deploy/solution/manifest.json` under `Workbooks`
