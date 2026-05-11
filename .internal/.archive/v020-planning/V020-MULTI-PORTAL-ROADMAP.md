# v0.2.0 Multi-Portal Expansion Roadmap

> **Scope**: post-v0.1.0 GA expansion to additional Microsoft security/admin portals using the same 4-function Durable orchestration topology + manifest-driven dispatch + per-category DCRs.
>
> **Status**: research-complete (2026-05-08); ~2,037 portal ops audited across 20 nodoc spec dirs; ~150 operator-value candidates identified. Implementation deferred until v0.1.0 GA stable + 7-day observation clean.
>
> **Source catalogues** (canonical reference): [`tests/online/CrossPortalCatalog-Defender-Entra.md`](../tests/online/CrossPortalCatalog-Defender-Entra.md) · [`tests/online/CrossPortalCatalog-Purview-M365.md`](../tests/online/CrossPortalCatalog-Purview-M365.md) · [`tests/online/CrossPortalCatalog-Intune-PowerPlatform.md`](../tests/online/CrossPortalCatalog-Intune-PowerPlatform.md) · [`tests/online/CrossPortalCatalog-Comms-SecCopilot.md`](../tests/online/CrossPortalCatalog-Comms-SecCopilot.md)

## Architecture invariants (preserved from v0.1.0 GA)

The 4-function topology stays 4. Multi-portal expansion adds:
- Per-portal manifest entries (`Portal=<X>`)
- Per-portal client modules (`Xdr.<Portal>.Client`)
- Per-portal auth chain (`Xdr.<Portal>.Auth`)
- Per-portal `<Portal>_<Category>_CL` workspace tables
- Per-portal cadence-tier DCRs sharing 1 DCE per portal (or consolidated across portals)

Architecture J Schema Unification (canonical Sentinel Entity Type cols: HostMdatpId / AccountUPNSuffix / IpAddress / FileName / CveId / etc.) extends BACKWARD-COMPATIBLY across portals — every portal manifest declares the same canonical entity cols where source response carries them. Cross-portal correlation enabled via KQL `join` on canonical cols (e.g., `Defender_VulnerabilityManagement_CL | join Entra_AuthenticationMethods_CL on HostAadId`).

## Per-portal phases (BINDING priority order; executed sequentially)

### v0.2.0a — More Defender streams (~1 week)

Source: `nodoc-defender-xdr/` (additional within existing 23 specs; ~558 unmapped GET paths beyond current 72).

Same auth chain (Defender portal SA + ESTSAUTH→sccauth→session). Same DCRs (existing 13). Net stream count: 72 → ~120.

| Category | Add streams | Effort |
|---|---|---|
| Identity Protection (MDI) | RiskyUsers + ISPM + LateralMovement + UserActivity | 1d |
| TVM | VulnerabilityChangeEvents + KbInsights + RemediationStats + Certificates | 1d |
| Threat Analytics | IndicatorReputation × 4 + FilePrevalence + EntityPivots | 1d |
| Multi-Tenant Operations | Configuration + CrossTenantAccess + WorkloadStatus | 0.5d |
| Action Center | PendingActions + AutomationRules + AirInvestigations | 0.5d |
| Live Response (audit metadata only) | Sessions | 0.5d |

### v0.2.0b — Entra (Azure AD) (~2-3 weeks)

Source: `nodoc-ibiza-iam/` (34 specs; 476 paths) + `nodoc-entra-{b2c,idgov,iga,pim}/` (4 specs; 43 paths). Total: 519 paths.

NEW auth chain (`Xdr.Entra.Auth` module) — Entra portal SA cookies + Graph PowerShell session pattern. NEW DCR category (`Entra_<Category>_CL` tables across IAM / SignIns / CA / AppRegistrations / NamedLocations / ServicePrincipals / Devices / Groups / IGA / PIM / B2C).

| Sub-portal | Path count | Operator-value subset | Effort |
|---|---|---|---|
| IAM core (Ibiza) | 476 | ~50 (signins / CA-policies / risk events / authMethods) | 1.5w |
| B2C | 12 | ~5 (tenant policies + custom policies) | 0.5w |
| IGA | 11 | ~5 (entitlement management + access reviews) | 0.5w |
| PIM | 13 | ~5 (eligible/active assignments + role activation) | 0.5w |
| IdGov | 7 | ~3 (lifecycle workflows) | 0.5w |

### v0.2.0c — Purview (Compliance) (~1.5 weeks)

Source: `nodoc-purview/` (20 specs; 238 paths).

NEW auth chain (`Xdr.Purview.Auth`). NEW workspace tables `Purview_<Category>_CL` across audit / eDiscovery / DLP / communication compliance / insider risk / info protection / data governance / AI governance.

| Category | Path count | Operator value | Effort |
|---|---|---|---|
| Audit logs | ~30 | unified audit events (Exchange + SharePoint + Teams) | 0.5w |
| DLP | ~25 | policy inventory + incident metadata | 0.5w |
| Insider Risk | ~20 | policy state + activity scoring | 0.3w |
| Info Protection | ~30 | sensitivity labels + retention policies | 0.3w |

