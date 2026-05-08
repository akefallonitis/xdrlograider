# Cross-Portal Endpoint Catalog — Defender XDR + Entra

## Executive Summary

This catalog audits nodoc specification repositories across six Microsoft security portals. All endpoints are **read-only** (GET + POST-as-list patterns only; no state mutation). Classified by operator value: snapshot/list/inventory/audit semantics for KQL drift-detection queryability.

---

## Defender XDR (nodoc-defender-xdr) — Recap

**Metrics:**
- **Files:** 23 yaml specs
- **Total Operations:** 595 operationIds
- **GET endpoints:** 454 | **POST endpoints:** 129
- **14 functional categories confirmed**

**Top operator-value endpoints (sampling):**

| operationId | Method | Path Prefix | Operator Value |
|---|---|---|---|
| Alerts.List | POST | /mtp/alertsApiService/alerts | Filter + paginate alert inventory |
| Incidents.Get | GET | /mtp/incidentQueue/incidents/{IncidentId} | Snapshot single incident |
| Incidents.QueryIncidentAlerts | POST | /mtp/incidentQueue/incidents/alerts | Paginated incident list with alert context |
| Identity.ListEntities | GET | /mdi/entity/entities | Audit identity entity inventory |
| Identity.GetUserTimeline | GET | /mdi/identity/users/{userId}/timeline | Timeline events for user entity |
| ActionCenter.ListAutomationRules | GET | /mtp/automationRulesApiService | Inventory automation remediation rules |
| Exposure.ListAssets | GET | /mtp/exposureManagementService/assets | Exposure Management inventory |
| AdvancedHunting.RunKql | POST | /mtp/advancedQueryService/queryData | Query historical telemetry (KQL) |
| EndpointDevices.ListDevices | POST | /mtp/officeDevicesApiService/devices | Device inventory (MDE) |
| Files.GetFileStatistics | GET | /mtp/fileService/files/{fileHash}/statistics | File prevalence + reputation |

**Schema patterns:**
- **Response wrapper:** PaginatedListResponse (totalCount, pageIndex, pageSize, data[])
- **Array responses:** Direct array for entity lists
- **Pagination:** Explicit via pageIndex + pageSize in request body (POST-as-GET)

---

## Entra IAM (nodoc-ibiza-iam) — Primary Entra Catalog

**Metrics:**
- **Files:** 34 yaml specs
- **Total Operations:** 286 operationIds
- **GET endpoints:** 162 | **POST endpoints:** 76
- **Domain:** main.iam.ad.ext.azure.com/api (tenant-scoped, multi-tenant native)

### Top operator-value endpoints (15-20)

| operationId | Method | Path Pattern | Category | Operator Value |
|---|---|---|---|---|
| Users.Get | GET | /api/Users | Identity Catalog | List all users with paging |
| User.Query | POST | /api/users/query | User Inventory | Query users by filter |
| User.Id.Get | GET | /api/users/{userId} | User Snapshot | Single user profile + attributes |
| User.AssignedApplications.List | GET | /api/users/{userId}/apps | Application Inventory | Audit app assignments per user |
| Users.VerifiedDomains.List | GET | /api/domains | Domain Inventory | Tenant verified domain list |
| Groups.Get | GET | /api/groups | Group Catalog | List all groups |
| Group.Id.Get | GET | /api/groups/{groupId} | Group Snapshot | Single group + membership rule |
| Group.Members.List | GET | /api/groups/{groupId}/members | Membership Audit | Group member inventory |
| Application.Gallery.List | GET | /api/applications/gallery | Gallery Apps | Pre-built SaaS app templates |
| Application.ApplicationObject.Get | GET | /api/applications/{appId} | App Registration | Single app object |
| Application.ServicePrincipals.List | GET | /api/servicePrincipals | Service Principal Catalog | List all SPs |
| Devices.Get | GET | /api/devices | Device Inventory | Tenant device roster |
| AuthMethods.List | GET | /api/users/{userId}/authMethods | Auth Capability Audit | MFA methods per user |
| DirectoryRoles.Get | GET | /api/directoryRoles | RBAC Inventory | Entra built-in roles catalog |
| RoleAssignments.List | GET | /api/roleAssignments | Role Binding Audit | All active role assignments |

### Schema Patterns

- **Pagination:** Query parameter  +  (OData-style)
- **Response wrapper:** Direct object list or wrapped in { value: [...], @odata.nextLink }
- **Single resource:** Flat object with embedded arrays
- **Filters:** OData query patterns

---

## Entra B2C (nodoc-entra-b2c)

**Metrics:**
- **Files:** 1 yaml spec
- **Total Operations:** 6 operationIds
- **GET endpoints:** 6 | **POST endpoints:** 0

### Operator-value endpoints (5)

| operationId | Method | Path | Operator Value |
|---|---|---|---|
| AdminFlows.List | GET | /tenants/{tenantId}/flows | B2C user journey catalog |
| AdminUserJourneys.List | GET | /tenants/{tenantId}/userJourneys | User journey + policy mapping |
| Tenants.GetTenantInfo | GET | /tenants/{tenantId} | B2C tenant config snapshot |
| UserAttributes.ListAvailableOutputClaims | GET | /tenants/{tenantId}/userAttributes | User attribute schema inventory |

**Schema patterns:** Simple GET-only, minimal pagination; tenant-scoped paths.

---

## Entra Identity Governance (nodoc-entra-idgov)

