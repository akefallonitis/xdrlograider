# XdrLogRaider v2 — Master Catalogue Index

Generated: 2026-05-13 07:23:06 UTC

Complete Phase 0 catalogue: all portals × all sub-areas × all endpoints × auth model × pagination × time-filter × entities × production-scale cadence. Sourced from nodoc (1,727 endpoints) + v1 reference + this session's live-probe evidence.

## Global tally

- **Portals**: 20
- **Sub-areas**: 116
- **Endpoints**: 1727
- **Live-captured (live verdict)**: 359

## Per-portal catalogue

### defender

- **Bucket**: A-cookie
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `(cookie-based, no audience)`
- **Unattended status**: proven-v1-production-live
- **Sub-areas**: 18 · **Endpoints**: 509 · **Live**: 120 / live-empty 28 / err 294

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| action_center | 11 | daily | topSkip:2, pageIndex0Based:1, none:7, pageIndex1Based:1 | Investigation.Id, Time.Generated, Action.Id, Host.MdatpId | 5 | 100-10K events · risk=LOW · delta=medium |
| attack_simulator | 10 | daily | none:10 | Time.Generated | 5 | 10-1K · risk=LOW · delta=low |
| cloud_apps | 92 | daily | none:92 | Software.Version, Software.Name, Url.Path, Account.Sid | 2 | 10K+ audit/day · risk=HIGH (MCAS audit) · delta=critical |
| configuration | 53 | daily | pageIndex0Based:1, none:52 | Software.Version, Tenant.Id, Url.Path, File.Name | 22 | 100-10K · risk=LOW · delta=low |
| data_lake | 7 | daily | none:7 | Software.Version, File.Name | 0 | 1-10 · risk=LOW · delta=none |
| endpoint_configuration | 19 | daily | topSkip:1, none:17, pageIndex1Based:1 | Host.MdatpId, Account.UPN, Host.AadDeviceId, Rule.Id | 5 | 10-1K · risk=LOW · delta=low |
| endpoint_devices | 48 | daily | pageIndex0Based:4, fromSize:2, none:41, pageIndex1Based:1 | Host.MdatpId, Host.FullName, Software.Version, Time.Generated | 12 | 10K-1M rows · risk=HIGH on first poll · delta=critical |
| entity_pivots | 19 | weekly | none:19 | Url.Domain, Url.Path | 0 | per-entity · risk=depends · delta=depends |
| exposure_management | 42 | 1h | pageIndex0Based:3, none:39 | Software.Version, Tenant.Id, Vuln.CveId, Host.RiskScore | 18 | 1K-100K rows · risk=MEDIUM · delta=high |
| files | 19 | 6h | pageIndex0Based:2, none:17 | File.Sha256, File.Sha1, Url.Path, File.Name | 1 | varies · risk=MEDIUM · delta=medium |
| identity | 74 | daily | none:74 | Url.Domain, File.Path, Account.AadId, Account.SamName | 14 | 1K-100K rows · risk=MEDIUM · delta=high |
| multi_tenant | 17 | daily | none:17 | Tenant.Id, File.Path | 6 | 10-1K tenants · risk=LOW · delta=low |
| portal_services | 21 | daily | none:21 | Tenant.Id, Time.Generated, Account.UPN, Software.Version | 7 | 1-100 · risk=LOW · delta=none |
| secure_score | 8 | daily | none:8 | Software.Vendor, Url.Path, Software.Version | 7 | 1-100 · risk=LOW · delta=none |
| sentinel_precision | 16 | daily | none:16 | Software.Version | 0 | varies · risk=MEDIUM · delta=medium |
| streaming | 1 | 6h | none:1 | - | 0 | 1-10 · risk=LOW · delta=none |
| threat_analytics | 20 | 6h | pageIndex0Based:1, none:19 | Host.RiskScore, Url.Path, Url.Domain | 4 | 100-1K · risk=LOW · delta=low |
| vulnerability_management | 32 | daily | pageIndex0Based:8, none:21, pageIndex1Based:3 | Software.Vendor, Host.OsPlatform, Software.Name, Host.FullName | 12 | 10K-500K rows · risk=HIGH (paginated) · delta=critical |