### v0.2.0d — Intune (~1 week + RESEARCH)

Source: `nodoc-intune-autopatch/` (49 paths) + `nodoc-intune-portal/` (5 paths stub).

**Research gap**: Intune Portal nodoc currently has only 5-path stub. Pre-implementation deep-dive needed to expand to ~50+ paths covering AppProtection / Compliance / DevicePolicies / AppConfig / Configuration profiles.

NEW auth chain (`Xdr.Intune.Auth`). NEW `Intune_<Category>_CL` tables.

| Phase | Effort |
|---|---|
| Phase 1: Research expansion (5-path stub → ~50 paths) | 2-3d |
| Phase 2: Implementation | 3-4d |

### v0.2.0e — Power Platform (~2 weeks)

Source: `nodoc-powerplatform/` (10 specs; 488 paths).

NEW auth chain (`Xdr.PowerPlatform.Auth`). NEW `PowerPlatform_<Category>_CL` tables across environments / apps / flows / solutions / connectors / DLP / data integration.

| Category | Path count | Operator value |
|---|---|---|
| Environments | ~80 | environment inventory + RBAC drift |
| Apps + Flows | ~150 | app inventory + connector consents |
| DLP policies | ~60 | environment DLP scoping + connector grouping |

### v0.2.0f — M365 Admin Center (~2 weeks)

Source: `nodoc-m365-admin/` (26 specs; 504 paths).

NEW `M365Admin_<Category>_CL` tables across service health / org settings / SKU+licensing / domains / users / groups / customization.

### v0.2.0g — SharePoint + Teams Admin (~1 week)

Sources: `nodoc-sharepoint-admin/` (1 spec; 35 paths) + `nodoc-teams-admin/` (1 spec; 98 paths).

NEW `SharePoint_<Category>_CL` + `Teams_<Category>_CL` tables.

### v0.2.0h — Security Copilot (~0.5 week)

Source: `nodoc-security-copilot/` (1 spec; 32 paths).

Prompt management + skill discovery + agent telemetry.

## v0.2.0 infrastructure work (cross-portal)

### v0.2.0-infra1 — Multi-tenant FA scoping

Per [V020-MULTI-TENANT-DESIGN.md](V020-MULTI-TENANT-DESIGN.md):
- Per-tenant secret namespace (`mde-portal-{tenantId}-password`)
- XdrTierState PartitionKey extension (`<TenantId>|<Portal>|<Tier>`)
- Per-tenant `Initialize-XdrLogRaiderAuth.ps1` seeding

### v0.2.0-infra2 — DCR consolidation 13 → 6-8

When per-portal additions reshape the category split layout, consolidate per-Defender DCRs back from 13 (post Phase 2 split) → 6-8 (per-category × per-portal matrix).

### v0.2.0-infra3 — Per-portal manifest module structure

Scaffold `Xdr.Entra.Client` / `Xdr.Purview.Client` / `Xdr.Intune.Client` / `Xdr.PowerPlatform.Client` / `Xdr.M365Admin.Client` / `Xdr.SharePoint.Client` / `Xdr.Teams.Client` / `Xdr.SecurityCopilot.Client` modules with per-portal client primitives.

## v0.2.0 marketplace work

Per [V020-MARKETPLACE-PR-CHECKLIST.md](V020-MARKETPLACE-PR-CHECKLIST.md): submit Microsoft Sentinel Solution Gallery PR under `Solutions/XdrLogRaider/` with multi-portal solution package.

## Calendar (honest senior-architect estimate)

| Phase | Calendar |
|---|---|
| v0.2.0a (more Defender) | 1 week |
| v0.2.0b (Entra) | 2-3 weeks |
| v0.2.0c (Purview) | 1.5 weeks |
| v0.2.0d (Intune research+impl) | 1 week + 0.5w research |
| v0.2.0e (Power Platform) | 2 weeks |
| v0.2.0f (M365 Admin) | 2 weeks |
| v0.2.0g (SharePoint + Teams) | 1 week |
| v0.2.0h (Security Copilot) | 0.5 week |
| Infrastructure (multi-tenant + DCR consolidation + module scaffold) | 1-2 weeks |
| Marketplace PR submission | 1-2 weeks (+ Microsoft review cycle) |
| **TOTAL** | **~13-16 weeks** (Q3 2026 target) |

## Dependencies

- v0.1.0 GA stable + 7-day observation clean
- v0.1.0.x patch backlog drained ([V010X-PATCH-BACKLOG.md](V010X-PATCH-BACKLOG.md))
- Architecture J Schema Unification stable across all 72 v0.1.0 streams (verified via cross-table KQL joins)
- Multi-tenant FA design reviewed + approved
- Microsoft Solution Gallery PR template + content checklist finalized

## Out of scope for v0.2.0

- Container Apps migration (Y1 Linux Consumption EOL hedge) — defer to v1.x
- Workspace-region geo-failover — v1.x
- Mutation testing — v1.x
- Per-stream cost-budget enforcement (DLQ exponential backoff with circuit-breaker) — v1.x
- Custom workspace tiers per category — v1.x
