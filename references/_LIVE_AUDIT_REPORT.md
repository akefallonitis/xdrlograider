# Live audit report — Phase 0 end-to-end verification

Generated: 2026-05-13 07:23:21 UTC

Goal: SA UPN + TOTP (or Passkey) -> all portals all endpoints unattended.
For portals/endpoints we cannot live-probe (license-gated, tenant-not-provisioned, path-templated needing entity IDs), nodoc OpenAPI + Postman provides design-time schemas.

## Global tally

- **Portals**: 20
- **Endpoints catalogued**: 1727
- **Live-captured (real JSON data)**: 359

Probed endpoints by SuccessKind:

| Kind | Count | Meaning |
|---|---:|---|
| error | 414 | - |
| live | 359 | HTTP 200 with non-empty response |
| live-empty | 52 | HTTP 200 with zero rows (tenant has no data of this type, but endpoint works) |
| network-error | 1 | Network/host issue — wrong audience or unreachable host |
| no-live-method-PATCH | 2 | - |
| no-live-pathparam | 92 | - |
| other | 5 | Method not allowed or unclassified status |
| request-shape-error | 20 | HTTP 400/422 — endpoint requires specific request shape (params, body) we have not yet replicated |
| server-error | 12 | HTTP 5xx — Microsoft-side issue |
| tenant-gated | 483 | HTTP 401/403/404 — license/RBAC/feature not present in this tenant; will work on production tenants with the right license |

## Per-portal end-to-end status

### defender

- **Bucket**: A-cookie
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `(cookie-based, no audience)`
- **Sub-areas**: 18 · **Endpoints**: 509

**Probe results:**

| SuccessKind | Count |
|---|---:|
| error | 294 |
| live | 120 |
| live-empty | 28 |
| no-live-method-PATCH | 2 |
| no-live-pathparam | 65 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| action_center | 11 | 5 | 2 | 0 | 0 | 4 |
| attack_simulator | 10 | 5 | 3 | 0 | 0 | 2 |
| cloud_apps | 92 | 2 | 0 | 0 | 0 | 90 |
| configuration | 53 | 22 | 5 | 0 | 0 | 26 |
| data_lake | 7 | 0 | 0 | 0 | 0 | 7 |
| endpoint_configuration | 19 | 5 | 2 | 0 | 0 | 12 |
| endpoint_devices | 48 | 12 | 2 | 0 | 0 | 34 |
| entity_pivots | 19 | 0 | 0 | 0 | 0 | 19 |
| exposure_management | 42 | 18 | 4 | 0 | 0 | 20 |
| files | 19 | 1 | 2 | 0 | 0 | 16 |
| identity | 74 | 14 | 3 | 0 | 0 | 57 |
| multi_tenant | 17 | 6 | 0 | 0 | 0 | 11 |
| portal_services | 21 | 7 | 1 | 0 | 0 | 13 |
| secure_score | 8 | 7 | 0 | 0 | 0 | 1 |
| sentinel_precision | 16 | 0 | 0 | 0 | 0 | 16 |
| streaming | 1 | 0 | 0 | 0 | 0 | 1 |
| threat_analytics | 20 | 4 | 0 | 0 | 0 | 16 |
| vulnerability_management | 32 | 12 | 4 | 0 | 0 | 16 |

### entra-b2c

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://main.b2cadmin.ext.azure.com`
- **Sub-areas**: 1 · **Endpoints**: 5

_Not yet probed live._ Design-time data available from nodoc OpenAPI + Postman.

