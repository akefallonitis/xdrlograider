# XdrLogRaider v2 — Full Phase 0 Catalogue

**Generated:** 2026-05-13 07:23:31 UTC
**Source:** disk-aggregated from `references/<portal>/<sub-area>/<endpoint>/metadata.json` + `live.json` + `_SUBAREA_ENRICHED.json` + `_AUTH_RESEARCH.json` + cross-referenced with vendored nodoc OpenAPI + Postman collections.
**Purpose:** core reference for Phase 1 manifest builder. Wins over `_CATALOGUE_INDEX.md` (legacy summary) on conflict.

Format conventions:
- ReadSemantics column: `read` (List/Get/Query/Search/Filter/Export/Probe/Fetch/Read/Inspect/Audit/Find/Resolve/Validate/Check/Test) · `write` (Create/Update/Delete/Save/Add/Remove/Move/Patch/Modify/Submit/Invoke/Run/Refresh/Reset/Reload/Reboot/Trigger/Send/Post/Put/Push/Apply/Approve/Reject/Suppress/Unsuppress/Disable/Enable/Override/Set) · `unknown` else
- Pagination column: `style (idx=...,size=...,tok=...)` or `none`
- TimeFilter column: `start=... end=... lookback=... type=...` or `-`
- Entities column: top 3 Sentinel-compatible entity hints (`Host.MdatpId`, `Account.UPN`, etc.) — see Enrich-Entities-Parsing-Value.ps1 mapping
- Live column: `successKind[httpStatus] r=rowCount` or `unprobed`
- Phase 1 in-scope sub-areas marked with [P1]; wholesale-excluded with [EXCL]

---

## Global tally

- **Portals:** 20
- **Endpoints:** 1727
- **Live-captured:** 359
- **Postman collections:** 20
- **Nodoc OpenAPI portal specs:** 20

| Portal | Endpoints | Live | Phase 1 in-scope |
|---|---:|---:|---|
| defender | 509 | 120 | YES (18 sub-areas) |
| entra-b2c | 5 | 0 | No (v0.2.0+ scope) |
| entra-ibiza-iam | 234 | 50 | No (v0.2.0+ scope) |
| entra-idgov | 14 | 0 | No (v0.2.0+ scope) |
| entra-iga | 9 | 2 | No (v0.2.0+ scope) |
| entra-pim | 14 | 0 | No (v0.2.0+ scope) |
| exchange | 41 | 16 | No (v0.2.0+ scope) |
| intune-autopatch | 49 | 0 | No (v0.2.0+ scope) |
| intune-portal | 5 | 0 | No (v0.2.0+ scope) |
| m365-admin | 251 | 82 | No (v0.2.0+ scope) |
| m365-apps-config | 22 | 4 | No (v0.2.0+ scope) |
| m365-apps-inventory | 25 | 0 | No (v0.2.0+ scope) |
| m365-apps-services | 8 | 1 | No (v0.2.0+ scope) |
| power-platform | 244 | 6 | No (v0.2.0+ scope) |
| purview | 127 | 20 | No (v0.2.0+ scope) |
| purview-portal | 0 | 0 | No (v0.2.0+ scope) |
| security-copilot | 32 | 2 | No (v0.2.0+ scope) |
| sharepoint | 35 | 0 | No (v0.2.0+ scope) |
| teams | 98 | 56 | No (v0.2.0+ scope) |
| viva | 5 | 0 | No (v0.2.0+ scope) |

---