### entra-b2c

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://main.b2cadmin.ext.azure.com`
- **Unattended status**: audience known; tenantId query param required per nodoc
- **Sub-areas**: 1 · **Endpoints**: 5 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 5 | daily | topSkip:1, none:4 | Tenant.Id | 0 | - |

### entra-ibiza-iam

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c`
- **Audience**: `74658136-14ec-4630-ad9b-26e160ff0fc6`
- **Unattended status**: FULLY-PROVEN-LIVE-JSON-DATA-RETURNED this session
- **Sub-areas**: 32 · **Endpoints**: 234 · **Live**: 50 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| account_sku | 17 | daily | none:17 | Software.Version, Account.AadId, File.Path, Software.Name | 1 | - |
| application_insights | 6 | daily | none:6 | Software.Version, Software.Name, Url.Path | 2 | - |
| application_proxy | 7 | daily | none:7 | Software.Version, File.Name, File.Path, Software.Name | 2 | - |
| application_sso | 27 | daily | none:27 | Software.Version, Url.Path | 2 | - |
| applications | 4 | daily | none:4 | Software.Version, Software.Name | 1 | - |
| authentication_methods | 3 | daily | none:3 | Software.Version | 0 | - |
| b2b | 3 | daily | none:3 | Software.Version | 2 | - |
| b2c | 1 | daily | none:1 | Software.Version, Url.Domain | 0 | - |
| claim_providers | 3 | daily | none:3 | Software.Version, File.Name | 1 | - |
| classic_policies | 7 | daily | none:7 | Software.Version | 0 | - |
| data_insights | 2 | daily | none:2 | Software.Version, Account.AadId, Account.UPN | 0 | - |
| devices | 3 | daily | none:3 | Software.Version | 0 | - |
| directories | 23 | daily | none:23 | File.Path, Software.Version, Tenant.Id, Software.Name | 11 | - |
| document_processor_tasks | 5 | daily | none:5 | - | 1 | - |
| enterprise_applications | 3 | daily | none:3 | Software.Version, Account.AadId | 1 | - |
| gdpr | 4 | daily | none:4 | Software.Version | 1 | - |
| groups | 8 | daily | none:8 | Software.Version, File.Name | 1 | - |
| managed_applications | 6 | daily | none:6 | Software.Version, Account.AadId | 0 | - |
| mdm_applications | 4 | daily | none:4 | Software.Version, File.Path | 1 | - |
| microsoft_entra_connect | 1 | daily | none:1 | File.Path, Software.Version | 1 | - |
| misc | 9 | daily | none:9 | Software.Version, File.Path, Url.Domain, File.Name | 2 | - |
| multifactor_authentication | 26 | daily | none:26 | Software.Version, Account.UPN, Tenant.Id, Policy.Id | 1 | - |
| named_networks | 4 | daily | none:4 | Software.Version, Software.Name | 0 | - |
| password_reset | 8 | daily | none:8 | Software.Version, Account.UPN, Account.AadId, Software.Name | 3 | - |
| permissions | 4 | daily | none:4 | Software.Version | 3 | - |
| policies | 6 | daily | none:6 | Software.Version, Time.Generated, Policy.Id, Software.Name | 0 | - |
| registered_applications | 3 | daily | none:3 | Software.Version | 1 | - |
| reports | 10 | daily | none:10 | Software.Version, Software.Name, Account.AadId, Account.UPN | 3 | - |
| request_approvals | 6 | daily | none:6 | Software.Version | 1 | - |
| roles | 2 | daily | none:2 | Software.Version, Account.AadId, Software.Name, File.Path | 0 | - |
| security_defaults | 3 | daily | none:3 | Software.Version | 2 | - |
| users | 16 | daily | none:16 | Software.Version, Account.AadId, Account.UPN, File.Path | 6 | - |

### entra-idgov

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://api.accessreviews.identitygovernance.azure.com`
- **Unattended status**: audience known; client likely shared
- **Sub-areas**: 1 · **Endpoints**: 14 · **Live**: 0 / live-empty 1 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 14 | daily | none:14 | Time.Generated, Software.Name | 0 | - |