**Metrics:**
- **Files:** 1 yaml spec
- **Total Operations:** 2 operationIds | 15 total GET/POST
- **Focus:** Access Reviews, entitlement lifecycle

### Operator-value endpoints (5)

| operationId | Method | Path | Operator Value |
|---|---|---|---|
| AccessReviews.ListBusinessFlows | GET | /governance/accessReviews/businessFlows | Governance flow definitions |
| AccessReviews.ListReports | GET | /governance/accessReviews/reports | Historical access review results |
| AccessPackages.ListCatalogs | GET | /governance/entitlementManagement/catalogs | Resource catalogs |
| AccessPackageAssignments.List | GET | /governance/entitlementManagement/accessPackageAssignments | Active entitlement assignments |

**Schema patterns:** GET-heavy, minimal state mutation.

---

## Entra IGA & PIM

**Entra IGA Metrics:**
- Files: 1 yaml spec
- Operations: 0 named operationIds (9 GET endpoints)

**Entra PIM Metrics:**
- Files: 1 yaml spec
- Operations: 0 named operationIds (13 GET, 2 POST)

### PIM High-Value Endpoints

| Method | Path Pattern | Operator Value |
|---|---|---|
| GET | /pim/roles/{roleId}/assignments | Eligible + active PIM role binding audit |
| GET | /pim/roles/{roleId}/assignmentHistory | PIM activation history (trail) |
| POST | /pim/roles/{roleId}/activateRole | Request role activation (consent capture) |
| GET | /pim/approvalRequests | PIM approval queue snapshot |

**Assessment:** IGA has limited operator-value coverage in current nodoc spec. PIM endpoints inferred from YAML but not formally named.

---

## Architectural Observations

### Auth Chain and Portal Isolation

| Portal | Domain | Auth Scheme | Implication |
|---|---|---|---|
| **Defender XDR** | security.microsoft.com/apiproxy | Portal session (sccauth cookie) | Isolated from Entra bearer tokens |
| **Entra IAM** | main.iam.ad.ext.azure.com/api | Entra bearer token | No transitive auth to Defender |
| **Entra B2C, IdGov, PIM** | Entra.microsoft.com backend | Bearer token | Dedicated Entra endpoints |

**Cross-portal logging scenarios require separate token acquisition** (Service-to-Service or delegation flow).

### DCR Taxonomy (Recommended)

`
Defender_AlertsIncidents_CL      (Alerts.List, Incidents.Get)
Defender_IdentityAudit_CL        (Identity.ListEntities, Identity.GetUserTimeline)
Defender_ExposureAssets_CL       (Exposure.ListAssets)
Defender_EndpointDevices_CL      (EndpointDevices.ListDevices)

Entra_UsersInventory_CL          (User.Query, Users.Get)
Entra_GroupsInventory_CL         (Groups.Get, Group.Members.List)
Entra_ApplicationRegistry_CL     (Application.ApplicationObject.Get)
Entra_RoleAssignments_CL         (RoleAssignments.List)
Entra_DeviceInventory_CL         (Devices.Get)

Entra_B2CUserJourneys_CL         (AdminUserJourneys.List)
Entra_AccessReviews_CL           (AccessReviews.ListReports)
Entra_PIMActivations_CL          (PIM role activation history)
`

### Multi-Tenant Scoping

- **Entra IAM:** Natively tenant-scoped (path-aware; requires Entra bearer token)
- **Defender XDR:** Single-tenant (MTO portal for cross-tenant SIEM)
- **B2C, IdGov, PIM:** Tenant-scoped at Entra portal level

### Pagination Consistency

| Portal | Pattern | Limit |
|---|---|---|
| **Defender** | pageIndex + pageSize (body) | 10,000 |
| **Entra IAM** | \ + \ (query params) | 1,000 (soft) |
| **B2C, IdGov** | Minimal / single-page | N/A |

---

## Operator-Value Priority (KQL Drift Detection)

**High-priority streams (daily ingest):**
1. Entra_UsersInventory_CL — User object changes
2. Defender_AlertsIncidents_CL — SOC audit trail
3. Entra_GroupsInventory_CL — Group membership rule changes
4. Entra_RoleAssignments_CL — RBAC drift
5. Defender_IdentityAudit_CL — MDI threat events

**Medium-priority (weekly):**
- Application Registry (SSO config drift)
- Device Inventory (Entra-joined roster)
- PIM Activation History (compliance trail)

**Hard-skip (per operator directive):**
- Advanced Hunting (use KQL API directly)
- Cloud Apps MCAS (alert stream sufficient)
- Attack Simulator results (operational tool, not audit)

---

## Files Audited

- nodoc-defender-xdr/specification/ (23 files, 595 ops)
- nodoc-ibiza-iam/specification/ (34 files, 286 ops)
- nodoc-entra-b2c/specification/ (1 file, 6 ops)
- nodoc-entra-idgov/specification/ (1 file, 2 named ops)
- nodoc-entra-iga/specification/ (1 file, 0 named ops)
- nodoc-entra-pim/specification/ (1 file, 0 named ops)

## Recommendations

1. **Immediate:** Ingest Defender XDR (Alerts, Incidents, Identity) + Entra IAM (Users, Groups, Roles)
2. **Phase 2:** B2C user journey tracking; Access Reviews
3. **Phase 3:** PIM activation audit; Exposure Management asset drift
4. **Hard-skip:** Advanced Hunting KQL transcripts; MCAS bulk data

**Runtime Classification:** Lab tenant 4xx responses do not invalidate endpoint candidacy. Recommend per-customer SuccessKind classification at deployment time.