## Portal: `defender`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie |
| ClientId | `80ccca67-54bd-44ab-8625-4b79c4dc7775` |
| Audience | `(cookie-based, no audience)` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-defender-xdr\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\defender.collection.json` (present)

### Sub-areas: 18 · Endpoints: 509 · Live: 120

#### `action_center` [P1]

**Sub-area summary:** 11 endpoints · cadence=daily · pagination=topSkip:2 / pageIndex0Based:1 / none:7 / pageIndex1Based:1 · time-filter coverage=0/11 · top entities=Investigation.Id, Time.Generated, Action.Id, Host.MdatpId, Tenant.Id · production scale=100-10K events · risk=LOW · delta=medium

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ExportHistory | `/mtp/actionCenter/actioncenterui/history-actions/export` | GET | read | pageIndex1Based (idx=pageIndex,size=pageSize) | start=fromDate end=toDate type=iso8601 | - | 10min | live[200] r=1 |
| GetCase | `/mtp/CaseManagement/be/cases/{CaseId}` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetHistory | `/mtp/actionCenter/actioncenterui/history-actions` | GET | read | pageIndex0Based (idx=pageIndex,size=pageSize,tok=$skip) | - | Action.Id, Host.MdatpId, Investigation.Id | 10min | live[200] r=30 |
| GetHistoryFilters | `/mtp/actionCenter/actioncenterui/history-actions/filters` | GET | read | none | - | Investigation.Id | 10min | live[200] r=1 |
| GetPending | `/mtp/actionCenter/actioncenterui/pending-actions` | GET | read | pageIndex0Based (idx=pageIndex,size=pageSize,tok=$skip) | - | - | 10min | live-empty[200] r=0 |
| GetPendingFilters | `/mtp/actionCenter/actioncenterui/pending-actions/filters` | GET | read | none | - | Investigation.Id | 10min | live[200] r=1 |
| GetPendingSummary | `...er/actioncenterui/pending-actions/pending-actions-summary` | GET | read | none | - | - | 10min | live-empty[200] r=0 |
| GetTileSummary | `/mtp/actionCenter/actioncenterui/tile` | GET | read | none | - | - | 10min | live[200] r=1 |
| ListAutomationRules | `...automation/internal/automation/{TenantId}/automationRules` | GET | read | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| ListCaseActivities | `/mtp/CaseManagement/be/cases/{CaseId}/activities` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| ListCaseAttachments | `/mtp/CaseManagement/be/attachments` | GET | read | none | - | - | daily | error[400] r=0 |

#### `attack_simulator` [P1]

**Sub-area summary:** 10 endpoints · cadence=daily · pagination=none:10 · time-filter coverage=0/10 · top entities=Time.Generated · production scale=10-1K · risk=LOW · delta=low

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetCampaignSettings | `/astgws/AttackSimulator/api/v1/campaignSettings` | GET | read | none | - | - | daily | live[200] r=1 |
| GetRecommendations | `/astgws/AttackSimulator/api/v1/Recommendations` | GET | read | none | - | - | daily | live[200] r=7 |
| GetRepeatOffenderChartNRT | `...imulator/api/v1/AdvanceReporting/chart/NRT/RepeatOffender` | GET | read | none | - | - | daily | error[404] r=0 |
| GetTrainingCompletionChartNRT | `...ator/api/v1/AdvanceReporting/chart/NRT/TrainingCompletion` | GET | read | none | - | - | daily | error[404] r=0 |
| GetTrainingEfficacyChart | `...kSimulator/api/v1/AdvanceReporting/chart/TrainingEfficacy` | GET | read | none | - | - | daily | live[200] r=1 |
| GetUserProfileType | `/astgws/AttackSimulator/api/v1/userProfileType` | GET | read | none | - | - | daily | live[200] r=1 |
| ListGlobalPayloads | `/astgws/AttackSimulator/api/v1/GlobalPayloads` | GET | read | none | - | Time.Generated | daily | live[200] r=1000 |
| ListSimulationAutomations | `/astgws/AttackSimulator/api/v1/simulationAutomations` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| ListSimulations | `/astgws/AttackSimulator/api/v1/Simulations` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| ListTrainingCampaignsV2 | `/astgws/AttackSimulator/api/v1/trainingCampaignsV2` | GET | read | none | - | - | daily | live-empty[200] r=0 |

#### `cloud_apps` [P1]

**Sub-area summary:** 92 endpoints · cadence=daily · pagination=none:92 · time-filter coverage=0/92 · top entities=Software.Version, Software.Name, Url.Path, Account.Sid · production scale=10K+ audit/day · risk=HIGH (MCAS audit) · delta=critical

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AutocompleteAppPermissionNames | `/mcas/api/v1/autocomplete/app-permission-names` | GET | unknown | none | - | - | daily | error[404] r=0 |
| AutocompleteAppPermissionPermissions | `/mcas/api/v1/autocomplete/app-permission-permissions` | GET | unknown | none | - | - | daily | error[404] r=0 |
| AutocompleteDiscoveryAppTags | `/mcas/cas/api/v1/autocomplete/discovery_app_tags` | GET | unknown | none | - | - | daily | error[403] r=0 |
| AutocompleteEntities | `/mcas/cas/api/v1/autocomplete/entities` | GET | unknown | none | - | - | daily | error[500] r=0 |
| AutocompleteScopedProfiles | `/mcas/cas/api/v1/autocomplete/scoped_profiles` | GET | unknown | none | - | - | daily | error[403] r=0 |
| AutocompleteTags | `/mcas/cas/api/v1/autocomplete/tags` | GET | unknown | none | - | - | daily | error[403] r=0 |
| AutocompleteTokens | `/mcas/cas/api/v1/autocomplete/tokens` | GET | unknown | none | - | - | daily | error[403] r=0 |
| AutocompleteUsers | `/mcas/cas/api/v1/autocomplete/users` | GET | unknown | none | - | - | daily | error[403] r=0 |
| CountSiemAgents | `/mcas/api/v1/agents/siem/count` | GET | unknown | none | - | - | daily | live[200] r=1 |
| GetAboutInfo | `/mcas/cas/api/about/info` | GET | read | none | - | - | daily | error[500] r=0 |
| GetAboutServerUrl | `/mcas/cas/api/about/server_url` | GET | read | none | - | Url.Path | daily | error[500] r=0 |
| GetActivitiesCount | `/mcas/cas/api/v1/activities/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetActivitiesMetadata | `/mcas/cas/api/v1/activities/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetActivitiesThreatScores | `/mcas/cas/api/v1/activities/get_activities_threat_scores` | POST | read | none | - | - | daily | error[403] r=0 |
| GetActivityLocationsByUser | `/mcas/cas/api/v1/activities_locations/by_user` | GET | read | none | - | - | daily | error[500] r=0 |
| GetAppConnectorInstanceCountByApp | `...api/v1/app_connectors/dashboard/get_instance_count_by_app` | GET | read | none | - | - | daily | error[500] r=0 |
| GetAppConnectorsCount | `/mcas/cas/api/v1/app_connectors/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetAppConnectorsLastActivity | `/mcas/cas/api/v1/app_connectors/last_activity` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAppConnectorsMetadata | `/mcas/cas/api/v1/app_connectors/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAppConnectorsTableConfigValues | `/mcas/cas/api/v1/app_connectors/table_config_values` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAppPermissionsCount | `/mcas/cas/api/v1/app_permissions/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetAppPermissionsMetadata | `/mcas/cas/api/v1/app_permissions/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAppsCountByStatus | `.../api/v1/app_connectors/dashboard/get_apps_count_by_status` | GET | read | none | - | - | daily | error[500] r=0 |
| GetBootConstants | `/mcas/cas/boot_constants` | GET | read | none | - | - | daily | error[500] r=0 |
| GetCloudAppsFileCount | `/mcas/cas/api/v1/files/count` | POST | read | none | - | - | 6h | error[403] r=0 |
| GetComplianceAppMetadata | `/m365appprotection/mapg-glsservice/compliance/appmetadata` | POST | read | none | - | - | daily | error[400] r=0 |
| GetDataEncryptionSettings | `/mcas/cas/api/v1/data_encryption_settings/get` | GET | read | none | - | - | daily | error[403] r=0 |
| GetDiscoveredAppsCount | `/mcas/cas/api/v1/discovery/discovered_apps/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetDiscoveredAppsMetadata | `/mcas/cas/api/v1/discovery/discovered_apps/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetDiscoveryAppCatalogCount | `/mcas/cas/api/v1/discovery/app_catalog/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetDiscoveryAppCatalogMetadata | `/mcas/cas/api/v1/discovery/app_catalog/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetDiscoveryCategoryStats | `/mcas/cas/api/v1/discovery/category_stats` | GET | read | none | - | - | daily | error[500] r=0 |
| GetDiscoveryConstants | `/mcas/cas/api/v1/discovery/constants` | GET | read | none | - | - | daily | error[500] r=0 |
| GetDiscoveryServiceLocations | `/mcas/cas/api/v1/discovery/service_locations` | GET | read | none | - | - | daily | error[500] r=0 |
| GetDiscoveryTopApps | `/mcas/cas/api/v1/discovery/top_apps` | GET | read | none | - | - | daily | error[500] r=0 |
| GetDiscoveryTopCategories | `/mcas/cas/api/v1/discovery/top_categories` | GET | read | none | - | - | daily | error[500] r=0 |
| GetDiscoveryTopEntities | `/mcas/cas/api/v1/discovery/top_entities` | GET | read | none | - | - | daily | error[500] r=0 |
| GetEntitiesMetadata | `/mcas/cas/api/v1/entities/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetFeatureValues | `/mcas/cas/api/v1/get_feature_values` | POST | read | none | - | - | daily | error[403] r=0 |
| GetGovernanceCount | `/mcas/cas/api/v1/governance/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetGovernanceMetadata | `/mcas/cas/api/v1/governance/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetLcncSettings | `/mcas/cas/api/v1/lcnc_settings` | GET | read | none | - | - | daily | error[403] r=0 |
| GetLinkedPoliciesByTemplateIds | `...1/policy_templates_inmemo/linked_policies_by_template_ids` | POST | read | none | - | - | daily | error[403] r=0 |
| GetMailSettings | `/mcas/cas/api/v1/mail_settings/get` | GET | read | none | - | - | daily | error[403] r=0 |
| GetMtpScopesAndPermissions | `/mcas/cas/api/v1/mtp_scopes_and_permissions` | GET | read | none | - | - | daily | error[500] r=0 |
| GetPoliciesCount | `/mcas/cas/api/v1/policies/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetPoliciesMetadata | `/mcas/cas/api/v1/policies/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetPolicy | `/m365appprotection/mapg-glsservice/compliance/Policy` | GET | read | none | - | - | daily | error[400] r=0 |
| GetPolicyInsights | `/m365appprotection/mapg-glsservice/compliance/policyinsights` | GET | read | none | - | - | daily | error[400] r=0 |
| GetPolicyTemplatesCount | `/mcas/cas/api/v1/policy_templates_inmemo/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetPolicyTemplatesMetadata | `/mcas/cas/api/v1/policy_templates_inmemo/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetSettings | `/mcas/cas/api/v1/settings` | GET | read | none | - | - | daily | error[403] r=0 |
| GetShouldDisplaySyncBar | `/mcas/cas/api/v1/user_config/get_should_display_sync_bar` | GET | read | none | - | - | daily | error[403] r=0 |
| GetStandaloneEntitiesCount | `/mcas/cas/api/v1/standalone_entities/count` | POST | read | none | - | - | daily | error[403] r=0 |
| GetStandaloneEntitiesMetadata | `/mcas/cas/api/v1/standalone_entities/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetStoryDetails | `/mcas/cas/api/stories/get_stories_details` | GET | read | none | - | - | daily | error[500] r=0 |
| GetSubnetMetadata | `/mcas/cas/api/v1/subnet/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetSupportedAppConnectorMetadata | `...i/v1/app_connectors/dashboard/get_supported_apps_metadata` | GET | read | none | - | - | daily | error[500] r=0 |
| GetTenantDataTraffic | `...ppprotection/mapg-glsservice/compliance/tenantdatatraffic` | GET | read | none | - | - | daily | error[400] r=0 |
| GetTenantLabelMetric | `...ppprotection/mapg-glsservice/compliance/tenantLabelMetric` | GET | read | none | - | - | daily | error[400] r=0 |
| GetTenantMetrics | `/m365appprotection/mapg-glsservice/compliance/tenantmetrics` | GET | read | none | - | - | daily | error[400] r=0 |
| GetTokensMetadata | `/mcas/cas/api/v1/tokens/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetUserProfile | `/m365appprotection/mapg-glsservice/compliance/getUserProfile` | GET | read | none | - | - | daily | error[400] r=0 |
| GetUserTagsMetadata | `/mcas/cas/api/v1/user_tags/metadata` | GET | read | none | - | - | daily | error[403] r=0 |
| GetVersion | `/mcas/cas/api/version` | GET | read | none | - | Software.Version | daily | live[200] r=1 |
| IsExternalAdminUser | `/mcas/cas/api/v1/manage_admins/is_external_user` | GET | unknown | none | - | - | daily | error[500] r=0 |
| ListActivities | `/mcas/cas/api/v1/activities` | POST | read | none | - | - | daily | error[403] r=0 |
| ListAppConnectors | `/mcas/cas/api/v1/app_connectors` | POST/GET | read | none | - | - | daily | error[403] r=0 |
| ListAppPermissions | `/mcas/cas/api/v1/app_permissions` | POST | read | none | - | - | daily | error[403] r=0 |
| ListComplianceApps | `/m365appprotection/mapg-glsservice/compliance/apps` | GET | read | none | - | - | daily | error[400] r=0 |
| ListComplianceLabels | `/m365appprotection/mapg-glsservice/compliance/getLabels` | GET | read | none | - | - | daily | error[400] r=0 |
| ListConnectedServiceApps | `/mcas/cas/api/v1/connected_services/apps` | GET | read | none | - | - | daily | error[403] r=0 |
| ListConnectedServiceInstances | `/mcas/cas/api/v1/connected_services/instances` | GET | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveredAppCategories | `/mcas/cas/api/v1/discovery/discovered_apps/categories` | POST | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveredApps | `/mcas/cas/api/v1/discovery/discovered_apps` | POST | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveryAppCatalog | `/mcas/cas/api/v1/discovery/app_catalog` | POST | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveryAppCatalogCategories | `/mcas/cas/api/v1/discovery/app_catalog/categories` | POST | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveryCategories | `/mcas/cas/api/v1/discovery/categories` | GET | read | none | - | - | daily | error[500] r=0 |
| ListDiscoverySnapshotReports | `/mcas/cas/api/v1/discovery/snapshot_reports` | POST | read | none | - | - | daily | error[403] r=0 |
| ListDiscoveryStreams | `/mcas/cas/api/discovery/streams` | GET | read | none | - | - | daily | error[500] r=0 |
| ListGovernanceActions | `/mcas/cas/api/v1/governance` | POST | read | none | - | - | daily | error[403] r=0 |
| ListInvitedGroupAdmins | `/mcas/cas/api/v1/invited_group_admins` | GET | read | none | - | - | daily | error[403] r=0 |
| ListPolicies | `/m365appprotection/mapg-glsservice/compliance/policies` | GET | read | none | - | - | daily | error[400] r=0 |
| ListPolicyTemplates | `/mcas/cas/api/v1/policy_templates_inmemo` | POST | read | none | - | - | daily | error[403] r=0 |
| ListServices | `/mcas/cas/api/services` | GET | read | none | - | - | daily | error[403] r=0 |
| ListSiemAgents | `/mcas/api/v1/agents/siem` | GET | read | none | - | - | daily | error[404] r=0 |
| ListTags | `/mcas/cas/api/tags` | GET | read | none | - | - | daily | error[403] r=0 |
| ListUserQueries | `/mcas/cas/api/v1/user_queries` | GET | read | none | - | - | daily | error[403] r=0 |
| LogTranslationError | `/mcas/cas/api/v1/translation/log-error` | POST | unknown | none | - | - | daily | error[403] r=0 |
| ResolveEntity | `/mcas/cas/api/v1/entities/resolve_entity` | POST | read | none | - | Account.Sid, Software.Name | daily | error[403] r=0 |
| SearchDiscoveryLocations | `/mcas/cas/api/v1/discovery/get_locations` | GET | read | none | - | - | daily | error[500] r=0 |
| UpdateUsageInfo | `/mcas/cas/update_usage_info` | POST | write | none | - | - | daily | error[500] r=0 |

#### `configuration` [P1]

**Sub-area summary:** 53 endpoints · cadence=daily · pagination=pageIndex0Based:1 / none:52 · time-filter coverage=0/53 · top entities=Software.Version, Tenant.Id, Url.Path, File.Name, Host.FullName · production scale=100-10K · risk=LOW · delta=low

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CheckUnifiedConnectorRequirements | `/mtp/unifiedConnectors/public/connectors/checkrequirements` | GET | read | none | - | Tenant.Id | daily | live[200] r=1 |
| GetAiAgentCountsByPlatform | `...ory/ai-agents-v3/agents-current-count-by-platform-metrics` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetAiAgentsDiscoveredOverTime | `/mdc/views/inventory/ai-agents-v3/agents-discovered-overtime` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetAiAgentsRequiringAttentionOverTime | `.../ai-agents-v3/agents-requiring-attention-overtime-metrics` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetAlertSharingStatus | `/mtp/wdatpInternalApi/compliance/alertSharing/status` | GET | read | none | - | - | 1h | live[200] r=1 |
| GetAllDisruptionExclusions | `/mtp/disrupt/api/exclusions/exclude-all` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAllowNonAuthSense | `/mtp/responseApiPortal/senseauth/allownonauthsense` | GET | read | none | - | - | weekly | live[200] r=1 |
| GetAssetRules | `/mtp/ndr/rulesengine/rules` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetAutoIrProperties | `/mtp/autoIr/ui/properties` | GET | read | none | - | - | daily | live[200] r=1 |
| GetBuiltInSuppressionRulesHash | `...suppressionRulesService/suppressionRules/builtInRulesHash` | GET | read | none | - | - | daily | live[200] r=1 |
| GetCloudAppsSettings | `/mcas/cas/api/v1/settings` | GET | read | none | - | - | 6h | error[403] r=0 |
| GetCloudAssetInventorySchema | `/mdc/views/inventory/schema` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetCloudOverviewMetrics | `/mdc/views/overview/overviewMetrics` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetCriticalAssetClassificationSchema | `/mtp/xspmatlas/assetrules/querybuilder/schema` | GET | read | none | - | - | 1h | live[200] r=1 |
| GetCurrentUserRbacRoles | `/mtp/rbacManagementApi/rbac/user_roles` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetDataExportSettings | `/mtp/wdatpApi/dataexportsettings` | GET | read | none | - | - | weekly | live[200] r=1 |
| GetDisabledAlertServices | `/mtp/alertsApiService/workloads/disabled` | GET | read | none | - | - | 1h | error[403] r=0 |
| GetGlobalIdentityDisruptionExclusion | `/mtp/disrupt/api/exclusions/Identity/global-exclusion` | GET | read | none | - | - | daily | error[403] r=0 |
| GetIdentityDisruptionExclusions | `/mtp/disrupt/api/exclusions/Identity` | GET | read | none | - | - | daily | error[403] r=0 |
| GetInternalIndicatorCount | `/mtp/papin/api/cloud/public/internal/indicators/count` | GET | read | none | - | - | daily | live[200] r=1 |
| GetInternalIndicatorFilterValues | `/mtp/papin/api/cloud/public/internal/indicators/filterValues` | GET | read | none | - | - | daily | error[500] r=0 |
| GetIntuneOnboardingStatus | `/mtp/responseApiPortal/onboarding/intune/status` | GET | read | none | - | - | weekly | live[200] r=1 |
| GetLicenseSums | `/mtp/licenses/mgmt/aadlicenses/sums` | GET | read | none | - | - | daily | error[403] r=0 |
| GetMcasPreviewFeatures | `/mcas/cas/api/v1/preview_features/get` | GET | read | none | - | - | daily | error[403] r=0 |
| GetMdcLicenseStatus | `/mtp/licenses/mgmt/aadlicenses/mdc/status` | GET | read | none | - | - | daily | error[403] r=0 |
| GetMdcPreviewFeatures | `/mdc/management/optin` | GET | read | none | - | - | daily | live[200] r=1 |
| GetSentinelOnboardedState | `/mtp/sentinelOnboarding/sentinel/workspaces/isOnboarded` | GET | read | none | - | - | daily | live[200] r=1 |
| GetServiceAccountClassifications | `/radius/api/radius/serviceaccounts/classificationrule/getall` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetServiceUrls | `/mtp/sccManagement/mgmt/ServicesUrls` | GET | read | none | - | Url.Path | daily | live[200] r=1 |
| GetTenantContext | `/mtp/sccManagement/mgmt/TenantContext` | GET | read | none | - | Account.AadId, Tenant.Id | daily | live[200] r=1 |
| GetTopWebContentFilteringCategories | `...rotection/WebContentFiltering/Reports/TopParentCategories` | GET | read | none | - | File.Name | daily | live[200] r=1 |
| GetUnifiedRbacPermissions | `...bacConfiguration/gw/unifiedrbac/configuration/permissions` | GET | read | none | - | - | 6h | error[403] r=0 |
| GetUnifiedRbacWorkload | `...rbacConfiguration/gw/unifiedrbac/configuration/tenantinfo` | GET | read | none | - | - | daily | error[403] r=0 |
| GetUserSettings | `/mtp/settings/GetUserSettings` | GET | read | none | - | - | daily | live[200] r=1 |
| GetWebThreatSummary | `/mtp/webThreatProtection/webThreats/reports/webThreatSummary` | GET | read | none | - | - | daily | live[200] r=1 |
| ListConnectedApps | `/mtp/responseApiPortal/apps/all` | GET | read | none | - | Software.Name | weekly | live[200] r=1 |
| ListCriticalAssetClassifications | `/mtp/xspmatlas/assetrules` | GET/POST/PUT/DELETE | read | none | - | Rule.Id, Tenant.Id | 1h | live[200] r=132 |
| ListEligibleSentinelWorkspaces | `...tinelOnboarding/sentinel/workspaces/eligibleForOnboarding` | POST | read | none | - | - | daily | error[415] r=0 |
| ListFileSubmissions | `...ustomerSubmissionService/file/enterprise/query/{TenantId}` | GET | read | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| ListIncidentNotificationSettings | `.../api/cloud/public/internal/IncidentNotificationSettingsV2` | GET | read | none | - | - | daily | live[200] r=1 |
| ListRbacAadGroups | `/mtp/rbacManagementApi/rbac/aad_groups` | GET | read | none | - | - | daily | live[200] r=3 |
| ListSuppressionRules | `/mtp/suppressionRulesService/suppressionRules` | GET | read | none | - | Host.FullName | daily | live[200] r=21 |
| ListThreatIndicators | `/mtp/responseApiPortal/ti/indicators` | GET | read | pageIndex0Based (idx=PageIndex) | - | Tenant.Id, Url.Path | weekly | live-empty[200] r=0 |
| ListUnifiedConnectors | `/mtp/unifiedConnectors/public/connectors` | GET | read | none | - | Software.Version, Tenant.Id, Url.Path | daily | live[200] r=3 |
| ListUnifiedRbacRoleAssignments | `...ration/roleDefinitions/{RoleDefinitionId}/roleAssignments` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| ListUnifiedRbacRoleDefinitions | `...onfiguration/gw/unifiedrbac/configuration/roleDefinitions` | GET | read | none | - | - | 6h | error[403] r=0 |
| ListUnifiedRbacWorkspaces | `...rbacConfiguration/gw/unifiedrbac/configuration/workspaces` | GET | read | none | - | - | 6h | error[403] r=0 |
| ListWebCategoryPolicies | `/mtp/responseApiPortal/webcategory/policies` | GET | read | none | - | File.Name | weekly | live-empty[200] r=0 |
| QueryCloudAssetInventory | `/mdc/views/inventory/assets` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| QueryCloudAssetInventoryMetrics | `/mdc/views/inventory/metrics` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| QueryCriticalAssetClassification | `...spmatlas/assetrules/querybuilder/assets/{encodedRuleName}` | GET | read | none | - | Url.Path | 1h | no-live-pathparam r=0 |
| SetMcasPreviewFeatures | `/mcas/cas/api/v1/preview_features/update` | POST | write | none | - | - | daily | error[403] r=0 |
| SetPreviewFeatures | `/mtp/settings/SavePreviewExperienceSetting` | POST | write | none | - | - | daily | error[403] r=0 |

#### `data_lake` [P1]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=0/7 · top entities=Software.Version, File.Name · production scale=1-10 · risk=LOW · delta=none

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CheckSentinelProvisioning | `/securityplatform/sentinelgraph/provisioning/checkTenant` | POST | read | none | - | - | daily | error[400] r=0 |
| GetJobDetails | `/securityplatform/jobs/details` | GET | read | none | - | - | daily | error[403] r=0 |
| GetJobRunsSummary | `/securityplatform/jobs/runs/summary` | GET | read | none | - | - | daily | error[403] r=0 |
| GetTableSchema | `/securityplatform/lake/kql/v1/rest/mgmt` | GET | read | none | - | - | daily | error[405] r=0 |
| ListDatabases | `/securityplatform/lake/databases` | GET | read | none | - | Software.Version | daily | error[400] r=0 |
| ListQueryHistory | `/securityplatform/lake/kql/query-history` | GET | read | none | - | - | daily | error[400] r=0 |
| ListSentinelGraphCatalogTables | `/securityplatform/sentinelgraph/catalog/tables` | GET | read | none | - | File.Name | daily | error[400] r=0 |

#### `endpoint_configuration` [P1]

**Sub-area summary:** 19 endpoints · cadence=daily · pagination=topSkip:1 / none:17 / pageIndex1Based:1 · time-filter coverage=1/19 · top entities=Host.MdatpId, Account.UPN, Host.AadDeviceId, Rule.Id · production scale=10-1K · risk=LOW · delta=low

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAdvancedFeaturesGet | `/mtp/settings/GetAdvancedFeaturesSetting` | GET/POST | read | none | - | - | daily | live[200] r=1 |
| GetAuthenticatedTelemetry | `/mtp/deviceManagement/configuration/AuthenticatedTelemetry` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetCustomCollectionModel | `/mtp/mdeCustomCollection/model` | GET | read | none | - | - | daily | live[200] r=1 |
| GetDiscoveryEnabledTags | `/mtp/mdiotSettingsService/settings/DiscoveryEnabledTags` | GET | read | none | - | - | daily | live[200] r=1 |
| GetIntuneConnection | `/mtp/deviceManagement/configuration/IntuneConnection` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetMagellanFeatures | `/mtp/mdiotSettingsService/settings/v2/MagellanFeatures` | GET | read | none | - | - | daily | live[200] r=1 |
| GetMdeFlavorOverride | `/mtp/settings/overrideMdeFlavor` | GET | read | none | - | - | daily | error[403] r=0 |
| GetPreviewFeatures | `/mtp/settings/GetPreviewExperienceSetting` | GET | read | none | - | - | daily | live[200] r=1 |
| GetPuaConfiguration | `...eManagement/configuration/PotentiallyUnwantedApplications` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetPurviewSharing | `/mtp/deviceManagement/configuration/PurviewSharing` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetSecurityPolicyFilters | `.../mde/configurationManagement/mem/securityPolicies/filters` | GET | read | none | - | - | 6h | error[403] r=0 |
| ListAlertEmailNotifications | `/mtp/alertsEmailNotifications/email_notifications` | GET | read | none | - | - | 1h | live-empty[200] r=0 |
| ListCustomCollectionRules | `/mtp/mdeCustomCollection/rules` | GET/POST | read | none | - | - | daily | live-empty[200] r=1 |
| ListDevicePolicies | `...e/configurationManagement/mem/device/{MachineId}/policies` | GET | read | pageIndex1Based (idx=page,size=pageSize) | - | Host.AadDeviceId, Host.MdatpId | 6h | no-live-pathparam r=0 |
| ListManagedDevices | `...ationManagement/mem/proxy/deviceManagement/managedDevices` | GET | read | none | - | - | 6h | error[403] r=0 |
| ListManagedDeviceUsers | `...y/deviceManagement/managedDevices/{ManagedDeviceId}/users` | GET | read | none | - | Account.UPN | 6h | no-live-pathparam r=0 |
| ListSecurityPolicies | `...perience/mde/configurationManagement/mem/securityPolicies` | POST | read | none | - | - | 6h | error[403] r=0 |
| SetAdvancedFeatures | `/mtp/settings/SaveAdvancedFeaturesSetting` | POST | write | none | - | - | daily | error[403] r=0 |
| UpdateCustomCollectionRule | `/mtp/mdeCustomCollection/rules/{RuleId}` | PUT | write | none | - | Rule.Id | daily | no-live-pathparam r=0 |

#### `endpoint_devices` [P1]

**Sub-area summary:** 48 endpoints · cadence=daily · pagination=pageIndex0Based:4 / fromSize:2 / none:41 / pageIndex1Based:1 · time-filter coverage=0/48 · top entities=Host.MdatpId, Host.FullName, Software.Version, Time.Generated, Host.RiskScore · production scale=10K-1M rows · risk=HIGH on first poll · delta=critical

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ExportNdrMachines | `/mtp/ndr/machines/commandExport` | GET | read | none | - | Host.RiskScore | daily | live[200] r=1 |
| Get | `/mtp/getMachine/machines` | GET | read | none | - | Host.MdatpId | daily | error[400] r=0 |
| GetActionPermissions | `/mtp/responseApiPortal/requests/permissions` | GET | read | none | - | Host.MdatpId | weekly | error[400] r=0 |
| GetActionResult | `/mtp/responseApiPortal/requests/{ActionId}` | GET/DELETE | read | none | - | Action.Id, Host.MdatpId, Time.Generated | weekly | no-live-pathparam r=0 |
| GetActionState | `/mtp/responseApiPortal/requests/machinestate` | GET | read | none | - | Host.MdatpId | daily | error[400] r=0 |
| GetAllFirmwareVersions | `/mtp/ndr/machines/allFirmwareVersions` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetAllMachineTags | `/mtp/ndr/machines/allMachinesTags` | GET | read | none | - | - | daily | live[200] r=1 |
| GetAllModels | `/mtp/ndr/machines/allModels` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetAllOsVersionFriendlyNames | `/mtp/ndr/machines/allOsVersionFriendlyNames` | GET | read | none | - | Software.Version | daily | live[200] r=7 |
| GetAllVendors | `/mtp/ndr/machines/allVendors` | GET | read | none | - | - | daily | live[200] r=1 |
| GetAllWindowsReleaseVersions | `/mtp/ndr/machines/allWindowsReleaseVersions` | GET | read | none | - | - | daily | live[200] r=3 |
| GetDataSensitivity | `/mtp/getDataSensitivity/machines/{MachineId}/dataSensitivity` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetDevicesWithoutSiteTotals | `/mtp/ndr/machines/devicesWithoutSiteTotals` | GET | read | none | - | - | daily | live[200] r=1 |
| GetDeviceTotals | `/mtp/ndr/machines/deviceTotals` | GET | read | none | - | Host.RiskScore | daily | live[200] r=14 |
| GetIpTimelineEvents | `/mtp/mdeTimelineExperience/ips/{IpAddress}/events` | GET | read | none | start=fromDate end=toDate type=iso8601 | IP.Address | daily | no-live-pathparam r=0 |
| GetLatestActionRequest | `/mtp/responseApiPortal/requests/latest` | GET | read | none | - | Host.MdatpId | weekly | error[400] r=0 |
| GetLatestIps | `/mtp/getLatestMachineIpsByIds/LatestMachineIpsByIds` | GET | read | none | - | Host.FullName, Host.MdatpId, Time.Generated | daily | error[400] r=0 |
| GetLicenseReport | `/mtp/deviceManagement/deviceLicenseReport` | GET | read | none | - | - | daily | error[404] r=0 |
| GetMachineGroups | `/mtp/rbacManagementApi/rbac/machine_groups` | GET | read | none | - | - | daily | live[200] r=4 |
| GetMachineMarkedEvents | `/mtp/getMachineMarkedEvents/machines/{MachineId}/eventMarks` | GET | read | none | - | Host.FullName, Host.MdatpId | daily | no-live-pathparam r=0 |
| GetMachinesWdatp | `/mtp/wdatpApi/machines` | GET | read | none | - | Host.AadDeviceId, Host.FullName, Host.HealthStatus | daily | live[200] r=14 |
| GetMachineTimelineEvents | `/mtp/mdeTimelineExperience/machines/{MachineId}/events` | GET | read | none | start=fromDate end=toDate type=iso8601 | Host.FullName, Host.MdatpId, Software.Version | daily | no-live-pathparam r=0 |
| GetNdrDeviceTotalCount | `/mtp/ndr/machines/deviceTotalCount` | GET | read | none | - | - | daily | live[200] r=1 |
| GetNdrDeviceTypeDistribution | `/mtp/ndr/machines/deviceTypeDistribution` | GET | read | none | - | - | daily | live[200] r=3 |
| GetNdrInterceptingMachines | `/mtp/ndr/machines/{MachineId}/InterceptingMachines` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetNdrMachineExclusionDetails | `/mtp/ndr/machines/{MachineId}/exclusionDetails` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetNdrMachineTags | `/mtp/ndr/machines/machineTags` | GET | read | none | - | - | daily | error[400] r=0 |
| GetRbacGroups | `...bacGroupAssignment/machineRbacGroupAssignments/{DeviceId}` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetRbacGroupScopes | `/mtp/rbacGroupAssignment/rbacGroupsScopes/{DeviceId}` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetSensorCompatibleMachines | `...ri/defensor/onboarding/devices/sensor_compatible_machines` | GET | read | none | - | - | daily | error[403] r=0 |
| GetTags | `/mtp/machineTag/machineTags/{DeviceId}` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetTimeline | `/mtp/deviceTimeline/timeline/{DeviceId}` | GET | read | none | - | Host.MdatpId | daily | no-live-pathparam r=0 |
| GetTopUsers | `/mtp/getTopUsersByIds/TopUsersByIds` | GET | read | none | - | Host.FullName, Host.MdatpId | daily | error[400] r=0 |
| GetTotals | `/mtp/deviceManagement/deviceTotals` | GET | read | none | - | - | daily | error[404] r=0 |
| HasAnyActionRequests | `/mtp/responseApiPortal/requests/machine/any` | GET | unknown | none | - | Host.MdatpId | weekly | error[400] r=0 |
| InvokeAction | `/mtp/responseApiPortal/requests/create` | POST | write | none | - | Action.Id, Host.MdatpId | weekly | error[415] r=0 |
| List | `/mtp/ndr/machines` | GET | read | pageIndex1Based (idx=pageIndex,size=pageSize) | - | Host.AadDeviceId, Host.FullName, Host.HealthStatus | daily | live[200] r=9 |
| ListAlertEvidences | `/mtp/alertsApiService/Evidences/device/Alerts` | GET | read | none | lookback=lookBackInDays type=duration-units-from-now | Host.FullName, Host.MdatpId | 1h | error[400] r=0 |
| ListModels | `/mtp/deviceManagement/deviceModels` | GET | read | none | - | - | daily | error[404] r=0 |
| ListOsVersions | `/mtp/deviceManagement/osVersions` | GET | read | none | - | Software.Version | daily | error[404] r=0 |
| ListVendors | `/mtp/deviceManagement/deviceVendors` | GET | read | none | - | - | daily | error[404] r=0 |
| ListWindowsReleaseVersions | `/mtp/deviceManagement/windowsReleaseVersions` | GET | read | none | - | - | daily | error[404] r=0 |
| PrefetchMachineTimeline | `/mtp/mdeTimelineExperience/machines/{MachineId}/prefetch` | POST | unknown | none | start=fromDate end=toDate type=iso8601 | Host.FullName, Host.MdatpId | daily | no-live-pathparam r=0 |
| SetAssetValue | `/mtp/assetvalue/machineAssetValue` | POST | write | none | - | Host.MdatpId | daily | error[404] r=0 |
| SetCriticalityLevel | `/mtp/assetvalue/setCriticalityLevel` | POST | write | none | - | Host.MdatpId | daily | error[404] r=0 |
| SetExclusionState | `/mtp/machineExclusionState/updateMachineExclusionState` | POST | write | none | - | Host.MdatpId | daily | error[404] r=0 |
| SetRbacGroup | `/mtp/rbacGroupAssignment/updateMachineRbacGroupAssignments` | POST | write | none | - | Host.MdatpId | daily | error[404] r=0 |
| SetTag | `/mtp/machineTag/machineTag` | PATCH | write | none | - | Host.MdatpId | daily | no-live-method-PATCH r=0 |

#### `entity_pivots` [P1]

**Sub-area summary:** 19 endpoints · cadence=weekly · pagination=none:19 · time-filter coverage=0/19 · top entities=Url.Domain, Url.Path · production scale=per-entity · risk=depends · delta=depends

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetDomainClickPrevalence | `...vot/cloud/pivot/portal/domainClick/email/click/prevalence` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetDomainClickTrend | `...oudPivot/cloud/pivot/portal/domainClick/email/click/trend` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetDomainDevicePrevalence | `/mtp/cloudPivot/cloud/pivot/portal/domain/device/prevalence` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetDomainDeviceTrend | `/mtp/cloudPivot/cloud/pivot/portal/domain/device/trend` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetDomainEmailPrevalence | `/mtp/cloudPivot/cloud/pivot/portal/domain/email/prevalence` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetDomainEmailTrend | `/mtp/cloudPivot/cloud/pivot/portal/domain/email/trend` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| GetUrlClickPrevalence | `...dPivot/cloud/pivot/portal/urlClick/email/click/prevalence` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlClickTrend | `.../cloudPivot/cloud/pivot/portal/urlClick/email/click/trend` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlDevicePrevalence | `/mtp/cloudPivot/cloud/pivot/portal/url/device/prevalence` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlDeviceTrend | `/mtp/cloudPivot/cloud/pivot/portal/url/device/trend` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlEmailPrevalence | `/mtp/cloudPivot/cloud/pivot/portal/url/email/prevalence` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlEmailTrend | `/mtp/cloudPivot/cloud/pivot/portal/url/email/trend` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| GetUrlOverview | `/mtp/useServiceBaseUrl/ine/entitypagesservice/urls/overview` | GET | read | none | - | Url.Domain, Url.Path | daily | error[400] r=0 |
| ListDomainClicks | `...dPivot/cloud/pivot/portal/domainClick/email/click/details` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| ListDomainDevices | `/mtp/cloudPivot/cloud/pivot/portal/domain/device/details` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| ListDomainEmails | `/mtp/cloudPivot/cloud/pivot/portal/domain/email/details` | GET | read | none | - | Url.Domain | weekly | error[400] r=0 |
| ListUrlClicks | `...loudPivot/cloud/pivot/portal/urlClick/email/click/details` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| ListUrlDevices | `/mtp/cloudPivot/cloud/pivot/portal/url/device/details` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |
| ListUrlEmails | `/mtp/cloudPivot/cloud/pivot/portal/url/email/details` | GET | read | none | - | Url.Path | weekly | error[400] r=0 |

#### `exposure_management` [P1]

**Sub-area summary:** 42 endpoints · cadence=1h · pagination=pageIndex0Based:3 / none:39 · time-filter coverage=0/42 · top entities=Software.Version, Tenant.Id, Vuln.CveId, Host.RiskScore, Time.Generated · production scale=1K-100K rows · risk=MEDIUM · delta=high

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAppsSecureScoreMetric | `/mtp/posture/oversight/metrics/category_apps_secure_score` | GET | read | none | - | Software.Version | daily | live[200] r=93 |
| GetAttackPaths | `/mtp/xspm/attackpaths` | POST | read | none | - | - | 1h | error[500] r=0 |
| GetAttackSurfaceAttackPathFilters | `/mtp/xspmatlas/attacksurface/attackpaths/filters` | GET | read | none | - | - | 1h | live[200] r=1 |
| GetAttackSurfaceChokepointFilters | `/mtp/xspmatlas/attacksurface/chokepoints/filters` | GET | read | none | - | - | 1h | live[200] r=1 |
| GetChokePoints | `/mtp/xspm/chokepoints` | POST | read | none | - | - | 1h | error[500] r=0 |
| GetDataSecureScoreMetric | `/mtp/posture/oversight/metrics/category_data_secure_score` | GET | read | none | - | Software.Version | daily | live[200] r=4 |
| GetEasmVendors | `/mtp/posture/oversight/easm/vendors` | GET | read | none | - | Software.Vendor | 1h | live[200] r=20 |
| GetIdentitySecureScoreMetric | `.../posture/oversight/metrics/category_identity_secure_score` | GET | read | none | - | Software.Version | daily | live[200] r=175 |
| GetK8sDeviceTotals | `/mtp/k8s/machines/deviceTotals` | GET | read | none | - | Host.RiskScore | daily | live[200] r=14 |
| GetMdcRecommendationMetrics | `/mdc/views/recommendations/recommendationsMetrics` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcRecommendationsByResourceType | `/mdc/views/vulnerabilities/recommendationsByResourceType` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcRecommendationSchema | `/mdc/views/recommendations/schema` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcTopCloudCvesSchema | `/mdc/views/vulnerabilities/topCloudCVEsSchema` | POST | read | none | - | Vuln.CveId | daily | live[200] r=1 |
| GetMdcVulnerabilitiesOverTime | `/mdc/views/vulnerabilities/getVulnerabilitiesOvertime` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcVulnerabilityInsights | `/mdc/views/vulnerabilities/vulnerabilitiesInsights` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcVulnerabilitySchema | `/mdc/views/vulnerabilities/schema` | POST | read | none | - | - | daily | error[400] r=0 |
| GetMdcVulnerabilityStatisticsHeader | `/mdc/views/vulnerabilities/statisticsHeader` | POST | read | none | - | - | daily | error[400] r=0 |
| GetPostureOversightInitiative | `/mtp/posture/oversight/initiatives/{InitiativeId}` | GET | read | none | - | - | 1h | no-live-pathparam r=0 |
| GetPostureOversightInitiativesSummarized | `/mtp/posture/oversight/initiatives/summarized` | GET | read | none | - | - | 1h | live-empty[200] r=0 |
| GetPostureOversightMetricIds | `/mtp/posture/oversight/metrics/ids` | GET | read | none | - | - | 1h | live[200] r=142 |
| GetPostureOversightRecommendationsAggregated | `/mtp/posture/oversight/recommendations/aggregated` | GET | read | none | - | - | 1h | error[400] r=0 |
| GetPostureOversightTenants | `/mtp/posture/oversight/tenants` | GET | read | none | - | Tenant.Id | daily | live[200] r=1 |
| GetRecommendations | `/mtp/exposureManagement/recommendations` | GET | read | pageIndex0Based (idx=pageIndex) | - | - | 1h | error[404] r=0 |
| GetScaRecommendationFilters | `/mtp/posture/oversight/scaRecommendations/filters` | GET | read | none | - | - | 1h | live[200] r=3 |
| GetScaRecommendationTags | `/mtp/posture/oversight/scaRecommendations/tags` | GET | read | none | - | - | 1h | live[200] r=3 |
| GetTopEntryPoints | `/mtp/xspm/topentrypoints` | POST | read | none | - | - | 1h | error[500] r=0 |
| GetTopTargets | `/mtp/xspm/toptargets` | POST | read | none | - | - | 1h | error[500] r=0 |
| GetTvmRiskScore | `/mtp/tvm/analytics/riskscore` | GET | read | none | - | Host.RiskScore | daily | live[200] r=1 |
| ListAttackSurfaceAttackPaths | `/mtp/xspmatlas/attacksurface/attackpaths` | GET | read | none | - | - | 1h | live[200] r=1 |
| ListAttackSurfaceChokepoints | `/mtp/xspmatlas/attacksurface/chokepoints/list` | GET | read | none | - | - | 1h | live-empty[200] r=0 |
| ListMdcAllVulnerabilitiesPageItems | `/mdc/views/vulnerabilities/allVulnerabilitiesPageItems` | POST | read | none | - | - | daily | error[400] r=0 |
| ListMdcRecommendationItems | `/mdc/views/recommendations/items` | POST | read | none | - | - | daily | error[400] r=0 |
| ListMdcTopCloudCvesItems | `/mdc/views/vulnerabilities/topCloudCVEsItems` | POST | read | none | - | Vuln.CveId | daily | error[400] r=0 |
| ListMdcVulnerabilityItems | `/mdc/views/vulnerabilities/items` | POST | read | none | - | - | daily | error[400] r=0 |
| ListPostureOversightInitiatives | `/mtp/posture/oversight/initiatives` | GET | read | none | - | Tenant.Id | 1h | live[200] r=10 |
| ListPostureOversightMetrics | `/mtp/posture/oversight/metrics` | GET | read | none | - | Software.Version, Tenant.Id | 1h | live[200] r=10 |
| ListPostureOversightRecommendations | `/mtp/posture/oversight/recommendations` | GET | read | none | - | Software.Name, Url.Path | 1h | live[200] r=10 |
| ListPostureOversightUpdates | `/mtp/posture/oversight/updates` | GET | read | none | - | - | 1h | live-empty[200] r=0 |
| ListPostureSecurityEvents | `/mtp/posture/oversight/securityEvents` | GET | read | none | - | Tenant.Id, Time.Generated | 1h | live[200] r=137 |
| ListXspmConnectors | `/mtp/XspmConnectors/connectors/getAllConnectors` | GET | read | none | - | - | 1h | live-empty[200] r=0 |
| QueryAttackSurface | `/mtp/xspmatlas/attacksurface/query` | POST | read | none | - | Software.Version | 1h | error[415] r=0 |
| RunHuntingQuery | `/mtp/xspm/hunting` | POST | write | none | - | - | 1h | error[500] r=0 |

#### `files` [P1]

**Sub-area summary:** 19 endpoints · cadence=6h · pagination=pageIndex0Based:2 / none:17 · time-filter coverage=0/19 · top entities=File.Sha256, File.Sha1, Url.Path, File.Name · production scale=varies · risk=MEDIUM · delta=medium

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CreateSampleCollectionRequest | `...seApiPortal/sampledownloadrequest/createcollectionrequest` | POST | write | none | - | - | weekly | error[403] r=0 |
| GenerateSampleDownloadUri | `...nseApiPortal/sampledownloadrequest/generatedownloaduri/V2` | GET | unknown | none | - | File.Name, Url.Path | weekly | error[403] r=0 |
| GetActiveAlertsSummary | `/mtp/activeAlertsSummary/activeAlertsSummary` | GET | read | none | - | File.Sha1, File.Sha256 | 1h | live[200] r=1 |
| GetCapabilities | `/mtp/mdeEntitiesExperience/files/{Sha256}/capabilities` | GET | read | none | - | File.Sha256 | daily | no-live-pathparam r=0 |
| GetContentAnalysis | `/mtp/mdeEntitiesExperience/files/{Sha256}/content` | GET | read | none | - | File.Sha256, Url.Path | daily | no-live-pathparam r=0 |
| GetDeepAnalysisStatus | `/mtp/mdeDeepAnalysis/api/DeepAnalysisRequest` | GET | read | none | - | File.Sha1 | daily | error[400] r=0 |
| GetDevicePrevalence | `/mtp/cloudPivot/cloud/pivot/portal/file/device/prevalence` | GET | read | none | - | - | weekly | error[400] r=0 |
| GetDeviceTrend | `/mtp/cloudPivot/cloud/pivot/portal/file/device/trend` | GET | read | none | - | - | weekly | error[400] r=0 |
| GetProfile | `...ile/api/detection/cyberprofileprovider/user/profiles/file` | GET | read | none | - | File.Sha1, File.Sha256 | daily | live-empty[200] r=0 |
| GetRemediationPermission | `/mtp/responseApiPortal/remediation/permission` | GET | read | none | - | File.Sha1 | weekly | error[500] r=0 |
| GetSampleDownloadState | `/mtp/responseApiPortal/sampledownloadrequest/state` | GET | read | none | - | - | weekly | error[400] r=0 |
| GetThreatReputation | `.../threatAnalyticsIndicators/stix/oneti/reputation/fileHash` | GET | read | none | - | - | 6h | error[400] r=0 |
| GetVirusTotalReport | `/mtp/files/files/{Sha256}/virustotal` | GET | read | none | - | File.Sha256 | daily | no-live-pathparam r=0 |
| GoHunt | `/mtp/huntingService/goHunt/File` | POST | unknown | none | - | - | daily | error[415] r=0 |
| ListDeviceDetails | `/mtp/cloudPivot/cloud/pivot/portal/file/device/details` | GET | read | none | - | - | weekly | error[400] r=0 |
| ListIndicators | `/mtp/papin/api/cloud/public/internal/indicators/getQuery` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| ListObservedNames | `...cloudPivot/cloud/pivot/portal/file/device/fileNamesBySha2` | GET | read | none | - | - | weekly | error[400] r=0 |
| ListVerdicts | `/mtp/files/files/{Sha256}/FileVerdict` | GET | read | none | - | File.Sha256 | daily | no-live-pathparam r=0 |
| QueryThreatAnalyticsOutbreaks | `...yticsIndicators/stix/outbreaks/indicators/outbreaks/query` | POST | read | none | - | - | 6h | error[415] r=0 |

#### `identity` [P1]

**Sub-area summary:** 74 endpoints · cadence=daily · pagination=none:74 · time-filter coverage=1/74 · top entities=Url.Domain, File.Path, Account.AadId, Account.SamName, Host.AadDeviceId · production scale=1K-100K rows · risk=MEDIUM · delta=high

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CheckWorkspaceActive | `/aatp/api/workspace/isActive` | GET | read | none | - | - | daily | error[404] r=0 |
| CheckWorkspaceExists | `/aatp/api/workspaces/isWorkspaceExists` | GET | read | none | - | - | daily | live[200] r=1 |
| GetAatpApplicationData | `/aatp/api/mtp/applicationData` | GET | read | none | - | - | daily | error[404] r=0 |
| GetActionsByAccounts | `/mdi/identity/userapiservice/actions/byAccounts` | POST | read | none | - | - | daily | error[405] r=0 |
| GetAlertThreshold | `/mdi/identity/userapiservice/alertThreshold` | GET | read | none | - | - | daily | error[404] r=0 |
| GetAlertThresholdsRecommendedTestMode | `/aatp/api/alertthresholds/withExpiry/recommendedTestMode` | GET | read | none | - | - | daily | error[404] r=0 |
| GetAlertThresholdsWithExpiry | `/aatp/api/alertthresholds/withExpiry` | GET | read | none | - | - | daily | error[404] r=0 |
| GetDefensorConfiguration | `/aatp/api/defensor/defensorConfiguration` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetDirectoryServiceAccount | `/mdi/identity/userapiservice/directoryServiceAccount` | GET | read | none | - | File.Path | daily | error[404] r=0 |
| GetDirectoryServicesOdata | `/aatp/odata/directoryServices` | GET | read | none | - | File.Path | daily | error[404] r=0 |
| GetDomainControllerCoverage | `/mdi/identity/identitiesapiservice/domainController/coverage` | GET | read | none | - | Url.Domain | daily | error[404] r=0 |
| GetDomainControllerCoverageAatp | `/aatp/api/sensors/domainControllerCoverage` | GET | read | none | - | Url.Domain | daily | error[404] r=0 |
| GetDomainControllerTotals | `/mtp/siamApi/domaincontrollers/totals` | GET | read | none | - | Url.Domain | daily | live[200] r=1 |
| GetDormantEntitiesNewEntryCount | `/aatp/api/ispmReports/DormantEntities/newEntryCount` | GET | read | none | - | - | daily | error[404] r=0 |
| GetEntityRemediatorCredentials | `/aatp/odata/EntityRemediatorCredentials` | GET | read | none | - | - | daily | error[404] r=0 |
| GetExposedPasswordReportDefinitions | `...piservice/pdProtection/reportDefinitions/ExposedPasswords` | GET | read | none | - | - | daily | live[200] r=1 |
| GetGlobalExclusionEntities | `/aatp/odata/ExclusionEntityDatas/Global` | GET | read | none | - | - | daily | error[404] r=0 |
| GetIdentitiesAggregatedData | `/mdi/identity/userapiservice/identities/aggregatedData` | POST | read | none | - | - | daily | error[403] r=0 |
| GetIdentitiesCount | `/mdi/identity/userapiservice/identities/count` | POST | read | none | - | - | daily | error[415] r=0 |
| GetIdentitiesStats | `/mdi/identity/userapiservice/users/IdentitiesStats` | POST | read | none | - | - | daily | error[415] r=0 |
| GetInfrastructureInfo | `/aatp/api/sensors/identityInfrastructuresInfo` | GET | read | none | - | - | daily | error[404] r=0 |
| GetIspmData | `/mdi/identity/userapiservice/ispms` | POST | read | none | - | - | daily | error[415] r=0 |
| GetLeakedCredentialReportDefinitions | `...iservice/pdProtection/reportDefinitions/LeakedCredentials` | GET | read | none | - | - | daily | live[200] r=1 |
| GetMachinesManagedByStatus | `/mtp/siamApi/MachinesManagedByStatus` | GET | read | none | - | Host.OsPlatform | daily | live[200] r=6 |
| GetManager | `/mdi/identity/userapiservice/manager` | GET | read | none | - | File.Path | daily | error[405] r=0 |
| GetMdeAttachEnabled | `/mtp/siamApi/MdeAttachEnabled` | GET | read | none | - | - | daily | live[200] r=1 |
| GetMemOnboardStatus | `/mtp/siamApi/memonboardstatus` | GET | read | none | - | - | daily | live[200] r=1 |
| GetOnboardedMachinesStatus | `/mtp/siamApi/OnboardedMachinesStatus` | GET | read | none | - | - | daily | live[200] r=1 |
| GetOnboardingStatus | `/mdi/identity/userapiservice/status` | GET | read | none | - | - | daily | error[404] r=0 |
| GetOnboardingSummary | `/mtp/siamApi/Onboarding` | GET | read | none | - | - | daily | live[200] r=1 |
| GetPasswordDomainsPolicies | `/mdi/identity/userapiservice/pdProtection/domainsPolicies` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetPasswordHygieneReportDefinitions | `...apiservice/pdProtection/reportDefinitions/PasswordHygiene` | GET | read | none | - | - | daily | live[200] r=1 |
| GetPasswordHygieneReports | `...ty/userapiservice/pdProtection/mdaReports/PasswordHygiene` | GET | read | none | - | - | daily | live[200] r=1 |
| GetPasswordPolicyReportDefinitions | `...piservice/pdProtection/reportDefinitions/PasswordPolicies` | GET | read | none | - | - | daily | live[200] r=1 |
| GetPasswordPolicyReports | `...y/userapiservice/pdProtection/mdaReports/PasswordPolicies` | GET | read | none | - | - | daily | live[200] r=1 |
| GetRadiusAccountsByUserIdCount | `/radius/api/radius/identities/accountsByUserIdCount` | POST | read | none | - | Account.AadId | daily | error[415] r=0 |
| GetRadiusCriticalityScore | `/radius/api/radius/identities/getCriticalityScore` | GET | read | none | - | Account.Sid, Host.AadDeviceId | daily | error[400] r=0 |
| GetRadiusDefenderRiskKillChain | `/radius/api/radius/identities/getDefenderRiskKillChain` | GET | read | none | - | - | daily | error[400] r=0 |
| GetRadiusDefenderRiskScoresOverTime | `/radius/api/radius/identities/getDefenderRiskScoresOverTime` | GET | read | none | start=startTime end=endTime type=iso8601 | Time.Generated | daily | error[400] r=0 |
| GetRadiusDefenderRiskSummary | `/radius/api/radius/identities/getDefenderRiskSummary` | GET | read | none | - | - | daily | error[400] r=0 |
| GetRadiusIdentityType | `/radius/api/radius/identities/getIdentityType` | GET | read | none | - | Host.AadDeviceId | daily | error[400] r=0 |
| GetRadiusRemediationState | `/radius/api/radius/remediation/lmf/{Sid}` | GET | read | none | - | Account.Sid | daily | no-live-pathparam r=0 |
| GetRadiusTenantPartners | `/radius/api/radius/identities/getTenantPartners` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetRemediationAccount | `/mdi/identity/identitiesapiservice/remediationAccount` | GET/POST/PUT/DELETE | read | none | - | - | daily | error[404] r=0 |
| GetRemediationActionsConfig | `/aatp/api/remediationActions/configuration` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetRiskyLateralMovementPathNewEntryCount | `/aatp/api/ispmReports/RiskyLateralMovementPath/newEntryCount` | GET | read | none | - | - | daily | error[404] r=0 |
| GetScopedHealthNotifications | `/aatp/api/workspace/configuration/scopedHealthNotifications` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetSecurityAlertExclusions | `/aatp/odata/SecurityAlertExclusionDatas` | GET | read | none | - | - | daily | error[404] r=0 |
| GetSensorsCoverage | `/aatp/api/sensors/sensorsCoverage` | GET | read | none | - | - | daily | error[404] r=0 |
| GetServiceAccountFilterOptions | `/mdi/identity/userapiservice/serviceAccounts/filterOptions` | POST | read | none | - | - | daily | error[415] r=0 |
| GetServiceAccountsCount | `/mdi/identity/userapiservice/serviceAccounts/count` | GET | read | none | - | - | daily | live[200] r=1 |
| GetStatistics | `/mdi/identity/userapiservice/statistics` | GET | read | none | - | - | daily | error[404] r=0 |
| GetSyslogConfiguration | `/aatp/api/workspace/configuration/syslog` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetTaggedSecurityPrincipals | `/aatp/odata/TaggedSecurityPrincipals` | GET | read | none | - | - | daily | error[404] r=0 |
| GetUnifiedRbacScopes | `/aatp/api/unifiedrbac/scopes` | GET | read | none | - | - | daily | error[404] r=0 |
| GetUnsecureDomainConfigurationsNewEntryCount | `...pi/ispmReports/UnsecureDomainConfigurations/newEntryCount` | GET | read | none | - | Url.Domain | 6h | error[404] r=0 |
| GetUsedUnifiedRbacScopes | `/aatp/api/unifiedrbac/usedScopes` | GET | read | none | - | - | daily | error[404] r=0 |
| GetUserActivityPeriod | `/mdi/identity/userapiservice/user/activityPeriod` | POST | read | none | - | - | daily | error[405] r=0 |
| GetUserDevicesCount | `/mdi/identity/userapiservice/devices/count` | POST | read | none | - | - | daily | error[405] r=0 |
| GetUserMtpTimeline | `/mdi/identity/userapiservice/timeline/mtp` | POST | read | none | - | - | daily | error[405] r=0 |
| GetUserTimeline | `/mdi/identity/userapiservice/user/timeline` | GET | read | none | - | Account.SamName, Url.Domain | daily | error[404] r=0 |
| GetVpnConfiguration | `/aatp/api/mtp/vpnConfiguration` | GET | read | none | - | - | 6h | error[404] r=0 |
| GetWorkspaceMonitoringAlerts | `/aatp/odata/workspaceMonitoringAlerts` | GET | read | none | - | - | 1h | error[404] r=0 |
| ListDomainControllers | `/mtp/siamApi/domaincontrollers/list` | GET | read | none | - | Host.FullName, Host.MdatpId, Url.Domain | daily | live-empty[200] r=0 |
| ListEntities | `/mdi/identity/identitiesapiservice/identity/entities` | POST | read | none | - | - | daily | error[404] r=0 |
| ListIdentities | `/mdi/identity/userapiservice/identities` | POST | read | none | - | - | daily | error[415] r=0 |
| ListPasswordProtectionEntities | `/mdi/identity/userapiservice/pdProtection/entities` | POST | read | none | - | - | daily | error[415] r=0 |
| ListRadiusAccountsByUserId | `/radius/api/radius/identities/accountsByUserId` | POST | read | none | - | Account.AadId | daily | error[415] r=0 |
| ListSensorsOdata | `/aatp/odata/sensors` | GET | read | none | - | - | daily | error[404] r=0 |
| ListServiceAccounts | `/mdi/identity/userapiservice/serviceaccount/entities` | POST | read | none | - | - | daily | error[404] r=0 |
| ListServiceAccountsV2 | `/mdi/identity/userapiservice/serviceAccounts` | POST | read | none | - | - | daily | error[415] r=0 |
| ListUnsecureDomainConfigurations | `/aatp/api/ispmReports/UnsecureDomainConfigurations` | GET | read | none | - | File.Path, Url.Domain | 6h | error[404] r=0 |
| ListUserDevices | `/mdi/identity/userapiservice/devices` | POST | read | none | - | - | daily | error[405] r=0 |
| ResolveUser | `/mdi/identity/userapiservice/user/resolve` | POST | read | none | - | Account.SamName, Url.Domain | daily | error[405] r=0 |

#### `multi_tenant` [P1]

**Sub-area summary:** 17 endpoints · cadence=daily · pagination=none:17 · time-filter coverage=0/17 · top entities=Tenant.Id, File.Path · production scale=10-1K tenants · risk=LOW · delta=low

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAdvancedHuntingPreferences | `...serpreferencesservice/userPreference/advanced_hunting_mto` | GET | read | none | - | - | daily | error[404] r=0 |
| GetCaseTemplate | `/mtoapi/mtp/CaseManagement/be/templates/{TemplateId}` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetEffectiveTenantGroup | `/mtoapi/tenantGroups/effective/` | GET | read | none | - | - | daily | error[400] r=0 |
| GetHuntingRbacGroups | `/mtoapi/mtp/userExposedRbacGroups/UserExposedRbacGroups` | GET | read | none | - | - | daily | live[200] r=1 |
| GetIdentitiesAggregatedData | `...api/mdi/identity/userapiservice/identities/aggregatedData` | POST | read | none | - | - | daily | live[200] r=1 |
| GetIdentitiesCount | `/mtoapi/mdi/identity/userapiservice/identities/count` | POST | read | none | - | - | daily | live[200] r=1 |
| GetRecentItems | `/mtoapi/recentItems` | GET | read | none | - | - | daily | error[400] r=0 |
| GetSecurityCopilotTrial | `/mtoapi/cdssecuritycopilot/trial` | GET | read | none | - | - | daily | error[400] r=0 |
| GetTenantContext | `/mtoapi/mtp/sccManagement/mgmt/TenantContext` | GET | read | none | - | File.Path | daily | live[200] r=1 |
| GetWorkloadStatus | `/mtoapi/tenants/{TenantId}/workloadStatus` | GET | read | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| ListAssignments | `/mtoapi/assignments` | GET | read | none | - | - | daily | error[400] r=0 |
| ListCases | `/mtoapi/mtp/CaseManagement/be/cases` | GET | read | none | - | - | daily | live[200] r=1 |
| ListHuntingQueries | `/mtoapi/mtp/huntingService/queries/` | GET | read | none | - | - | daily | live[200] r=1 |
| ListIdentities | `/mtoapi/mdi/identity/userapiservice/identities` | POST | read | none | - | - | daily | error[500] r=0 |
| ListTenantGroups | `/mtoapi/tenantGroups` | GET | read | none | - | - | daily | error[400] r=0 |
| ListTenants | `/mtoapi/tenants/TenantPicker` | GET | read | none | - | - | daily | error[400] r=0 |
| RunHuntingQuery | `/mtoapi/tenants/{TenantId}/huntingQueries/run` | POST | write | none | - | Tenant.Id | daily | no-live-pathparam r=0 |

#### `portal_services` [P1]

**Sub-area summary:** 21 endpoints · cadence=daily · pagination=none:21 · time-filter coverage=2/21 · top entities=Tenant.Id, Time.Generated, Account.UPN, Software.Version, Account.SamName · production scale=1-100 · risk=LOW · delta=none

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AggregateSubmissionDiesData | `/di/Search/SubmissionDIESDataAggregation` | POST | unknown | none | start=StartTime end=EndTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |
| AggregateThreatInstances | `/di/Aggregate/ThreatInstanceList` | POST | unknown | none | - | - | daily | error[403] r=0 |
| AggregateThreatProfileDetails | `/di/Aggregate/ThreatProfileDetails` | POST | unknown | none | - | - | daily | error[403] r=0 |
| CheckAppGovernanceInsightsReady | `...otection/mapg-glsservice/compliance/istenantinsightsready` | GET | read | none | - | - | daily | error[400] r=0 |
| CheckAppGovernanceOnboarding | `...ppprotection/mapg-glsservice/compliance/istenantonboarded` | GET | read | none | - | Tenant.Id | daily | live[200] r=1 |
| CheckCompliancePermissions | `/gws/ComplianceAuthServer/v1.0/IsAllowedPermissionWithScopes` | POST | read | none | - | - | daily | error[400] r=0 |
| FindCustomTag | `/di/Find/CustomTag` | GET | read | none | - | - | daily | error[403] r=0 |
| FindTrialOffer | `/di/Find/TrialOffer` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAttackSimUserCoverage | `...ttackSimulator/api/v1/AdvanceReporting/chart/UserCoverage` | GET | read | none | - | - | daily | live[200] r=1 |
| GetMachineHealthStatus | `/mtp/mdepDnH/reports/machineHealth/healthStatus` | GET | read | none | - | Host.HealthStatus | daily | live[200] r=1 |
| GetMedeinaAuth | `/medeina/auth` | GET | read | none | - | - | daily | error[400] r=0 |
| GetOptimizeRecommendations | `/mtp/optimize/OptimizeRecommendation` | GET | read | none | - | - | daily | error[403] r=0 |
| GetSecurityCopilotTrial | `/cdssecuritycopilot/trial` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetShellInfo | `/shell/api/shell/shellinfo` | GET | read | none | - | Software.Version | daily | live[200] r=1 |
| GetSubscribedSkusGraph | `/msgraph/v1.0/subscribedSkus` | GET | read | none | - | Account.SamName | daily | live[200] r=5 |
| GetUserGraph | `/msgraph/v1.0/users/{UserId}` | GET | read | none | - | Account.AadId, Account.UPN | daily | no-live-pathparam r=0 |
| GetUserPreferences | `...references/api/mgmt/userpreferencesservice/userPreference` | GET/PATCH | read | none | - | - | daily | live[200] r=1 |
| GetUtcPreference | `...i/mgmt/userpreferencesservice/userPreference/alwaysUseUtc` | GET | read | none | - | - | daily | error[404] r=0 |
| InvokeAdminCommand | `/admin/Beta/{tenantId}/InvokeCommand` | POST | write | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| ListUsersGraph | `/msgraph/v1.0/users` | GET | read | none | - | Account.UPN | daily | live[200] r=7 |
| SearchSubmissionDiesData | `/di/Search/SubmissionDIESData` | POST | read | none | start=StartTime end=EndTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |

#### `secure_score` [P1]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=Software.Vendor, Url.Path, Software.Version · production scale=1-100 · risk=LOW · delta=none

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetCloudInitiativeMetrics | `/mdc/views/secureScore/cloudInitiativeMetrics` | POST | read | none | - | Software.Version | daily | error[400] r=0 |
| GetConfigurationsSecureScoreCategories | `/mtp/tvm/analytics/configurations/securescore/categories` | GET | read | none | - | - | daily | live[200] r=5 |
| GetConfigurationsSecureScoreTotal | `/mtp/tvm/analytics/configurations/securescore/total` | GET | read | none | - | - | daily | live[200] r=1 |
| GetControlProfilesV2 | `/mtp/secureScore/security/secureScoreControlProfilesV2` | GET | read | none | - | Software.Vendor, Url.Path | daily | live[200] r=445 |
| GetInsights | `/mtp/secureScore/security/secureScoreInsights` | GET | read | none | - | - | daily | live[200] r=2700 |
| GetSecureScoresV2 | `/mtp/secureScore/security/secureScoresV2` | GET | read | none | - | Software.Vendor | daily | live[200] r=90 |
| GetSecurityInitiativesV2 | `/mtp/secureScore/security/secureScoreSecurityInitiativesV2` | GET | read | none | - | Software.Vendor | daily | live[200] r=1 |
| GetTenantProfile | `/mtp/secureScore/security/secureScoreTenantProfile` | GET | read | none | - | - | daily | live[200] r=1 |

#### `sentinel_precision` [P1]

**Sub-area summary:** 16 endpoints · cadence=daily · pagination=none:16 · time-filter coverage=2/16 · top entities=Software.Version · production scale=varies · risk=MEDIUM · delta=medium

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CountThreatIntelligence | `.../Microsoft.SecurityInsights/threatintelligence/main/count` | POST | unknown | none | - | Software.Version | daily | no-live-pathparam r=0 |
| GetAnomaliesSummary | `...s/Microsoft.SecurityInsights/entities/GetAnomaliesSummary` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| GetOverview | `...kspaceName}/providers/Microsoft.SecurityInsights/overview` | POST | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| GetSetting | `...oviders/Microsoft.SecurityInsights/settings/{settingName}` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| GetWorkspace | `.../Microsoft.OperationalInsights/workspaces/{workspaceName}` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListContentTemplates | `...me}/providers/Microsoft.SecurityInsights/contenttemplates` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListDataConnectorDefinitions | `...iders/Microsoft.SecurityInsights/dataConnectorDefinitions` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListDataConnectors | `...Name}/providers/Microsoft.SecurityInsights/dataConnectors` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListMetadata | `...kspaceName}/providers/Microsoft.SecurityInsights/metadata` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListRecommendations | `...ame}/providers/Microsoft.SecurityInsights/recommendations` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListSubscriptions | `/apiproxy/arm/subscriptions` | GET | read | none | - | Software.Version | daily | error[404] r=0 |
| ListWorkbooks | `...resourceGroupName}/providers/Microsoft.Insights/workbooks` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListWorkspacePermissions | `...kspaceName}/providers/microsoft.authorization/permissions` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| ListWorkspaceTables | `...oft.OperationalInsights/workspaces/{workspaceName}/tables` | GET | read | none | - | Software.Version | daily | no-live-pathparam r=0 |
| QueryResourceGraph | `/apiproxy/arm/providers/Microsoft.ResourceGraph/resources` | POST | read | none | - | Software.Version | daily | error[404] r=0 |
| QueryThreatIntelligence | `.../Microsoft.SecurityInsights/threatintelligence/main/query` | POST | read | none | - | Software.Version | daily | no-live-pathparam r=0 |

#### `streaming` [P1]

**Sub-area summary:** 1 endpoints · cadence=6h · pagination=none:1 · time-filter coverage=0/1 · top entities=- · production scale=1-10 · risk=LOW · delta=none

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetConfiguration | `/mtp/streamingapi/streamingApiConfiguration` | GET | read | none | - | - | 6h | error[404] r=0 |

#### `threat_analytics` [P1]

**Sub-area summary:** 20 endpoints · cadence=6h · pagination=pageIndex0Based:1 / none:19 · time-filter coverage=0/20 · top entities=Host.RiskScore, Url.Path, Url.Domain · production scale=100-1K · risk=LOW · delta=low

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CountOutbreakIndicators | `...csIndicators/stix/outbreaks/{OutbreakId}/indicators/count` | POST | unknown | none | - | - | 6h | no-live-pathparam r=0 |
| GetEnrichedOutbreakData | `/mtp/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp` | GET | read | none | - | Host.RiskScore | 6h | live[200] r=1000 |
| GetIndicatorReputation | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation` | GET | read | none | - | Url.Domain | 6h | error[400] r=0 |
| GetOutbreakAlertsOverTimeSummary | `...eatAnalytics/outbreaks/{OutbreakId}/alertsOvertimeSummary` | GET | read | none | - | - | 1h | no-live-pathparam r=0 |
| GetOutbreakChangeCount | `/mtp/threatAnalytics/outbreaks/changeCount` | GET | read | none | - | - | 6h | live[200] r=1 |
| GetOutbreakDevices | `/mtp/outbreaks/outbreaks/v2/{OutbreakId}/devices` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetOutbreakImpactedAssetsOverTime | `...nalytics/outbreaks/v2/{OutbreakId}/impactedAssetsOvertime` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakImpactedAssetsSummary | `...Analytics/outbreaks/v2/{OutbreakId}/impactedAssetsSummary` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakIncidentsAlertsSummary | `...nalytics/outbreaks/v2/{OutbreakId}/incidentsAlertsSummary` | GET | read | none | - | - | 1h | no-live-pathparam r=0 |
| GetOutbreakOverview | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/overview` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakPatchData | `/mtp/threatAnalytics/outbreaks/{OutbreakId}/patchdata` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakRelatedIntelligence | `...hreatAnalytics/outbreaks/{OutbreakId}/relatedIntelligence` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakTvmDetails | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/tvmDetails` | GET | read | none | - | - | 6h | no-live-pathparam r=0 |
| GetOutbreakUserExposure | `/mtp/threatAnalytics/outbreaks/v2/{OutbreakId}/userExposure` | GET | read | none | - | - | 1h | no-live-pathparam r=0 |
| GetTopThreats | `/mtp/threatAnalytics/outbreaks/topthreats` | GET | read | none | - | Host.RiskScore | 6h | live[200] r=1 |
| GetUrlReputation | `/mtp/threatAnalyticsIndicators/stix/oneti/reputation/URL` | GET | read | none | - | Url.Path | 6h | error[400] r=0 |
| ListOutbreaks | `/mtp/threatAnalyticsAPI/outbreaks` | GET | read | pageIndex0Based (idx=pageIndex,size=pageSize) | - | - | 6h | error[404] r=0 |
| ListPortalOutbreaks | `/mtp/threatAnalytics/outbreaks` | GET | read | none | - | - | weekly | live[200] r=2984 |
| QueryOutbreakIndicators | `...csIndicators/stix/outbreaks/{OutbreakId}/indicators/query` | POST | read | none | - | - | 6h | no-live-pathparam r=0 |
| UpdateOutbreakUserState | `/mtp/threatAnalytics/outbreaks/userState` | PATCH | write | none | - | - | 6h | no-live-method-PATCH r=0 |