### entra-iga

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://elm.iga.azure.com`
- **Unattended status**: audience known; client likely shared
- **Sub-areas**: 1 · **Endpoints**: 9 · **Live**: 2 / live-empty 1 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 9 | daily | none:9 | - | 2 | - |

### entra-pim

- **Bucket**: C-azure-ad-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://api.azrbac.mspim.azure.com`
- **Unattended status**: audience known from nodoc; client likely shared with Entra IAM
- **Sub-areas**: 1 · **Endpoints**: 14 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 14 | daily | none:14 | Alert.Id, File.Path | 0 | - |

### exchange

- **Bucket**: A-cookie
- **ClientId**: `4765445b-32c6-49b0-83e6-1d93765276ca`
- **Audience**: `(cookie-based, no audience)`
- **Unattended status**: proven-session-16-live-endpoints
- **Sub-areas**: 1 · **Endpoints**: 41 · **Live**: 16 / live-empty 5 / err 20

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 41 | daily | none:41 | - | 16 | - |

### intune-autopatch

- **Bucket**: B-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `https://services.autopatch.microsoft.com`
- **Unattended status**: auth-chain-pattern-shared-with-intune; audience known
- **Sub-areas**: 1 · **Endpoints**: 49 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 49 | daily | none:49 | Tenant.Id, Url.Path, Policy.Id, File.Path | 0 | - |

### intune-portal

- **Bucket**: B-bearer
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c`
- **Audience**: `TBD: try https://intune.microsoft.com, https://api.manage.microsoft.com, or use existing Intune-service-API resource`
- **Unattended status**: session-proven-auth-chain-end-to-end; code+access_token+refresh_token obtained; API audience TBD
- **Sub-areas**: 1 · **Endpoints**: 5 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 5 | daily | none:5 | - | 0 | - |

### m365-admin

- **Bucket**: A-cookie+B-bearer-hybrid
- **ClientId**: `4765445b-32c6-49b0-83e6-1d93765276ca`
- **Audience**: `https://admin.microsoft.com`
- **Unattended status**: cookie-chain-works-via-Exchange-client; bearer-side pending audience
- **Sub-areas**: 24 · **Endpoints**: 251 · **Live**: 82 / live-empty 7 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| agents | 6 | daily | none:6 | - | 0 | - |
| app_settings | 32 | daily | none:32 | - | 3 | - |
| billing | 17 | daily | none:17 | Software.Version, Software.Name | 6 | - |
| company_settings | 11 | daily | none:11 | Software.Name, Url.Path, Url.Domain, File.Name | 3 | - |
| content_understanding | 10 | daily | none:10 | - | 1 | - |
| copilot | 6 | daily | none:6 | - | 4 | - |
| domains | 5 | daily | none:5 | Url.Domain, File.Name | 2 | - |
| edge | 13 | daily | none:13 | Software.Version | 0 | - |
| features | 4 | daily | none:4 | - | 4 | - |
| graph_proxy | 13 | 6h | topSkip:2, none:11 | Time.Generated, Software.Name, Url.Full, Url.Path | 2 | - |
| health | 7 | daily | none:7 | - | 5 | - |
| identity_security | 1 | daily | none:1 | - | 0 | - |
| integrated_apps | 7 | daily | limitOffset:2, none:5 | - | 5 | - |
| miscellaneous | 22 | daily | none:22 | File.Path, Software.Version | 13 | - |
| navigation | 3 | daily | none:3 | - | 3 | - |
| partners | 5 | daily | none:5 | File.Path, Software.Version | 1 | - |
| purview | 5 | daily | none:5 | Tenant.Id, Time.Generated, Software.Version | 1 | - |
| reports | 9 | daily | pageIndex0Based:1, none:8 | - | 2 | - |
| search | 13 | daily | none:13 | Tenant.Id | 0 | - |
| security_settings | 9 | daily | none:9 | - | 3 | - |
| tenant | 15 | daily | none:15 | Software.Name | 5 | - |
| tenant_relationships | 3 | daily | none:3 | - | 0 | - |
| users_groups | 32 | daily | none:32 | Account.AadId, Software.Version, Account.SamName | 16 | - |
| viva | 3 | daily | none:3 | - | 3 | - |