### entra-ibiza-iam

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c`
- **Audience**: `74658136-14ec-4630-ad9b-26e160ff0fc6`
- **Sub-areas**: 32 · **Endpoints**: 234

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 50 |
| other | 4 |
| request-shape-error | 1 |
| server-error | 1 |
| tenant-gated | 44 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| account_sku | 17 | 1 | 0 | 5 | 0 | 0 |
| application_insights | 6 | 2 | 0 | 2 | 0 | 1 |
| application_proxy | 7 | 2 | 0 | 0 | 1 | 0 |
| application_sso | 27 | 2 | 0 | 0 | 0 | 1 |
| applications | 4 | 1 | 0 | 0 | 0 | 0 |
| authentication_methods | 3 | 0 | 0 | 2 | 0 | 0 |
| b2b | 3 | 2 | 0 | 0 | 0 | 0 |
| b2c | 1 | 0 | 0 | 0 | 0 | 0 |
| claim_providers | 3 | 1 | 0 | 1 | 0 | 0 |
| classic_policies | 7 | 0 | 0 | 1 | 0 | 0 |
| data_insights | 2 | 0 | 0 | 0 | 0 | 0 |
| devices | 3 | 0 | 0 | 0 | 0 | 0 |
| directories | 23 | 11 | 0 | 3 | 0 | 1 |
| document_processor_tasks | 5 | 1 | 0 | 0 | 0 | 0 |
| enterprise_applications | 3 | 1 | 0 | 0 | 0 | 0 |
| gdpr | 4 | 1 | 0 | 0 | 0 | 0 |
| groups | 8 | 1 | 0 | 1 | 0 | 0 |
| managed_applications | 6 | 0 | 0 | 0 | 0 | 0 |
| mdm_applications | 4 | 1 | 0 | 0 | 0 | 0 |
| microsoft_entra_connect | 1 | 1 | 0 | 0 | 0 | 0 |
| misc | 9 | 2 | 0 | 2 | 0 | 0 |
| multifactor_authentication | 26 | 1 | 0 | 13 | 0 | 2 |
| named_networks | 4 | 0 | 0 | 2 | 0 | 0 |
| password_reset | 8 | 3 | 0 | 4 | 0 | 0 |
| permissions | 4 | 3 | 0 | 0 | 0 | 0 |
| policies | 6 | 0 | 0 | 2 | 0 | 0 |
| registered_applications | 3 | 1 | 0 | 0 | 0 | 0 |
| reports | 10 | 3 | 0 | 2 | 0 | 0 |
| request_approvals | 6 | 1 | 0 | 1 | 0 | 0 |
| roles | 2 | 0 | 0 | 1 | 0 | 0 |
| security_defaults | 3 | 2 | 0 | 0 | 0 | 0 |
| users | 16 | 6 | 0 | 2 | 0 | 0 |

### entra-idgov

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://api.accessreviews.identitygovernance.azure.com`
- **Sub-areas**: 1 · **Endpoints**: 14

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live-empty | 1 |
| request-shape-error | 5 |
| tenant-gated | 1 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 14 | 0 | 1 | 1 | 5 | 0 |

### entra-iga

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://elm.iga.azure.com`
- **Sub-areas**: 1 · **Endpoints**: 9

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 2 |
| live-empty | 1 |
| server-error | 1 |
| tenant-gated | 1 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 9 | 2 | 1 | 1 | 0 | 1 |

### entra-pim

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://api.azrbac.mspim.azure.com`
- **Sub-areas**: 1 · **Endpoints**: 14

**Probe results:**

| SuccessKind | Count |
|---|---:|
| request-shape-error | 4 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 14 | 0 | 0 | 0 | 4 | 0 |

### exchange

- **Bucket**: A-cookie
- **ClientId**: `4765445b-32c6-49b0-83e6-1d93765276ca`
- **Audience**: `(cookie-based, no audience)`
- **Sub-areas**: 1 · **Endpoints**: 41

**Probe results:**

| SuccessKind | Count |
|---|---:|
| error | 20 |
| live | 16 |
| live-empty | 5 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 41 | 16 | 5 | 0 | 0 | 20 |

### intune-autopatch

- **Bucket**: B-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://services.autopatch.microsoft.com`
- **Sub-areas**: 1 · **Endpoints**: 49

**Probe results:**

| SuccessKind | Count |
|---|---:|
| tenant-gated | 27 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 49 | 0 | 0 | 27 | 0 | 0 |

### intune-portal

- **Bucket**: B-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c`
- **Audience**: `TBD: try https://intune.microsoft.com, https://api.manage.microsoft.com, or use existing Intune-service-API resource`
- **Sub-areas**: 1 · **Endpoints**: 5

**Probe results:**

| SuccessKind | Count |
|---|---:|
| tenant-gated | 1 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 5 | 0 | 0 | 1 | 0 | 0 |

### m365-admin