#### `vulnerability_management` [P1]

**Sub-area summary:** 32 endpoints · cadence=daily · pagination=pageIndex0Based:8 / none:21 / pageIndex1Based:3 · time-filter coverage=6/32 · top entities=Software.Vendor, Host.OsPlatform, Software.Name, Host.FullName, Host.RiskScore · production scale=10K-500K rows · risk=HIGH (paginated) · delta=critical

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CheckProvisioningEligibility | `/mtp/tvm/orgsettings/provision/isEligible` | GET | read | none | - | - | daily | error[403] r=0 |
| GetAsset | `/mtp/tvm/analytics/assets/{assetId}` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetAssetCountByExposureLevel | `/mtp/tvm/analytics/assets/countByExposureLevel` | GET | read | none | - | - | 1h | live[200] r=2 |
| GetAssetVulnerabilityDistribution | `...vm/analytics/assets/{assetId}/vulnerabilitiesDistribution` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetBaseline | `/mtp/tvm/analytics/vulnerabilities/baseline` | GET | read | none | - | - | daily | error[404] r=0 |
| GetCertificateAlgorithms | `/mtp/tvm/analytics/certificates/algorithms` | GET | read | none | - | - | daily | error[400] r=0 |
| GetDashboard | `/mtp/tvm/analytics/dashboard` | GET | read | none | - | - | daily | error[404] r=0 |
| GetDeviceHealth | `/mtp/tvm/analytics/devicehealth` | GET | read | none | - | Host.FullName, Host.MdatpId, Host.OsPlatform | daily | live[200] r=7 |
| GetNotificationRulesMetadata | `...tvm/orgsettings/vulnerability-notification-rules/metadata` | GET | read | none | - | - | daily | live[200] r=1 |
| GetRecommendationAssetStats | `...ytics/recommendations/{recommendationId}/assetsStatistics` | GET | read | none | - | - | daily | no-live-pathparam r=0 |
| GetRecommendationFilters | `/mtp/tvm/analytics/recommendations/filters` | GET | read | none | - | - | daily | live[200] r=4 |
| GetSummary | `/mtp/tvm/analytics/vulnerabilities/summary` | GET | read | none | - | - | daily | live[200] r=1 |
| GetTopRemediationTasks | `/mtp/tvm/remediation-tasks/remediationTasks/top` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| GetTopSoftwareChangeEventsPerDay | `/mtp/tvm/analytics/changeEvents/sca/topPerDay` | GET | read | none | - | - | daily | error[405] r=0 |
| GetTopVaChangeEventsPerDay | `/mtp/tvm/analytics/changeEvents/va/topPerDay` | GET | read | none | - | Software.Name, Software.Vendor | daily | live[200] r=20 |
| GetVaRecommendations | `/mtp/tvm/analytics/recommendations/va` | GET | read | none | - | Host.OsPlatform, Software.Name, Software.Vendor | daily | live[200] r=20 |
| GetVulnerabilityAssets | `/mtp/tvm/analytics/vulnerabilities/{cveId}/assets` | GET | read | none | - | Vuln.CveId | daily | no-live-pathparam r=0 |
| GetVulnerableDevicesReport | `/mtp/tvm/analytics/vulnerableDevicesReport` | GET | read | none | - | - | daily | error[404] r=0 |
| ListAdvisories | `/mtp/tvm/analytics/advisories` | GET | read | pageIndex0Based (idx=pageIndex) | - | - | daily | live-empty[200] r=0 |
| ListAssetInstallations | `/mtp/tvm/analytics/assets/{assetId}/installations` | GET | read | pageIndex1Based (idx=pageIndex,size=pageSize) | - | - | daily | no-live-pathparam r=0 |
| ListAssetRecommendations | `/mtp/tvm/analytics/assets/{assetId}/recommendations` | GET | read | pageIndex1Based (idx=pageIndex,size=pageSize) | - | - | daily | no-live-pathparam r=0 |
| ListAssetVulnerabilities | `/mtp/tvm/analytics/assets/{assetId}/vulnerabilities` | GET | read | pageIndex1Based (idx=pageIndex,size=pageSize) | - | - | daily | no-live-pathparam r=0 |
| ListCertificates | `/mtp/tvm/analytics/certificates` | GET | read | pageIndex0Based (idx=pageIndex) | - | - | daily | error[400] r=0 |
| ListChangeEvents | `/mtp/tvm/analytics/changeevents` | GET | read | pageIndex0Based (idx=pageIndex) | - | Software.Name, Software.Vendor | daily | live[200] r=20 |
| ListExtensions | `/mtp/tvm/analytics/extensions` | GET | read | pageIndex0Based (idx=pageIndex) | - | - | daily | error[400] r=0 |
| ListProducts | `/mtp/tvm/analytics/products` | GET | read | pageIndex0Based (idx=pageIndex) | - | Host.OsPlatform, Host.RiskScore, Software.Vendor | daily | live[200] r=20 |
| ListRecommendations | `/mtp/tvm/analytics/recommendations` | GET | read | pageIndex0Based (idx=pageIndex) | - | Host.OsPlatform, Software.Name, Software.Vendor | daily | live[200] r=20 |
| ListRemediations | `/mtp/tvm/analytics/remediations` | GET | read | pageIndex0Based (idx=pageIndex) | - | - | daily | error[404] r=0 |
| ListRemediationTaskExceptions | `/mtp/tvm/remediation-tasks/allExceptions/aggregated` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| ListRemediationTasks | `/mtp/tvm/remediation-tasks/remediationTasks` | GET | read | none | - | - | daily | live-empty[200] r=0 |
| ListTopVulnerableAssets | `/mtp/tvm/analytics/assets/topVulnerable` | GET | read | none | - | Host.FullName, Host.OsPlatform, Host.RiskScore | daily | live[200] r=3 |
| ListVulnerabilities | `/mtp/tvm/analytics/vulnerabilities` | GET | read | pageIndex0Based (idx=pageIndex) | - | Url.Path | daily | live[200] r=20 |

---

## Portal: `entra-b2c`

### Auth

| Field | Value |
|---|---|
| Bucket | C-azure-ad-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `https://main.b2cadmin.ext.azure.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-entra-b2c\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\entra-b2c.collection.json` (present)

### Sub-areas: 1 · Endpoints: 5 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=topSkip:1 / none:4 · time-filter coverage=0/5 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAndInitializeTenantPolicy | `/api/tenants/GetAndInitializeTenantPolicy` | GET | read | none | - | - | daily | unprobed |
| GetARpDataWithTenantId | `/api/tenantResource/GetARpDataWithTenantId` | GET | read | none | - | - | daily | unprobed |
| GetTenantInfo | `/api/tenants/GetTenantInfo` | GET | read | none | - | Tenant.Id | daily | unprobed |
| List | `/api/adminuserjourneys` | GET | read | none | - | Tenant.Id | daily | unprobed |
| ListAvailableOutputClaims | `/api/userAttribute/GetAvailableOutputClaimsList` | GET | read | none | - | Tenant.Id | daily | unprobed |

---

## Portal: `entra-ibiza-iam`

### Auth

| Field | Value |
|---|---|
| Bucket | C-azure-ad-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` |
| Audience | `74658136-14ec-4630-ad9b-26e160ff0fc6` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-ibiza-iam\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\entra-iam.collection.json` (present)

### Sub-areas: 32 · Endpoints: 234 · Live: 50

#### `account_sku` [v0.2.0+]

**Sub-area summary:** 17 endpoints · cadence=daily · pagination=none:17 · time-filter coverage=0/17 · top entities=Software.Version, Account.AadId, File.Path, Software.Name, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Assign | `/AccountSkus/Assign` | POST | unknown | none | - | Software.Version | daily | unprobed |
| AssignUpdateRemove | `/AccountSkus/AssignUpdateRemove` | POST | unknown | none | - | Software.Version | daily | unprobed |
| Delete | `/ViralSku/delete` | DELETE | write | none | - | Software.Name, Software.Version | daily | unprobed |
| DirectoryMembersImageUrlFromIds.Get | `/Licenses/DirectoryMembersImageUrlFromIds` | POST | unknown | none | - | Account.AadId, File.Path, Software.Version | daily | unprobed |
| Get | `/ViralSubscriptions` | GET | read | none | - | File.Name, Software.Version | daily | live[200] |
| Group.Error.List | `/AccountSkus/GroupsWithLicensingErrors` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| Group.Errors.Get | `/AccountSkus/Group/{groupId}/AssignmentErrors` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Group.Get | `/AccountSkus/Group/{groupId}` | GET | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| Group.List | `/AccountSkus/GroupAssignments` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| Group.Reprocess | `/AccountSkus/Group/{groupId}/Reprocess` | POST | unknown | none | - | Software.Version | daily | unprobed |
| List | `/AccountSkus` | GET | read | none | - | Software.Version | daily | tenant-gated[404] |
| Remove | `/AccountSkus/Remove` | POST | write | none | - | Software.Version | daily | unprobed |
| Trial.Create | `/AccountSkus/CreateTrial` | POST | unknown | none | - | Software.Version | daily | unprobed |
| Update | `/AccountSkus/Update` | POST | write | none | - | Software.Version | daily | unprobed |
| user.Get | `/AccountSkus/User/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Software.Version | daily | tenant-gated[404] |
| User.List | `/AccountSkus/UserAssignments` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| User.Reprocess | `/AccountSkus/User/{userId}/Reprocess` | POST | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |

#### `application_insights` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=Software.Version, Software.Name, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ApplicationLogos.Get | `/ApplicationInsights/ApplicationLogos` | POST | unknown | none | - | Software.Version | daily | unprobed |
| AppMigrations.List | `/ApplicationInsights/AppMigration` | GET | unknown | none | - | Software.Version | daily | live[200] |
| ConsentedPermissionsData.List | `/ApplicationInsights/ConsentedPermissionsData` | GET | unknown | none | - | Software.Name, Software.Version | daily | live[200] |
| ConsentedPermissionsDataAppBased.List | `/ApplicationInsights/ConsentedPermissionsDataAppBased` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| EnterpriseAppSignIns.List | `/ApplicationInsights/EnterpriseAppSignIns` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| SAMLApps.List | `/ApplicationInsights/SAMLApps` | GET | unknown | none | - | Software.Name, Software.Version | daily | server-error[500] |

#### `application_proxy` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=0/7 · top entities=Software.Version, File.Name, File.Path, Software.Name, Url.Domain · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Applications.Get | `/ApplicationProxy/Applications/{appId}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Applications.TestButtonReport.Get | `/ApplicationProxy/Applications/TestButtonReport` | GET | unknown | none | - | Software.Version | daily | request-shape-error[400] |
| ConnectorGroups.Applications.List | `/ApplicationProxy/ConnectorGroups/{groupId}/Applications` | GET | unknown | none | - | - | daily | unprobed |
| ConnectorGroups.Get | `/ApplicationProxy/ConnectorGroups/{groupId}` | GET/PATCH/DELETE | unknown | none | - | - | daily | unprobed |
| ConnectorGroups.List | `/ApplicationProxy/ConnectorGroups` | GET/POST | unknown | none | - | File.Name, Software.Version | daily | live[200] |
| Connectors.Get | `/ApplicationProxy/Connectors/{connectorId}` | GET/PATCH | unknown | none | - | - | daily | unprobed |
| Directory.Get | `/ApplicationProxy/Directory` | GET | unknown | none | - | File.Name, File.Path, Software.Name | daily | live[200] |

#### `application_sso` [v0.2.0+]

**Sub-area summary:** 27 endpoints · cadence=daily · pagination=none:27 · time-filter coverage=0/27 · top entities=Software.Version, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Certificate.Get | `...spId}/GetCertificateByThumbprintBase64String/{thumbprint}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| ClaimIssuancePolicyId.Get | `/ApplicationSso/{spId}/ClaimIssuancePolicyId` | GET | unknown | none | - | Software.Version | daily | unprobed |
| ClaimTest.Setup | `/ApplicationSso/{spId}/SetupClaimTest` | POST | unknown | none | - | Software.Version | daily | unprobed |
| CleanClaimTest.Run | `/ApplicationSso/{spId}/CleanClaimTest` | POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedOneClickSsoSetupData.Get | `/ApplicationSso/{spId}/GetFederatedOneClickSsoSetupData` | GET | unknown | none | - | - | daily | unprobed |
| FederatedSsoClaimsPolicy.Link | `/ApplicationSso/{spId}/LinkFederatedSsoClaimsPolicy` | POST | unknown | none | - | - | daily | unprobed |
| FederatedSsoClaimsPolicyV2.Set | `/ApplicationSso/{spId}/FederatedSsoClaimsPolicyV2` | POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoClaimsPolicyV3.Set | `/ApplicationSso/{spId}/FederatedSsoClaimsPolicyV3` | POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoConfigV2.Update | `/ApplicationSso/{spId}/FederatedSsoConfigV2` | POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoConfigV4.Update | `/ApplicationSso/{spId}/FederatedSsoConfigV4/{appId}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoDefaultClaimsV2.Get | `/ApplicationSso/FederatedSsoDefaultClaimsV2` | GET | unknown | none | - | Software.Version | daily | live[200] |
| FederatedSsoV2.Get | `/ApplicationSso/{spId}/FederatedSsoV2` | GET/POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoV3.Get | `/ApplicationSso/{spId}/FederatedSsoV3` | GET/POST | unknown | none | - | Software.Version | daily | unprobed |
| FederatedSsoV4.Get | `/ApplicationSso/{spId}/FederatedSsoV4/{appId}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| LinkedSso.Get | `/ApplicationSso/{spId}/LinkedSso` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| RegexTransformation.Evaluate | `/ApplicationSso/EvaluateRegexTransformation` | GET | unknown | none | - | Software.Version | daily | other[405] |
| SignInUrl.Get | `/ApplicationSso/{spId}/GetSignInUrl` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| SingleSignOn.Get | `/ApplicationSso/{spId}/SingleSignOn` | GET/POST | unknown | none | - | Software.Version | daily | unprobed |
| SPsWithSharedPolicy.Get | `/ApplicationSso/{spId}/SPsWithSharedPolicy` | GET | unknown | none | - | Software.Version | daily | unprobed |
| SsoApplication.Get | `/ApplicationSso/{spId}/SsoApplication` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| SsoFederation.Setup | `/ApplicationSso/{spId}/SetupFederation` | POST | unknown | none | - | - | daily | unprobed |
| TestLink.Get | `/ApplicationSso/{spId}/TestLink` | GET | read | none | - | Software.Version | daily | unprobed |
| TokenIssuancePolicyId.Get | `/ApplicationSso/{spId}/TokenIssuancePolicyId` | GET | unknown | none | - | Software.Version | daily | unprobed |
| TokenSigningCert.Get | `/ApplicationSso/TokenSigningCert` | POST | unknown | none | - | - | daily | unprobed |
| UserExtensionProperties.Get | `/ApplicationSso/UserExtensionProperties` | GET | unknown | none | - | Software.Version | daily | live[200] |
| ValidIdentifierUri.Check | `/ApplicationSso/IsValidIdentifierUriV2` | POST | unknown | none | - | Software.Version | daily | unprobed |
| ValidUri.Check | `/ApplicationSso/IsValidUri` | POST | unknown | none | - | Software.Version | daily | unprobed |

#### `applications` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=Software.Version, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ApplicationObject.Get | `/ApplicationManagement/ApplicationObject/{appId}` | GET | unknown | none | - | Software.Name, Software.Version | daily | unprobed |
| FederatedOneClickSsoConfigureInfo.Get | `...dApplications/{spId}/GetFederatedOneClickSsoConfigureInfo` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Gallery.Get | `/Applications/Gallery/{appId}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Gallery.List | `/Applications/Gallery` | GET | unknown | none | - | Software.Version | daily | live[200] |

#### `authentication_methods` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AuthenticationMethodsPolicy.Get | `/AuthenticationMethods/AuthenticationMethodsPolicy` | GET/POST/DELETE | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| PasswordPolicy.Get | `/AuthenticationMethods/PasswordPolicy` | GET/POST | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| RequireVerification | `/RequireAuthMethodVerification/{0}` | PUT | unknown | none | - | - | daily | unprobed |

#### `b2b` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| B2BPolicy.Get | `/B2B/b2bpolicy` | GET | unknown | none | - | Software.Version | daily | live[200] |
| CustomIdentityProviders.List | `/B2B/customIdentityProviders` | GET/POST/PATCH | unknown | none | - | - | daily | live[200] |
| MetadataFile.Get | `/B2B/getMetadataFile` | POST | unknown | none | - | Software.Version | daily | unprobed |

#### `b2c` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=Software.Version, Url.Domain · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| B2C.Create | `/Directories/B2C` | POST | unknown | none | - | Software.Version, Url.Domain | daily | unprobed |

#### `claim_providers` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Controls.List | `/ClaimProviders/Controls` | GET | unknown | none | - | File.Name, Software.Version | daily | live[200] |
| List | `/ClaimProviders` | GET/POST/PUT/DELETE | read | none | - | Software.Version | daily | tenant-gated[401] |
| Validate | `/ClaimProviders/Validate` | POST | read | none | - | Software.Version | daily | unprobed |

#### `classic_policies` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=0/7 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Detail.Delete | `/ClassicPolicies/Delete` | DELETE | unknown | none | - | - | daily | unprobed |
| Detail.Get | `/ClassicPolicies/Detail` | POST | unknown | none | - | - | daily | unprobed |
| Detail2.Get | `/ClassicPolicies/Detail2` | POST | unknown | none | - | Software.Version | daily | unprobed |
| Disable | `/ClassicPolicies/Disable` | PUT | write | none | - | - | daily | unprobed |
| List | `/ClassicPolicies` | GET | read | none | - | - | daily | tenant-gated[404] |
| Migrate | `/ClassicPolicies/Migrate` | POST | unknown | none | - | - | daily | unprobed |
| Save | `/ClassicPolicies/Save` | POST | write | none | - | - | daily | unprobed |

#### `data_insights` [v0.2.0+]

**Sub-area summary:** 2 endpoints · cadence=daily · pagination=none:2 · time-filter coverage=0/2 · top entities=Software.Version, Account.AadId, Account.UPN · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| UserCredentialUsageDetails.List | `/DataInsights/GetUserCredentialUsageDetails` | POST | unknown | none | - | - | daily | unprobed |
| UserCredentialUserRegistrationDetails.List | `/DataInsights/GetCredentialUserRegistrationDetails` | POST | unknown | none | - | Account.AadId, Account.UPN, Software.Version | daily | unprobed |

#### `devices` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Create | `/Devices` | POST | write | none | - | - | daily | unprobed |
| Download | `/SyncingDevices/{0}/Download` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Get | `/SyncingDevices/{0}` | GET | read | none | - | Software.Version | daily | unprobed |

#### `directories` [v0.2.0+]

**Sub-area summary:** 23 endpoints · cadence=daily · pagination=none:23 · time-filter coverage=0/23 · top entities=File.Path, Software.Version, Tenant.Id, Software.Name, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| DeletionRestrictions.Get | `/Directories/DeletionRestrictions` | GET | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| Details.Get | `/Directories/45f52f35-73d5-4066-8378-fe506ee90fb1/Details` | GET | unknown | none | - | Account.AadId, File.Path, Software.Name | daily | live[200] |
| DomainAvailability.Check | `/Directories/DomainAvailability/{domainPrefix}` | GET | unknown | none | - | File.Path, Software.Version, Url.Domain | daily | unprobed |
| FeatureSettingsProperties.Get | `/Directories/FeatureSettingsProperties` | GET/PUT | unknown | none | - | File.Path, Software.Version | daily | tenant-gated[401] |
| LcmSettings.Get | `/Directories/LcmSettings` | GET/PUT | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| LoginTenantBranding.BannerImage.Get | `/LoginTenantBrandings/BannerImage/{locale}` | GET | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| LoginTenantBranding.Get | `/LoginTenantBrandings/{locale}` | GET/PUT/DELETE | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| LoginTenantBranding.List | `/LoginTenantBrandings` | GET/POST | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| Member.Get | `/DirectoryObjectPicker/DirectoryMembersFromIds` | POST | unknown | none | - | Account.UPN, File.Path, Software.Name | daily | unprobed |
| MemberOfCount.Get | `/directoryObjects/{objectId}/memberOf/count` | GET | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| Object.Get | `/directoryObjects/{objectId}` | GET | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| OnPremisesAgents.List | `...ies/45f52f35-73d5-4066-8378-fe506ee90fb1/OnPremisesAgents` | GET | unknown | none | - | File.Path, Tenant.Id | daily | live[200] |
| OnPremisesPublishedResources.Get | `...antId}/OnPremisesPublishedResources/{publishedResourceId}` | GET | unknown | none | - | File.Path, Tenant.Id | daily | unprobed |
| OnPremisesPublishedResources.List | `...-73d5-4066-8378-fe506ee90fb1/OnPremisesPublishedResources` | GET | unknown | none | - | File.Path, Tenant.Id | daily | live[200] |
| PasswordSync.Check | `/Directories/GetPasswordSyncStatus` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| Properties.Get | `/Directories/Properties` | GET/PUT | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| PropertiesV2.Set | `/Directories/PropertiesV2` | PUT | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| RecommendedPayloads.Get | `/Directories/RecommendedPayloads` | GET | unknown | none | - | File.Name, File.Path, Software.Version | daily | live[200] |
| SeamlessSigleSignOnDomains.Get | `/Directories/GetSeamlessSingleSignOnDomains` | GET | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| Search | `/DirectoryObjectPicker/Search` | GET | read | none | - | File.Path, Software.Version | daily | other[405] |
| SsgmProperties.Get | `/Directories/SsgmProperties` | GET/PUT | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| Summary.Get | `/Directories/Summary` | GET | unknown | none | - | File.Path, Software.Version | daily | live[200] |
| WhatsNew.List | `/Directories/DirectoryWhatsNew` | GET | unknown | none | - | File.Path, Software.Version | daily | tenant-gated[404] |

#### `document_processor_tasks` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=0/5 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Create | `/DocumentProcessorTasks` | POST | write | none | - | - | daily | unprobed |
| Download | `/DocumentProcessorTasks/Download/{id}` | GET | unknown | none | - | - | daily | unprobed |
| Get | `/DocumentProcessorTasks/{id}` | GET | read | none | - | - | daily | unprobed |
| List | `/DocumentProcessorTasks/ListTasks` | GET | read | none | - | - | daily | live[200] |
| TaskFile.Upload | `/DocumentProcessorTasks/UploadTaskFile` | POST | unknown | none | - | - | daily | unprobed |

#### `enterprise_applications` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version, Account.AadId · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Permissions.Get | `/EnterpriseApplications/{spId}/ServicePrincipalPermissions` | GET | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| Properties.Get | `/EnterpriseApplications/{spId}/Properties` | GET/PATCH | unknown | none | - | Software.Version | daily | unprobed |
| UserSettings.Get | `/EnterpriseApplications/UserSettings` | GET/PATCH | unknown | none | - | Software.Version | daily | live[200] |

#### `gdpr` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ExportRequest.Create | `/GDPR/InitiateExportRequest` | POST | read | none | - | - | daily | unprobed |
| IsViralUser.Check | `/GDPR/IsViralUser` | GET | unknown | none | - | Software.Version | daily | live[200] |
| Requests.List | `/GDPR/ListRequests` | POST | unknown | none | - | - | daily | unprobed |
| SelfDelete.Create | `/GDPR/DeleteSelf` | POST/DELETE | unknown | none | - | - | daily | unprobed |

