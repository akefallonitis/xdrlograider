# Workbooks

Six Sentinel workbooks ship with XdrLogRaider.

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

## Customizing

Each workbook is JSON following the Microsoft Application Insights Workbooks schema. Edit the `.json` file, redeploy the solution, and Sentinel reconciles.

## Adding a new workbook

1. Create `sentinel/workbooks/MDE_<Name>.json`
2. Use existing workbooks as templates
3. Add a corresponding YAML sidecar if submitting to Content Hub
4. Add to `deploy/solution/manifest.json` under `Workbooks`
