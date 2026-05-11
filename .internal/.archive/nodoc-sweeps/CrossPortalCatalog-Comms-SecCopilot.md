# Cross-Portal Endpoint Catalog — Comms (Exchange/SharePoint/Teams/Viva) + Security Copilot

**Generated:** 2026-05-08 (Plan R++++++++++ Phase 0 research)
**Project goal lens:** capture portal-internal data NOT exposed by official Microsoft Graph / Sentinel built-in connectors. Recommend additions only where there's incremental operator value beyond official APIs.

## Inventory

| Portal | Path count | GET | POST/PUT |
|---|---|---|---|
| Exchange Online beta (`nodoc-exchange-beta/`) | 41 | 60 | 1 |
| SharePoint Admin (`nodoc-sharepoint-admin/`) | 35 | 32 | 9 |
| Teams Admin (`nodoc-teams/`) | 98 | 89 | 8 |
| Viva Engage (`nodoc-viva-engage/`) | 5 | 1 | 4 |
| Security Copilot (`nodoc-security-copilot/`) | 32 | 29 | 3 |
| **Total** | **211** | 211 | 25 |

## Exchange Online beta — Top operator-value (10)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `Exchange_TenantDataBoundary_CL` | GET | `/beta/TenantDataBoundary` | Settings | Geo/data residency constraints (no Graph equiv) |
| `Exchange_TenantMonitoring_CL` | GET | `/beta/TenantMonitoring` | Health | Service state + monitored feature flags |
| `Exchange_AcceptedDomains_CL` | GET | `/beta/AcceptedDomain` | Mail Flow | Domain list for inbound routing audits |
| `Exchange_RemoteDomains_CL` | GET | `/beta/RemoteDomain` | Mail Flow | External domain settings (relay/forwarding) |
| `Exchange_InboundConnectors_CL` | GET | `/beta/InboundConnector` | Mail Flow | Email ingestion routes (3rd-party + hybrid) |
| `Exchange_OutboundConnectors_CL` | GET | `/beta/OutboundConnector` | Mail Flow | Egress routes |
| `Exchange_TransportRules_CL` | GET | `/beta/TransportRule` | Mail Flow | Message classification + DLP rules inventory |
| `Exchange_ConnectorReports_CL` | GET | `/beta/ConnectorReport` | Audit | Per-connector success/fail metrics |
| `Exchange_MailflowForwardingReport_CL` | GET | `/beta/MailflowForwardingReport/{startDate}/{endDate}` | Audit | Forwarding rule execution + recipient counts |
| `Exchange_AlertPolicies_CL` | GET | `/beta/AlertPolicy` | Security | Alert rule definitions + thresholds |

**Auth:** session cookie within `admin.exchange.microsoft.com`. **vs official APIs:** Exchange Online Management PowerShell + Graph have most domains/connectors; transport rules + alert policies + per-connector reports are richer in portal beta.

## SharePoint Admin — Top operator-value (8)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `SharePoint_TenantInformation_CL` | GET | `/_api/TenantInformationCollection` | Tenant | Multigeo domains + root site + MySite URIs |
| `SharePoint_SuiteNavData_CL` | GET | `/_api/Microsoft.SharePoint.Portal.SuiteNavData.GetSuiteNavData` | Bootstrap | Shell links + user context |
| `SharePoint_TenantSettings_CL` | GET | `/_api/SP_TenantSettings_Current` | Settings | Global sharing + external invite settings |
| `SharePoint_SpoTenant_CL` | GET | `/_api/SPO.Tenant` | Settings | Syntex/DLP/OneDrive licensing + retention policies |
| `SharePoint_AdminSettings_CL` | GET | `/_api/TenantAdminSettings` | Settings | Auto-quota + brand center + admin prefs |
| `SharePoint_SharingStatus_CL` | GET | `/_api/TenantAdminSettings/GetTenantSharingStatus` | Audit | Sharing-mode code: Internal/AllowLinks/External |
| `SharePoint_HomeSitesDetails_CL` | GET | `/_api/SPO.Tenant/GetHomeSitesDetails` | Settings | Home site + landing page assignments |
| `SharePoint_AllWebTemplates_CL` | GET | `/_api/SPO.Tenant/GetSPOAllWebTemplates` | Inventory | Available site/team templates + governance tags |

**Auth:** SharePoint Modern Auth (same-origin OData). **vs official APIs:** Graph has limited SharePoint admin coverage (most go via SharePoint Online Management Shell); these endpoints expose tenant-wide policy + DLP/Syntex/retention config not in Graph.