#### `groups` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=Software.Version, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| DynamicMembershipBaseAttributes.Get | `/Groups/GetSupportedDynamicMembershipBaseAttributes/{id}` | GET | unknown | none | - | - | daily | unprobed |
| DynamicMembershipOperators.List | `/Groups/GetSupportedDynamicMembershipOperators` | GET | unknown | none | - | File.Name, Software.Version | daily | live[200] |
| ExtensionPropertiesByApp.Get | `/Groups/{groupId}/GetExtensionPropertiesByApp` | GET | unknown | none | - | - | daily | unprobed |
| id.dynamic,get | `/Groups/{groupId}/GetDynamicGroupProperties` | GET | unknown | none | - | Software.Version | daily | unprobed |
| id.get | `/Groups/{groupId}` | GET | unknown | none | - | Software.Version | daily | unprobed |
| id.owner.count.get | `/Groups/{groupId}/owners/count` | GET | unknown | none | - | Software.Version | daily | unprobed |
| list | `/Groups` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| MemberCount.Get | `/Groups/{groupId}/members/count` | GET | unknown | none | - | Software.Version | daily | unprobed |

#### `managed_applications` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=Software.Version, Account.AadId · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AppRoleAssginemnts.Get | `/ManagedApplications/{spId}/AppRoleAssignments` | GET/POST | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| Get | `/ManagedApplications/{spId}` | GET | read | none | - | Software.Version | daily | unprobed |
| List | `/ManagedApplications/List` | POST | read | none | - | Software.Version | daily | unprobed |
| PasswordSsoCustomApp.Create | `/ManagedApplications/{spId}/PasswordSsoCustomApp` | POST | unknown | none | - | Software.Version | daily | unprobed |
| PasswordSsoCustomApp.Get | `...gedApplications/{spId}/PasswordSsoCustomApp/{customAppId}` | GET | unknown | none | - | - | daily | unprobed |
| PasswordSsoCustomApp.Target.Get | `...ons/{spId}/PasswordSsoCredentials/{targetType}/{targetId}` | GET | unknown | none | - | - | daily | unprobed |

#### `mdm_applications` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=Software.Version, File.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Application.Get | `/MdmApplications/Application/{appId}` | GET | unknown | none | - | - | daily | unprobed |
| List | `/MdmApplications` | GET | read | none | - | Software.Version | daily | live[200] |
| Permissions.List | `/MdmApplications/Permissions/{appId}` | GET | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| Update | `/MdmApplications/{spId}` | PUT/GET | write | none | - | Software.Version | daily | unprobed |

#### `microsoft_entra_connect` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=File.Path, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ADConnectStatus.Get | `/Directories/ADConnectStatus` | GET | unknown | none | - | File.Path, Software.Version | daily | live[200] |

#### `misc` [v0.2.0+]

**Sub-area summary:** 9 endpoints · cadence=daily · pagination=none:9 · time-filter coverage=0/9 · top entities=Software.Version, File.Path, Url.Domain, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ChartCounts.Get | `/Security/Overview/ChartCounts` | POST | unknown | none | - | Software.Version | daily | unprobed |
| Document.Get | `/SupportRequestProblemDetails/Document` | GET | unknown | none | - | File.Name, File.Path, Software.Version | daily | tenant-gated[404] |
| Document.XMLContent.Get | `/SupportRequestProblemDetails/Document/XMLContent` | POST | unknown | none | - | - | daily | unprobed |
| Get | `/FeatureConfigurations` | GET | read | none | - | Software.Version | 6h | live[200] |
| Object.Get | `/Common/GetObjectsByObjectIds` | POST | unknown | none | - | File.Path, Software.Version | daily | unprobed |
| SSPR.Enable | `/Spotlight/enableSSPR` | POST | unknown | none | - | - | daily | unprobed |
| TileCounts.Get | `/Security/Overview/TileCounts` | GET | unknown | none | - | Software.Version | daily | tenant-gated[401] |
| VerifiedDomains.List | `/Common/VerifiedDomains` | GET | unknown | none | - | File.Name, Software.Version, Url.Domain | daily | live[200] |
| Verify | `/Domains('{domainName}')/verify` | GET | unknown | none | - | Url.Domain | daily | unprobed |

#### `multifactor_authentication` [v0.2.0+]

**Sub-area summary:** 26 endpoints · cadence=daily · pagination=none:26 · time-filter coverage=0/26 · top entities=Software.Version, Account.UPN, Tenant.Id, Policy.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ActivationCredentials.Get | `/MultiFactorAuthentication/ActivationCredentials` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| AuthenticationReport.Download | `/MultiFactorAuthentication/DownloadAuthenticationReport` | POST | unknown | none | - | - | daily | unprobed |
| AuthenticationReport.Get | `/MultiFactorAuthentication/AuthenticationReport` | POST | unknown | none | - | Software.Version, Tenant.Id | daily | unprobed |
| BlockedUsers.List | `/MultiFactorAuthentication/BlockedUser` | GET/POST/DELETE | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| BypassedUsers.List | `/MultiFactorAuthentication/BypassedUser` | GET/POST/DELETE | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| CacheConfig.List | `/MultiFactorAuthentication/CacheConfig` | GET/POST/DELETE | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| CacheConfig.Update | `/MultiFactorAuthentication/CacheConfig/{configId}` | PATCH | unknown | none | - | Policy.Id, Software.Version | daily | unprobed |
| ExpandedTenantModel.Get | `/MultiFactorAuthentication/ExpandedTenantModel` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| Get | `/MultiFactorAuthentication/GetOrCreateExpandedTenantModel` | GET | read | none | - | Software.Version | daily | tenant-gated[403] |
| Greetings.List | `/MultiFactorAuthentication/Greeting` | GET/POST/DELETE | unknown | none | - | - | daily | tenant-gated[403] |
| Groups.List | `/MultiFactorAuthentication/Group` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| HardwareToken.Create | `/MultiFactorAuthentication/HardwareToken/upload` | POST | unknown | none | - | - | daily | unprobed |
| HardwareToken.Delete | `/MultiFactorAuthentication/HardwareToken/remove` | POST | unknown | none | - | - | daily | unprobed |
| HardwareToken.Enable | `/MultiFactorAuthentication/HardwareToken/enable` | POST | unknown | none | - | Software.Version | daily | unprobed |
| HardwareToken.Upload | `/MultiFactorAuthentication/HardwareToken/upload/{tokenId}` | DELETE | unknown | none | - | - | daily | unprobed |
| HardwareToken.Uploads.List | `/MultiFactorAuthentication/HardwareToken/listUploads` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| HardwareToken.Users.Download | `/MultiFactorAuthentication/HardwareToken/users/download` | GET | unknown | none | - | Account.UPN | daily | tenant-gated[403] |
| HardwareToken.Users.List | `/MultiFactorAuthentication/HardwareToken/users` | GET | unknown | continuationToken (tok=skipToken) | - | Account.UPN, Software.Version | daily | tenant-gated[403] |
| LicenseKey.Get | `/MultiFactorAuthentication/TenantModel/LicenseKey` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| PaidSubscription.Check | `/MultiFactorAuthentication/HasPaidSubscription` | GET | unknown | none | - | Software.Version | daily | live[200] |
| Providers.List | `/MultiFactorAuthentication/Providers` | GET | unknown | none | - | - | daily | other[405] |
| Revoke | `/RevokeMFA/{0}` | PUT | unknown | none | - | - | daily | unprobed |
| ServerStatusReport.Download | `/MultiFactorAuthentication/DownloadServerStatusReport` | GET | unknown | none | - | - | daily | other[405] |
| ServerStatusReport.Get | `/MultiFactorAuthentication/ServerStatusReport` | POST | unknown | none | - | Software.Version | daily | unprobed |
| SoundFile.Create | `/MultiFactorAuthentication/Soundfile` | POST | unknown | none | - | - | daily | unprobed |
| TenantModel.Get | `/MultiFactorAuthentication/TenantModel` | GET/PATCH | unknown | none | - | Software.Version | daily | tenant-gated[403] |

#### `named_networks` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=Software.Version, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CountryCodes.List | `/NamedNetworksV2/CountryCodes` | GET | unknown | none | - | Software.Name, Software.Version | daily | tenant-gated[404] |
| Get | `/NamedNetworksV2/{id}` | GET | read | none | - | Software.Version | daily | unprobed |
| List | `/NamedNetworksV2` | GET/POST | read | none | - | Software.Version | daily | tenant-gated[404] |
| PolicySize.Validate | `/NamedNetworksV2/ValidatePolicySize/{id}` | GET | unknown | none | - | Software.Version | daily | unprobed |

#### `password_reset` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=Software.Version, Account.UPN, Account.AadId, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ConditionalAccessPolicyInfo.List | `/PasswordReset/ListConditionalAccessPolicyInfo` | GET | unknown | none | - | Software.Name, Software.Version | daily | live[200] |
| Execute | `/PasswordReset/ResetPasswordByUpn` | PUT | unknown | none | - | Account.UPN, Software.Version | daily | unprobed |
| OnPremisesPasswordResetAvailable.Check | `/PasswordReset/IsOnPremisesPasswordResetAvailable` | GET | unknown | none | - | Software.Version | daily | live[200] |
| OnPremisesPasswordResetPolicies.Get | `/PasswordReset/OnPremisesPasswordResetPolicies` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |
| PasswordResetPolicies.Get | `/PasswordReset/PasswordResetPolicies` | GET/PUT | unknown | none | - | Software.Version | daily | live[200] |
| ResetPasswordByObjectIdAllowed.Check | `/PasswordReset/IsResetPasswordByObjectIdAllowed` | GET | write | none | - | Account.AadId, Account.UPN, Software.Version | daily | tenant-gated[404] |
| ResetPasswordByUpnAllowed.Check | `/PasswordReset/IsResetPasswordByUpnAllowed` | GET | write | none | - | Account.UPN, Software.Version | daily | tenant-gated[404] |
| WritebackConnectivityStatus.Check | `/PasswordReset/CheckWritebackConnectivityStatus` | GET | unknown | none | - | Software.Version | daily | tenant-gated[403] |

#### `permissions` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Get | `/Permissions` | GET | read | none | - | Software.Version | daily | live[200] |
| Object.Owner.Check | `/Permissions/{objectId}/IsOwner` | GET | unknown | none | - | Software.Version | daily | unprobed |
| SystemRoleTemplateIds.Get | `/Permissions/GetUserSystemRoleTemplateIds` | GET | unknown | none | - | Software.Version | daily | live[200] |
| TenantRegionScope.Check | `/Permissions/IsTenantRegionScopeAllowed` | GET | unknown | none | - | Software.Version | daily | live[200] |

#### `policies` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=Software.Version, Time.Generated, Policy.Id, Software.Name, IP.Address · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CheckPolicyCountUnderMaxAllowedLimit | `/Policies/PolicyCountUnderMaxAllowedLimit` | GET | read | none | - | Software.Version | daily | tenant-gated[401] |
| Create | `/Policies` | POST | write | none | - | Software.Version | daily | unprobed |
| Evaluate | `/WhatIf/Evaluate` | POST | unknown | none | - | IP.Address, Software.Name, Software.Version | daily | unprobed |
| Get | `/Policies/{policyId}` | GET/PUT/DELETE | read | none | - | Policy.Id, Software.Version | daily | unprobed |
| List | `/Policies/Policies` | GET | read | none | - | Policy.Id, Software.Version, Time.Generated | daily | tenant-gated[401] |
| Validate | `/Policies/Validate` | POST | read | none | - | Software.Version | daily | unprobed |

#### `registered_applications` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Consent | `/RegisteredApplications/{appId}/Consent` | POST | unknown | none | - | Software.Version | daily | unprobed |
| List | `/RegisteredApplications` | GET/POST | read | none | - | Software.Version | daily | live[200] |
| Update | `/RegisteredApplications/{appId}` | PUT/DELETE | write | none | - | Software.Version | daily | unprobed |

#### `reports` [v0.2.0+]

**Sub-area summary:** 10 endpoints · cadence=daily · pagination=none:10 · time-filter coverage=0/10 · top entities=Software.Version, Software.Name, Account.AadId, Account.UPN, IP.Address · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AuditActivityTypes.Get | `/Reports/AuditActivityTypes` | GET | read | none | - | Software.Version | daily | live[200] |
| AuditActivityTypesV2.Get | `/Reports/AuditActivityTypesV2` | GET | read | none | - | Software.Version | daily | live[200] |
| AuditEventsV2.List | `/Reports/AuditEventsV2` | POST | read | none | - | Account.AadId, Account.UPN, File.Path | daily | unprobed |
| Get | `/Reports/{reportId}` | GET | read | none | - | - | daily | unprobed |
| Group.Get | `/Reports/Groups/{groupId}` | GET | unknown | none | - | Software.Name, Software.Version | daily | unprobed |
| GroupActivitySummary.Get | `/Reports/GroupsActivitySummary` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| ServicePrincipal.Get | `/Reports/ServicePrincipals/{spId}` | GET | unknown | none | - | - | daily | unprobed |
| SignInEventsV2.Get | `/Reports/SignInEventsV2` | POST | unknown | none | - | Account.AadId, Account.UPN, Host.MdatpId | daily | unprobed |
| UserActivitySummary.Get | `/Reports/UsersActivitySummary` | GET | unknown | none | - | Software.Version | daily | tenant-gated[404] |
| Users.Get | `/Reports/Users/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Account.UPN, Software.Name | daily | live[200] |

#### `request_approvals` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| BusinessFlows.Get | `/RequestApprovals/V2/BusinessFlows` | GET | unknown | offsetLimit (tok=skip) | - | Software.Version | daily | live[200] |
| PolicyTemplate.Create | `/RequestApprovals/V2/PolicyTemplates` | POST | unknown | none | - | Software.Version | daily | unprobed |
| PolicyTemplate.Update | `/RequestApprovals/V2/PolicyTemplates/{templateId}` | PATCH/DELETE | unknown | none | - | Software.Version | daily | unprobed |
| Request.Block | `/RequestApprovals/V2/Requests/{requestId}/block/{0}` | POST | unknown | none | - | Software.Version | daily | unprobed |
| Request.Deny | `/RequestApprovals/V2/Requests/{requestId}/deny` | GET | unknown | none | - | Software.Version | daily | unprobed |
| Request.List | `/RequestApprovals/V2/Requests` | GET | unknown | offsetLimit (tok=skip) | - | Software.Version | daily | tenant-gated[404] |

#### `roles` [v0.2.0+]

**Sub-area summary:** 2 endpoints · cadence=daily · pagination=none:2 · time-filter coverage=0/2 · top entities=Software.Version, Account.AadId, Software.Name, File.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Assignments.Create | `/Roles/{roleId}/RoleAssignments` | PUT/DELETE | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| User.Assignments.Get | `/Roles/User/xdrlogreader@CloudSectra.com/RoleAssignments` | GET/PUT | unknown | none | - | Account.AadId, File.Path, Software.Name | daily | tenant-gated[404] |

#### `security_defaults` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Configuration.Get | `/SecurityDefaults/Configuration` | GET | unknown | none | - | Software.Version | 6h | live[200] |
| Set | `/SecurityDefaults/UpdateSecurityDefaultOnSave` | PUT | write | none | - | Software.Version | daily | unprobed |
| Status.Get | `/SecurityDefaults/GetSecurityDefaultStatus` | GET | unknown | none | - | Software.Version | daily | live[200] |

#### `users` [v0.2.0+]

**Sub-area summary:** 16 endpoints · cadence=daily · pagination=none:16 · time-filter coverage=0/16 · top entities=Software.Version, Account.AadId, Account.UPN, File.Path, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AssignedApplications.List | `/Users/xdrlogreader@CloudSectra.com/assignedApplications` | GET | unknown | none | - | Account.AadId, Software.Version, Url.Path | daily | live[200] |
| CountryCode.List | `/Users/Settings` | GET | unknown | none | - | Software.Name, Software.Version | daily | live[200] |
| Create | `/UserDetails` | POST | write | none | - | Software.Version | daily | unprobed |
| FIDODevices.List | `/User/xdrlogreader@CloudSectra.com/FIDODevices` | GET | unknown | none | - | Account.AadId, Software.Version | daily | live[200] |
| Get | `/Users/GetUserFromObjectIds` | POST | read | none | - | Account.AadId, Software.Version | daily | unprobed |
| Id.Get | `/UserDetails/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Software.Version | daily | live[200] |
| ImageProperties.Update | `/UpdateUser/{userId}/ImageProperties` | PATCH | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| MFAProperties.Update | `/UpdateUser/{userId}/MfaProperties` | PATCH | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| Permanent.Delete | `/Users/PermanentDelete` | DELETE | unknown | none | - | Account.AadId, Software.Version | daily | unprobed |
| Query | `/Users` | POST/DELETE | read | none | - | Account.AadId, File.Path, Software.Version | daily | unprobed |
| Reinvite | `/Users/ReInvite` | PUT | unknown | none | - | - | daily | unprobed |
| TemporaryPassword.Get | `/User/TemporaryPassword` | GET | unknown | none | - | Software.Version | daily | live[200] |
| Upn.AllowedDomain.Check | `/Users/IsUPNInAllowedDomain` | GET | unknown | none | - | Account.UPN, Software.Version, Url.Domain | daily | tenant-gated[404] |
| Upn.Unique.Check | `/Users/IsUPNUnique` | GET | unknown | none | - | Account.UPN, Software.Version | daily | tenant-gated[404] |
| UPNUnique.Check | `/Users/IsUPNUniqueOrPending/{userPrincipalName}` | GET | unknown | none | - | Account.UPN, File.Path, Software.Version | daily | unprobed |
| VerifiedDomains.List | `/Users/ListVerifiedDomains` | GET | unknown | none | - | Software.Version | daily | live[200] |

---

## Portal: `entra-idgov`

### Auth

| Field | Value |
|---|---|
| Bucket | C-azure-ad-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `https://api.accessreviews.identitygovernance.azure.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-entra-idgov\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\entra-idgov.collection.json` (present)

### Sub-areas: 1 · Endpoints: 14 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 14 endpoints · cadence=daily · pagination=none:14 · time-filter coverage=0/14 · top entities=Time.Generated, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| accessReviews_v2_0_approvalWorkflowProviders | `/accessReviews/v2.0/approvalWorkflowProviders` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__featureFlags | `...iews/v2.0/approvalWorkflowProviders/aadroles/featureFlags` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__partnerTenantSettings | `.../approvalWorkflowProviders/aadroles/partnerTenantSettings` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests | `...sReviews/v2.0/approvalWorkflowProviders/aadroles/requests` | GET/POST | unknown | none | - | - | daily | request-shape-error[400] |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId | `...provalWorkflowProviders/{providerId}/requests/{requestId}` | GET/PATCH/DELETE | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances | `...flowProviders/{providerId}/requests/{requestId}/instances` | GET | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances__instanceId | `.../{providerId}/requests/{requestId}/instances/{instanceId}` | GET | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances__instanceId__applyDecisions | `...equests/{requestId}/instances/{instanceId}/applyDecisions` | POST | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances__instanceId__decisions | `...Id}/requests/{requestId}/instances/{instanceId}/decisions` | GET | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances__instanceId__resetDecisions | `...equests/{requestId}/instances/{instanceId}/resetDecisions` | POST | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requests__requestId__instances__instanceId__stop | `...viderId}/requests/{requestId}/instances/{instanceId}/stop` | POST | unknown | none | - | - | daily | unprobed |
| accessReviews_v2_0_approvalWorkflowProviders__providerId__requestsAwaitingMyDecision | `...ovalWorkflowProviders/aadroles/requestsAwaitingMyDecision` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| ListBusinessFlows | `...ews/v2.0/approvalWorkflowProviders/aadroles/businessFlows` | GET | read | none | - | Software.Name, Time.Generated | daily | request-shape-error[400] |
| ListReports | `/accessReviews/v2.0/reports` | GET | read | none | - | - | daily | live-empty[200] |

---

## Portal: `entra-iga`

### Auth

| Field | Value |
|---|---|
| Bucket | C-azure-ad-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `https://elm.iga.azure.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-entra-iga\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\entra-iga.collection.json` (present)

### Sub-areas: 1 · Endpoints: 9 · Live: 2

#### `openapi` [v0.2.0+]

**Sub-area summary:** 9 endpoints · cadence=daily · pagination=none:9 · time-filter coverage=0/9 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| api_v1_accessPackages | `/api/v1/accessPackages` | GET | unknown | none | - | - | daily | live-empty[200] |
| api_v1_accessPackages__accessPackageId | `/api/v1/accessPackages/{accessPackageId}` | GET | unknown | none | - | - | daily | unprobed |
| api_v1_billingConfigurations_guestBilling | `/api/v1/billingConfigurations/guestBilling` | GET/PUT | unknown | none | - | - | 6h | tenant-gated[404] |
| api_v1_catalogs | `/api/v1/catalogs` | GET | unknown | none | - | - | daily | live[200] |
| api_v1_catalogs__catalogId | `/api/v1/catalogs/{catalogId}` | GET | unknown | none | - | - | daily | unprobed |
| api_v1_catalogs__catalogId__resources | `/api/v1/catalogs/{catalogId}/resources` | GET | unknown | none | - | - | daily | unprobed |
| api_v1_connectedOrganizations | `/api/v1/connectedOrganizations` | GET | unknown | none | - | - | daily | server-error[500] |
| api_v1_connectedOrganizations__connectedOrganizationId | `/api/v1/connectedOrganizations/{connectedOrganizationId}` | GET | unknown | none | - | - | daily | unprobed |
| api_v1_settings | `/api/v1/settings` | GET/PATCH | unknown | none | - | - | daily | live[200] |

---

## Portal: `entra-pim`

### Auth

| Field | Value |
|---|---|
| Bucket | C-azure-ad-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `https://api.azrbac.mspim.azure.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-entra-pim\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\entra-pim.collection.json` (present)

### Sub-areas: 1 · Endpoints: 14 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 14 endpoints · cadence=daily · pagination=none:14 · time-filter coverage=0/14 · top entities=Alert.Id, File.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| api_v2_privilegedAccess__provider__activities | `/api/v2/privilegedAccess/aadroles/activities` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| api_v2_privilegedAccess__provider__activities_getExpiredAssignmentAudits_roleAssignmentLevel___level___resourceId___resourceId___subjectId___subjectId | `...evel}',resourceId='{resourceId}',subjectId='{subjectId}')` | GET | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__resources | `/api/v2/privilegedAccess/aadroles/resources` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| api_v2_privilegedAccess__provider__resources__resourceId__alerts | `...privilegedAccess/{provider}/resources/{resourceId}/alerts` | GET | unknown | none | - | - | 1h | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__alerts__alertId | `...Access/{provider}/resources/{resourceId}/alerts/{alertId}` | GET | unknown | none | - | Alert.Id | 1h | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__alerts__alertId__alertIncidents | `...r}/resources/{resourceId}/alerts/{alertId}/alertIncidents` | GET | unknown | none | - | Alert.Id | 1h | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__permissions | `...legedAccess/{provider}/resources/{resourceId}/permissions` | GET | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__roleDefinitions | `...dAccess/{provider}/resources/{resourceId}/roleDefinitions` | GET | unknown | none | - | File.Path | daily | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__roleDefinitions__roleDefinitionId | `...resources/{resourceId}/roleDefinitions/{roleDefinitionId}` | GET | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__roleSettings | `...egedAccess/{provider}/resources/{resourceId}/roleSettings` | GET | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__resources__resourceId__roleSettings__roleSettingId | `...ider}/resources/{resourceId}/roleSettings/{roleSettingId}` | GET/PATCH | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__roleAssignmentRequests | `/api/v2/privilegedAccess/aadroles/roleAssignmentRequests` | GET/POST | unknown | none | - | - | daily | request-shape-error[400] |
| api_v2_privilegedAccess__provider__roleAssignmentRequests__requestId__cancel | `...cess/{provider}/roleAssignmentRequests/{requestId}/cancel` | POST | unknown | none | - | - | daily | unprobed |
| api_v2_privilegedAccess__provider__roleAssignments | `/api/v2/privilegedAccess/aadroles/roleAssignments` | GET | unknown | none | - | - | daily | request-shape-error[400] |

---

## Portal: `exchange`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie |
| ClientId | `4765445b-32c6-49b0-83e6-1d93765276ca` |
| Audience | `(cookie-based, no audience)` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-exchange-beta\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\exchange-beta.collection.json` (present)

### Sub-areas: 1 · Endpoints: 41 · Live: 16

#### `openapi` [v0.2.0+]

**Sub-area summary:** 41 endpoints · cadence=daily · pagination=none:41 · time-filter coverage=0/41 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Bootstrap.GetCmdletInfo | `/beta/CmdletInfo` | GET | unknown | none | - | - | daily | live[200] r=226 |
| Bootstrap.GetMyTimeZone | `/beta/TimeZone/ExchangeAdminCenter.MyTimeZone` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Bootstrap.GetShell | `/beta/Shell` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Bootstrap.GetTenantDataBoundary | `/beta/TenantDataBoundary` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Bootstrap.GetTenantMonitoring | `/beta/TenantMonitoring` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Bootstrap.ListTimeZones | `/beta/TimeZone` | GET | unknown | none | - | - | daily | live[200] r=419 |
| Folders.ListPublicFolderMailboxes | `/beta/PublicFolderMailbox` | GET | unknown | none | - | - | daily | error[403] r=0 |
| Folders.ListPublicFolders | `/beta/PublicFolder` | GET | unknown | none | - | - | daily | error[403] r=0 |
| MailFlow.GetAlertPolicies | `/beta/ProtectionAlert/ExchangeAdminCenter.GetAlertPolicies()` | GET | unknown | none | - | - | daily | live[200] r=2 |
| MailFlow.GetTransportRuleLastExecutionData | `...a/MailflowReport/ExchangeAdminCenter.EtrLastExecutionData` | GET/GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| MailFlow.ListAcceptedDomains | `/beta/AcceptedDomain` | GET | unknown | none | - | - | daily | live[200] r=4 |
| MailFlow.ListAcceptedDomainsFull | `/beta/AcceptedDomainFullListIC` | GET | unknown | none | - | - | daily | live[200] r=4 |
| MailFlow.ListHistoricalSearches | `/beta/HistoricalSearch` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| MailFlow.ListInboundConnectors | `/beta/InboundConnector` | GET | unknown | none | - | - | daily | error[500] r=0 |
| MailFlow.ListOutboundConnectors | `/beta/OutboundConnector` | GET | unknown | none | - | - | daily | error[500] r=0 |
| MailFlow.ListRemoteDomains | `/beta/RemoteDomain` | GET | unknown | none | - | - | daily | error[412] r=0 |
| MailFlow.ListTransportRules | `/beta/TransportRule` | GET/GET/GET/GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| Migration.ListMigrationBatches | `/beta/MigrationBatch` | GET | unknown | none | - | - | daily | error[412] r=0 |
| Migration.ListMigrationEndpoints | `/beta/MigrationEndpoint` | GET | unknown | none | - | - | daily | error[412] r=0 |
| Mobile.ListActiveSyncDeviceAccessRules | `/beta/ActiveSyncDeviceAccessRule` | GET | unknown | none | - | - | daily | error[500] r=0 |
| Mobile.ListActiveSyncDeviceClasses | `/beta/ActiveSyncDeviceClass` | GET | unknown | none | - | - | daily | error[500] r=0 |
| Mobile.ListMobileDeviceMailboxPolicies | `/beta/MobileDeviceMailboxPolicy` | GET | unknown | none | - | - | daily | error[500] r=0 |
| Mobile.ListMobileDevices | `/beta/MobileDevice` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| Objects.GetRecipientsIC | `/beta/Recipient/ExchangeAdminCenter.GetRecipientsIC` | GET | unknown | none | - | - | daily | live[200] r=3 |
| Objects.ListAddressBookPolicies | `/beta/AddressBookPolicy` | GET | unknown | none | - | - | daily | error[500] r=0 |
| Objects.ListDynamicDistributionGroups | `/beta/DynamicDistributionGroupIC` | GET | unknown | none | - | - | daily | error[403] r=0 |
| Objects.ListMailContacts | `/beta/MailContact` | GET | unknown | none | - | - | daily | live[200] r=2 |
| Objects.ListMailUsersIC | `/beta/MailUserIC` | GET | unknown | none | - | - | daily | error[403] r=0 |
| Objects.ListOwaMailboxPolicies | `/beta/OwaMailboxPolicy` | GET/GET/GET/GET | unknown | none | - | - | daily | error[403] r=0 |
| Objects.ListRecipients | `/beta/Recipient` | GET/GET/GET/GET/GET/GET/GET | unknown | none | - | - | daily | live[200] r=3 |
| Objects.ListResourceMailboxes | `/beta/ResourceMailbox` | GET/GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| Preferences.GetFeedbackAccessToken | `.../UserProfile/ExchangeAdminCenter.GetFeedbackAccessToken()` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Preferences.GetFeedbackAttribute | `/beta/UserProfile/ExchangeAdminCenter.GetFeedbackAttribute()` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Preferences.GetOCPSAccessToken | `/beta/UserProfile/ExchangeAdminCenter.GetOCPSAccessToken()` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Preferences.GetUserProfile | `/beta/UserProfile` | GET | unknown | none | - | - | daily | live[200] r=1 |
| Preferences.UpsertUserPreference | `/beta/UserPreference` | POST/GET/GET/GET | unknown | none | - | - | daily | error[500] r=0 |
| Roles.ListManagementRoles | `/beta/ManagementRoleV2` | GET | unknown | none | - | - | daily | error[403] r=0 |
| Roles.ListRoleAssignments | `/beta/RoleAssignments` | GET/GET | unknown | none | - | - | daily | error[500] r=0 |
| Roles.ListRoleGroups | `/beta/RoleGroup` | GET | unknown | none | - | - | daily | error[403] r=0 |
| Sharing.ListIndividualSharingPolicies | `/beta/IndividualSharing` | GET/GET | unknown | none | - | - | daily | error[403] r=0 |
| Sharing.ListOrganizationRelationships | `/beta/OrganizationRelationship` | GET/GET | unknown | none | - | - | daily | error[403] r=0 |

---

## Portal: `intune-autopatch`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `https://services.autopatch.microsoft.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-intune-autopatch\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\intune-autopatch.collection.json` (present)

### Sub-areas: 1 · Endpoints: 49 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 49 endpoints · cadence=daily · pagination=none:49 · time-filter coverage=0/49 · top entities=Tenant.Id, Url.Path, Policy.Id, File.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AutopatchGroups.List | `/device/v2/autopatchGroups` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| AutopatchGroups.ListMembershipRegistered | `...ed-reporting/odata/1.0/AutopatchGroupMembershipRegistered` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Messages.ListCustomerComms | `/support/v1/Messages/CustomerComms` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Platform.GetFlighting | `/api/Flighting` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Reporting.GetExportStatus | `/reporting/reports/v1/export/status/` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| Reporting.GetFeatureUpdateDistinctColumns | `...eports/v2/windowsFeatureUpdates/distinct/planTypes/{plan}` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.GetFeatureUpdateSummaryMetrics | `/reporting/reports/v2/windowsFeatureUpdates/summaryMetrics` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.GetManagementStatusSummaryOData | `...fied-reporting/odata/1.0/AutopatchManagementStatusSummary` | GET | unknown | none | - | Tenant.Id | daily | tenant-gated[401] |
| Reporting.GetQualityUpdateDistinctColumns | `.../reports/v2/deviceAccounting/wqu/distinct/selectedColumns` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.GetQualityUpdateSummaryMetrics | `/reporting/reports/v2/deviceAccounting/wqu/summaryMetrics` | POST | unknown | none | - | Tenant.Id | daily | unprobed |
| Reporting.ListFeatureUpdateCompletionReleases | `...ting/reports/v2/windowsFeatureUpdates/completion/releases` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListFeatureUpdateDetails | `/reporting/reports/v2/windowsFeatureUpdates/details` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListFeatureUpdateDistinctColumnsOData | `...-reporting/odata/1.0/WindowsFeatureUpdatesDistinctColumns` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Reporting.ListFeatureUpdatePhases | `/reporting/reports/v2/windowsFeatureUpdates/summary/phases` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListFeatureUpdateReleases | `/reporting/reports/v2/windowsFeatureUpdates/summary/releases` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListFeatureUpdateSummaryMetricsOData | `...d-reporting/odata/1.0/WindowsFeatureUpdatesSummaryMetrics` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Reporting.ListFeatureUpdateSummaryReleaseOData | `...d-reporting/odata/1.0/WindowsFeatureUpdatesSummaryRelease` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Reporting.ListFeatureUpdateTrending | `/reporting/reports/v2/windowsFeatureUpdates/trending` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListFeatureUpdateTrendingOData | `/unified-reporting/odata/1.0/WindowsFeatureUpdatesTrending` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Reporting.ListQualityUpdateBusinessGroups | `...ng/reports/v2/deviceAccounting/wqu/summary/businessgroups` | POST | unknown | none | - | Policy.Id, Tenant.Id | daily | unprobed |
| Reporting.ListQualityUpdateDeploymentGroups | `.../reports/v2/deviceAccounting/wqu/summary/deploymentgroups` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListQualityUpdateDetails | `/reporting/reports/v2/deviceAccounting/wqu/details` | POST | unknown | none | - | - | daily | unprobed |
| Reporting.ListQualityUpdateTrending | `/reporting/reports/v2/deviceAccounting/wqu/trending` | POST | unknown | none | - | Tenant.Id | daily | unprobed |
| Reporting.StartFeatureUpdateDetailsExport | `/reporting/reports/v2/windowsFeatureUpdates/detailsExport` | POST | unknown | none | - | Url.Path | daily | unprobed |
| Reporting.StartQualityUpdateDetailsExport | `/reporting/reports/v2/deviceAccounting/wqu/detailsExport` | POST | unknown | none | - | Url.Path | daily | unprobed |
| Roles.GetEffectivePermissions | `/access-control/odata/v1/EffectivePermissions` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Roles.GetScopedForResources | `/access-control/odata/v1/ScopedForResources` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Roles.GetScopeTags | `/access-control/odata/v1/ScopeTags` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Roles.GetUserToken | `/access-control/v1/UserToken` | GET | unknown | none | - | File.Path | daily | tenant-gated[401] |
| Roles.ListResourceOperations | `/access-control/odata/v1/ResourceOperations` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Roles.ListRoleAssignments | `/access-control/odata/v1/RoleAssignments` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Roles.ListRoleDefinitions | `/access-control/odata/v1/RoleDefinitions` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Support.AddSupportRequestNote | `...rt/odata/v1/supportRequests('{supportRequestId}')/addNote` | POST | unknown | none | - | - | daily | unprobed |
| Support.GetEntitlementInfo | `/support/v1/tenants/getSupportEntitlementInfo` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Support.GetRequestTypeHierarchy | `/support/v1/RequestTypeHierarchy` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Support.GetSupportRequest | `/support/odata/v1/supportRequests('{supportRequestId}')` | GET/PATCH | unknown | none | - | - | daily | unprobed |
| Support.GetTenantManagedService | `/support/v1.0/Tenants/GetTenantManagedService/{plan}` | GET | unknown | none | - | - | daily | unprobed |
| Support.ListLanguages | `/support/v1/Languages` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Support.ListSupportRequestActivities | `...odata/v1/supportRequests('{supportRequestId}')/activities` | GET | unknown | none | - | - | daily | unprobed |
| Support.ListSupportRequests | `/support/odata/v1/supportRequests` | GET/POST | unknown | none | - | - | daily | tenant-gated[401] |
| Support.ReactivateSupportRequest | `...odata/v1/supportRequests('{supportRequestId}')/Reactivate` | POST | unknown | none | - | - | daily | unprobed |
| Support.UpdateSupportRequestContact | `...ta/v1/supportRequests('{supportRequestId}')/UpdateContact` | POST | unknown | none | - | - | daily | unprobed |
| Support.UploadSupportRequestAttachment | `...v1/supportRequests('{supportRequestId}')/UploadAttachment` | POST | unknown | none | - | - | daily | unprobed |
| Tenant.GetAdminActionStatus | `/tenant-management/v2/AdminActionsV/actionStatus` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Tenant.GetFeatureEnablementStatus | `...-management/v1/Enrollment/Starter/featureEnablementStatus` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Tenant.GetMdmAppSettings | `...management/partnergraph/1.0/tenantSettings/mdmAppSettings` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Tenant.GetSetting | `/tenant-management/v1/TenantSetting` | GET/POST | unknown | none | - | Tenant.Id | daily | tenant-gated[401] |
| Tenant.ListAdminActions | `/tenant-management/v2/AdminActionsV` | GET/POST | unknown | none | - | - | daily | tenant-gated[401] |
| Tenant.Resolve | `/api/v1.0/tenant/resolve` | GET | unknown | none | - | - | daily | tenant-gated[401] |