### m365-apps-config

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Unattended status**: headers known; client + audience pending
- **Sub-areas**: 1 · **Endpoints**: 22 · **Live**: 4 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 22 | daily | none:22 | Software.Version | 4 | - |

### m365-apps-inventory

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Unattended status**: same as m365-apps-config
- **Sub-areas**: 1 · **Endpoints**: 25 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 25 | daily | none:25 | Software.Version, Url.Path, Vuln.CveId | 0 | - |

### m365-apps-services

- **Bucket**: B-bearer
- **ClientId**: `TBD-from-bundle`
- **Audience**: `TBD`
- **Unattended status**: same as m365-apps-config
- **Sub-areas**: 1 · **Endpoints**: 8 · **Live**: 1 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 8 | daily | none:8 | Software.Version | 1 | - |

### power-platform

- **Bucket**: B-bearer-multi-audience
- **ClientId**: `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely`
- **Audience**: `per-host: bap=https://api.bap.microsoft.com; dynamics=https://{org}.crm.dynamics.com`
- **Unattended status**: multi-audience pattern known; per-host audience map pending
- **Sub-areas**: 9 · **Endpoints**: 244 · **Live**: 6 / live-empty 2 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| admin_analytics | 7 | daily | none:7 | Url.Path, Time.Generated | 0 | - |
| admin_portal | 3 | weekly | none:3 | Url.Path | 0 | - |
| business_app_platform | 19 | daily | topSkip:2, none:17 | Software.Version, Url.Path, Time.Generated, File.Name | 6 | - |
| config_analytics | 1 | daily | none:1 | Tenant.Id, Url.Path | 0 | - |
| dynamics_crm | 135 | daily | topSkip:1, none:134 | Url.Path, Software.Version, Time.Generated, Account.UPN | 0 | - |
| licensing | 65 | daily | pageIndex0Based:1, topSkip:1, fromSize:8, none:55 | Tenant.Id, Url.Path, Software.Name | 0 | - |
| notification_service | 1 | daily | none:1 | Software.Version, Url.Path | 0 | - |
| power_pages_portal_infra | 10 | daily | none:10 | Url.Path, Tenant.Id | 0 | - |
| tenant_api | 3 | daily | none:3 | Software.Version, Url.Path | 0 | - |

### purview

- **Bucket**: A-cookie
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `(cookie-based, no audience)`
- **Unattended status**: proven-v1-and-session
- **Sub-areas**: 19 · **Endpoints**: 127 · **Live**: 20 / live-empty 8 / err 94

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| audit | 2 | daily | pageIndex0Based:1, none:1 | - | 2 | - |
| billing | 7 | daily | none:7 | Tenant.Id | 2 | - |
| communication_compliance | 3 | daily | topSkip:1, none:2 | Tenant.Id | 1 | - |
| compliance_manager | 9 | daily | none:9 | Account.UPN | 0 | - |
| copilot | 8 | daily | none:8 | Software.Version | 0 | - |
| data_governance | 3 | daily | none:3 | Software.Version | 1 | - |
| data_infrastructure | 24 | daily | pageIndex0Based:3, none:21 | Tenant.Id, Time.Generated | 0 | - |
| data_security_investigations | 1 | daily | none:1 | - | 0 | - |
| dlp_devices | 8 | 1h | pageIndex0Based:1, none:7 | Time.Generated, Host.FullName, Host.MdatpId, Account.AadId | 4 | - |
| ediscovery | 6 | daily | none:6 | - | 0 | - |
| exchange_admin | 1 | daily | none:1 | Tenant.Id | 0 | - |
| governance_services | 6 | daily | none:6 | - | 0 | - |
| graph_proxy | 8 | daily | topSkip:1, none:7 | File.Path, Account.SamName | 4 | - |
| information_protection | 2 | daily | none:2 | - | 0 | - |
| insider_risk | 5 | daily | topSkip:2, none:3 | Tenant.Id | 0 | - |
| openapi | 8 | daily | none:8 | - | 0 | - |
| platform_services | 10 | daily | none:10 | Software.Version | 4 | - |
| purview_for_ai | 14 | daily | none:14 | Tenant.Id, Time.Generated, Software.Name | 2 | - |
| sharepoint | 2 | daily | none:2 | - | 0 | - |