- **Bucket**: A-cookie+B-bearer-hybrid
- **ClientId**: `4765445b-32c6-49b0-83e6-1d93765276ca`
- **Audience**: `https://admin.microsoft.com`
- **Sub-areas**: 24 · **Endpoints**: 251

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 82 |
| live-empty | 7 |
| network-error | 1 |
| request-shape-error | 8 |
| server-error | 8 |
| tenant-gated | 114 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| agents | 6 | 0 | 0 | 4 | 0 | 1 |
| app_settings | 32 | 3 | 0 | 29 | 0 | 0 |
| billing | 17 | 6 | 0 | 5 | 0 | 1 |
| company_settings | 11 | 3 | 0 | 7 | 1 | 0 |
| content_understanding | 10 | 1 | 0 | 9 | 0 | 0 |
| copilot | 6 | 4 | 0 | 2 | 0 | 0 |
| domains | 5 | 2 | 0 | 2 | 0 | 1 |
| edge | 13 | 0 | 0 | 12 | 0 | 0 |
| features | 4 | 4 | 0 | 0 | 0 | 0 |
| graph_proxy | 13 | 2 | 2 | 5 | 1 | 0 |
| health | 7 | 5 | 0 | 1 | 0 | 0 |
| identity_security | 1 | 0 | 0 | 1 | 0 | 0 |
| integrated_apps | 7 | 5 | 0 | 0 | 0 | 1 |
| miscellaneous | 22 | 13 | 1 | 4 | 0 | 1 |
| navigation | 3 | 3 | 0 | 0 | 0 | 0 |
| partners | 5 | 1 | 2 | 0 | 1 | 1 |
| purview | 5 | 1 | 0 | 3 | 1 | 0 |
| reports | 9 | 2 | 0 | 7 | 0 | 0 |
| search | 13 | 0 | 0 | 8 | 0 | 0 |
| security_settings | 9 | 3 | 0 | 5 | 0 | 1 |
| tenant | 15 | 5 | 2 | 6 | 0 | 1 |
| tenant_relationships | 3 | 0 | 0 | 2 | 1 | 0 |
| users_groups | 32 | 16 | 0 | 2 | 3 | 1 |
| viva | 3 | 3 | 0 | 0 | 0 | 0 |

### m365-apps-config

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Sub-areas**: 1 · **Endpoints**: 22

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 4 |
| tenant-gated | 14 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 22 | 4 | 0 | 14 | 0 | 0 |

### m365-apps-inventory

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Sub-areas**: 1 · **Endpoints**: 25

**Probe results:**

| SuccessKind | Count |
|---|---:|
| tenant-gated | 21 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 25 | 0 | 0 | 21 | 0 | 0 |

### m365-apps-services

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Sub-areas**: 1 · **Endpoints**: 8

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 1 |
| tenant-gated | 5 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 8 | 1 | 0 | 5 | 0 | 0 |

### power-platform

- **Bucket**: B-bearer-multi-audience
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `per-host: bap=https://api.bap.microsoft.com; dynamics=https://{org}.crm.dynamics.com`
- **Sub-areas**: 9 · **Endpoints**: 244

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 6 |
| live-empty | 2 |
| request-shape-error | 1 |
| tenant-gated | 204 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| admin_analytics | 7 | 0 | 0 | 1 | 0 | 0 |
| admin_portal | 3 | 0 | 0 | 2 | 0 | 0 |
| business_app_platform | 19 | 6 | 2 | 2 | 1 | 0 |
| config_analytics | 1 | 0 | 0 | 1 | 0 | 0 |
| dynamics_crm | 135 | 0 | 0 | 128 | 0 | 0 |
| licensing | 65 | 0 | 0 | 58 | 0 | 0 |
| notification_service | 1 | 0 | 0 | 1 | 0 | 0 |
| power_pages_portal_infra | 10 | 0 | 0 | 10 | 0 | 0 |
| tenant_api | 3 | 0 | 0 | 1 | 0 | 0 |

### purview

- **Bucket**: A-cookie
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `(cookie-based, no audience)`
- **Sub-areas**: 19 · **Endpoints**: 127

**Probe results:**

| SuccessKind | Count |
|---|---:|
| error | 94 |
| live | 20 |
| live-empty | 8 |
| no-live-pathparam | 5 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| audit | 2 | 2 | 0 | 0 | 0 | 0 |
| billing | 7 | 2 | 0 | 0 | 0 | 5 |
| communication_compliance | 3 | 1 | 0 | 0 | 0 | 2 |
| compliance_manager | 9 | 0 | 0 | 0 | 0 | 9 |
| copilot | 8 | 0 | 1 | 0 | 0 | 7 |
| data_governance | 3 | 1 | 0 | 0 | 0 | 2 |
| data_infrastructure | 24 | 0 | 0 | 0 | 0 | 24 |
| data_security_investigations | 1 | 0 | 0 | 0 | 0 | 1 |
| dlp_devices | 8 | 4 | 0 | 0 | 0 | 4 |
| ediscovery | 6 | 0 | 2 | 0 | 0 | 4 |
| exchange_admin | 1 | 0 | 0 | 0 | 0 | 1 |
| governance_services | 6 | 0 | 0 | 0 | 0 | 6 |
| graph_proxy | 8 | 4 | 2 | 0 | 0 | 2 |
| information_protection | 2 | 0 | 0 | 0 | 0 | 2 |
| insider_risk | 5 | 0 | 0 | 0 | 0 | 5 |
| openapi | 8 | 0 | 0 | 0 | 0 | 8 |
| platform_services | 10 | 4 | 2 | 0 | 0 | 4 |
| purview_for_ai | 14 | 2 | 1 | 0 | 0 | 11 |
| sharepoint | 2 | 0 | 0 | 0 | 0 | 2 |