---

## Portal: `intune-portal`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c` |
| Audience | `TBD: try https://intune.microsoft.com, https://api.manage.microsoft.com, or use existing Intune-service-API resource` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-intune-portal\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\intune-portal.collection.json` (present)

### Sub-areas: 1 · Endpoints: 5 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=0/5 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Experimentation.GetExtensionVariants | `/api/Experimentation/GetExtensionVariants` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| Portal.GetEarlyUserData | `/api/Portal/GetEarlyUserData` | POST | unknown | none | - | - | weekly | unprobed |
| Portal.GetLazyUserData | `/api/Portal/GetLazyUserData` | POST | unknown | none | - | - | weekly | unprobed |
| Settings.Select | `/api/Settings/Select` | POST | write | none | - | - | daily | unprobed |
| Settings.Update | `/api/Settings/Update` | POST | write | none | - | - | daily | unprobed |

---

## Portal: `m365-admin`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie+B-bearer-hybrid |
| ClientId | `4765445b-32c6-49b0-83e6-1d93765276ca` |
| Audience | `https://admin.microsoft.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-m365-admin\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\m365-admin.collection.json` (present)

### Sub-areas: 24 · Endpoints: 251 · Live: 82

#### `agents` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAgentTemplates | `/admin/api/agenttemplates/getagenttemplates` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetEntitiesAtRisk | `/admin/api/agentusers/metrics/agents/entitiesAtRisk` | POST | read | none | - | - | daily | unprobed |
| GetFrontierAccess | `/admin/api/settings/company/frontier/access` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetMcpServers | `/admin/api/agentssettings/mcpservers` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetRiskyAgents | `/admin/api/agentusers/metrics/agents/risky` | GET | read | none | - | - | daily | server-error[500] |
| GetTemplatePolicies | `/admin/api/agenttemplates/getpolicies` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `app_settings` [v0.2.0+]

**Sub-area summary:** 32 endpoints · cadence=daily · pagination=none:32 · time-filter coverage=0/32 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetBookings | `/admin/api/settings/apps/bookings` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetBriefing | `/admin/api/settings/apps/briefing` | GET/POST | read | none | - | - | daily | tenant-gated[404] |
| GetCalendarSharing | `/admin/api/settings/apps/calendarsharing` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetCortana | `/admin/api/settings/apps/cortana` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetCortanaService | `/admin/api/services/apps/cortana` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetEndUserCommunications | `/admin/api/settings/apps/EndUserCommunications` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetLearning | `/admin/api/settings/apps/learning` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetM365Groups | `/admin/api/settings/apps/m365groups` | GET/POST | read | none | - | - | daily | tenant-gated[404] |
| GetM365Lighthouse | `/admin/api/services/apps/m365lighthouse` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetMail | `/admin/api/settings/apps/mail` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetMicrosoftLoop | `/admin/api/settings/apps/MicrosoftLoop` | GET/POST | read | none | - | - | daily | tenant-gated[404] |
| GetModernAuth | `/admin/api/services/apps/modernAuth` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetMyAnalytics | `/admin/api/services/apps/myanalytics` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetO365DataPlan | `/admin/api/settings/apps/o365dataplan` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetOfficeForms | `/admin/api/settings/apps/officeforms` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetOfficeOnline | `/admin/api/settings/apps/officeonline` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetOfficeOnTheWeb | `/admin/api/settings/apps/officeontheweb` | GET/POST | read | none | - | - | daily | tenant-gated[404] |
| GetOfficeOnTheWebPolicies | `/fd/ocps/user/v1.0/web/policies` | GET | read | none | - | - | daily | live[200] |
| GetPlanner | `/admin/api/settings/apps/planner` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetPlannerService | `/admin/api/services/apps/planner` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSitesSharing | `/admin/api/settings/apps/sitessharing` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetStore | `/admin/api/settings/apps/store` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetSway | `/admin/api/settings/apps/sway` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetTeams | `/admin/api/settings/apps/skypeteams` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetTeamsClientConfiguration | `...nfig/Skype.Policy/configurations/TeamsClientConfiguration` | GET | read | none | - | - | 6h | tenant-gated[403] |
| GetTeamsProvisioningCustomization | `/admin/api/TeamsProvisioning/Customization` | GET | read | none | - | - | daily | live[200] |
| GetToDo | `/admin/api/settings/apps/todo` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetToDoService | `/admin/api/services/apps/todo` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetUserOwnedApps | `/admin/api/settings/apps/userownedapps` | GET/POST | read | none | - | - | daily | tenant-gated[404] |
| GetUserSoftware | `/admin/api/settings/apps/usersoftware` | GET | read | none | - | - | daily | live[200] |
| GetVivaInsights | `/admin/api/services/apps/vivainsights` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetWhiteboard | `/admin/api/settings/apps/whiteboard` | GET/POST | read | none | - | - | daily | tenant-gated[403] |

#### `billing` [v0.2.0+]

**Sub-area summary:** 17 endpoints · cadence=daily · pagination=none:17 · time-filter coverage=2/17 · top entities=Software.Version, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| BrowseMarketplaceCatalog | `/fd/bsxcommerce/v1/moderncatalog/browsecatalog` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| BrowseMarketplaceCatalogPreview | `/fd/bsxcommerce/v1/moderncatalog/browsecatalogforpreview` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| GetBillingAccount | `...ders/Microsoft.Billing/billingAccounts/{billingAccountId}` | GET | read | none | - | Software.Version | daily | unprobed |
| GetBillingModel | `/admin/api/billing/BillingModel` | GET | read | none | - | - | daily | live[200] |
| GetMarketplaceMarketingGroups | `/fd/bsxcommerce/v1/moderncatalog/marketinggroups` | GET | read | none | - | Software.Name | daily | tenant-gated[401] |
| GetMarketplacePrices | `/fd/bsxcommerce/v1/moderncatalog/new/prices` | GET | read | none | - | Software.Name | daily | tenant-gated[404] |
| GetMicrosoft365BackupFeature | `/_api/v2.1/billingFeatures('M365Backup')` | GET | read | none | - | - | daily | live[200] |
| GetModernCommerceFootprint | `/fd/commerceMgmt/moderncommerce/footprint` | GET | read | none | - | Software.Version | daily | server-error[500] |
| GetPurchaseServiceFieldLedFlag | `/fd/commerceapi/my-org/purchaseService.isFieldLedDeschutes` | GET | read | none | - | - | daily | live[200] |
| GetSyntexSubscriptionPermissions | `...exbilling/azureSubscriptions/{subscriptionId}/permissions` | GET | read | none | - | - | daily | unprobed |
| GetVolumeLicensingPermissions | `/fd/storeForBusinessMgmt/bd-prod/agreements/vlpermissions` | GET | read | none | - | Software.Version | daily | live[200] |
| ListBillingProfiles | `...illing/billingAccounts/{billingAccountId}/billingProfiles` | GET | read | none | - | Software.Version | daily | unprobed |
| ListBillingRoleAssignments | `...billingAccounts/{billingAccountId}/billingRoleAssignments` | GET | read | none | - | Software.Version | daily | unprobed |
| ListBillingSubscriptions | `...g/billingAccounts/{billingAccountId}/billingSubscriptions` | GET | read | none | - | Software.Name, Software.Version | daily | unprobed |
| ListLicensedProducts | `/fd/m365licensing/v3/licensedProducts` | GET | read | none | - | Software.Name | daily | live[200] |
| ListMarketplaceCategories | `/fd/bsxcommerce/v1/moderncatalog/listcategories` | GET | read | none | - | - | daily | tenant-gated[401] |
| ListSoftwareKeys | `/fd/KeyFulfillment/v3.0/softwareKeys` | GET | read | none | - | Software.Name | daily | live[200] |

#### `company_settings` [v0.2.0+]

**Sub-area summary:** 11 endpoints · cadence=daily · pagination=none:11 · time-filter coverage=0/11 · top entities=Software.Name, Url.Path, Url.Domain, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetBrandCenterConfiguration | `/_api/spo.tenant/GetBrandCenterConfiguration` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetBrandCenterSiteUrl | `/_api/GroupSiteManager/GetValidSiteUrlFromAlias` | GET | read | none | - | Url.Path | daily | request-shape-error[400] |
| GetHelpdesk | `/admin/api/Settings/company/helpdesk` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetProfile | `/admin/api/Settings/company/profile` | GET/POST | read | none | - | - | daily | live[200] |
| GetReleaseTrack | `/admin/api/Settings/company/releasetrack` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetSendFromAddress | `/admin/api/Settings/company/sendfromaddress` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetSharePointAutoQuotaEnabled | `...i/SPOInternalUseOnly.TenantAdminSettings/AutoQuotaEnabled` | GET/PUT | read | none | - | - | daily | tenant-gated[403] |
| GetSharePointInternalTenantSettings | `/_api/SPOInternalUseOnly.Tenant` | GET | read | none | - | Url.Domain | daily | tenant-gated[404] |
| GetSharePointSiteCreationSources | `/_api/SPO.Tenant/GetSPOSiteCreationSources` | GET | read | none | - | File.Name, Software.Name | daily | tenant-gated[403] |
| GetTheme | `/admin/api/Settings/company/theme/v2` | GET | read | none | - | - | daily | live[200] |
| GetTile | `/admin/api/Settings/company/tile` | GET/POST | read | none | - | - | daily | live[200] |

#### `content_understanding` [v0.2.0+]

**Sub-area summary:** 10 endpoints · cadence=daily · pagination=none:10 · time-filter coverage=0/10 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAutoFill | `/admin/api/contentunderstanding/autofillsetting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetBillingSettings | `/admin/api/contentunderstanding/billingSettings` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetESignature | `/admin/api/contentunderstanding/esignaturesettings` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetImageTagging | `/admin/api/contentunderstanding/imagetaggingsetting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetLicensing | `/admin/api/contentunderstanding/licensing` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetPowerAppsEnvironments | `/admin/api/contentunderstanding/powerAppsEnvironments` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSetting | `/admin/api/contentunderstanding/setting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSyntexBillingSubscriptions | `/admin/api/syntexbilling/azureSubscriptions` | GET | read | none | - | - | daily | live[200] |
| GetTaxonomyTagging | `/admin/api/contentunderstanding/taxonomytaggingsetting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetTranscriptTranslation | `...ontentunderstanding/playbacktranscripttranslationsettings` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `copilot` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetDismissedSettings | `/admin/api/copilotsettings/settings/dismissed` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetLicenseAssignmentDate | `/admin/api/Copilot/getcopilotlicenseassignmentdate` | GET | read | none | - | - | daily | live[200] |
| GetPinPolicy | `/admin/api/settings/company/copilotpolicy/pin` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetSecurityCopilotAuth | `/admin/api/copilotsettings/securitycopilot/auth` | GET | read | none | - | - | daily | live[200] |
| GetSettings | `/admin/api/copilotsettings/settings` | GET | read | none | - | - | daily | live[200] |
| GetShowColorCopilotIcon | `/admin/api/m365copilot/ShowColorCopilotIcon` | GET | read | none | - | - | daily | live[200] |

#### `domains` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=0/5 · top entities=Url.Domain, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ExportDomainRecords | `/admin/api/Domains/Records/Export` | GET | read | none | - | Url.Domain | daily | tenant-gated[404] |
| GetDomainBuyModel | `/admin/api/Domains/GetDomainBuyModel` | GET | read | none | - | Url.Domain | daily | live[200] |
| GetDomainListCustomization | `/admin/api/DomainList/Customization` | GET | read | none | - | Url.Domain | daily | live[200] |
| GetVerifiedDomains | `/admin/api/Domains/Verified` | GET | read | none | - | File.Name | daily | server-error[500] |
| ListDomains | `/admin/api/Domains/List` | GET | read | none | - | File.Name, Url.Domain | daily | tenant-gated[403] |

#### `edge` [v0.2.0+]

**Sub-area summary:** 13 endpoints · cadence=daily · pagination=none:13 · time-filter coverage=0/13 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetBrowserPolicies | `/fd/OfficePolicyAdmin/v1.0/edge/policies` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetExtensionFeatureFlags | `...dgeenterpriseextensionsmanagement/api/config/featureflags` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetExtensionFeedback | `...riseextensionsmanagement/api/extensions/extensionFeedback` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetExtensionPolicies | `/fd/edgeenterpriseextensionsmanagement/api/policies` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetFeatureManagementShard | `...nterpriseextensionsmanagement/api/featureManagement/shard` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetIEModeSiteLists | `/fd/edgeenterprisesitemanagement/api/v2/emiesitelists` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetPolicyWithPayload | `...ficePolicyAdmin/v1.0/edge/policies/{id}/policywithpayload` | GET | read | none | - | - | daily | unprobed |
| GetSecurityInsightsNotificationPreferences | `...ionsmanagement/security-insights/notification-preferences` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetTelemetryDeviceCount | `...nterpriseextensionsmanagement/api/telemetry/devices/count` | GET | read | none | lookback=lookbackHours type=duration-units-from-now | - | daily | tenant-gated[403] |
| GetVersionUpdate | `/fd/edgeenterpriseextensionsmanagement/api/version/update` | GET | read | none | - | Software.Version | daily | tenant-gated[403] |
| ListFeatureManagementProfiles | `...rpriseextensionsmanagement/api/featureManagement/profiles` | GET | read | none | - | - | daily | tenant-gated[403] |
| ListReleaseVersions | `/fd/edgeenterpriseextensionsmanagement/api/version/releases` | GET | read | none | - | Software.Version | daily | tenant-gated[403] |
| ListTelemetryDeviceReportVersions | `...tensionsmanagement/api/telemetry/devices/reports/versions` | GET | read | none | - | Software.Version | daily | tenant-gated[403] |

#### `features` [v0.2.0+]

**Sub-area summary:** 4 endpoints · cadence=daily · pagination=none:4 · time-filter coverage=0/4 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAdminContentCdnImagePath | `/admin/api/features/admincontentcdnimagepath` | GET | read | none | - | - | daily | live[200] |
| GetAll | `/admin/api/features/all` | GET | read | none | - | - | daily | live[200] |
| GetConfig | `/admin/api/features/config` | GET | read | none | - | - | daily | live[200] |
| GetInitialLoad | `/admin/api/features/initialload` | GET | read | none | - | - | daily | live[200] |

#### `graph_proxy` [v0.2.0+]

**Sub-area summary:** 13 endpoints · cadence=6h · pagination=topSkip:2 / none:11 · time-filter coverage=2/13 · top entities=Time.Generated, Software.Name, Url.Full, Url.Path, Account.AadId · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Batch | `/fd/msgraph/beta/$batch` | POST | unknown | none | - | Url.Full, Url.Path | daily | unprobed |
| BatchV1 | `/fd/msgraph/v1.0/$batch` | POST | unknown | none | - | Url.Full, Url.Path | daily | unprobed |
| GetBackupEmailNotificationsSetting | `...ph/beta/solutions/backupRestore/emailNotificationsSetting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetBackupProtectionPolicies | `/fd/msgraph/beta/solutions/backupRestore/protectionPolicies` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetBackupRestoreSolution | `/fd/msgraph/beta/solutions/backupRestore` | GET | read | none | - | Time.Generated | daily | tenant-gated[403] |
| GetCloudAppDiscoveryAggregatedAppsDetails | `...aph.security.aggregatedAppsDetails(period=duration'P90D')` | GET | read | none | - | Host.RiskScore, Software.Name | daily | unprobed |
| GetDeviceManagementRoot | `/fd/msgraph/beta/deviceManagement` | GET | read | none | - | - | daily | live[200] |
| GetDevices | `/fd/msgraph/v1.0/devices` | GET | read | none | - | - | daily | live-empty[200] |
| GetDevicesCount | `/fd/msgraph/v1.0/devices/$count` | GET | read | none | - | - | daily | request-shape-error[400] |
| GetSubscribedSkus | `/fd/msgraph/v1.0/subscribedSkus` | GET | read | none | - | - | daily | live[200] |
| GetUserCommercePreferencesExtension | `...er@CloudSectra.com/extensions/commerce.Common.Preferences` | GET | read | none | - | Account.AadId | daily | tenant-gated[404] |
| ListCloudAppDiscoveryUploadedStreams | `.../security/dataDiscovery/cloudAppDiscovery/uploadedStreams` | GET | read | none | - | Software.Name, Time.Generated | daily | tenant-gated[401] |
| ListDeviceManagementConfigurationPolicies | `/fd/msgraph/beta/deviceManagement/configurationPolicies` | GET | read | continuationToken (tok=$skiptoken) | - | - | 6h | live-empty[200] |

#### `health` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=0/7 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetActiveCM | `/admin/api/servicehealth/status/activeCM` | GET | read | none | - | - | daily | live[200] |
| GetConfiguration | `/admin/api/messagecenter/configuration` | GET | read | none | - | - | 6h | live[200] |
| GetDisplayPreferences | `/admin/api/servicehealth/getDisplayPreferences` | GET | read | none | - | - | daily | live[200] |
| GetMessages | `/admin/api/messagecenter` | GET | read | none | - | - | daily | live[200] |
| GetPlannerIntegrationPreferences | `/admin/api/messagecenter/GetPlannerIntegrationPreferences` | GET | read | none | - | - | daily | tenant-gated[404] |
| GetPlannerIntegrationTaskSet | `/admin/api/messagecenter/GetPlannerIntegrationTaskSet` | GET | read | none | - | - | daily | live[200] |
| UpdateActivities | `/admin/api/messagecenter/activities` | PUT | write | none | - | - | daily | unprobed |

#### `identity_security` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetSecurityDefaults | `/admin/api/identitysecurity/securitydefaults` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `integrated_apps` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=limitOffset:2 / none:5 · time-filter coverage=0/7 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetActionableApps | `/fd/addins/api/actionableApps` | GET | read | none | - | - | daily | live[200] |
| GetAddInDetails | `/admin/api/privatecatalog/GetAddInDetails` | POST | read | none | - | - | daily | unprobed |
| GetAgents | `/fd/addins/api/agents` | GET | read | none | - | - | daily | live[200] |
| GetApps | `/fd/addins/api/apps` | GET | read | none | - | - | daily | live[200] |
| GetAvailableApps | `/fd/addins/api/availableApps` | GET | read | none | - | - | daily | network-error |
| GetRecommendations | `/fd/addins/api/recommendations/appRecommendations` | GET | read | none | - | - | daily | live[200] |
| GetSettings | `/fd/addins/api/v2/settings` | GET | read | none | - | - | daily | live[200] |

#### `miscellaneous` [v0.2.0+]

**Sub-area summary:** 22 endpoints · cadence=daily · pagination=none:22 · time-filter coverage=0/22 · top entities=File.Path, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| BlockGenAIRecommendationView | `...in/api/recommendations/m365/BlockGenAIRecommendation/view` | POST | unknown | none | - | - | daily | unprobed |
| GetA365Conversion | `/admin/api/a365conversion` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetAdminDashboardTenantSettings | `/admin/api/admindashboard/tenantsettings` | GET | read | none | - | - | daily | live[200] |
| GetARMBillingAccounts | `/fd/arm/providers/Microsoft.Billing/billingAccounts` | GET | read | none | - | Software.Version | daily | live-empty[200] |
| GetDirSyncErrors | `/admin/api/dirsyncerrors/listdirsyncerrors` | POST | read | none | - | File.Path | daily | unprobed |
| GetDirSyncManagement | `/admin/api/DirsyncManagement/manage` | GET | read | none | - | File.Path | daily | live[200] |
| GetEnhancedRestoreSettings | `/fd/enhancedRestorev2/v1/featureSetting` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetHomeDataStream | `/adminportal/home/ClassicModernAdminDataStream` | GET | read | none | - | - | weekly | live[200] |
| GetIrisPlacement | `/fd/iris` | GET | read | none | - | - | daily | server-error[500] |
| GetIrisRecommendations | `/admin/api/irisrecommendations/v1` | GET | read | none | - | - | daily | live[200] |
| GetM365Alerts | `/admin/api/recommendations/m365alerts` | GET | read | none | - | - | 1h | live[200] |
| GetM365Recommendations | `/admin/api/recommendations/m365` | GET | read | none | - | - | daily | live[200] |
| GetM365Suggestions | `/admin/api/recommendations/m365suggestions` | GET | read | none | - | - | daily | live[200] |
| GetMarketplaceOfferRecommendation | `/admin/api/offerrec/marketplaceoffer` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetNotifications | `/admin/api/notifications` | GET | read | none | - | - | daily | live[200] |
| GetOfferRecommendation | `/admin/api/offerrec/offer/{id}` | GET | read | none | - | - | daily | unprobed |
| GetRecommendations | `/admin/api/recommendations/m365/ccs` | GET | read | none | - | - | daily | live[200] |
| GetRememberPreferences | `/admin/api/rememberpreferences` | GET | read | none | - | - | daily | live[200] |
| GetSetupBanner | `/admin/api/setupwizard/setupbanner` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetShellInfo | `/admin/api/coordinatedbootstrap/shellinfo` | GET | read | none | - | - | daily | live[200] |
| GetUxVersion | `/admin/api/uxversion` | GET | read | none | - | Software.Version | daily | live[200] |
| HasObjectsWithDirSyncErrors | `/admin/api/DirsyncManagement/hasobjectswithdirsyncerrors` | GET | unknown | none | - | File.Path | daily | live[200] |

#### `navigation` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAsyncNavigation | `/admin/api/navigation/async` | GET | read | none | - | - | daily | live[200] |
| GetDarkMode | `/admin/api/navigation/darkmode` | GET | read | none | - | - | daily | live[200] |
| GetNavigation | `/admin/api/navigation` | GET | read | none | - | - | daily | live[200] |

#### `partners` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=0/5 · top entities=File.Path, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAOBOClients | `/admin/api/partners/AOBOClients` | GET | read | none | - | - | daily | live[200] |
| ListCustomerGranularAdminRelationships | `...ServiceAdminApi/Web/v1/CustomerGranularAdminRelationships` | GET | read | none | - | - | daily | live-empty[200] |
| ListDirectoryPartners | `/fd/MSGraph/beta/directory/partners` | GET | read | none | - | File.Path | daily | live-empty[200] |
| ListJarvisCommerceProfiles | `/fd/jarvisCM/my-org/profiles` | GET | read | none | - | - | daily | request-shape-error[400] |
| ListPartnerManagedPartners | `/fd/commerceMgmt2/partnermanage/partners` | GET | read | none | - | Software.Version | daily | server-error[500] |

#### `purview` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=1/5 · top entities=Tenant.Id, Time.Generated, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAIBaselineSummary | `/fd/purview/apiproxy/cpm/v1.0/Tenant/AIBaselineSummary` | GET | read | none | - | Software.Version, Tenant.Id | daily | request-shape-error[400] |
| GetDlpPolicies | `/fd/purview/apiproxy/di/find/DlpCompliancePolicy` | GET | read | none | - | Tenant.Id | daily | tenant-gated[403] |
| GetNexusBootInfo | `/fd/purview/api/boot/getNexusBootInfo` | GET | read | none | - | - | daily | live[200] |
| GetPurviewForAI | `/fd/purview/apiproxy/di/find/PurviewForAI` | GET | read | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | tenant-gated[403] |
| GetSensitiveInfoTypes | `/fd/purview/apiproxy/di/find/DlpSensitiveInformationType` | GET | read | none | - | Tenant.Id | daily | tenant-gated[403] |

#### `reports` [v0.2.0+]

**Sub-area summary:** 9 endpoints · cadence=daily · pagination=pageIndex0Based:1 / none:8 · time-filter coverage=0/9 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAdminDashboardPreferences | `/admin/api/admindashboard/preferences` | GET | read | none | - | - | daily | live[200] |
| GetProductivityScoreConfig | `...eports/productivityScoreConfig/GetProductivityScoreConfig` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetProductivityScoreCustomerOption | `/admin/api/reports/productivityScoreCustomerOption` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetReportCategoryDetails | `/admin/api/reports/GetReportCategoryDetails` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetReportData | `/admin/api/reports/GetReportData` | GET | read | none | - | - | daily | live[200] |
| GetReportsWidgetConfig | `/admin/api/reports/GetReportsWidgetConfig` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetReportTileData | `/admin/api/reports/GetReportTileData` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSummaryDataV3 | `/admin/api/reports/GetSummaryDataV3` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetTenantConfiguration | `/admin/api/reports/config/GetTenantConfiguration` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `search` [v0.2.0+]

**Sub-area summary:** 13 endpoints · cadence=daily · pagination=none:13 · time-filter coverage=0/13 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetBingNewsOptions | `/admin/api/searchadminapi/news/options/Bing` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetConfigurations | `/admin/api/searchadminapi/configurations` | GET | read | none | - | - | 6h | tenant-gated[403] |
| GetConnectionStatistics | `/fd/mssearchconnectors/v1.0/admin/connections/getStatistics` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetConnectorAdminUxOptions | `/fd/mssearchconnectors/v1.0/admin/AdminUxOptions` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetConnectorsSummary | `/admin/api/searchadminapi/UDTConnectorsSummary` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetFirstRunExperience | `/admin/api/searchadminapi/firstrunexperience/get` | POST | read | none | - | - | daily | unprobed |
| GetInsightsGenericReport | `...rchinsights/api/v1/{tenantId}/TenantReports/GenericReport` | POST | read | none | - | Tenant.Id | daily | unprobed |
| GetInsightsReportStatus | `...v1/45f52f35-73d5-4066-8378-fe506ee90fb1/status/reportdata` | GET | read | none | - | Tenant.Id | daily | tenant-gated[403] |
| GetQnas | `/admin/api/searchadminapi/Qnas` | POST | read | none | - | - | daily | unprobed |
| GetSearchIntelligenceHomeCards | `/admin/api/searchadminapi/searchintelligencehome/cards` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSubstrateBookmarks | `/fd/substrateBookmarks/api/v3/management/bookmarks` | POST | read | none | - | - | daily | unprobed |
| GetTenantAcronyms | `/fd/substrateAcronyms/api/v1.0/GetTenantAdminAcronymsFromSds` | POST | read | none | - | - | daily | unprobed |
| ListConnectorConnections | `/fd/mssearchconnectors/v1.0/admin/connections` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `security_settings` [v0.2.0+]

**Sub-area summary:** 9 endpoints · cadence=daily · pagination=none:9 · time-filter coverage=0/9 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetDataAccess | `/admin/api/settings/security/dataaccess` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetGuestUserPolicy | `/admin/api/Settings/security/guestUserPolicy` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetO365GuestUser | `/admin/api/Settings/security/o365guestuser` | GET/POST | read | none | - | - | daily | tenant-gated[403] |
| GetPasswordPolicy | `/admin/api/settings/security/passwordpolicy` | GET | read | none | - | - | daily | live[200] |
| GetPrivacyPolicy | `/admin/api/settings/security/privacypolicy` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSecurityControlsCatalog | `/admin/api/securitysettings/settings` | GET | read | none | - | - | daily | live[200] |
| GetSecurityControlsOptIn | `/admin/api/securitysettings/optIn` | GET | read | none | - | - | daily | server-error[500] |
| GetSecurityControlsStatus | `/admin/api/securitysettings/settings/status` | GET | read | none | - | - | daily | live[200] |
| GetTenantLockbox | `/admin/api/settings/security/tenantLockbox` | GET | read | none | - | - | daily | tenant-gated[403] |

#### `tenant` [v0.2.0+]

**Sub-area summary:** 15 endpoints · cadence=daily · pagination=none:15 · time-filter coverage=0/15 · top entities=Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAzureSubscriptions | `/admin/api/tenant/azureSubscriptions` | GET | read | none | - | - | daily | live[200] |
| GetBillingAccounts | `/admin/api/tenant/billingAccountsWithShell` | GET | read | none | - | - | daily | live-empty[200] |
| GetCustomViewFilterDefaults | `/admin/api/tenant/customviewfilterdefaults` | GET | read | none | - | - | daily | live[200] |
| GetDataLocation | `/admin/api/tenant/datalocationandcommitments` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetLocalDataLocation | `/admin/api/tenant/localdatalocation` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetMarketplaceSeatSize | `/admin/api/tenant/marketplaceSeatSize` | GET | read | none | - | - | daily | live[200] |
| GetO365ActivationUserCounts | `/admin/api/tenant/o365activationusercounts` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetSeatSize | `/admin/api/tenant/seatSize` | GET | read | none | - | - | daily | live[200] |
| GetSelfServicePurchaseProducts | `/admin/api/selfServicePurchasePolicy/products` | GET | read | none | - | Software.Name | daily | tenant-gated[403] |
| GetUnifiedStorageQuotaEligibility | `/_api/v2.1/unifiedStorageQuotaEligible` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetUserViews | `/admin/api/tenant/userviews` | GET | read | none | - | - | daily | live[200] |
| IsReportsPrivacyEnabled | `/admin/api/tenant/isReportsPrivacyEnabled` | GET | unknown | none | - | - | daily | server-error[500] |
| IsTenantEligibleToRemoveSAC | `/admin/api/tenant/isTenantEligibleToRemoveSAC` | GET | unknown | none | - | - | daily | tenant-gated[403] |
| SACProvisioning | `/admin/api/tenant/SACProvisioning` | POST | unknown | none | - | - | daily | unprobed |
| StartOfflineProcesses | `/admin/api/Tenant/StartOfflineProcesses` | GET | unknown | none | - | - | daily | live-empty[200] |

#### `tenant_relationships` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetMTO | `/admin/api/tenantRelationships/multiTenantOrganization` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetMTOTenants | `...n/api/tenantRelationships/multiTenantOrganization/tenants` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetUserSyncOutbound | `/admin/api/tenantRelationships/userSyncApps/outboundDetails` | GET | read | none | - | - | daily | request-shape-error[400] |

#### `users_groups` [v0.2.0+]

**Sub-area summary:** 32 endpoints · cadence=daily · pagination=none:32 · time-filter coverage=0/32 · top entities=Account.AadId, Software.Version, Account.SamName · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetAdministrativeUnits | `/admin/api/users/administrativeunits` | GET | read | none | - | - | daily | live[200] |
| GetAvailableRoles | `/admin/api/users/getavailableroles` | GET | read | none | - | - | daily | live[200] |
| GetCommonDVPreferences | `/admin/api/users/getcommondvpreferences` | GET | read | none | - | - | daily | live[200] |
| GetContactCustomization | `/admin/api/contact/Customization` | GET | read | none | - | - | daily | live[200] |
| GetContacts | `/admin/api/contact/GetContacts` | POST | read | none | - | - | daily | unprobed |
| GetContextualAlerts | `/admin/api/users/contextualalerts` | POST | read | none | - | - | 1h | unprobed |
| GetCurrentUser | `/admin/api/users/currentUser` | GET | read | none | - | - | daily | live[200] |
| GetDashboardLayout | `/admin/api/users/dashboardlayout` | GET | read | none | - | - | daily | live[200] |
| GetDeviceUpdateChannelEligibility | `/admin/api/users/deviceupdatechanneleligibility` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetGroupCount | `/admin/api/groups/GetGroupCount` | GET | read | none | - | - | daily | live[200] |
| GetGroupLabels | `/admin/api/groups/labels` | GET | read | none | - | - | daily | live[200] |
| GetGroupListCustomization | `/admin/api/grouplist/Customization` | GET | read | none | - | - | daily | live[200] |
| GetGroupPermissions | `/admin/api/groups/permissions` | GET | read | none | - | - | daily | live[200] |
| GetGroups | `/admin/api/groups/GetGroups` | POST | read | none | - | - | daily | unprobed |
| GetGroupsByIds | `/admin/api/groups/getgroupsbyids` | POST | read | none | - | - | daily | unprobed |
| GetGuestUserListCustomization | `/admin/api/guestuserlist/Customization` | GET | read | none | - | - | daily | live[200] |
| GetLocalizedVideoByFeature | `/admin/api/localizedvideo/getbyfeature/{locale}` | POST | read | none | - | - | daily | unprobed |
| GetNewGroupOptions | `/admin/api/groups/new/options` | GET | read | none | - | - | daily | live[200] |
| GetNewUserOptions | `/admin/api/users/new/options` | GET | read | none | - | - | daily | tenant-gated[403] |
| GetServerVersionInfo | `/admin/api/users/svinfo` | GET | read | none | - | Software.Version | daily | live[200] |
| GetSurveysInfo | `/admin/api/users/surveysInfo` | GET | read | none | - | - | daily | request-shape-error[400] |
| GetTeamsSettingsInfo | `/admin/api/users/teamssettingsinfo` | GET | read | none | - | - | daily | server-error[500] |
| GetTokenWithExpiry | `/admin/api/users/tokenWithExpiry` | POST | read | none | - | - | daily | unprobed |
| GetUserAccessToken | `/admin/api/users/getuseraccesstoken` | GET | read | none | - | - | daily | request-shape-error[400] |
| GetUserById | `/admin/api/users/xdrlogreader@CloudSectra.com` | GET | read | none | - | Account.AadId | daily | request-shape-error[400] |
| GetUserListCustomization | `/admin/api/UserList/Customization` | GET | read | none | - | - | daily | live[200] |
| GetUserProducts | `/admin/api/users/products` | GET | read | none | - | Account.AadId, Account.SamName | daily | live[200] |
| GetUserRoles | `/admin/api/users/getuserroles` | POST | read | none | - | - | daily | unprobed |
| ListExternalGuestUsers | `/admin/api/users/ListExternalGuestUsers` | POST | read | none | - | - | daily | unprobed |
| ListRbacRoles | `/admin/api/rbac/roles` | GET | read | none | - | - | daily | live[200] |
| ListUsers | `/admin/api/Users/ListUsers` | POST | read | none | - | - | daily | unprobed |
| SaveCommonDVPreferences | `/admin/api/users/savecommondvpreferences` | POST | write | none | - | - | daily | unprobed |

#### `viva` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| GetGlintClient | `/admin/api/viva/glint/lookupClient` | GET | read | none | - | - | daily | live[200] |
| GetModules | `/admin/api/viva/modules` | GET | read | none | - | - | daily | live[200] |
| GetRoles | `/admin/api/viva/roles` | GET | read | none | - | - | daily | live[200] |

---

## Portal: `m365-apps-config`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer |
| ClientId | `TBD-from-bundle` |
| Audience | `TBD` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-m365-apps-config\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\m365-apps-config.collection.json` (present)