### purview-portal

- **Bucket**: A-cookie+silent-token
- **ClientId**: `80ccca67-54bd-44ab-8625-4b79c4dc7775`
- **Audience**: `same-origin /api/Auth/getToken mints downstream`
- **Unattended status**: auth-chain-proven; same-origin-token-mint-pending
- **Sub-areas**: 0 · **Endpoints**: 0 · **Live**: 0 / live-empty 0 / err 0

### security-copilot

- **Bucket**: B-bearer-multi-host
- **ClientId**: `TBD-extract-from-next-js-bundle`
- **Audience**: `TBD per host`
- **Unattended status**: auth-chain-pattern-known; multi-host audience discovery pending
- **Sub-areas**: 1 · **Endpoints**: 32 · **Live**: 2 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 32 | daily | none:32 | File.Path, Account.AadId | 2 | - |

### sharepoint

- **Bucket**: A-cookie+digest
- **ClientId**: `TBD-discover-from-tenant-admin-spo-bundle`
- **Audience**: `(cookie-based)`
- **Unattended status**: auth-chain-pattern-known; tenant-host + digest pending
- **Sub-areas**: 1 · **Endpoints**: 35 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 35 | daily | none:35 | Software.Version, Url.Path, File.Path | 0 | - |

### teams

- **Bucket**: B-bearer-regional
- **ClientId**: `TBD-from-msftauth-bundle`
- **Audience**: `TBD via regional discovery: POST /api/authsvc/v1.0/users/region`
- **Unattended status**: auth-chain-pattern-known; regional-discovery step required
- **Sub-areas**: 1 · **Endpoints**: 98 · **Live**: 56 / live-empty 0 / err 6

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 98 | daily | none:98 | Url.Path, Tenant.Id, Account.AadId, Software.Version | 56 | - |

### viva

- **Bucket**: B-bearer-PKCE+Bayeux
- **ClientId**: `TBD-yammer-msal-pkce-client`
- **Audience**: `https://www.yammer.com/user_impersonation`
- **Unattended status**: scope-known; client discovery + Bayeux relay handshake pending
- **Sub-areas**: 1 · **Endpoints**: 5 · **Live**: 0 / live-empty 0 / err 0

| Sub-area | Endpoints | Cadence | Pagination | Top entities | Live | Production scale |
|---|---:|---|---|---|---:|---|
| openapi | 5 | daily | none:5 | Url.Path, Software.Version | 0 | - |

## How to operate this catalogue

### Per-endpoint enrichment fields (in each metadata.json)

- `parameters` — path/query/header/body parameters from nodoc OpenAPI
- `paginationStyle` — pageIndex0Based | pageIndex1Based | topSkip | continuationToken | limitOffset | fromSize | none
- `timeFilterParams` — names of time-filter params (startDateTime, since, etc.) for delta-poll
- `entities` — canonical Sentinel entity types extracted from response schema (Host.MdatpId, Account.UPN, File.Sha256, ...)
- `cadenceSuggestion` — 10min | 1h | 6h | daily | weekly (FA timer hint per sub-area)

### Per-sub-area roll-up (_SUBAREA_ENRICHED.json)

- `paginationDistribution` — count of endpoints per pagination style in this sub-area
- `timeFilterEndpointCount` — how many endpoints support incremental polls
- `topEntities` — top 8 cross-correlation join keys (Sentinel entity types)
- `productionScale` — VolumeLargeT (rows expected on large tenants), RateLimitRisk, DeltaPollPriority

### Per-portal auth research (_AUTH_RESEARCH.json)

- `authModel` — bucket, clientId, portalHost, audience, cookieNames, requiredHeaders
- `unattendedAuth` — TOTP+Passkey support, CA matrix, ESTSAUTHPERSISTENT, refreshToken cadence
- `kvSecretSchema` — KV secret names per portal

