# Cross-Portal Endpoint Catalog — Purview + M365 Admin

**Generated:** 2026-05-08 (Plan R++++++++++ Phase 0 research)
**Source:** `.internal/nodoc-reference/specifications/nodoc-{purview,purview-portal,m365-admin,m365-apps-*}/specification/`
**Project goal lens:** capture portal-internal data NOT exposed by official Microsoft Graph / Sentinel built-in connectors. Recommend additions only where there's incremental operator value beyond official APIs.

## Inventory

| Portal | Path count | GET | POST/PUT |
|---|---|---|---|
| Purview Compliance (`nodoc-purview/`) | ~85 | ~70 | ~15 |
| Purview Portal (`nodoc-purview-portal/`) | small | mostly GET | minimal |
| M365 Admin (`nodoc-m365-admin/`) | 252 (180+ unique ops) | ~190 | ~62 |
| M365 Apps Config (`nodoc-m365-apps-config/`) | 22 | ~18 | ~4 |
| M365 Apps Inventory (`nodoc-m365-apps-inventory/`) | 25 | ~10 | ~15 |
| M365 Apps Services (`nodoc-m365-apps-services/`) | 8 | ~6 | ~2 |
| **Total** | **~404** | ~294 | ~110 |

## Purview Compliance — Top operator-value endpoints (15)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `Purview_AuditEnabled_CL` | GET | `/adtsch/AuditEnabled` | Audit | Tenant audit enablement gate (not in Graph) |
| `Purview_AuditLogSearches_CL` | GET | `/adtsch/AuditLogSearch` | Audit | Saved audit-log search inventory + results |
| `Purview_CompliancePostureSummary_CL` | POST | `/cpm/v1.0/Tenant/CompliancePostureSummary` | Compliance Manager | Compliance score + breakdown (Graph has limited subset) |
| `Purview_ComplianceAssessments_CL` | POST | `/cpm/v1.0/Assessments` | Compliance Manager | Assessment inventory by template |
| `Purview_TenantLicense_CL` | GET | `/dgs/Item/GetTenantLicense` | Data Governance | DG SKU entitlements |
| `Purview_DgsTypeAggregates_CL` | GET | `/dgs/aggregate/GetTypeAggregates` | Data Governance | Classification type counts |
| `Purview_CommunicationCompliancePolicies_CL` | GET | `/cc/policies` | Communication Compliance | Policies + incident counts |
| `Purview_InsiderRiskExtensibleIndicators_CL` | GET | `/insiderrisk/.../ExtensibleIndicators` | Insider Risk | Custom risk indicators |
| `Purview_InsiderRiskAnalyticsInsights_CL` | GET | `/insiderrisk/.../InsiderRiskAnalyticsInsightMetadata` | Insider Risk | Date-scoped analytics insights |
| `Purview_EdiscoveryCases_CL` | GET | `/aedmcc/ediscovery/v1/purviewcases` | eDiscovery | Cases + custodians inventory |
| `Purview_DlpEndpointMachines_CL` | GET | `/dlp/machines` | DLP Endpoints | Endpoint device inventory + DLP status |
| `Purview_DlpMachineCount_CL` | GET | `/dlp/machines/count` | DLP Endpoints | Aggregate device count |
| `Purview_DlpLogCollections_CL` | GET | `/dlp/logcollections` | DLP Endpoints | Log collection exclusion windows |
| `Purview_NativeConnectorJobs_CL` | GET | `/native_connectors/jobs` | Data Infrastructure | Connector sync status |
| `Purview_E5TenantUsage_CL` | GET | `/billing/E5TenantUsage` | Billing | E5 adoption metrics |

**Auth chain:** isolated routes (`/adtsch/`, `/cpm/`, `/dgs/`, `/cc/`, `/dlp/`, `/insiderrisk/`) — separate from Defender `/apiproxy/`. Bearer token auth.
**Pagination:** mixed — OData `$filter`/`$top`, custom `pageSize`. Standard `{value: [...]}` wrapping.
**vs official APIs:** Microsoft Graph has **partial** Compliance Manager + DLP endpoints; Purview portal exposes WAY more (audit search history, communication compliance policy bodies, insider risk extensible indicators, DG type aggregates). All 15 candidates above add operator value beyond Graph.