### Sub-areas: 1 · Endpoints: 22 · Live: 4

#### `openapi` [v0.2.0+]

**Sub-area summary:** 22 endpoints · cadence=daily · pagination=none:22 · time-filter coverage=0/22 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| appConfig_v1_0_ServiceHealth | `/appConfig/v1.0/ServiceHealth` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| appConfig_v1_0_ShellService_GetShellInfo | `/appConfig/v1.0/ShellService/GetShellInfo` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| appConfig_v1_0_userflights | `/appConfig/v1.0/userflights` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| endpointprovisionhealth_v1_0_tenantassociation | `/endpointprovisionhealth/v1.0/tenantassociation` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| intents_v1_0_AuthDeploymentSettings_UpdateConfiguration__configurationId | `...hDeploymentSettings/UpdateConfiguration/{configurationId}` | PUT | unknown | none | - | - | 6h | unprobed |
| intents_v1_0_DeploymentConfiguration_GetConfigurations | `/intents/v1.0/DeploymentConfiguration/GetConfigurations` | GET | unknown | none | - | - | 6h | tenant-gated[401] |
| intents_v1_0_DeploymentConfiguration_UpdateConfiguration__configurationId | `...oymentConfiguration/UpdateConfiguration/{configurationId}` | PUT | unknown | none | - | - | 6h | unprobed |
| policyadmin_v1_0_DbsLicensing_HasDbsLicense | `/policyadmin/v1.0/DbsLicensing/HasDbsLicense` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| policyadmin_v1_0_policies | `/policyadmin/v1.0/policies` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| releases_v1_0_LatestRelease_CurrentChannel | `/releases/v1.0/LatestRelease/CurrentChannel` | GET | unknown | none | - | - | daily | live[200] |
| releases_v1_0_LatestRelease_MonthlyEnterpriseChannel | `/releases/v1.0/LatestRelease/MonthlyEnterpriseChannel` | GET | unknown | none | - | - | daily | live[200] |
| releases_v1_0_NextReleaseVersion_MonthlyEnterpriseChannel | `/releases/v1.0/NextReleaseVersion/MonthlyEnterpriseChannel` | GET | unknown | none | - | Software.Version | daily | live[200] |
| rollout_v1_0_residency | `/rollout/v1.0/residency` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| serviceProfile_v1_0__profileId__rules | `/serviceProfile/v1.0/{profileId}/rules` | GET | unknown | none | - | - | daily | unprobed |
| ServiceProfile_v1_0_Profiles | `/ServiceProfile/v1.0/Profiles` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| serviceProfile_v1_0_serviceProfileAggregator__profileId__rollbackEntries | `...v1.0/serviceProfileAggregator/{profileId}/rollbackEntries` | GET | unknown | none | - | - | daily | unprobed |
| serviceProfile_v1_0_serviceProfileAggregator_filteredDevicesAndGroups | `...le/v1.0/serviceProfileAggregator/filteredDevicesAndGroups` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| serviceProfile_v1_0_ServiceProfileAggregator_tenantServicingExclusionWindows | `.../ServiceProfileAggregator/tenantServicingExclusionWindows` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| serviceProfile_v1_0_tenantrules | `/serviceProfile/v1.0/tenantrules` | GET/PUT | unknown | none | - | - | daily | tenant-gated[401] |
| serviceProfile_v3_0_profiles | `/serviceProfile/v3.0/profiles` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| settings_v1_0_SettingsCatalog_auth_Settings | `/settings/v1.0/SettingsCatalog/auth/Settings` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| settings_v1_0_SettingsCatalog_Settings | `/settings/v1.0/SettingsCatalog/Settings` | GET | unknown | none | - | - | daily | live[200] |

---

## Portal: `m365-apps-inventory`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer |
| ClientId | `TBD-from-bundle` |
| Audience | `TBD` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-m365-apps-inventory\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\m365-apps-inventory.collection.json` (present)

### Sub-areas: 1 · Endpoints: 25 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 25 endpoints · cadence=daily · pagination=none:25 · time-filter coverage=0/25 · top entities=Software.Version, Url.Path, Vuln.CveId · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| inventory_api_DeviceActions_GetUpdateProgressSummaryByChannel | `...ory/api/DeviceActions/GetUpdateProgressSummaryByChannel()` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Devices | `/inventory/api/Devices` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Devices_GetDeviceSummary | `/inventory/api/Devices/GetDeviceSummary` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_DevicesWithCloudManagementInfo | `/inventory/api/DevicesWithCloudManagementInfo` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_DevicesWithMetadata_GetOfficeBuildChannelSummaryWithMetadata | `...icesWithMetadata/GetOfficeBuildChannelSummaryWithMetadata` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_DevicesWithMetadata_GetOfficeBuildDeviceSummaryWithMetadata | `...vicesWithMetadata/GetOfficeBuildDeviceSummaryWithMetadata` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Languages | `/inventory/api/Languages` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_OfficeAddins | `/inventory/api/OfficeAddins` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_OfficeAddins__Count | `/inventory/api/OfficeAddins/$Count` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_OfficeAddinVersions | `/inventory/api/OfficeAddinVersions` | GET | unknown | none | - | Software.Version | daily | tenant-gated[401] |
| inventory_api_OfficeApplications | `/inventory/api/OfficeApplications` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Onboarding | `/inventory/api/Onboarding` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Onboarding_Offboard | `/inventory/api/Onboarding/Offboard` | POST | unknown | none | - | - | daily | unprobed |
| inventory_api_Onboarding_Onboard | `/inventory/api/Onboarding/Onboard()` | POST | unknown | none | - | - | daily | unprobed |
| inventory_api_SecurityCurrencyDevices_GetLatestPatchDate | `/inventory/api/SecurityCurrencyDevices/GetLatestPatchDate` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityCurrencyDevices_GetLatestSecurityReleasesPerServicingChannel | `...rencyDevices/GetLatestSecurityReleasesPerServicingChannel` | GET | unknown | none | - | Vuln.CveId | daily | tenant-gated[401] |
| inventory_api_SecurityCurrencyDevices_GetSecurityUpdateStatusMetrics | `...pi/SecurityCurrencyDevices/GetSecurityUpdateStatusMetrics` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityCurrencyDevices_GetSecurityUpdateStatusMetricsByChannel | `...tyCurrencyDevices/GetSecurityUpdateStatusMetricsByChannel` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityCurrencyGoal | `/inventory/api/SecurityCurrencyGoal` | GET/POST | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityCurrencyGoal__goalId | `/inventory/api/SecurityCurrencyGoal({goalId})` | PATCH | unknown | none | - | - | daily | unprobed |
| inventory_api_SecurityVulnerabilities_GetSecurityVulnerabilityByChannel | `...SecurityVulnerabilities/GetSecurityVulnerabilityByChannel` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityVulnerabilities_GetSecurityVulnerabilityByReleaseDate | `...rityVulnerabilities/GetSecurityVulnerabilityByReleaseDate` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_SecurityVulnerabilitiesDevices_GetSecurityVulnerabilityForEveryDevice | `...abilitiesDevices/GetSecurityVulnerabilityForEveryDevice()` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| inventory_api_Settings | `/inventory/api/Settings` | GET/POST | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| inventory_api_Settings__settingsId | `/inventory/api/Settings({settingsId})` | PATCH | unknown | none | - | - | daily | unprobed |

---

## Portal: `m365-apps-services`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer |
| ClientId | `TBD-from-bundle` |
| Audience | `TBD` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-m365-apps-services\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\m365-apps-services.collection.json` (present)

### Sub-areas: 1 · Endpoints: 8 · Live: 1

#### `openapi` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| intents_v1_0_ComponentGroupIntentShard | `/intents/v1.0/ComponentGroupIntentShard` | POST | unknown | none | - | - | daily | unprobed |
| odbhealth_v1_0_synchealth_reports_count | `/odbhealth/v1.0/synchealth/reports/count` | POST | unknown | none | - | - | daily | unprobed |
| odbhealth_v1_0_synchealth_reports_versioncount | `/odbhealth/v1.0/synchealth/reports/versioncount` | GET | unknown | none | - | Software.Version | daily | tenant-gated[401] |
| onboarding_odata_v1_0_Agreementdata | `/onboarding/odata/v1.0/Agreementdata` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| onboarding_odata_v1_0_EligibilityRecord | `/onboarding/odata/v1.0/EligibilityRecord` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| onboarding_odata_v1_0_FeatureData | `/onboarding/odata/v1.0/FeatureData` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| onboarding_odata_v1_0_FeatureProvisiondata | `/onboarding/odata/v1.0/FeatureProvisiondata` | GET/POST | unknown | none | - | - | daily | tenant-gated[401] |
| releases_v1_0_OfficeReleases | `/releases/v1.0/OfficeReleases` | GET | unknown | none | - | - | daily | live[200] |

---

