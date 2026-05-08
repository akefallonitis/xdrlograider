# Cross-Portal Endpoint Catalog — Intune + Power Platform

**Generated:** 2026-05-08 (Plan R++++++++++ Phase 0 research)
**Project goal lens:** capture portal-internal data NOT exposed by official Microsoft Graph / Intune Beta Graph / Sentinel built-in connectors. Recommend additions only where there's incremental operator value beyond official APIs.

## Inventory

| Portal | Path count | GET | POST/PUT |
|---|---|---|---|
| Intune Autopatch (`nodoc-intune-autopatch/`) | 49 | 30 | 22 |
| Intune Portal (`nodoc-intune-portal/`) | **5 (STUB)** | 1 | 4 |
| Power Platform (`nodoc-power-platform/`) | 488 | 226 | 18 |
| **Total** | **542** | 257 | 44 |

## Intune Autopatch — Top operator-value endpoints (10)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `Intune_AutopatchEffectivePermissions_CL` | GET | `/access-control/odata/v1/EffectivePermissions` | RBAC | Scope-tag compliance + principal permissions audit |
| `Intune_AutopatchRoleAssignments_CL` | GET | `/access-control/odata/v1/RoleAssignments` | RBAC | Admin delegation inventory |
| `Intune_AutopatchScopeTags_CL` | GET | `/access-control/odata/v1/ScopeTags` | RBAC | Isolation boundary definition |
| `Intune_AutopatchGroups_CL` | GET | `/device/v2/autopatchGroups` | Device | Device cohort + patch staging gates |
| `Intune_AutopatchQualityUpdateMetrics_CL` | POST | `/reporting/reports/v2/deviceAccounting/wqu/*` | Reporting | Windows quality-update compliance per-device histogram |
| `Intune_AutopatchFeatureUpdateReleases_CL` | POST | `/reporting/reports/v2/windowsFeatureUpdates/summary/*` | Reporting | Feature-update rollout phases |
| `Intune_AutopatchManagementSummary_CL` | GET | `/unified-reporting/odata/1.0/AutopatchManagementStatusSummary` | Health | Tenant device health + enrollment KPIs |
| `Intune_AutopatchSupportRequests_CL` | GET | `/support/odata/v1/supportRequests` | Support | Tenant support-request audit trail |
| `Intune_AutopatchAdminActions_CL` | GET | `/tenant-management/v2/AdminActionsV` | Audit | Tenant state mutations + feature-flag transitions |
| `Intune_AutopatchFeatureEnablement_CL` | GET | `/tenant-management/v1/Enrollment/Starter/featureEnablementStatus` | Tenant | Feature-rollout entitlement + SKU gates |