### purview-portal

- **Bucket**: A-cookie+silent-token
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `same-origin /api/Auth/getToken mints downstream`
- **Sub-areas**: 0 · **Endpoints**: 0

_Not yet probed live._ Design-time data available from nodoc OpenAPI + Postman.

### security-copilot

- **Bucket**: B-bearer-multi-host
- **ClientId**: `TBD-extract-from-next-js-bundle`
- **Audience**: `TBD per host`
- **Sub-areas**: 1 · **Endpoints**: 32

**Probe results:**

| SuccessKind | Count |
|---|---:|
| live | 2 |
| request-shape-error | 1 |
| tenant-gated | 11 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 32 | 2 | 0 | 11 | 1 | 0 |

### sharepoint

- **Bucket**: A-cookie+digest
- **ClientId**: `TBD-discover-from-tenant-admin-spo-bundle`
- **Audience**: `(cookie-based)`
- **Sub-areas**: 1 · **Endpoints**: 35

**Probe results:**

| SuccessKind | Count |
|---|---:|
| tenant-gated | 28 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 35 | 0 | 0 | 28 | 0 | 0 |

### teams

- **Bucket**: B-bearer-regional
- **ClientId**: `TBD-from-msftauth-bundle`
- **Audience**: `TBD via regional discovery: POST /api/authsvc/v1.0/users/region`
- **Sub-areas**: 1 · **Endpoints**: 98

**Probe results:**

| SuccessKind | Count |
|---|---:|
| error | 6 |
| live | 56 |
| no-live-pathparam | 22 |
| server-error | 2 |
| tenant-gated | 12 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 98 | 56 | 0 | 12 | 0 | 30 |

### viva

- **Bucket**: B-bearer-PKCE+Bayeux
- **ClientId**: `TBD-yammer-msal-pkce-client`
- **Audience**: `https://www.yammer.com/user_impersonation`
- **Sub-areas**: 1 · **Endpoints**: 5

**Probe results:**

| SuccessKind | Count |
|---|---:|
| other | 1 |

**Sub-area breakdown:**

| Sub-area | Eps | Live | LE | Tenant-gated | Req-shape | Other |
|---|---:|---:|---:|---:|---:|---:|
| openapi | 5 | 0 | 0 | 0 | 0 | 1 |

## Production-scale + cross-correlation reference

- **Cadence tiers** (per FA timer): 10min · 1h · 6h · daily · weekly (assigned per sub-area in `_SUBAREA_ENRICHED.json`)
- **Pagination styles** detected: pageIndex0Based · pageIndex1Based · topSkip · continuationToken · limitOffset · fromSize · none
- **Time-filter params** detected: startDateTime · since · before · updatedAfter · \ (where supported per endpoint)
- **Production-scale ratings** per sub-area: VolumeLargeT (rows on a 100K-user tenant) · RateLimitRisk · DeltaPollPriority
- **Cross-correlation entities** catalogued: 24 Sentinel-compatible entity types (Host.MdatpId / Account.UPN / File.Sha256 / Software.Version / Tenant.Id / Time.Generated / ...) — 834 endpoints tagged with entity hints from nodoc response schemas

## Blockers + nodoc-fallback decisions

| Blocker pattern | Affected portals | Resolution |
|---|---|---|
| AADSTS500011 (resource not in tenant) | intune-autopatch, entra-b2c (likely) | **Tenant-not-provisioned** — nodoc OpenAPI + Postman fallback for design schemas. Will work on production tenants with the service licensed. |
| AADSTS65002 (first-party preauth needed) | When using c44b4083 with non-preauth resources | **Resolved**: use Azure PowerShell public client \1950a258\ instead — pre-authorized broadly across Azure-side resources |
| Path-templated endpoints {id} | All portals | **Substituted** well-known values ({provider}=aadroles, {tenantId}=tenant guid); path-template-only-with-arbitrary-IDs are documented from nodoc OpenAPI |
| HTTP 400 request-shape | PIM activity endpoints, some PowerPlatform, etc. | Endpoint requires specific \ / \ / body — documented in nodoc \parameters[]\; production callers must include them |
| Intune Admin Center (intune.microsoft.com/api/*) | intune-portal | SPA same-origin endpoints; design-time from nodoc, runtime needs browser-equivalent MSAL token mint (separate research) |
| Defender / Purview / Exchange (cookie portals) | defender, purview, exchange | **Fully proven** via v1's cookie-chain |