## M365 Admin Center — Top operator-value endpoints (15)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `M365Admin_CopilotSettings_CL` | GET | `/admin/api/copilotsettings/settings` | Copilot | Tenant Copilot enablement + policy assignments |
| `M365Admin_RiskyAgents_CL` | GET | `/admin/api/agentusers/metrics/agents/risky` | Agents | AI agent risk signals (no Graph equivalent) |
| `M365Admin_TeamsSettings_CL` | GET | `/admin/api/settings/apps/skypeteams` | App Settings | Coexistence + client settings |
| `M365Admin_MailSettings_CL` | GET | `/admin/api/settings/apps/mail` | App Settings | Tenant-wide Exchange policies |
| `M365Admin_ServiceHealth_CL` | GET | `/admin/api/servicehealth/current` | Service Health | Workload incident summary (Graph subset) |
| `M365Admin_Domains_CL` | GET | `/admin/api/domains` | Domains | Tenant domains + verification (Graph subset) |
| `M365Admin_Subscriptions_CL` | GET | `/admin/api/subscriptions` | Billing | SKU counts + license assignments (Graph has subset) |
| `M365Admin_OrgProfile_CL` | GET | `/admin/api/settings/company/profile` | Company Settings | Tenant name/address/contact |
| `M365Admin_SecurityComplianceSettings_CL` | GET | `/admin/api/settings/security` | Security Settings | Guest access + DLP state |
| `M365Admin_MessageCenterMessages_CL` | GET | `/admin/api/messagecenter/messages` | Message Center | MC posts + affected services |
| `M365Admin_AzureADRoles_CL` | GET | `/admin/api/roles` | Identity Security | Role assignments + admin counts |
| `M365Admin_TenantRelationships_CL` | GET | `/admin/api/tenantrelationships` | Tenant Relationships | B2B direct connect config |
| `M365Admin_VivaPulseInsights_CL` | GET | `/admin/api/viva/insights` | Viva | Survey metrics + sentiment |
| `M365Admin_ManagedDevices_CL` | GET | `/admin/api/settings/devices/inventory` | Reports | OS distribution per device |
| `M365Admin_SharedLinks_CL` | GET | `/admin/api/settings/sharing/links` | Sharing | External sharing link policy |

**Auth chain:** session-based (`AjaxSessionKey` cookie + `x-portal-routekey`); per-blade `x-ms-mac-appid` header.
**vs official APIs:** Graph covers domains, subscriptions, service health partially; M365 Admin portal exposes Copilot agent risk, Viva insights, blade-specific app config that Graph does NOT.

## M365 Apps (Config + Inventory + Services) — Top 8

| Stream candidate | Method | Path | Operator value |
|---|---|---|---|
| `M365Apps_UpdateProfiles_CL` | GET | `/serviceProfile/v3.0/profiles` | Servicing profiles + rollout windows |
| `M365Apps_TenantRules_CL` | GET | `/serviceProfile/v1.0/tenantrules` | Update rules + exclusion windows |
| `M365Apps_DeviceInventory_CL` | POST | `/inventory/api/Devices` | Per-device Office version + add-ins |
| `M365Apps_SecurityUpdatesStatus_CL` | POST | `/inventory/api/SecurityUpdates` | Patch level + vulnerable device count |
| `M365Apps_SecurityCurrencyGoal_CL` | GET | `/inventory/api/SecurityCurrencyGoal` | Update compliance target % |
| `M365Apps_LanguagesPacks_CL` | POST | `/inventory/api/Languages` | Language pack distribution |
| `M365Apps_ReleaseCatalog_CL` | GET | `/releasemanagement/releases` | Release catalog by servicing channel |
| `M365Apps_OneDriveSyncHealth_CL` | GET | `/sync/health` | OneDrive client error rates |

**Auth chain:** bearer token + diagnostic headers (`x-api-name`, `x-correlationid`, `api-version=1.1`).
**vs official APIs:** ZERO Graph coverage for M365 Apps inventory + security currency. All 8 candidates are pure portal-internal additional value.

## Architectural observations

1. **Auth boundaries are strict** — Purview `/adtsch/`, M365 Admin `/admin/api/`, and M365 Apps `/inventory/api/` are 3 separate auth chains. Each needs its own `Xdr.<Portal>.Auth` module.
2. **Pagination semantics differ** — OData (`$skip/$top`) vs `pageIndex/pageSize` vs custom `?api-version=1.1`. Activity must adapt per portal.
3. **Multi-tenant scoping** — most endpoints tenant-scoped. M365 Admin `/tenantrelationships` is one of the few B2B-aware endpoints.
4. **Graph overlap exclusion** — domains/subscriptions/service-health partially in Graph. Endpoints flagged with operator-value rationale are those with NO Graph equivalent OR significantly richer payload.

**Recommended DCR taxonomy for v0.2.0c:** `Purview_<Category>_CL` × 6 (Audit / ComplianceManager / DataGovernance / CommunicationCompliance / InsiderRisk / DLPEndpoints + eDiscovery as 7th).
**Recommended DCR taxonomy for v0.2.0f:** `M365Admin_<Category>_CL` × 5 (Copilot / Settings / ServiceHealth / Roles / Reports).