**vs official APIs:** Autopatch data is NOT in Microsoft Graph (graph.microsoft.com Intune endpoints don't expose autopatch group + quality-update reporting). All 10 are pure portal-internal additional value.

**Pagination:** OData v1.0 + custom POST bodies for reports.

## Intune Portal — confirmed STUB

Spec is 5-path stub (per Plan R++++++++.3 prior finding still valid). Only 1 GET endpoint is policy/data-bearing:
- `IntunePortal.Experimentation.GetExtensionVariants` GET — portal flight variants (low operator value)

Other 4 endpoints are POST writes (Settings.Update mutation) or bootstrap helpers (no operator value).

**Recommendation:** SKIP `nodoc-intune-portal` for v0.1.0/v0.2.0d. Use Intune Autopatch as primary Intune source. v0.2.0d may need additional spec (deeper nodoc-intune research) before formal Intune coverage ships.

## Power Platform — Top operator-value endpoints (15)

| Stream candidate | Method | Path | Category | Operator value |
|---|---|---|---|---|
| `PowerPlatform_TenantCapacity_CL` | GET | `/licensing/tenants/{tenantId}/TenantCapacity` | Licensing | Capacity provisioning + seats consumed |
| `PowerPlatform_LicenseSummary_CL` | GET | `/v1.0/tenants/{tenantId}/FinOpsLicensing/GetLicenseSummaryV2` | Licensing | License entitlement inventory + SKU |
| `PowerPlatform_BillingPolicies_CL` | GET | `/v0.1-alpha/tenants/{tenantId}/BillingPolicies` | Licensing | Billing policy assignment + cost-center |
| `PowerPlatform_EntitlementTrends_CL` | GET | `/v0.1-alpha/tenants/{tenantId}/entitlements/*/trends` | Licensing | Capacity consumption trends |
| `PowerPlatform_Environments_CL` | GET | `/providers/Microsoft.BusinessAppPlatform/environments` | Environment | Environment inventory + compliance scope |
| `PowerPlatform_AdminEnvironments_CL` | GET | `/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments` | Environment | Admin-scoped environment list |
| `PowerPlatform_OrgInsightsMetrics_CL` | GET | `/api/v1/cds/OrgInsightsMetrics/List` | Analytics | Dataverse org metrics + resource usage |
| `PowerPlatform_CloudFlowMetrics_CL` | GET | `/api/v1/metrics/resourceType/powerautomate/*` | Analytics | Cloud flow usage + automation adoption |
| `PowerPlatform_CopilotStudioMetrics_CL` | GET | `/api/v1/metrics/resourceType/copilotstudio/*` | Analytics | **Copilot agent inventory + shadow-IT detection** |
| `PowerPlatform_PerFlowCapacity_CL` | GET | `/licensing/tenants/{tenantId}/UserPerFlowCapacitySource/TenantContextSummary` | Licensing | Per-flow capacity accounting |
| `PowerPlatform_TenantInfo_CL` | GET | `/providers/Microsoft.BusinessAppPlatform/tenant` | Tenant | Regional residency config |
| `PowerPlatform_EnvironmentLocations_CL` | GET | `/providers/Microsoft.BusinessAppPlatform/environmentLocations` | Compliance | Regional deployment zones (geo-compliance) |
| `PowerPlatform_EnvironmentGroups_CL` | GET | `/providers/Microsoft.BusinessAppPlatform/environmentGroups` | Governance | Logical grouping + isolation |
| `PowerPlatform_OrgTimeSeries_CL` | GET | `/api/v1/cds/TimeSeries/Organizations/{organizationId}` | Analytics | Historical org metrics |
| `PowerPlatform_TenantLicenseModel_CL` | GET | `/v0.1-alpha/tenants/{tenantId}/TenantLicenseModel` | Licensing | License model + pricing tier |

**Auth chain:** service-specific bearer tokens (audience varies); `X-Correlation-ID`, `x-ms-client-{request,session,tenant,principal}-id` headers.
**Multi-tenant patterns:** heavy `{tenantId}`, `{environmentId}`, `{organizationId}` placeholders → PerEntityFanout via tenant-relationship source.
**vs official APIs:** Microsoft Graph has minimal Power Platform coverage; Power Platform admin APIs expose licensing depth + Copilot Studio agent inventory + cloud flow analytics that Graph does NOT.

**Shadow-IT detection signal:** `PowerPlatform_CopilotStudioMetrics_CL` is the highest-value addition — exposes unmanaged AI agent deployments (no Graph equivalent at all).

## Architectural observations

- All 3 portals (Autopatch + Power Platform + Intune) use Entra/Azure AD bearer tokens; auth chain extension straightforward
- DCR taxonomy: per-portal naming (`Intune_<Category>_CL`, `PowerPlatform_<Category>_CL`)
- Multi-tenant: PowerPlatform tenant-scoped paths native; needs PerEntityFanout for tenant relationships
- v0.2.0d Intune scope = Intune Autopatch primary (Intune Portal stub insufficient); v0.2.0e Power Platform = highest operator-value tier (Copilot adoption + capacity audit)

**Recommended DCR taxonomy:**
- v0.2.0d: `Intune_<Category>_CL` × 4 (Autopatch / RBAC / Reporting / Tenant)
- v0.2.0e: `PowerPlatform_<Category>_CL` × 4 (Licensing / Environment / Analytics / Governance)