## Portal: `power-platform`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer-multi-audience |
| ClientId | `c44b4083-3bb0-49c1-b47d-974e53cbdf3c-likely` |
| Audience | `per-host: bap=https://api.bap.microsoft.com; dynamics=https://{org}.crm.dynamics.com` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-power-platform\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\power-platform.collection.json` (present)

### Sub-areas: 9 · Endpoints: 244 · Live: 6

#### `admin_analytics` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=2/7 · top entities=Url.Path, Time.Generated · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AdminAnalytics_get_api_v1_cds_CategorySeries_Organizations_organizationId | `/api/v1/cds/CategorySeries/Organizations/{organizationId}` | GET | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |
| AdminAnalytics_get_api_v1_cds_OrgInsightsMetrics_List | `/api/v1/cds/OrgInsightsMetrics/List` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| AdminAnalytics_get_api_v1_cds_TimeSeries_Organizations_organizationId | `/api/v1/cds/TimeSeries/Organizations/{organizationId}` | GET | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |
| AdminAnalytics_post_api_v1_metrics_resourceType_copilotstudio_resourceSubType_agent_latest | `...s/resourceType/copilotstudio/resourceSubType/agent/latest` | POST | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |
| AdminAnalytics_post_api_v1_metrics_resourceType_powerautomate_resourceSubType_cloudflow_latest | `...sourceType/powerautomate/resourceSubType/cloudflow/latest` | POST | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |
| AdminAnalytics_post_api_v1_metrics_resourceType_powerautomate_resourceSubType_desktopflow_latest | `...urceType/powerautomate/resourceSubType/desktopflow/latest` | POST | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |
| AdminAnalytics_post_api_v1_metrics_resourceType_powerautomate_resourceSubType_workqueue_latest | `...sourceType/powerautomate/resourceSubType/workqueue/latest` | POST | unknown | none | - | Time.Generated, Url.Path | daily | unprobed |

#### `admin_portal` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=weekly · pagination=none:3 · time-filter coverage=0/3 · top entities=Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AdminPortal_get_api_AppManagement_TenantProducts | `/api/AppManagement/TenantProducts` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| AdminPortal_get_api_environments_environmentsId_features | `/api/environments/{environmentsId}/features` | GET | unknown | none | - | Url.Path | weekly | unprobed |
| AdminPortal_get_api_health_ping | `/api/health/ping` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |

#### `business_app_platform` [v0.2.0+]

**Sub-area summary:** 19 endpoints · cadence=daily · pagination=topSkip:2 / none:17 · time-filter coverage=3/19 · top entities=Software.Version, Url.Path, Time.Generated, File.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_environmentGroups | `/providers/Microsoft.BusinessAppPlatform/environmentGroups` | GET | unknown | none | - | Software.Version, Url.Path | daily | live-empty[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_environmentLocations | `...viders/Microsoft.BusinessAppPlatform/environmentLocations` | GET | unknown | none | - | Software.Version, Url.Path | daily | live[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_environments | `/providers/Microsoft.BusinessAppPlatform/environments` | GET | unknown | none | - | Software.Version, Time.Generated, Url.Path | daily | live[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_environments_default | `...iders/Microsoft.BusinessAppPlatform/environments/~default` | GET | unknown | none | - | Software.Version, Url.Path | daily | live[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_lifecycleOperations | `/providers/Microsoft.BusinessAppPlatform/lifecycleOperations` | GET | unknown | none | - | Software.Version, Url.Path | daily | request-shape-error[400] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_locations | `/providers/Microsoft.BusinessAppPlatform/locations` | GET | unknown | none | - | Software.Version, Url.Path | daily | live[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_locations_locationName_environmentCurrencies | `...ppPlatform/locations/{locationName}/environmentCurrencies` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_locations_locationName_environmentLanguages | `...AppPlatform/locations/{locationName}/environmentLanguages` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_locations_unitedstates_templates | `...soft.BusinessAppPlatform/locations/unitedstates/templates` | GET | unknown | none | - | Software.Version, Url.Path | daily | live[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_scopes_admin_environments | `...s/Microsoft.BusinessAppPlatform/scopes/admin/environments` | GET | unknown | none | - | Software.Version, Url.Path | daily | live-empty[200] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_scopes_admin_environments_environmentId | `...nessAppPlatform/scopes/admin/environments/{environmentId}` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_scopes_admin_environments_environmentId_lastActivity | `...rm/scopes/admin/environments/{environmentId}/lastActivity` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_t2tmigrationapprovals | `...iders/Microsoft.BusinessAppPlatform/t2tmigrationapprovals` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[401] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_t2tmigrations | `/providers/Microsoft.BusinessAppPlatform/t2tmigrations` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[401] |
| BusinessAppPlatform_get_providers_Microsoft_BusinessAppPlatform_tenant | `/providers/Microsoft.BusinessAppPlatform/tenant` | GET | unknown | none | - | Software.Version, Url.Path | daily | live[200] |
| BusinessAppPlatform_post_providers_Microsoft_BusinessAppPlatform_environments_environmentId_checkAccess | `...inessAppPlatform/environments/{environmentId}/checkAccess` | POST | unknown | none | - | File.Name, Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_post_providers_Microsoft_BusinessAppPlatform_environments_getOrCreate | `...rs/Microsoft.BusinessAppPlatform/environments/getOrCreate` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_post_providers_Microsoft_BusinessAppPlatform_listTenantSettings | `/providers/Microsoft.BusinessAppPlatform/listTenantSettings` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| BusinessAppPlatform_post_providers_Microsoft_BusinessAppPlatform_scopes_admin_enroll | `/providers/Microsoft.BusinessAppPlatform/scopes/admin/enroll` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |

#### `config_analytics` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=Tenant.Id, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| ConfigAnalytics_get_api_v1_tenants_tenantId_tenantconsent | `...enants/45f52f35-73d5-4066-8378-fe506ee90fb1/tenantconsent` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |

#### `dynamics_crm` [v0.2.0+]

**Sub-area summary:** 135 endpoints · cadence=daily · pagination=topSkip:1 / none:134 · time-filter coverage=11/135 · top entities=Url.Path, Software.Version, Time.Generated, Account.UPN · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| DynamicsCrm_get_api_data_v9_0_applicationusers | `/api/data/v9.0/applicationusers` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_appmodules_Microsoft_Dynamics_CRM_RetrieveUnpublishedMultiple | `...ules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_audits | `/api/data/v9.0/audits` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_businessunits | `/api/data/v9.0/businessunits` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_businessunits_businessunitId | `/api/data/v9.0/businessunits({businessunitId})` | GET | unknown | none | - | Url.Path | daily | unprobed |
| DynamicsCrm_get_api_data_v9_0_deploymentpipelines | `/api/data/v9.0/deploymentpipelines` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_deploymentstageruns | `/api/data/v9.0/deploymentstageruns` | GET | unknown | none | - | Time.Generated, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions | `/api/data/v9.0/EntityDefinitions` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions_LogicalName_businessunit | `/api/data/v9.0/EntityDefinitions(LogicalName='businessunit')` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions_LogicalName_role_Attributes_LogicalName_issytemgenerated | `...alName='role')/Attributes(LogicalName='issytemgenerated')` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions_LogicalName_systemuser | `/api/data/v9.0/EntityDefinitions(LogicalName='systemuser')` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions_LogicalName_systemuser_Attributes_LogicalName_systemmanagedusertype | `...temuser')/Attributes(LogicalName='systemmanagedusertype')` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_EntityDefinitions_LogicalName_team | `/api/data/v9.0/EntityDefinitions(LogicalName='team')` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_GetClientMetadata_ClientMetadataQuery_ClientMetadataQuery | `...tClientMetadata(ClientMetadataQuery=@ClientMetadataQuery)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_organizations | `/api/data/v9.0/organizations` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_privileges | `/api/data/v9.0/privileges` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_0002921c_d1d0_f011_8543_7c1e52689cc6 | `...ivilegesRole(RoleId=0002921c-d1d0-f011-8543-7c1e52689cc6)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_02123b67_66ae_4a69_8cdc_6473b94ad1a9 | `...ivilegesRole(RoleId=02123b67-66ae-4a69-8cdc-6473b94ad1a9)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_169ead94_a7e8_42c5_9ae8_d81205dfee77 | `...ivilegesRole(RoleId=169ead94-a7e8-42c5-9ae8-d81205dfee77)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_1a6feece_0ba1_4739_8dee_eb83b1b591ea | `...ivilegesRole(RoleId=1a6feece-0ba1-4739-8dee-eb83b1b591ea)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_1bb44f6d_15a5_48aa_a2f2_8d2cb0095d2d | `...ivilegesRole(RoleId=1bb44f6d-15a5-48aa-a2f2-8d2cb0095d2d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_1f6c957f_9851_4dbe_ab1c_508c06faa8be | `...ivilegesRole(RoleId=1f6c957f-9851-4dbe-ab1c-508c06faa8be)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_20902168_ee38_ea11_a81c_000d3ac3e6d8 | `...ivilegesRole(RoleId=20902168-ee38-ea11-a81c-000d3ac3e6d8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_25f9a5ed_60fd_4bcf_bf4b_b40296410bf4 | `...ivilegesRole(RoleId=25f9a5ed-60fd-4bcf-bf4b-b40296410bf4)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_2c321cf0_f096_ea11_a81a_000d3a6ecd99 | `...ivilegesRole(RoleId=2c321cf0-f096-ea11-a81a-000d3a6ecd99)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_2fe4d72e_e538_ea11_a81c_000d3ac3e6d8 | `...ivilegesRole(RoleId=2fe4d72e-e538-ea11-a81c-000d3ac3e6d8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_313995f9_4a4a_4d4a_afd1_c892da78e13e | `...ivilegesRole(RoleId=313995f9-4a4a-4d4a-afd1-c892da78e13e)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_3f199ebd_977e_43e5_abe5_fe865a1f2904 | `...ivilegesRole(RoleId=3f199ebd-977e-43e5-abe5-fe865a1f2904)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_4931681d_8163_e811_a965_000d3a11fe32 | `...ivilegesRole(RoleId=4931681d-8163-e811-a965-000d3a11fe32)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_4f9dbfce_f797_40d8_a8ac_902e441e371b | `...ivilegesRole(RoleId=4f9dbfce-f797-40d8-a8ac-902e441e371b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_500073fc_54f7_429b_822e_f28b01fa5148 | `...ivilegesRole(RoleId=500073fc-54f7-429b-822e-f28b01fa5148)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_5225adeb_859b_42f3_8289_a399e47512d5 | `...ivilegesRole(RoleId=5225adeb-859b-42f3-8289-a399e47512d5)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_6b860c71_0e4e_ec11_b1b5_000d3a6ed5b3 | `...ivilegesRole(RoleId=6b860c71-0e4e-ec11-b1b5-000d3a6ed5b3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_726d11d6_d9cf_4503_ade9_d6a4be7fa095 | `...ivilegesRole(RoleId=726d11d6-d9cf-4503-ade9-d6a4be7fa095)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_7be5a395_6b58_4f8c_908f_97dc8810fc50 | `...ivilegesRole(RoleId=7be5a395-6b58-4f8c-908f-97dc8810fc50)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_854af338_f3c5_e711_8122_000d3aa01c52 | `...ivilegesRole(RoleId=854af338-f3c5-e711-8122-000d3aa01c52)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_88b87c37_1472_4798_ac48_d56509eb6e1d | `...ivilegesRole(RoleId=88b87c37-1472-4798-ac48-d56509eb6e1d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_896a28e5_678d_4fa8_ad59_c606d1aa98ce | `...ivilegesRole(RoleId=896a28e5-678d-4fa8-ad59-c606d1aa98ce)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_8a2f35d9_e447_4285_974c_81382317ca21 | `...ivilegesRole(RoleId=8a2f35d9-e447-4285-974c-81382317ca21)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_95aa4c68_04e0_4982_b994_7b5ed6c0771d | `...ivilegesRole(RoleId=95aa4c68-04e0-4982-b994-7b5ed6c0771d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_979144c2_989b_41a5_a146_6b3ea4130e8c | `...ivilegesRole(RoleId=979144c2-989b-41a5-a146-6b3ea4130e8c)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_987674dd_f4a4_45a8_a1f7_f2cce1cf87f8 | `...ivilegesRole(RoleId=987674dd-f4a4-45a8-a1f7-f2cce1cf87f8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_99b7f9c4_5c1e_4b9a_b756_fdfa137b6f85 | `...ivilegesRole(RoleId=99b7f9c4-5c1e-4b9a-b756-fdfa137b6f85)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_9f572d55_6090_493b_904a_3956bdc55343 | `...ivilegesRole(RoleId=9f572d55-6090-493b-904a-3956bdc55343)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_a0537877_879d_4b70_a391_bb07b94fbba2 | `...ivilegesRole(RoleId=a0537877-879d-4b70-a391-bb07b94fbba2)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_a0a59a4a_b5a8_4e6f_a094_a866573c17d4 | `...ivilegesRole(RoleId=a0a59a4a-b5a8-4e6f-a094-a866573c17d4)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_a1801436_efd6_e811_a96e_000d3a3ab886 | `...ivilegesRole(RoleId=a1801436-efd6-e811-a96e-000d3a3ab886)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_ab8b8c58_1f50_4037_8b26_7523d6145cc3 | `...ivilegesRole(RoleId=ab8b8c58-1f50-4037-8b26-7523d6145cc3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_b21a7144_299d_4c21_a116_30f60e9c159a | `...ivilegesRole(RoleId=b21a7144-299d-4c21-a116-30f60e9c159a)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_b9b08637_acf6_e711_a95a_000d3a11f5ee | `...ivilegesRole(RoleId=b9b08637-acf6-e711-a95a-000d3a11f5ee)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_bdf1780b_2867_4c3e_8957_dce785eac543 | `...ivilegesRole(RoleId=bdf1780b-2867-4c3e-8957-dce785eac543)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_c95980b3_97dc_4762_a037_c15fe02dae8c | `...ivilegesRole(RoleId=c95980b3-97dc-4762-a037-c15fe02dae8c)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_d19d7df9_96e3_440a_ada1_7f469d2a00d1 | `...ivilegesRole(RoleId=d19d7df9-96e3-440a-ada1-7f469d2a00d1)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_d58407f2_48d5_e711_a82c_000d3a37c848 | `...ivilegesRole(RoleId=d58407f2-48d5-e711-a82c-000d3a37c848)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_d6e926ad_4afc_42fb_97f1_6e50c2ef174e | `...ivilegesRole(RoleId=d6e926ad-4afc-42fb-97f1-6e50c2ef174e)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_e0d2794e_82f3_e811_a951_000d3a1bcf17 | `...ivilegesRole(RoleId=e0d2794e-82f3-e811-a951-000d3a1bcf17)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_e389a4a6_b53b_4828_bca9_4b5d25f1763b | `...ivilegesRole(RoleId=e389a4a6-b53b-4828-bca9-4b5d25f1763b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_e57bff35_58b4_4725_aee2_40fb18f4c8bd | `...ivilegesRole(RoleId=e57bff35-58b4-4725-aee2-40fb18f4c8bd)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_edfcbfd2_358f_ea11_a81f_000d3a6eafd3 | `...ivilegesRole(RoleId=edfcbfd2-358f-ea11-a81f-000d3a6eafd3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_ee18dcf2_6f83_4cd7_aa5c_1d8a88947d51 | `...ivilegesRole(RoleId=ee18dcf2-6f83-4cd7-aa5c-1d8a88947d51)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_ee2c8e11_6d57_4c5d_9f84_659c0db132bb | `...ivilegesRole(RoleId=ee2c8e11-6d57-4c5d-9f84-659c0db132bb)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_ee7bc749_3dd6_45ac_b95d_a3031463380b | `...ivilegesRole(RoleId=ee7bc749-3dd6-45ac-b95d-a3031463380b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_f600921c_d1d0_f011_8543_7c1e52689cc6 | `...ivilegesRole(RoleId=f600921c-d1d0-f011-8543-7c1e52689cc6)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_f9e46d0f_d53e_4d5c_b06b_24948b4606ed | `...ivilegesRole(RoleId=f9e46d0f-d53e-4d5c-b06b-24948b4606ed)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_fc3e65d9_450a_4301_933b_f9bcaee20521 | `...ivilegesRole(RoleId=fc3e65d9-450a-4301-933b-f9bcaee20521)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveRolePrivilegesRole_RoleId_ffadce64_3542_4bf1_a83a_ac9941104680 | `...ivilegesRole(RoleId=ffadce64-3542-4bf1-a83a-ac9941104680)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveSetting_SettingName_CrossRegionDeploymentEnabled | `...trieveSetting(SettingName='CrossRegionDeploymentEnabled')` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveSetting_SettingName_DefaultCustomPipelinesHostEnvForTenant | `...ing(SettingName='DefaultCustomPipelinesHostEnvForTenant')` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveSetting_SettingName_EnablePipelinesManagedEnvironmentCompliance | `...ettingName='EnablePipelinesManagedEnvironmentCompliance')` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_RetrieveSetting_SettingName_EnableSolutionImportFromPipelineHost | `...tting(SettingName='EnableSolutionImportFromPipelineHost')` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roleeditorlayouts | `/api/data/v9.0/roleeditorlayouts` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles | `/api/data/v9.0/roles` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_0002921c_d1d0_f011_8543_7c1e52689cc6 | `...v9.0/roles(roleid = 0002921c-d1d0-f011-8543-7c1e52689cc6)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_02123b67_66ae_4a69_8cdc_6473b94ad1a9 | `...v9.0/roles(roleid = 02123b67-66ae-4a69-8cdc-6473b94ad1a9)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_169ead94_a7e8_42c5_9ae8_d81205dfee77 | `...v9.0/roles(roleid = 169ead94-a7e8-42c5-9ae8-d81205dfee77)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_1a6feece_0ba1_4739_8dee_eb83b1b591ea | `...v9.0/roles(roleid = 1a6feece-0ba1-4739-8dee-eb83b1b591ea)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_1bb44f6d_15a5_48aa_a2f2_8d2cb0095d2d | `...v9.0/roles(roleid = 1bb44f6d-15a5-48aa-a2f2-8d2cb0095d2d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_1f6c957f_9851_4dbe_ab1c_508c06faa8be | `...v9.0/roles(roleid = 1f6c957f-9851-4dbe-ab1c-508c06faa8be)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_20902168_ee38_ea11_a81c_000d3ac3e6d8 | `...v9.0/roles(roleid = 20902168-ee38-ea11-a81c-000d3ac3e6d8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_25f9a5ed_60fd_4bcf_bf4b_b40296410bf4 | `...v9.0/roles(roleid = 25f9a5ed-60fd-4bcf-bf4b-b40296410bf4)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_2c321cf0_f096_ea11_a81a_000d3a6ecd99 | `...v9.0/roles(roleid = 2c321cf0-f096-ea11-a81a-000d3a6ecd99)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_2fe4d72e_e538_ea11_a81c_000d3ac3e6d8 | `...v9.0/roles(roleid = 2fe4d72e-e538-ea11-a81c-000d3ac3e6d8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_313995f9_4a4a_4d4a_afd1_c892da78e13e | `...v9.0/roles(roleid = 313995f9-4a4a-4d4a-afd1-c892da78e13e)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_3f199ebd_977e_43e5_abe5_fe865a1f2904 | `...v9.0/roles(roleid = 3f199ebd-977e-43e5-abe5-fe865a1f2904)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_4931681d_8163_e811_a965_000d3a11fe32 | `...v9.0/roles(roleid = 4931681d-8163-e811-a965-000d3a11fe32)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_4f9dbfce_f797_40d8_a8ac_902e441e371b | `...v9.0/roles(roleid = 4f9dbfce-f797-40d8-a8ac-902e441e371b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_500073fc_54f7_429b_822e_f28b01fa5148 | `...v9.0/roles(roleid = 500073fc-54f7-429b-822e-f28b01fa5148)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_5225adeb_859b_42f3_8289_a399e47512d5 | `...v9.0/roles(roleid = 5225adeb-859b-42f3-8289-a399e47512d5)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_6b860c71_0e4e_ec11_b1b5_000d3a6ed5b3 | `...v9.0/roles(roleid = 6b860c71-0e4e-ec11-b1b5-000d3a6ed5b3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_726d11d6_d9cf_4503_ade9_d6a4be7fa095 | `...v9.0/roles(roleid = 726d11d6-d9cf-4503-ade9-d6a4be7fa095)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_7be5a395_6b58_4f8c_908f_97dc8810fc50 | `...v9.0/roles(roleid = 7be5a395-6b58-4f8c-908f-97dc8810fc50)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_854af338_f3c5_e711_8122_000d3aa01c52 | `...v9.0/roles(roleid = 854af338-f3c5-e711-8122-000d3aa01c52)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_88b87c37_1472_4798_ac48_d56509eb6e1d | `...v9.0/roles(roleid = 88b87c37-1472-4798-ac48-d56509eb6e1d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_896a28e5_678d_4fa8_ad59_c606d1aa98ce | `...v9.0/roles(roleid = 896a28e5-678d-4fa8-ad59-c606d1aa98ce)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_8a2f35d9_e447_4285_974c_81382317ca21 | `...v9.0/roles(roleid = 8a2f35d9-e447-4285-974c-81382317ca21)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_95aa4c68_04e0_4982_b994_7b5ed6c0771d | `...v9.0/roles(roleid = 95aa4c68-04e0-4982-b994-7b5ed6c0771d)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_979144c2_989b_41a5_a146_6b3ea4130e8c | `...v9.0/roles(roleid = 979144c2-989b-41a5-a146-6b3ea4130e8c)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_987674dd_f4a4_45a8_a1f7_f2cce1cf87f8 | `...v9.0/roles(roleid = 987674dd-f4a4-45a8-a1f7-f2cce1cf87f8)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_99b7f9c4_5c1e_4b9a_b756_fdfa137b6f85 | `...v9.0/roles(roleid = 99b7f9c4-5c1e-4b9a-b756-fdfa137b6f85)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_9f572d55_6090_493b_904a_3956bdc55343 | `...v9.0/roles(roleid = 9f572d55-6090-493b-904a-3956bdc55343)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_a0537877_879d_4b70_a391_bb07b94fbba2 | `...v9.0/roles(roleid = a0537877-879d-4b70-a391-bb07b94fbba2)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_a0a59a4a_b5a8_4e6f_a094_a866573c17d4 | `...v9.0/roles(roleid = a0a59a4a-b5a8-4e6f-a094-a866573c17d4)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_a1801436_efd6_e811_a96e_000d3a3ab886 | `...v9.0/roles(roleid = a1801436-efd6-e811-a96e-000d3a3ab886)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_ab8b8c58_1f50_4037_8b26_7523d6145cc3 | `...v9.0/roles(roleid = ab8b8c58-1f50-4037-8b26-7523d6145cc3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_b21a7144_299d_4c21_a116_30f60e9c159a | `...v9.0/roles(roleid = b21a7144-299d-4c21-a116-30f60e9c159a)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_b9b08637_acf6_e711_a95a_000d3a11f5ee | `...v9.0/roles(roleid = b9b08637-acf6-e711-a95a-000d3a11f5ee)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_bdf1780b_2867_4c3e_8957_dce785eac543 | `...v9.0/roles(roleid = bdf1780b-2867-4c3e-8957-dce785eac543)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_c95980b3_97dc_4762_a037_c15fe02dae8c | `...v9.0/roles(roleid = c95980b3-97dc-4762-a037-c15fe02dae8c)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_d19d7df9_96e3_440a_ada1_7f469d2a00d1 | `...v9.0/roles(roleid = d19d7df9-96e3-440a-ada1-7f469d2a00d1)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_d58407f2_48d5_e711_a82c_000d3a37c848 | `...v9.0/roles(roleid = d58407f2-48d5-e711-a82c-000d3a37c848)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_d6e926ad_4afc_42fb_97f1_6e50c2ef174e | `...v9.0/roles(roleid = d6e926ad-4afc-42fb-97f1-6e50c2ef174e)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_e0d2794e_82f3_e811_a951_000d3a1bcf17 | `...v9.0/roles(roleid = e0d2794e-82f3-e811-a951-000d3a1bcf17)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_e389a4a6_b53b_4828_bca9_4b5d25f1763b | `...v9.0/roles(roleid = e389a4a6-b53b-4828-bca9-4b5d25f1763b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_e57bff35_58b4_4725_aee2_40fb18f4c8bd | `...v9.0/roles(roleid = e57bff35-58b4-4725-aee2-40fb18f4c8bd)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_edfcbfd2_358f_ea11_a81f_000d3a6eafd3 | `...v9.0/roles(roleid = edfcbfd2-358f-ea11-a81f-000d3a6eafd3)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_ee18dcf2_6f83_4cd7_aa5c_1d8a88947d51 | `...v9.0/roles(roleid = ee18dcf2-6f83-4cd7-aa5c-1d8a88947d51)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_ee2c8e11_6d57_4c5d_9f84_659c0db132bb | `...v9.0/roles(roleid = ee2c8e11-6d57-4c5d-9f84-659c0db132bb)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_ee7bc749_3dd6_45ac_b95d_a3031463380b | `...v9.0/roles(roleid = ee7bc749-3dd6-45ac-b95d-a3031463380b)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_f600921c_d1d0_f011_8543_7c1e52689cc6 | `...v9.0/roles(roleid = f600921c-d1d0-f011-8543-7c1e52689cc6)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_f9e46d0f_d53e_4d5c_b06b_24948b4606ed | `...v9.0/roles(roleid = f9e46d0f-d53e-4d5c-b06b-24948b4606ed)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_fc3e65d9_450a_4301_933b_f9bcaee20521 | `...v9.0/roles(roleid = fc3e65d9-450a-4301-933b-f9bcaee20521)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_roles_roleid_ffadce64_3542_4bf1_a83a_ac9941104680 | `...v9.0/roles(roleid = ffadce64-3542-4bf1-a83a-ac9941104680)` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_savedqueries | `/api/data/v9.0/savedqueries` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_solutions | `/api/data/v9.0/solutions` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_solutions_solutionId | `/api/data/v9.0/solutions({solutionId})` | GET | unknown | none | - | Url.Path | daily | unprobed |
| DynamicsCrm_get_api_data_v9_0_systemusers | `/api/data/v9.0/systemusers` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_systemusers_systemuserId_Microsoft_Dynamics_CRM_RetrieveUserPrivileges | `...temuserId})/Microsoft.Dynamics.CRM.RetrieveUserPrivileges` | GET | unknown | none | - | Url.Path | daily | unprobed |
| DynamicsCrm_get_api_data_v9_0_systemusers_systemuserId_Microsoft_Dynamics_CRM_RetrieveUsersPrivilegesThroughTeams_ExcludeOrgDisabledPrivileges_true_IncludeSetupUserFiltering_true | `...rgDisabledPrivileges=true,IncludeSetupUserFiltering=true)` | GET | unknown | none | - | Url.Path | daily | unprobed |
| DynamicsCrm_get_api_data_v9_0_teammemberships | `/api/data/v9.0/teammemberships` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_0_teams | `/api/data/v9.0/teams` | GET | unknown | none | - | Account.UPN, Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_data_v9_1_systemusers | `/api/data/v9.1/systemusers` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_get_api_nosql_audit_isreadenabled | `/api/nosql/audit/isreadenabled` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |
| DynamicsCrm_post_api_data_v9_0_batch | `/api/data/v9.0/$batch` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| DynamicsCrm_post_api_data_v9_0_GetFeatureEnabledState | `/api/data/v9.0/GetFeatureEnabledState` | POST | unknown | none | - | Url.Path | daily | unprobed |
| DynamicsCrm_post_api_data_v9_0_RetrieveFeatureControlSettingsByNamespace | `/api/data/v9.0/RetrieveFeatureControlSettingsByNamespace` | POST | unknown | none | - | Url.Path | daily | unprobed |

#### `licensing` [v0.2.0+]

**Sub-area summary:** 65 endpoints · cadence=daily · pagination=pageIndex0Based:1 / topSkip:1 / fromSize:8 / none:55 · time-filter coverage=1/65 · top entities=Tenant.Id, Url.Path, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Licensing_get_licensing_tenants_tenantId_UserPerFlowCapacitySource_TenantContextSummary | `...506ee90fb1/UserPerFlowCapacitySource/TenantContextSummary` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_licensing_tenants_tenantId_UserPerFlowCapacitySource_UserContextSummary | `...fe506ee90fb1/UserPerFlowCapacitySource/UserContextSummary` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_BillingPolicies | `...ants/45f52f35-73d5-4066-8378-fe506ee90fb1/BillingPolicies` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_CurrencyReports | `...ants/45f52f35-73d5-4066-8378-fe506ee90fb1/CurrencyReports` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_AppPass_trends | `...5-73d5-4066-8378-fe506ee90fb1/entitlements/AppPass/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_Database_trends | `...-73d5-4066-8378-fe506ee90fb1/entitlements/Database/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_extension | `...f52f35-73d5-4066-8378-fe506ee90fb1/entitlements/extension` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_File_trends | `...2f35-73d5-4066-8378-fe506ee90fb1/entitlements/File/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_FinOpsDatabase_trends | `...4066-8378-fe506ee90fb1/entitlements/FinOpsDatabase/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_FinOpsFile_trends | `...3d5-4066-8378-fe506ee90fb1/entitlements/FinOpsFile/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_Log_trends | `...52f35-73d5-4066-8378-fe506ee90fb1/entitlements/Log/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_MCSMessages_snapshot_product | `...78-fe506ee90fb1/entitlements/MCSMessages/snapshot/product` | GET | unknown | none | - | Software.Name, Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_entitlements_MCSMessages_trends | `...d5-4066-8378-fe506ee90fb1/entitlements/MCSMessages/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_environments_capacityTypes_PowerPagesAnonymous_trends | `...fb1/environments/capacityTypes/PowerPagesAnonymous/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_environments_capacityTypes_PowerPagesAuthenticated_trends | `...environments/capacityTypes/PowerPagesAuthenticated/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_licenseRequests_all | `.../45f52f35-73d5-4066-8378-fe506ee90fb1/licenseRequests/all` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_TenantCapacity | `...nants/45f52f35-73d5-4066-8378-fe506ee90fb1/TenantCapacity` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_TenantConsumptionReport_GetAllReports | `...6-8378-fe506ee90fb1/TenantConsumptionReport/GetAllReports` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_alpha_tenants_tenantId_TenantLicenseModel | `...s/45f52f35-73d5-4066-8378-fe506ee90fb1/TenantLicenseModel` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v0_1_tenants_tenantId_allocationsV2_sum | `...ts/45f52f35-73d5-4066-8378-fe506ee90fb1/allocationsV2/sum` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_capacityTypes_MCSMessages_trends | `...5-4066-8378-fe506ee90fb1/capacityTypes/MCSMessages/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_capacityTypes_MCSSessions_trends | `...5-4066-8378-fe506ee90fb1/capacityTypes/MCSSessions/trends` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_CurrencyReports | `...ants/45f52f35-73d5-4066-8378-fe506ee90fb1/CurrencyReports` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_Downloads_getAll_EntitlementConsumptionTenantDetailsReport | `...ownloads/getAll/EntitlementConsumptionTenantDetailsReport` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_Downloads_getAll_PowerAppsTenantLicenseDetailsDownload | `...b1/Downloads/getAll/PowerAppsTenantLicenseDetailsDownload` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_FinOpsLicensing_GetLicenseSummaryV2 | `...066-8378-fe506ee90fb1/FinOpsLicensing/GetLicenseSummaryV2` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_FinOpsLicensing_GetUsersExemptFromLicensing | `...-fe506ee90fb1/FinOpsLicensing/GetUsersExemptFromLicensing` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_FinOpsLicensing_GetUsersExemptFromLicensing_Count | `...ee90fb1/FinOpsLicensing/GetUsersExemptFromLicensing/Count` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_ManagedEnvironment_GetAllProductSkus | `...66-8378-fe506ee90fb1/ManagedEnvironment/GetAllProductSkus` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_ManagedEnvironment_PowerApps_GetLicenseSummary | `...506ee90fb1/ManagedEnvironment/PowerApps/GetLicenseSummary` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_ManagedEnvironment_PowerAutomate_GetLicenseSummary | `...e90fb1/ManagedEnvironment/PowerAutomate/GetLicenseSummary` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_productCategories_PowerApps_userSubscribedLicenseSummary | `.../productCategories/PowerApps/userSubscribedLicenseSummary` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v1_0_tenants_tenantId_recommendations_PowerAppsUnderlicensedUsers | `...-fe506ee90fb1/recommendations/PowerAppsUnderlicensedUsers` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_BillingPolicies | `...ants/45f52f35-73d5-4066-8378-fe506ee90fb1/BillingPolicies` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_AppPass | `...45f52f35-73d5-4066-8378-fe506ee90fb1/entitlements/AppPass` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_Database | `...5f52f35-73d5-4066-8378-fe506ee90fb1/entitlements/Database` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_File | `...ts/45f52f35-73d5-4066-8378-fe506ee90fb1/entitlements/File` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_FinOpsDatabase | `...5-73d5-4066-8378-fe506ee90fb1/entitlements/FinOpsDatabase` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_FinOpsFile | `...52f35-73d5-4066-8378-fe506ee90fb1/entitlements/FinOpsFile` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_Log | `...nts/45f52f35-73d5-4066-8378-fe506ee90fb1/entitlements/Log` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_MCSMessages | `...2f35-73d5-4066-8378-fe506ee90fb1/entitlements/MCSMessages` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_entitlements_MCSSessions | `...2f35-73d5-4066-8378-fe506ee90fb1/entitlements/MCSSessions` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_AppPass | `...fe506ee90fb1/environments/entitlementConsumptions/AppPass` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_Database | `...e506ee90fb1/environments/entitlementConsumptions/Database` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_File | `...78-fe506ee90fb1/environments/entitlementConsumptions/File` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_FinOpsDatabase | `...90fb1/environments/entitlementConsumptions/FinOpsDatabase` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_FinOpsFile | `...06ee90fb1/environments/entitlementConsumptions/FinOpsFile` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_Log | `...378-fe506ee90fb1/environments/entitlementConsumptions/Log` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_MCSMessages | `...6ee90fb1/environments/entitlementConsumptions/MCSMessages` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlementConsumptions_MCSSessions | `...6ee90fb1/environments/entitlementConsumptions/MCSSessions` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_AppPass | `...-4066-8378-fe506ee90fb1/environments/entitlements/AppPass` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_Database | `...4066-8378-fe506ee90fb1/environments/entitlements/Database` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_File | `...3d5-4066-8378-fe506ee90fb1/environments/entitlements/File` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_FinOpsDatabase | `...378-fe506ee90fb1/environments/entitlements/FinOpsDatabase` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_FinOpsFile | `...66-8378-fe506ee90fb1/environments/entitlements/FinOpsFile` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_Log | `...73d5-4066-8378-fe506ee90fb1/environments/entitlements/Log` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_MCSMessages | `...6-8378-fe506ee90fb1/environments/entitlements/MCSMessages` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_get_v2_0_tenants_tenantId_environments_entitlements_MCSSessions | `...6-8378-fe506ee90fb1/environments/entitlements/MCSSessions` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | tenant-gated[404] |
| Licensing_post_v0_1_alpha_tenants_tenantId_BillingPolicies_getEnvironmentMap | `...lpha/tenants/{tenantId}/BillingPolicies/getEnvironmentMap` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v0_1_tenants_tenantId_allocationsV2_getmany | `/v0.1/tenants/{tenantId}/allocationsV2/getmany` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v0_1_tenants_tenantId_allocationsV2_overage_getmany | `/v0.1/tenants/{tenantId}/allocationsV2/overage/getmany` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v1_0_tenants_tenantId_FinOpsLicensing_GetUserLicenseDetailsV2 | `...enants/{tenantId}/FinOpsLicensing/GetUserLicenseDetailsV2` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v1_0_tenants_tenantId_ManagedEnvironment_PowerApps_GetAppPassEnvironments | `...ntId}/ManagedEnvironment/PowerApps/GetAppPassEnvironments` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v1_0_tenants_tenantId_ManagedEnvironment_PowerAutomate_GetComplianceSummary | `...Id}/ManagedEnvironment/PowerAutomate/GetComplianceSummary` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |
| Licensing_post_v1_0_tenants_tenantId_productCategories_PowerApps_userSubscribedLicenseTrends | `...}/productCategories/PowerApps/userSubscribedLicenseTrends` | POST | unknown | none | - | Tenant.Id, Url.Path | daily | unprobed |

#### `notification_service` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=Software.Version, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| NotificationService_get_notificationservice_notifications_metadata | `/notificationservice/notifications/metadata` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |

#### `power_pages_portal_infra` [v0.2.0+]

**Sub-area summary:** 10 endpoints · cadence=daily · pagination=none:10 · time-filter coverage=0/10 · top entities=Url.Path, Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| PowerPagesPortalInfra_get_api_v1_powerPortal_environment_CoreEntitiesPackageInstallStatus | `.../powerPortal/environment/CoreEntitiesPackageInstallStatus` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_environment_optInStatus | `/api/v1/powerPortal/environment/optInStatus` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_FeatureConfiguration_GetFeatureControlValues | `.../powerPortal/FeatureConfiguration/GetFeatureControlValues` | GET | unknown | none | - | Url.Path | 6h | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_GetEnvironment | `/api/v1/powerPortal/GetEnvironment` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_IsCDSOrg | `/api/v1/powerPortal/IsCDSOrg` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_ListPortals | `/api/v1/powerPortal/ListPortals` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_ListPortalsByOrgId | `/api/v1/powerPortal/ListPortalsByOrgId` | GET | unknown | none | - | Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_tps_GetAvailablePackages | `/api/v1/powerPortal/tps/GetAvailablePackages` | GET | unknown | none | - | Tenant.Id, Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_tps_GetInstancePackages | `/api/v1/powerPortal/tps/GetInstancePackages` | GET | unknown | none | - | Tenant.Id, Url.Path | weekly | tenant-gated[404] |
| PowerPagesPortalInfra_get_api_v1_powerPortal_ZAP_GetDeepScanEnabledPortalByTenant | `/api/v1/powerPortal/ZAP/GetDeepScanEnabledPortalByTenant` | GET | unknown | none | - | Url.Path | daily | tenant-gated[404] |

#### `tenant_api` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version, Url.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| TenantApi_get_appmanagement_environments_environmentId_AvailablePackages_Microsoft_Crm_Cloud_Pes_Tps_UserGetAvailableInstancePackages_Lcid_1033_InstanceCountryCode_US_CrmVersion_9_2_26031_180 | `...033',InstanceCountryCode='US',CrmVersion='9.2.26031.180')` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| TenantApi_get_appmanagement_environments_environmentId_InstancePackages_Microsoft_Crm_Cloud_Pes_Tps_UserGetInstancePackages_Lcid_1033 | `...ft.Crm.Cloud.Pes.Tps.UserGetInstancePackages(Lcid='1033')` | GET | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| TenantApi_get_licensing_autoClaimPolicies | `/licensing/autoClaimPolicies` | GET | unknown | none | - | Software.Version, Url.Path | daily | tenant-gated[404] |

---

## Portal: `purview`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie |
| ClientId | `80ccca67-54bd-44ab-8625-4b79c4dc7775` |
| Audience | `(cookie-based, no audience)` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-purview\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\purview.collection.json` (present)

### Sub-areas: 19 · Endpoints: 127 · Live: 20

#### `audit` [v0.2.0+]

**Sub-area summary:** 2 endpoints · cadence=daily · pagination=pageIndex0Based:1 / none:1 · time-filter coverage=0/2 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| checkAuditEnabled | `/adtsch/AuditEnabled` | GET | unknown | none | - | - | daily | live[200] r=1 |
| listAuditLogSearches | `/adtsch/AuditLogSearch` | GET | unknown | none | - | - | daily | live[200] r=1 |

#### `billing` [v0.2.0+]

**Sub-area summary:** 7 endpoints · cadence=daily · pagination=none:7 · time-filter coverage=0/7 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| checkFreeTrialAvailability | `/cbill/purview/offer/freetrial` | GET | unknown | none | - | Tenant.Id | daily | live[200] r=1 |
| getE5TenantLicenseBreakdown | `/cbill/LicenseUsage/E5TenantLicenseBreakdown` | GET | unknown | none | - | - | daily | error[500] r=0 |
| getE5TenantSolutionBreakdown | `/cbill/LicenseUsage/E5TenantSolutionBreakdown` | GET | unknown | none | - | - | daily | error[500] r=0 |
| getE5TenantUsage | `/cbill/LicenseUsage/E5TenantUsage` | GET | unknown | none | - | - | daily | error[500] r=0 |
| getPurviewBillingAccount | `/cbill/PurviewAccount` | GET | unknown | none | - | - | daily | error[403] r=0 |
| getPurviewBillingAggregates | `/cbill/CbsReport/ReportingAPI/GetAggregates` | POST | unknown | none | - | - | daily | error[415] r=0 |
| getPurviewBillingConfigDetails | `/cbill/PurviewAccount/billing-config-details` | GET | unknown | none | - | - | daily | live[200] r=1 |

#### `communication_compliance` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=topSkip:1 / none:2 · time-filter coverage=0/3 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getCommunicationComplianceServiceSettings | `...CommsComplianceService/api/v1/Supervision/ServiceSettings` | GET | unknown | none | - | - | daily | live[200] r=1 |
| getSelectedSitsForSitIndicator | `.../api/v1/Supervision/Policy/GetSelectedSITsForSITIndicator` | GET | unknown | none | - | - | daily | error[403] r=0 |
| listCommunicationCompliancePolicies | `/gws/CommsComplianceService/api/v1/Supervision/Policy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |

#### `compliance_manager` [v0.2.0+]

**Sub-area summary:** 9 endpoints · cadence=daily · pagination=none:9 · time-filter coverage=0/9 · top entities=Account.UPN · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| exportComplianceManagerHistoryReport | `/cpm/v1.0/Reporting/Export` | POST | unknown | none | - | - | daily | error[400] r=0 |
| getApplicationUserContext | `/cpm/v1.0/ApplicationUserContext` | GET | unknown | none | - | Account.UPN | daily | error[400] r=0 |
| getComplianceManagerUserProfile | `/cpm/v1.0/Users/Profile` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getNativeConnectorJobStatus | `/Ingestion/NativeConnectorJob` | GET | unknown | none | - | - | daily | error[404] r=0 |
| getPremiumRegulationSummary | `/cpm/v1.0/Regulations/PremiumRegulationSummary` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getTenantAssessmentFilters | `/cpm/v1.0/Tenant/Filters` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getTenantCompliancePostureSummary | `/cpm/v1.0/Tenant/CompliancePostureSummary` | POST | unknown | none | - | - | daily | error[400] r=0 |
| listComplianceAssessments | `/cpm/v1.0/Assessments/List` | POST | unknown | none | - | - | daily | error[400] r=0 |
| listRegulationTemplates | `/cpm/v1.0/RegulationTemplates` | GET | unknown | none | - | - | daily | error[400] r=0 |

#### `copilot` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| checkCopilotAuth | `/medeina/auth` | GET | unknown | none | - | - | daily | error[400] r=0 |
| checkSecurityPlatformTenantProvisioning | `/securityplatform/sentinelgraph/provisioning/checkTenant` | POST | unknown | none | - | Software.Version | daily | error[400] r=0 |
| getCopilotAuthExpiryDate | `/medeina/auth/expiryDate` | GET | unknown | none | - | - | daily | error[404] r=0 |
| getCopilotDataShareSettings | `/medeina/settings/datashare` | GET | unknown | none | - | - | daily | error[404] r=0 |
| getSecurityCopilotTrialStatus | `/cdssecuritycopilot/trial` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| getSecurityPlatformAccount | `/securityplatform/provisioning/account` | GET | unknown | none | - | Software.Version | daily | error[400] r=0 |
| listCopilotAgents | `/medeina/agents` | GET | unknown | none | - | - | daily | error[404] r=0 |
| listSecurityPlatformWorkspaces | `/securityplatform/workspaces` | GET | unknown | none | - | Software.Version | daily | error[404] r=0 |

#### `data_governance` [v0.2.0+]

**Sub-area summary:** 3 endpoints · cadence=daily · pagination=none:3 · time-filter coverage=0/3 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getClassificationTypesV2 | `/dgs/item/GetTypesV2` | GET | unknown | none | - | Software.Version | daily | error[500] r=0 |
| getDataGovernanceTypeAggregates | `/dgs/aggregate/GetTypeAggregates` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getTenantLicense | `/dgs/Item/GetTenantLicense` | GET | unknown | none | - | - | daily | live[200] r=1 |

#### `data_infrastructure` [v0.2.0+]

**Sub-area summary:** 24 endpoints · cadence=daily · pagination=pageIndex0Based:3 / none:21 · time-filter coverage=2/24 · top entities=Tenant.Id, Time.Generated · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getAppRetentionCompliancePolicies | `/di/find/AppRetentionCompliancePolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getAutoSensitivityLabelPolicies | `/di/find/AutoSensitivityLabelPolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getComplianceAlerts | `/di/find/Alert` | GET | unknown | none | - | Tenant.Id | 1h | error[403] r=0 |
| getComplianceTags | `/di/find/ComplianceTag` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getCustomTags | `/di/find/CustomTag` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getDlpAlertAgentPolicyInsights | `/di/find/DlpAlertAgentPolicyInsights` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getDlpCompliancePolicies | `/di/find/DlpCompliancePolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getDlpComplianceRules | `/di/find/DlpComplianceRule` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getDlpEdmSchemas | `/di/find/DlpEdmSchema` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getDlpSensitiveInformationTypes | `/di/find/DlpSensitiveInformationType` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getFeatureConfiguration | `/di/find/FeatureConfiguration` | GET | unknown | none | - | Tenant.Id | 6h | error[403] r=0 |
| getInsiderRiskEntityList | `/di/find/InsiderRiskEntityList` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getInsiderRiskPolicies | `/di/find/InsiderRiskPolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getLabelPolicies | `/di/find/LabelPolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getMipAnalyticsTenantSettings | `/di/find/MipAnalyticsTenantSettings` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getMipSavedQueries | `/di/find/MIPSavedQuery` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getPolicyConfig | `/di/find/PolicyConfig` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getProtectionAlertDefinitions | `/di/find/ProtectionAlert` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getProtectionCompliancePolicies | `/di/find/ProtectionCompliancePolicy` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getRetentionEvents | `/di/find/RetentionEvent` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getRiskSpotlightingInsights | `/di/find/RiskSpotlightingInsight` | GET | unknown | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |
| getSensitivityLabels | `/di/find/Label` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| getTrialOffer | `/di/Find/TrialOffer` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| searchLabelAnalyticsActivityData | `/di/search/LabelAnalyticsActivityData` | POST | unknown | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |

#### `data_security_investigations` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| listDataSecurityInvestigations | `/dsi/api/v1/investigations` | GET | unknown | none | - | - | daily | error[403] r=0 |

#### `dlp_devices` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=1h · pagination=pageIndex0Based:1 / none:7 · time-filter coverage=0/8 · top entities=Time.Generated, Host.FullName, Host.MdatpId, Account.AadId, Host.HealthStatus · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getDlpMachineCount | `/mtp/ndr/dlpmachines/count` | GET | unknown | none | - | - | daily | live[200] r=1 |
| getDlpMachineFilters | `/mtp/ndr/dlpmachines/filters` | GET | unknown | none | - | - | daily | live[200] r=1 |
| getDlpMachinesSummaryStatus | `/mtp/ndr/dlpmachines/summaryStatus` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getEndpointDlpLogCollectionSettings | `/edlp/dlpInternalApi/api/cloud/dlp/logCollectionsSetting` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getMtpTenantContext | `/mtp/sccManagement/mgmt/TenantContext` | GET | unknown | none | - | Account.AadId, Tenant.Id | daily | live[200] r=1 |
| listDlpMachines | `/mtp/ndr/dlpmachines` | GET | unknown | pageIndex-unknown (idx=pageIndex,size=pageSize) | - | Host.FullName, Host.HealthStatus, Host.OsPlatform | daily | live[200] r=7 |
| listEndpointDlpLogCollections | `/edlp/dlpInternalApi/api/cloud/dlp/logCollections/` | GET | unknown | none | - | Host.MdatpId | daily | error[400] r=0 |
| queryIncidentAlerts | `/mtp/incidentQueue/incidents/alerts` | POST | unknown | none | - | - | 1h | error[415] r=0 |

#### `ediscovery` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getEdiscoveryFavorites | `/aedmcc/ediscovery/v1/getFavorites` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getEdiscoveryRolesMapping | `/aedmcc/ediscovery/v1/getEDiscoveryRolesMapping` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| getEdiscoveryTenantSettings | `/aedmcc/ediscovery/v1/tenantSettings` | GET | unknown | none | - | - | daily | error[403] r=0 |
| getEdiscoveryViewState | `/aedmcc/ediscovery/v1/getViewState` | GET | unknown | none | - | - | daily | error[400] r=0 |
| listPurviewEdiscoveryCases | `/aedmcc/ediscovery/v1/purviewcases` | GET/GET/GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| setEdiscoveryViewState | `/aedmcc/ediscovery/v1/setViewState` | POST | unknown | none | - | - | daily | error[415] r=0 |

#### `exchange_admin` [v0.2.0+]

**Sub-area summary:** 1 endpoints · cadence=daily · pagination=none:1 · time-filter coverage=0/1 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| invokeExchangeAdminCommand | `/admin/Beta/{tenantId}/InvokeCommand` | POST | unknown | none | - | Tenant.Id | daily | no-live-pathparam r=0 |

#### `governance_services` [v0.2.0+]

**Sub-area summary:** 6 endpoints · cadence=daily · pagination=none:6 · time-filter coverage=0/6 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| checkPermissionWithScopes | `/gws/ComplianceAuthServer/v1.0/IsAllowedPermissionWithScopes` | POST | unknown | none | - | - | daily | error[400] r=0 |
| getDispositionStatistics | `/gws/DlmServices/api/v1.0/disposition/DispositionStatistics` | GET/GET | unknown | none | - | - | daily | error[500] r=0 |
| getGrantedPermissions | `/gws/ComplianceAuthServer/v1.0/GetGrantedPermissions` | POST | unknown | none | - | - | daily | error[400] r=0 |
| getTrainableClassifierModelMetadataCanonical | `/gws/ipmlservice/CategoryTrainingModel/ModelMetadata` | GET | unknown | none | - | - | daily | error[400] r=0 |
| getUserRoles | `/gws/ComplianceAuthServer/v1.0/GetUserRoles` | POST | unknown | none | - | - | daily | error[400] r=0 |
| getUserRolesWithScopeInfo | `/gws/ComplianceAuthServer/v1.0/GetUserRolesWithScopeInfo` | POST | unknown | none | - | - | daily | error[400] r=0 |

#### `graph_proxy` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=topSkip:1 / none:7 · time-filter coverage=4/8 · top entities=File.Path, Account.SamName · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getAdministrativeUnits | `/msgraph/v1.0/directory/administrativeUnits` | GET | unknown | none | - | File.Path | daily | live-empty[200] r=0 |
| getConditionalAccessPolicies | `/msgraph/beta/identity/conditionalAccess/policies` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| getCurrentUserMemberObjects | `/msgraph/v1.0/me/getMemberObjects` | POST | unknown | none | - | File.Path | daily | error[415] r=0 |
| getDirectoryRoleAssignments | `/msgraph/v1.0/roleManagement/directory/roleAssignments` | GET | unknown | none | - | File.Path | daily | live[200] r=8 |
| getServiceAnnouncementMessages | `/msgraph/v1.0/admin/serviceAnnouncement/messages` | GET | unknown | none | - | - | daily | live[200] r=100 |
| getSubscribedSkus | `/msgraph/v1.0/subscribedSkus` | GET | unknown | none | - | Account.SamName | daily | live[200] r=5 |
| getTransitiveRoleAssignments | `...h/beta/roleManagement/directory/transitiveRoleAssignments` | GET | unknown | none | - | File.Path | daily | error[400] r=0 |
| listDirectoryRoles | `/msgraph/v1.0/directoryRoles` | GET | unknown | none | - | File.Path | daily | live[200] r=7 |

#### `information_protection` [v0.2.0+]

**Sub-area summary:** 2 endpoints · cadence=daily · pagination=none:2 · time-filter coverage=0/2 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getAipTenantInfo | `/aip/api/TenantInfo` | GET | unknown | none | - | - | daily | error[403] r=0 |
| listRmsTrackedDocuments | `/rms/api/docs/all` | GET | unknown | none | - | - | daily | error[500] r=0 |

#### `insider_risk` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=topSkip:2 / none:3 · time-filter coverage=1/5 · top entities=Tenant.Id · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getExtensibleIndicatorLimits | `...siderrisk/api/v1.0/{tenantId}/ExtensibleIndicators/limits` | GET | unknown | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| getInsiderRiskMcasStatus | `/insiderrisk/insiderrisk/api/v1.0/{tenantId}/IsMcasEnabled` | GET | unknown | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| getPolicyScoringDefaults | `...isk/insiderrisk/api/v1.0/{tenantId}/PolicyScoringDefaults` | GET | unknown | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| listExtensibleIndicators | `...risk/insiderrisk/api/v1.0/{tenantId}/ExtensibleIndicators` | GET | unknown | none | - | Tenant.Id | daily | no-live-pathparam r=0 |
| listInsiderRiskAppConnectors | `/mcas/cas/api/v1/app_connectors/` | GET | unknown | offsetLimit (tok=skip) | - | - | daily | error[500] r=0 |

#### `openapi` [v0.2.0+]

**Sub-area summary:** 8 endpoints · cadence=daily · pagination=none:8 · time-filter coverage=0/8 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Analytics.GetLabelUserActivityChartData | `/api/LabelUserActivityLog/GetChartData` | POST | unknown | none | - | - | daily | error[404] r=0 |
| Analytics.GetReportSummaryData | `/api/Report/GetReportSummaryData` | POST | unknown | none | - | - | daily | error[404] r=0 |
| Audit.GetAdminAuditLogConfig | `/api/adminauditlogconfig/` | GET | read | none | - | - | daily | error[404] r=0 |
| Auth.GetCachedRoles | `/api/v2/auth/GetCachedRoles` | GET | unknown | none | - | - | daily | error[404] r=0 |
| Auth.GetSpaAuthCode | `/api/Auth/getSpaAuthCode` | GET | unknown | none | - | - | daily | error[404] r=0 |
| Auth.GetToken | `/api/Auth/getToken` | GET | unknown | none | - | - | daily | error[404] r=0 |
| Auth.IsInRoles | `/api/auth/IsInRoles` | POST | unknown | none | - | - | daily | error[404] r=0 |
| Users.Search | `/api/user/` | GET | unknown | none | - | - | daily | error[404] r=0 |

#### `platform_services` [v0.2.0+]

**Sub-area summary:** 10 endpoints · cadence=daily · pagination=none:10 · time-filter coverage=1/10 · top entities=Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getAzurePurviewAccount | `/azurepurview/account` | GET | unknown | none | - | Software.Version | daily | error[400] r=0 |
| getIrisSelection | `/iris/v4/api/selection` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| getOfficeConfigPolicies | `/ocps/user/v1.0/web/policies` | GET | unknown | none | - | Software.Version | daily | live[200] r=1 |
| getOverallProtectionStatus | `/purviewplatform/api/v1/insight/GetOverallProtectionStatus` | GET | unknown | none | - | - | daily | live[200] r=1 |
| getPlatformTypeAggregates | `/purviewplatform/api/v1/insight/GetTypeAggregates` | GET | unknown | none | - | - | daily | error[500] r=0 |
| getRecommendedTasks | `/purviewplatform/api/v1/insight/RecommendedTasks` | GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| getShellInfo | `/shell/api/shell/shellinfo` | GET | unknown | none | - | Software.Version | daily | live[200] r=1 |
| getStartedTasks | `/purviewplatform/api/v1/insight/GetStartedTasks` | GET | unknown | none | - | - | daily | live[200] r=3 |
| getTypeAggregatesByWorkload | `/purviewplatform/api/v1/insight/GetTypeAggregatesByWorkload` | GET | unknown | none | - | - | daily | error[500] r=0 |
| listArmRoleAssignments | `/arm/providers/Microsoft.Authorization/roleAssignments` | GET | unknown | none | - | Software.Version | daily | error[400] r=0 |

#### `purview_for_ai` [v0.2.0+]

**Sub-area summary:** 14 endpoints · cadence=daily · pagination=none:14 · time-filter coverage=3/14 · top entities=Tenant.Id, Time.Generated, Software.Name · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| getPurviewAiHubActionsStatus | `/cpm/v1.0/Tenant/AIHubActionsStatus` | GET | unknown | none | - | Tenant.Id | daily | error[400] r=0 |
| getPurviewAiIrmTenantStatus | `/WdatpPublicApi/irm/tenant/status` | GET | unknown | none | - | Tenant.Id | daily | live[200] r=1 |
| getPurviewDefaultDataShareWorkspace | `/medeina/settings/datashare/defaultWorkspace` | GET | unknown | none | - | - | daily | error[404] r=0 |
| getPurviewForAiInsights | `/di/find/PurviewForAI` | GET | unknown | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |
| getPurviewForAiSettings | `/di/find/PurviewForAISetting` | GET | unknown | none | - | Tenant.Id | daily | error[403] r=0 |
| listDspmAiAgents | `/gws/dspmaimtapp/api/v1/Agents` | POST | unknown | none | - | - | daily | error[415] r=0 |
| listPurviewAgentDefinitions | `/medeina/agentDefinitions` | GET | unknown | none | - | Software.Name | daily | error[404] r=0 |
| listPurviewAiOversharingAssessments | `/oversharing/api/v1/p4ai/assessment` | GET/GET | unknown | none | - | - | daily | live-empty[200] r=0 |
| registerPurviewAiTenant | `/oversharing/api/v1/p4ai/tenant/register` | POST | unknown | none | - | Tenant.Id | daily | live[200] r=1 |
| searchDspmAiScenarios | `/gws/dspmaimtapp/api/v1/scenariosearch` | POST | unknown | none | - | - | daily | error[415] r=0 |
| searchPurviewDataAssessmentsInsights | `/di/search/PurviewDataAssessmentsInsights` | POST | unknown | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |
| searchPurviewForAiActivityData | `/di/search/PurviewForAIActivityData` | POST | unknown | none | start=startTime end=endTime type=iso8601 | Tenant.Id, Time.Generated | daily | error[403] r=0 |
| validatePurviewAiFabricStoredSettings | `...rsharing/api/v1/p4ai/tenantSettings/validateStored/fabric` | POST | unknown | none | - | - | daily | error[404] r=0 |
| validatePurviewAiStoredSettings | `/oversharing/api/v1/p4ai/tenantSettings/validateStored` | POST | unknown | none | - | - | daily | error[404] r=0 |

#### `sharepoint` [v0.2.0+]

**Sub-area summary:** 2 endpoints · cadence=daily · pagination=none:2 · time-filter coverage=0/2 · top entities=- · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| checkAipIntegrationEnabled | `/spo/admin/_api/SPO.Tenant/EnableAIPIntegration` | GET | unknown | none | - | - | daily | error[403] r=0 |
| checkSensitivityLabelForPdfEnabled | `/spo/admin/_api/SPO.Tenant/EnableSensitivityLabelForPDF` | GET | unknown | none | - | - | daily | error[403] r=0 |

---

## Portal: `purview-portal`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie+silent-token |
| ClientId | `80ccca67-54bd-44ab-8625-4b79c4dc7775` |
| Audience | `same-origin /api/Auth/getToken mints downstream` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-purview-portal\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\purview-portal.collection.json` (present)

_(no sub-areas)_

---

## Portal: `security-copilot`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer-multi-host |
| ClientId | `TBD-extract-from-next-js-bundle` |
| Audience | `TBD per host` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-security-copilot\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\security-copilot.collection.json` (present)

### Sub-areas: 1 · Endpoints: 32 · Live: 2

#### `openapi` [v0.2.0+]

**Sub-area summary:** 32 endpoints · cadence=daily · pagination=none:32 · time-filter coverage=0/32 · top entities=File.Path, Account.AadId · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| Account.ListWorkspaces | `/account/workspaces` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| ActionGateway.EvaluateContainerPermissions | `/api/gateway/actions/containers/me` | POST | unknown | none | - | - | daily | unprobed |
| AgentDefinitions.List | `...rkspaces/{workspaceName}/securitycopilot/agentdefinitions` | GET | unknown | none | - | - | daily | unprobed |
| Agents.List | `...{podId}/workspaces/{workspaceName}/securitycopilot/agents` | GET | unknown | none | - | - | daily | unprobed |
| Auth.GetExpiryDate | `/auth/expiryDate` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Auth.GetUserInfo | `/auth/userInfo` | GET | unknown | none | - | - | daily | live[200] |
| Auth.Probe | `/auth` | GET | unknown | none | - | - | daily | request-shape-error[400] |
| GraphData.GetDetails | `/graphData/details` | POST | unknown | none | - | File.Path | daily | unprobed |
| Personas.ListSkillsets | `...spaces/{workspaceName}/securitycopilot/personas/skillsets` | GET | unknown | none | - | - | daily | unprobed |
| Personas.ListValues | `...orkspaces/{workspaceName}/securitycopilot/personas/values` | GET | unknown | none | - | - | daily | unprobed |
| Promptbooks.List | `...d}/workspaces/{workspaceName}/securitycopilot/promptbooks` | GET | unknown | none | - | - | daily | unprobed |
| PromptSuggestions.ListByPersona | `...orkspaceName}/securitycopilot/prompt-suggestions/personas` | GET | unknown | none | - | - | daily | unprobed |
| Provisioning.CheckTenant | `/provisioning/checkTenant` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Provisioning.CreateWhatIf | `/provisioning/create` | POST | unknown | none | - | - | daily | unprobed |
| Provisioning.GetAccount | `/provisioning/account` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Sessions.List | `...odId}/workspaces/{workspaceName}/securitycopilot/sessions` | GET | unknown | none | - | - | daily | unprobed |
| Settings.GetDataShare | `/settings/datashare` | GET | write | none | - | - | daily | tenant-gated[404] |
| Settings.GetDefaultWorkspace | `/settings/datashare/defaultWorkspace` | GET | write | none | - | - | daily | tenant-gated[404] |
| Skillsets.CheckRequirements | `...orkspaceName}/securitycopilot/skillsets/checkRequirements` | GET | unknown | none | - | - | daily | unprobed |
| Skillsets.List | `...dId}/workspaces/{workspaceName}/securitycopilot/skillsets` | GET | unknown | none | - | - | daily | unprobed |
| Skillsets.ListConfigurations | `.../{workspaceName}/securitycopilot/skillsets/configurations` | GET | unknown | none | - | - | 6h | unprobed |
| Skillsets.ListSkills | `...paceName}/securitycopilot/skillsets/{skillsetName}/skills` | GET | unknown | none | - | - | daily | unprobed |
| Store.GetClientConfiguration | `/config/v1/SecurityMarketplaceClient/1.0.0` | GET | unknown | none | - | - | 6h | tenant-gated[404] |
| Store.SearchCatalog | `/catalog/search` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Trial.List | `/trial` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Usage.ListCapacities | `/usage/capacities` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| UserPreferences.GetCurrentWorkspace | `/userPreferences/currentWorkspace` | GET | unknown | none | - | - | daily | tenant-gated[404] |
| Users.GetActivities | `...{workspaceName}/securitycopilot/users/{userId}/activities` | GET | unknown | none | - | Account.AadId | daily | unprobed |
| Users.GetFeatures | `/users/features` | GET | unknown | none | - | - | daily | live[200] |
| Workspace.ListAvailableTrials | `...orkspaces/{workspaceName}/securitycopilot/availabletrials` | GET | unknown | none | - | - | daily | unprobed |
| WorkspacePolicy.Get | `...d}/policystore/workspaces/{workspaceName}/workspacePolicy` | GET | unknown | none | - | - | daily | unprobed |
| Workspaces.Get | `/pods/{podId}/workspaces/{workspaceName}` | GET | unknown | none | - | - | daily | unprobed |

---

## Portal: `sharepoint`

### Auth

| Field | Value |
|---|---|
| Bucket | A-cookie+digest |
| ClientId | `TBD-discover-from-tenant-admin-spo-bundle` |
| Audience | `(cookie-based)` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-sharepoint-admin\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\sharepoint-admin.collection.json` (present)

### Sub-areas: 1 · Endpoints: 35 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 35 endpoints · cadence=daily · pagination=none:35 · time-filter coverage=0/35 · top entities=Software.Version, Url.Path, File.Path · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| CanUserCreateGroup | `/_api/GroupSiteManager/CanUserCreateGroup` | GET | unknown | none | - | - | daily | tenant-gated[401] |
| CheckSiteExists | `/_api/SP.Site.Exists(url=@v)` | GET/GET | read | none | - | File.Path, Url.Path | daily | tenant-gated[401] |
| CheckTenantLicenses | `/_api/SPOInternalUseOnly.Tenant/CheckTenantLicenses` | GET | read | none | - | - | daily | tenant-gated[401] |
| ExportSitesToCsv | `/_api/SPO.Tenant/ExportToCSV` | POST | read | none | - | - | daily | unprobed |
| GetAdminListItemCount | `/_api/SPO.Tenant/GetSPListItemCount` | POST | read | none | - | - | daily | unprobed |
| GetAdminListRootFolderProperties | `/_api/SPO.Tenant/GetSPListRootFolderProperties` | POST | read | none | - | - | daily | unprobed |
| GetAdminListViews | `/_api/SPO.Tenant/GetAdminListViews` | GET/GET | read | none | - | - | daily | tenant-gated[401] |
| GetAllWebTemplates | `/_api/SPO.Tenant/GetSPOAllWebTemplates` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetAutoQuotaEnabled | `/_api/TenantAdminSettings/AutoQuotaEnabled` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetBrandCenterConfiguration | `/_api/SPO.Tenant/GetBrandCenterConfiguration` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetClientSideComponents | `/_api/web/GetClientSideComponents` | POST | read | none | - | - | daily | unprobed |
| GetCurrentTenantSettings | `/_api/SP_TenantSettings_Current` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetFilteredListItems | `/_api/SPO.Tenant/GetFilteredSPListItems` | POST/GET/GET | read | none | - | - | daily | tenant-gated[401] |
| GetGroupCreationContext | `/_api/GroupSiteManager/GetGroupCreationContext` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetHomeSitesDetails | `/_api/SPO.Tenant/GetHomeSitesDetails` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetHubSites | `/_api/HubSites` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetInternalTenantAdminSettings | `/_api/SPOInternalUseOnly.TenantAdminSettings` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetInternalTenantProperties | `/_api/SPOInternalUseOnly.Tenant` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetMigrationTotalDevicesAdded | `/_api/MigrationCenterServices/Storage/TotalDevicesAdded` | GET/GET | read | none | - | - | daily | tenant-gated[401] |
| GetRestrictedOneDriveLicense | `/_api/SPO.Tenant/RestrictedOneDriveLicense` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetSiteAdministrators | `/_api/SPO.Tenant/GetSiteAdministrators` | POST/GET | read | none | - | Url.Path | daily | tenant-gated[401] |
| GetSiteCreationSources | `/_api/SPO.Tenant/GetSPOSiteCreationSources` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetSitesByState | `/_api/SPO.Tenant/GetSitesByState` | POST | read | none | - | - | daily | unprobed |
| GetStorageQuotas | `/_api/StorageQuotas()` | GET | read | none | - | Software.Version | daily | tenant-gated[401] |
| GetSuiteNavData | `.../Microsoft.SharePoint.Portal.SuiteNavData.GetSuiteNavData` | GET | read | none | - | Software.Version | weekly | tenant-gated[401] |
| GetTenantAdminEndpoints | `/_api/TenantAdminEndpoints` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetTenantAdminSettings | `/_api/TenantAdminSettings` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetTenantInformationCollection | `/_api/TenantInformationCollection` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetTenantProperties | `/_api/SPO.Tenant` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetTenantSharingStatus | `/_api/TenantAdminSettings/GetTenantSharingStatus` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetTrackViewFeatureVisibility | `/_api/SPO.Tenant/GetTrackViewFeatureAlwaysVisible` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetUnifiedStorageQuotaEligibility | `/_api/v2.1/unifiedStorageQuotaEligible` | GET | read | none | - | - | daily | tenant-gated[401] |
| GetUnifiedStorageQuotaService | `/_api/v2.1/unifiedstoragequota/tenant/services/SPO` | GET | read | none | - | - | daily | tenant-gated[401] |
| RenderAdminListData | `/_api/SPO.Tenant/RenderAdminListData` | POST | unknown | none | - | - | daily | unprobed |
| UpdateJobsWorkItems | `/_api/SPO.Tenant/UpdateJobsWorkItems` | POST | write | none | - | - | daily | unprobed |

---

## Portal: `teams`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer-regional |
| ClientId | `TBD-from-msftauth-bundle` |
| Audience | `TBD via regional discovery: POST /api/authsvc/v1.0/users/region` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-teams\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\teams.collection.json` (present)

### Sub-areas: 1 · Endpoints: 98 · Live: 56

#### `openapi` [v0.2.0+]

**Sub-area summary:** 98 endpoints · cadence=daily · pagination=none:98 · time-filter coverage=0/98 · top entities=Url.Path, Tenant.Id, Account.AadId, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| admin_api_v1_MoPo_metaData | `/admin/api/v1/MoPo/metaData` | GET | unknown | none | - | Url.Path | daily | live[200] |
| AdminAppCatalog_teamsApps | `/AdminAppCatalog/teamsApps` | GET | unknown | none | - | Url.Path | daily | live[200] |
| AdminAppCatalog_teamsApps__catalogAppId__appAssignments | `/AdminAppCatalog/teamsApps/{catalogAppId}/appAssignments` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| AdminAppCatalog_teamsApps_acmStatus | `/AdminAppCatalog/teamsApps/acmStatus` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_reports_v1_0_flw_orchestration_usage | `/amer/api/reports/v1.0/flw/orchestration/usage` | POST | unknown | none | - | Url.Path | daily | error r=0 |
| amer_api_reports_v1_0_flw_usage | `/amer/api/reports/v1.0/flw/usage` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_reports_v1_0_flw_usage_metadata | `/amer/api/reports/v1.0/flw/usage/metadata` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_v1_0_hybridTeams_deployedLocationsCount | `/amer/api/v1.0/hybridTeams/deployedLocationsCount` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_v1_0_managementUnits | `/amer/api/v1.0/managementUnits` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_v1_0_orchestrationStatus | `/amer/api/v1.0/orchestrationStatus` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_v1_0_settings | `/amer/api/v1.0/settings` | GET | unknown | none | - | Url.Path | daily | live[200] |
| amer_api_v1_Security_Rules_InactiveTeams_View_Details | `/amer/api/v1/Security/Rules/InactiveTeams/View-Details` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_authsvc_v1_0_users_region | `/api/authsvc/v1.0/users/region` | POST | unknown | none | - | Url.Path | daily | error r=0 |
| api_log | `/api/log` | POST | unknown | none | - | Url.Path | daily | error[415] r=0 |
| api_mt__beta_me_engagementSurfaces | `/api/mt//beta/me/engagementSurfaces` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_mt_part__partition___beta_me_engagementSurfaces | `/api/mt/part/{partition}//beta/me/engagementSurfaces` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition___beta_me_engagementSurfaces_displayed | `...mt/part/{partition}//beta/me/engagementSurfaces/displayed` | PUT | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_apps__catalogAppId__appAccessRequests | `...rtition}/beta/admin/apps/{catalogAppId}/appAccessRequests` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_apps_appAccessRequests | `/api/mt/part/{partition}/beta/admin/apps/appAccessRequests` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_deviceStoreSetting | `/api/mt/part/{partition}/beta/admin/deviceStoreSetting` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_getAgentSettingsForTAC | `/api/mt/part/{partition}/beta/admin/getAgentSettingsForTAC` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_tenantSharedChannelsSettings | `.../part/{partition}/beta/admin/tenantSharedChannelsSettings` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_admin_tenantStagedApps | `/api/mt/part/{partition}/beta/admin/tenantStagedApps` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_users_apps_store | `/api/mt/part/{partition}/beta/users/apps/store` | POST | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_users_appsCatalog | `/api/mt/part/{partition}/beta/users/appsCatalog` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_users_tenantWideAppsSettings | `/api/mt/part/{partition}/beta/users/tenantWideAppsSettings` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_mt_part__partition__beta_users_useraggregatesettings | `/api/mt/part/{partition}/beta/users/useraggregatesettings` | POST | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_ths_api_v1_hierarchies__tenantId__operations | `...erarchies/45f52f35-73d5-4066-8378-fe506ee90fb1/operations` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | live[200] |
| api_user_IsAdminForVirtualVisitsAnalytics | `/api/user/IsAdminForVirtualVisitsAnalytics` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_0_assets | `/api/v1.0/assets` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_0_offers__offerId | `/api/v1.0/offers/{offerId}` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| api_v1_CartService_carts | `/api/v1/CartService/carts` | POST | unknown | none | - | Url.Path | daily | error[401] r=0 |
| api_v1_clientHealth_clientHealthDetails | `/api/v1/clientHealth/clientHealthDetails` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_clientHealth_clientHealthIssues | `/api/v1/clientHealth/clientHealthIssues` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_clientHealth_clientHealthTopIssues | `/api/v1/clientHealth/clientHealthTopIssues` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_clientHealth_clientHealthUpdateStatus | `/api/v1/clientHealth/clientHealthUpdateStatus` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_clientHealth_clientHealthUserDevices | `/api/v1/clientHealth/clientHealthUserDevices` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_ContentManagementService_BannerApps | `/api/v1/ContentManagementService/BannerApps` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_DeploymentTasks_getdefault | `/api/v1/DeploymentTasks/getdefault` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_DeploymentTeams | `/api/v1/DeploymentTeams` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_jobs | `/api/v1/jobs` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_mta_rule | `/api/v1/mta/rule` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_mta_TenantclusterLookup | `/api/v1/mta/TenantclusterLookup` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_NetworkPlans_getplansintenant | `/api/v1/NetworkPlans/getplansintenant` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_Persona_GetAll | `/api/v1/Persona/GetAll` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_regionalDomainNameForTenant | `/api/v1/regionalDomainNameForTenant` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v1_userpreference | `/api/v1/userpreference` | GET/PUT | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_usersettings | `/api/v1/usersettings` | GET | unknown | none | - | Url.Path | daily | tenant-gated[401] |
| api_v1_virtualvisits_aggregaterecords | `/api/v1/virtualvisits/aggregaterecords` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v2_0_billing_accounts | `/api/v2.0/billing-accounts` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v2_devices | `/api/v2/devices` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v2_devices_summary | `/api/v2/devices/summary` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v2_tags_enroll | `/api/v2/tags/enroll` | GET | unknown | none | - | Url.Path | daily | live[200] |
| api_v2_tenants__tenantId | `/api/v2/tenants/45f52f35-73d5-4066-8378-fe506ee90fb1` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | live[200] |
| config_v1_MicrosoftTeams__version | `/config/v1/MicrosoftTeams/{version}` | GET | unknown | none | - | Software.Version, Url.Path | daily | no-live-pathparam r=0 |
| config_v1_Skype__version | `/config/v1/Skype/{version}` | GET | unknown | none | - | Software.Version, Url.Path | daily | no-live-pathparam r=0 |
| data_noam_DataUpload_AllTenantDataFiles | `/data/noam/DataUpload/AllTenantDataFiles` | GET | unknown | none | - | Url.Path | daily | live[200] |
| data_noam_RunQueryDashboard | `/data/noam/RunQueryDashboard` | POST | unknown | none | - | Url.Path | daily | error r=0 |
| hasActiveCapabilities | `/hasActiveCapabilities` | POST | unknown | none | - | Url.Path | daily | error r=0 |
| haslicense | `/haslicense` | GET | unknown | none | - | Url.Path | daily | server-error[503] |
| internal_ux_getTeamsAppUsageDetail | `/internal/ux/getTeamsAppUsageDetail` | GET | unknown | none | - | Url.Path | daily | live[200] |
| internal_ux_getTeamsPremiumV2ActiveUserCounts | `/internal/ux/getTeamsPremiumV2ActiveUserCounts` | GET | unknown | none | - | Url.Path | daily | live[200] |
| internal_ux_getTeamsPremiumV2MeetingCounts | `/internal/ux/getTeamsPremiumV2MeetingCounts` | GET | unknown | none | - | Url.Path | daily | live[200] |
| internal_ux_getTeamsPremiumV2UserDetail | `/internal/ux/getTeamsPremiumV2UserDetail` | GET | unknown | none | - | Url.Path | daily | live[200] |
| private_intraTenantConfig_host | `/private/intraTenantConfig/host` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Realtime_Analytics_Users__userId__CommunicationsSummary__lookbackDays | `...ytics/Users/{userId}/CommunicationsSummary/{lookbackDays}` | GET | unknown | none | - | Account.AadId, Url.Path | daily | no-live-pathparam r=0 |
| regionalDomainNameForTenant | `/regionalDomainNameForTenant` | GET | unknown | none | - | Url.Path | daily | live[200] |
| repository_tenant_dataservice | `/repository/tenant/dataservice` | GET | unknown | none | - | Url.Path | daily | server-error[503] |
| Skype_Ncs_civicAddresses_filters | `/Skype.Ncs/civicAddresses/filters` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Skype_Ncs_locations_filters | `/Skype.Ncs/locations/filters` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Skype_OperatorConnect_operator_consents | `/Skype.OperatorConnect/operator-consents` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Skype_OperatorConnect_operators | `/Skype.OperatorConnect/operators` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Skype_Policy_assignments_operationsall | `/Skype.Policy/assignments/operationsall` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Skype_Policy_configurations__policyType | `/Skype.Policy/configurations/{policyType}` | GET | unknown | none | - | Url.Path | 6h | no-live-pathparam r=0 |
| Skype_Policy_configurations__policyType__configuration__policyName | `...cy/configurations/{policyType}/configuration/{policyName}` | GET | unknown | none | - | Url.Path | 6h | no-live-pathparam r=0 |
| Skype_TelephoneNumberMgmt_Tenants__tenantId___telephonyResource | `...elephoneNumberMgmt/Tenants/{tenantId}/{telephonyResource}` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | no-live-pathparam r=0 |
| Skype_TelephoneNumberMgmt_tenants__tenantId__country__countryCode___briefType | `...Mgmt/tenants/{tenantId}/country/{countryCode}/{briefType}` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | no-live-pathparam r=0 |
| Skype_TelephoneNumberMgmt_tenants__tenantId__port_out_pin | `...tenants/45f52f35-73d5-4066-8378-fe506ee90fb1/port-out-pin` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | live[200] |
| Skype_TelephoneNumberMgmt_Tenants__tenantId__telephone_number_aggregation | `...-73d5-4066-8378-fe506ee90fb1/telephone-number-aggregation` | GET | unknown | none | - | Tenant.Id, Url.Path | daily | live[200] |
| Skype_TelephoneNumberMgmt_tenants__tenantId__voice_users__userId | `...378-fe506ee90fb1/voice-users/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Tenant.Id, Url.Path | daily | live[200] |
| Skype_User_users__userId__policies | `/Skype.User/users/xdrlogreader@CloudSectra.com/policies` | GET | unknown | none | - | Account.AadId, Url.Path | daily | live[200] |
| Teams_Artifacts_meetingTemplate_admin_descriptions | `/Teams.Artifacts/meetingTemplate/admin/descriptions` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_Cpc_bridges | `/Teams.Cpc/bridges` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_Cpc_languagesSupported | `/Teams.Cpc/languagesSupported` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_Cpc_users__userId | `/Teams.Cpc/users/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Url.Path | daily | live[200] |
| Teams_PlatformService_v2_ApplicationInstances | `/Teams.PlatformService/v2/ApplicationInstances` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_SilentTest_list | `/Teams.SilentTest/list` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_Templates_api_teamtemplates_v1_0__localeCode | `/Teams.Templates/api/teamtemplates/v1.0/{localeCode}` | GET | unknown | none | - | Url.Path | daily | no-live-pathparam r=0 |
| Teams_Tenant_tenants | `/Teams.Tenant/tenants` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_User_users | `/Teams.User/users` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_User_users__userId | `/Teams.User/users/xdrlogreader@CloudSectra.com` | GET | unknown | none | - | Account.AadId, Url.Path | daily | live[200] |
| Teams_VerticalPackaging_package | `/Teams.VerticalPackaging/package` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_auto_attendants | `/Teams.VoiceApps/auto-attendants` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_auto_attendants_count | `/Teams.VoiceApps/auto-attendants/count` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_callqueues | `/Teams.VoiceApps/callqueues` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_callqueues_count | `/Teams.VoiceApps/callqueues/count` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_schedules | `/Teams.VoiceApps/schedules` | GET | unknown | none | - | Url.Path | daily | live[200] |
| Teams_VoiceApps_shared_call_queue_history | `/Teams.VoiceApps/shared-call-queue-history` | GET | unknown | none | - | Url.Path | daily | live[200] |

---

## Portal: `viva`

### Auth

| Field | Value |
|---|---|
| Bucket | B-bearer-PKCE+Bayeux |
| ClientId | `TBD-yammer-msal-pkce-client` |
| Audience | `https://www.yammer.com/user_impersonation` |
| ApiBase | `` |

### Source references

- **Nodoc OpenAPI:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\specifications\nodoc-viva-engage\specification` (present)
- **Postman collection:** `C:\Users\alkef\Desktop\Repos\xdrlograider-v2\tools\..\..\xdrlograider\.internal\nodoc-reference\postman\collections\viva-engage.collection.json` (present)

### Sub-areas: 1 · Endpoints: 5 · Live: 0

#### `openapi` [v0.2.0+]

**Sub-area summary:** 5 endpoints · cadence=daily · pagination=none:5 · time-filter coverage=0/5 · top entities=Url.Path, Software.Version · production scale=-

| Slug | Path | Methods | ReadSemantics | Pagination | TimeFilter | Entities | Cadence | Live |
|---|---|---|---|---|---|---|---|---|
| AdminGraphQL_PostGraphql | `/graphql` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| AuthHelpers_GetAadAccessToken | `/api/v1/oauth2/aad_access_token` | GET | unknown | none | - | Url.Path | daily | other[406] |
| RealtimeRelay_PostConnect | `/cometd/connect` | POST | unknown | none | - | Url.Path | daily | unprobed |
| RealtimeRelay_PostHandshake | `/cometd/handshake` | POST | unknown | none | - | Software.Version, Url.Path | daily | unprobed |
| RealtimeRelay_PostSubscribe | `/cometd/` | POST | unknown | none | - | Url.Path | daily | unprobed |

---

## Appendix A — ReadSemantics distribution (Defender only)

- read: 473 · unknown: 20 · write: 16

### Write-shaped endpoints in Defender (must exclude from Phase 1 manifest)

| Sub-area | Slug |
|---|---|
| cloud_apps | UpdateUsageInfo |
| configuration | SetMcasPreviewFeatures |
| configuration | SetPreviewFeatures |
| endpoint_configuration | SetAdvancedFeatures |
| endpoint_configuration | UpdateCustomCollectionRule |
| endpoint_devices | InvokeAction |
| endpoint_devices | SetAssetValue |
| endpoint_devices | SetCriticalityLevel |
| endpoint_devices | SetExclusionState |
| endpoint_devices | SetRbacGroup |
| endpoint_devices | SetTag |
| exposure_management | RunHuntingQuery |
| files | CreateSampleCollectionRequest |
| multi_tenant | RunHuntingQuery |
| portal_services | InvokeAdminCommand |
| threat_analytics | UpdateOutbreakUserState |

### Unknown-classification endpoints in Defender (need manual review)

| Sub-area | Slug |
|---|---|
| cloud_apps | AutocompleteAppPermissionNames |
| cloud_apps | AutocompleteAppPermissionPermissions |
| cloud_apps | AutocompleteDiscoveryAppTags |
| cloud_apps | AutocompleteEntities |
| cloud_apps | AutocompleteScopedProfiles |
| cloud_apps | AutocompleteTags |
| cloud_apps | AutocompleteTokens |
| cloud_apps | AutocompleteUsers |
| cloud_apps | CountSiemAgents |
| cloud_apps | IsExternalAdminUser |
| cloud_apps | LogTranslationError |
| endpoint_devices | HasAnyActionRequests |
| endpoint_devices | PrefetchMachineTimeline |
| files | GenerateSampleDownloadUri |
| files | GoHunt |
| portal_services | AggregateSubmissionDiesData |
| portal_services | AggregateThreatInstances |
| portal_services | AggregateThreatProfileDetails |
| sentinel_precision | CountThreatIntelligence |
| threat_analytics | CountOutbreakIndicators |

## Appendix B — Cadence + production-scale map (Defender Phase 1)

| Sub-area | Cadence | Pagination distribution | Time-filter coverage | Top entities | Production scale |
|---|---|---|---|---|---|
| action_center | daily | topSkip:2 / pageIndex0Based:1 / none:7 / pageIndex1Based:1 | 0/11 | Investigation.Id, Time.Generated, Action.Id, Host.MdatpId | 100-10K events · risk=LOW · delta=medium |
| attack_simulator | daily | none:10 | 0/10 | Time.Generated | 10-1K · risk=LOW · delta=low |
| cloud_apps | daily | none:92 | 0/92 | Software.Version, Software.Name, Url.Path, Account.Sid | 10K+ audit/day · risk=HIGH (MCAS audit) · delta=critical |
| configuration | daily | pageIndex0Based:1 / none:52 | 0/53 | Software.Version, Tenant.Id, Url.Path, File.Name | 100-10K · risk=LOW · delta=low |
| data_lake | daily | none:7 | 0/7 | Software.Version, File.Name | 1-10 · risk=LOW · delta=none |
| endpoint_configuration | daily | topSkip:1 / none:17 / pageIndex1Based:1 | 1/19 | Host.MdatpId, Account.UPN, Host.AadDeviceId, Rule.Id | 10-1K · risk=LOW · delta=low |
| endpoint_devices | daily | pageIndex0Based:4 / fromSize:2 / none:41 / pageIndex1Based:1 | 0/48 | Host.MdatpId, Host.FullName, Software.Version, Time.Generated | 10K-1M rows · risk=HIGH on first poll · delta=critical |
| entity_pivots | weekly | none:19 | 0/19 | Url.Domain, Url.Path | per-entity · risk=depends · delta=depends |
| exposure_management | 1h | pageIndex0Based:3 / none:39 | 0/42 | Software.Version, Tenant.Id, Vuln.CveId, Host.RiskScore | 1K-100K rows · risk=MEDIUM · delta=high |
| files | 6h | pageIndex0Based:2 / none:17 | 0/19 | File.Sha256, File.Sha1, Url.Path, File.Name | varies · risk=MEDIUM · delta=medium |
| identity | daily | none:74 | 1/74 | Url.Domain, File.Path, Account.AadId, Account.SamName | 1K-100K rows · risk=MEDIUM · delta=high |
| multi_tenant | daily | none:17 | 0/17 | Tenant.Id, File.Path | 10-1K tenants · risk=LOW · delta=low |
| portal_services | daily | none:21 | 2/21 | Tenant.Id, Time.Generated, Account.UPN, Software.Version | 1-100 · risk=LOW · delta=none |
| secure_score | daily | none:8 | 0/8 | Software.Vendor, Url.Path, Software.Version | 1-100 · risk=LOW · delta=none |
| sentinel_precision | daily | none:16 | 2/16 | Software.Version | varies · risk=MEDIUM · delta=medium |
| streaming | 6h | none:1 | 0/1 | - | 1-10 · risk=LOW · delta=none |
| threat_analytics | 6h | pageIndex0Based:1 / none:19 | 0/20 | Host.RiskScore, Url.Path, Url.Domain | 100-1K · risk=LOW · delta=low |
| vulnerability_management | daily | pageIndex0Based:8 / none:21 / pageIndex1Based:3 | 6/32 | Software.Vendor, Host.OsPlatform, Software.Name, Host.FullName | 10K-500K rows · risk=HIGH (paginated) · delta=critical |