## Teams Admin — Top operator-value (10)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `Teams_DeploymentTeams_CL` | GET | `/api/v1/DeploymentTeams` (noneu-admin) | Inventory | Deployment-phase team records for rollout tracking |
| `Teams_ClientHealthDetails_CL` | GET | `/api/v1/clientHealth/clientHealthDetails` | Health | Teams client crash + sync issue aggregates |
| `Teams_ClientHealthIssues_CL` | GET | `/api/v1/clientHealth/clientHealthIssues` | Health | Per-issue detail + affected client count |
| `Teams_AppAccessRequests_CL` | GET | `/api/mt/part/{partition}/beta/admin/apps/appAccessRequests` | Governance | Pending app + admin-approved app audit log |
| `Teams_DeviceStoreSettings_CL` | GET | `/api/mt/part/{partition}/beta/admin/deviceStoreSetting` | Settings | Device compliance + policy assignment rules |
| `Teams_TenantSharedChannelsSettings_CL` | GET | `/api/mt/part/{partition}/beta/admin/tenantSharedChannelsSettings` | Settings | Cross-tenant channel governance |
| `Teams_StagedApps_CL` | GET | `/api/mt/part/{partition}/beta/admin/tenantStagedApps` | Inventory | Apps in rollout queue |
| `Teams_TenantsList_CL` | GET | `/Teams.Tenant/tenants` | Tenant | Tenant metadata + licensing SKU summary |

**Auth:** portal context header + regional gateway routing (`admin.teams.microsoft.com` vs `noneu-admin.teams.microsoft.com`). **vs official APIs:** Graph Teams API covers basic team/channel; client health + admin app governance + staged app rollout are portal-only.

## Viva Engage — Top operator-value (1)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `VivaEngage_AdminGraphQL_CL` | POST | `/graphql` | Query | Communities + conversations + engagement metrics (flexible schema) |

**Caveat:** GraphQL requires per-query schema documentation; flexible body. Other 4 endpoints are auth/realtime-CometD (skip per session).

## Security Copilot — Top operator-value (10)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `SecCopilot_UserContext_CL` | GET | `/auth/userInfo` | Auth | User roles + feature flags |
| `SecCopilot_CapacityExpiry_CL` | GET | `/auth/expiryDate` | Auth | Trial/capacity expiry state |
| `SecCopilot_FeatureFlags_CL` | GET | `/users/features` | Bootstrap | Copilot features enabled per tenant |
| `SecCopilot_DataShareSettings_CL` | GET | `/settings/datashare` | Settings | Tenant data-sharing toggles |
| `SecCopilot_Capacities_CL` | GET | `/usage/capacities` | Billing | Capacity subscriptions + usage tier |
| `SecCopilot_TrialStatus_CL` | GET | `/trial` | Licensing | Trial eligibility + expiry |
| `SecCopilot_Workspaces_CL` | GET | `/account/workspaces?api-version=2023-12-01-preview` | Inventory | Workspaces + permissions per user |
| `SecCopilot_Agents_CL` | GET | `/workspaces/{workspaceName}/agents?scope=Workspace` | Inventory | Custom + Copilot-managed agents |
| `SecCopilot_Promptbooks_CL` | GET | `/workspaces/{workspaceName}/promptbooks` | Inventory | Saved prompt sequences + builder templates |
| `SecCopilot_Skillsets_CL` | GET | `/workspaces/{workspaceName}/skillsets/{skillsetName}?scope=UserWorkspace` | Settings | Skill enablement + custom plugin mappings |

**vs official APIs:** Security Copilot has NO Microsoft Graph coverage today. All 10 are pure portal-only. **Highest priority for v0.2.0h.**

## Architectural observations

1. **Auth boundaries are STRICT** — 5 different auth chains (Exchange portal session / SharePoint Modern Auth / Teams portal + regional / Viva GraphQL bearer / Security Copilot bearer). Each requires its own `Xdr.<Portal>.Auth` module.
2. **Tenant scope** — all read-only; no MTO sampling. Per-mailbox/site/user PerEntityFanout candidates for drilldowns.
3. **State-mutation endpoints excluded** — all POST writes (Settings.Update, CreateSite, CartService) are skipped per project read-only constraint.
4. **GraphQL and CometD endpoints** — Viva Engage GraphQL is technically POST-as-GET (query body, response data) but requires schema-mapping layer per query type; defer to v0.2.0+ research. CometD realtime is per-session; skip permanently.
5. **Schema commonalities** — Exchange + SharePoint use OData (`@odata.context`, `value[]`); Teams = generic JSON; Security Copilot = generic JSON + `api-version` query strings.

**Recommended DCR taxonomy:**
- v0.2.0g (SharePoint+Teams): `SharePoint_<Category>_CL` × 3 + `Teams_<Category>_CL` × 4
- v0.2.0g.exchange: `Exchange_<Category>_CL` × 3 (MailFlow / Audit / Security)
- v0.2.0h: `SecCopilot_<Category>_CL` × 4 (Auth / Settings / Inventory / Billing)
- Viva Engage: defer pending GraphQL schema-mapping layer

## Cross-portal architecture impact for v0.1.0 GA

Although v0.1.0 GA is Defender-only, the cross-portal research informs:
- **Auth abstraction shape** — `Xdr.<Portal>.Auth` modules need a common interface across 5+ different chains
- **Pagination abstraction** — manifest must support OData (`$skip/$top`), pageIndex/pageSize, GraphQL cursor, OData v1.0 — already partially done with current `Pagination` field
- **Multi-tenant scoping** — `XdrTierState` PartitionKey must extend to include `<Portal>` (already does) and probably `<TenantId>` (v0.2.0 multi-tenant work)
- **DCR per-category split** — current 13-DCR model (Defender_<Cat>_CL × 10 + ops) extrapolates cleanly: each new portal adds 3-7 DCRs; expect 60-80 DCRs total at v0.2.0h
