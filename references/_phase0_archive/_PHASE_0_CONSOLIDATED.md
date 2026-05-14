# XdrLogRaider v2 — Phase 0 consolidated source of truth

**Last updated:** 2026-05-12 (deep audit from disk + nodoc + Microsoft API research + v1/v2 module inventory + full per-endpoint catalogue build). Supersedes prior catalogue index / live audit report claims. Regenerate `_CATALOGUE_INDEX.md` + `_LIVE_AUDIT_REPORT.md` + `_FULL_CATALOGUE.md` after catalogue mutations; this file wins on conflict.

**Layered Phase 0 docs:**
- `_PHASE_0_CONSOLIDATED.md` — this file: decisions, scope rules, completeness checklist (executive layer)
- `_FULL_CATALOGUE.md` — exhaustive per-portal-per-sub-area-per-endpoint table with schema/pagination/time-filter/entities/cadence/live-status (Phase 1 manifest builder's source layer)
- `_CATALOGUE_INDEX.md` — legacy summary index (machine-regenerated)
- `_LIVE_AUDIT_REPORT.md` — live-probe results by SuccessKind (machine-regenerated)
- `_AUTH_INDEX.md` — per-portal auth chain summary

---

## 0. Status (Phase 0 cleanup executed 2026-05-12)

✅ **All Phase 0 cleanup done.** Catalogue is at canonical 509-endpoint Phase 1 state.

| Decision | Status | Action taken |
|---|---|---|
| AH / AI / LR scope | **Wholesale-excluded** (user directive) | Deleted `references/defender/{advanced_hunting,alerts_incidents,live_response}/` — 34 endpoint folders + 6 sub-area files + bad `Reverse-Include-StateEndpoints.ps1` script |
| ReadSemantics annotation | **Done** | All 1727 metadata.json files now carry `readSemantics: 'read'\|'write'\|'unknown'` + `readSemanticsReason`. Defender: 492 read · 17 write · 0 unknown. |
| Unknown resolution | **Done** | 19 unknowns auto-classified as `read` (Count*, Aggregate*, Autocomplete*, Has*, Is*, Generate*, GoHunt, Prefetch); 1 as `write` (`Log*`) — all via semantic-override prefix rules. |
| v1 cross-reference | **Done** | `_VALUE_PROP_VERIFICATION.md` shows 67/72 v1 streams mapped to v2 (5 unmapped: 2 expected in AH/LR exclusions, 3 path-drift gaps Microsoft renamed). 426 net-new v2 read endpoints not in v1. |
| Critical-path verification | **Done** | 16/17 critical paths PRESENT (1 label mismatch in my critical-paths list — `Critical asset classification` covered as `configuration/ListCriticalAssetClassifications` but path-string different from my assumption) |
| Stub-portal verification | **Done** | 7 portals confirmed genuinely single-YAML (entra-b2c, intune-portal, viva, m365-apps-services, entra-iga, entra-idgov, entra-pim) — no missing nodoc files |
| Master index regeneration | **Done** | `_CATALOGUE_INDEX.md` + `_LIVE_AUDIT_REPORT.md` + `_FULL_CATALOGUE.md` all reflect post-revert 1727/116 totals |

**The 3 wholesale-excluded sub-areas (gap deferred to v0.2.0 re-evaluation):**
- `advanced_hunting` — Microsoft Graph covers basic query exec + custom detection rule CRUD ONLY. Portal-internal saved queries / saved functions / community queries / favorites / schema introspection / user preferences are real gaps Microsoft does NOT expose via public API. **User directive: exclude wholesale; revisit v0.2.0 if Graph beta closes the gap.**
- `alerts_incidents` — Microsoft Graph covers basic alert/incident CRUD ONLY. Portal-internal case management / risk factors / audit history / incident graph / dashboard summaries / disruption summary / incident-scoped device-user rollups are real gaps. **User directive: exclude wholesale; revisit v0.2.0.**
- `live_response` — Microsoft MDE REST `/api/libraryfiles` + `/api/machineactions` cover everything. **Truly wholesale-Microsoft-covered; no v0.2.0 reconsideration.**

**Connector mode locked:** READ-ONLY. We do NOT mutate Defender portal state. 17 write-shaped endpoints in catalogue are flagged via `readSemantics='write'` and will be excluded from Phase 1 manifest. We are building a Sentinel/Defender internal-telemetry ingestion connector — not an admin tool.

---

## 1. Locked requirements (mirror of memory — authoritative)

Source of truth: `internal architectural reference`.

| Locked rule | Value |
|---|---|
| Phase 1 portal | Defender XDR only (security.microsoft.com) |
| Phase 1 in-scope sub-areas (18) | action_center, attack_simulator, cloud_apps, configuration, data_lake, endpoint_configuration, endpoint_devices, entity_pivots, exposure_management, files, identity, multi_tenant, portal_services, secure_score, sentinel_precision, streaming, threat_analytics, vulnerability_management |
| Phase 1 wholesale-excluded (3+1) | advanced_hunting, alerts_incidents, live_response (user directive), common (schema-only) |
| Auth chain | SA UPN + TOTP / Passkey → sccauth + XSRF (Defender cookie clientId `80ccca67-54bd-44ab-8625-4b79c4dc7775`); ESTSAUTHPERSISTENT 90-day KMSI; silent prompt=none renewal |
| LA table naming | `Defender_<NodocSubArea>_CL` — LOCKED |
| DCR streams | `Custom-Defender_<NodocSubArea>_CL` (one per sub-area) |
| Mandatory row columns | TimeGenerated, Endpoint, EntityId, SuccessKind, HttpStatus, RawJson, RawResponseBody + ProjectionMap typed cols |
| 4 SuccessKind values | `live`, `live-empty`, `rate-limited`, `error` |
| Scope filter | `ReadSemantics: 'read' \| 'write'` (operationId-driven; NOT HTTP-method-based) |
| Phase 1 FA topology | 18 per-sub-area timer triggers + 1 ConnectorHeartbeat = 19 functions; NOT Durable Functions |
| Heartbeat Notes | MUST populate `{perStream, errors, rate429Count, gzipBytes, fatalError, tier, cadenceSeconds}` (v1 bug fix) |
| Deploy | ARM JSON (NOT Bicep) · WEBSITE_RUN_FROM_PACKAGE · KV-RBAC + SAMI · zip cosign-signed |
| CI | offline gates only (PSSA, Pester, gitleaks, ARM-TTK hard-fail, recompile gate); NO SP secrets in GH Actions; release signing via cosign keyless OIDC OK |
| Online probing | NOT in CI; operators / internal-dev run probes locally with TOTP creds |

---

## 2. Scope rules

**Per-endpoint inclusion check (in order):**

1. **Is the sub-area in-scope?** Defender Phase 1 in-scope list above. If sub-area is excluded → exclude.
2. **Is endpoint state-read?** `ReadSemantics: 'read'`:
   - **read** if operationId/slug starts with: `List, Get, Query, Search, Filter, Export, Probe, Fetch, Read, Inspect, Audit, Find, Resolve, Validate, Check, Test`
   - **write** if starts with: `Create, Update, Delete, Save, Add, Remove, Move, Patch, Modify, Submit, Invoke, Run, Refresh, Reset, Reload, Reboot, Trigger, Send, Post, Put, Push, Apply, Approve, Reject, Suppress, Unsuppress, Disable, Enable, Override, Set`
   - `write` → exclude from manifest (we ingest events/state, never invoke actions).
3. **Does Microsoft public API cover this endpoint?** Check overlap matrix in §3. If covered → exclude.
4. Else → include in catalogue + manifest.

HTTP method is NOT a filter — POST endpoints can be read operations (query/filter/search with body for complex filters). The 2026-05-12 prior-session `GET-only filter` violated this rule.

---

## 3. Microsoft official API overlap matrix (2026)

Verdict source: parallel Microsoft API research with WebFetch on docs.microsoft.com.

| Defender feature | Microsoft official surface | GA/Beta | Verdict |
|---|---|---|---|
| Alerts (`alerts_v2`) | Microsoft Graph Security `/security/alerts_v2` | GA (legacy `microsoft.graph.alert` REMOVED April 2026) | Excluded (basic CRUD) |
| Incidents | Microsoft Graph Security `/security/incidents` | GA | Excluded (basic CRUD) |
| Incident risk factors / case mgmt / audit history / incident graph / suppression counts / disruption / dashboard / per-incident device-user rollups | NOT in Graph or MDE REST | n/a | **GAP — wholesale-excluded per user directive; documented for v0.2.0 re-evaluation** |
| Advanced Hunting query execution | Microsoft Graph `/v1.0/security/runHuntingQuery` | GA | Excluded |
| Custom Detection Rules CRUD | Microsoft Graph beta `/beta/security/rules/detectionRules` (`microsoft.graph.security.detectionRule`) | Beta only (May 2026) | Excluded |
| Saved hunting queries / saved functions / community queries / favorites / schema introspection / user prefs | NOT in Graph or MDE REST | n/a | **GAP — wholesale-excluded per user directive; documented for v0.2.0 re-evaluation** |
| Live Response sessions + commands | MDE REST `/api/machines/{id}/runliveresponse` + `/api/machineactions/{id}/getLiveResponseResultDownloadLink` | GA | Excluded |
| Live Response library | MDE REST `GET/POST/DELETE /api/libraryfiles` | GA | Excluded |
| Machine actions (isolate, scan, etc.) | MDE REST `/api/machineactions` | GA | Excluded (we don't perform actions anyway) |
| Streaming Event Hub / Storage destination config | Microsoft Graph beta + MDE REST | GA/Beta | Sub-area `streaming` in-scope for state-read only (last-touched config) |
| Purview Unified Audit Log | M365 Defender Purview UAL API | GA | Excluded UAL-equivalent events; we capture portal-internal **STATE-SNAPSHOTS**, not change-events |

**Defender portal-internal state Microsoft does NOT cover** = our value-prop scope:

- Action Center pending/history snapshot views
- Attack Simulator config + training campaign state
- Cloud Apps (MCAS) policy/governance/discovery state
- Configuration: suppression rules, NDR rules, XSPM atlas rules, web category policies, critical-asset classification (DRIFT snapshots)
- Data Lake settings
- Endpoint Configuration: Advanced Features 24 toggles, ASR rule state via `/mem/securityPolicies`, custom collection rules, MDIoT settings
- Endpoint Devices: NDR machines view, MDE timeline experience, MDI sensor compatibility, device management aggregates, tag/criticality state
- Entity Pivots: per-entity drill-down state
- Exposure Management: XSPM dashboards, attack paths, critical asset criticality
- Files: file detail/timeline state
- Identity: MDI account state, sensor view
- Multi-Tenant Ops: tenant inventory, MTO state
- Portal Services: RBAC roles, scopes, service health
- Secure Score: portal-internal DCSPM/TVM/V2 views Graph doesn't cover
- Sentinel Precision: defender→sentinel forwarding state
- Streaming: destination config + last-touched state
- Threat Analytics: TI feeds, reports state
- Vulnerability Management: TVM dashboards, CVE/asset coverage

---

## 4. Current catalogue state (verified from disk)

**Global tally:** 20 portals · 1,761 endpoint metadata.json files · 354 live-captured · all 20 portals have `_AUTH_RESEARCH.json`.

**Defender (Phase 1 — currently in 3-sub-area-over state pending Decision 1):**
- Sub-areas: 21 (correct = 18 after revert)
- Endpoints: 543 (correct = 509 after revert)
- ReadSemantics distribution: 508 read · 22 write · 22 unknown · ~1 pending (post-revert: 491 read · 19 write · ~18 unknown after the 34 endpoints removed)
- Live-captured: 120 (out of 543 = 22.1%)

**Defender per-sub-area** (post-revert assumption — 509 endpoints):

| Sub-area | Endpoints | Cadence | Pagination styles | Top live count |
|---|---:|---|---|---:|
| action_center | 11 | 10min | pageIndex0Based:3 / 1Based:1 / none:7 | 5 |
| attack_simulator | 10 | daily | none:10 | 5 |
| cloud_apps | 92 | daily | none:92 | 2 |
| configuration | 53 | daily | 0Based:1 / none:52 | 22 |
| data_lake | 7 | daily | none:7 | 0 |
| endpoint_configuration | 19 | daily | topSkip:1 / 1Based:1 / none:17 | 5 |
| endpoint_devices | 48 | daily | 0Based:4 / 1Based:1 / none:41 / fromSize:2 | 12 |
| entity_pivots | 19 | weekly | none:19 | 0 |
| exposure_management | 42 | 1h | 0Based:3 / none:39 | 18 |
| files | 19 | 6h | 0Based:2 / none:17 | 1 |
| identity | 74 | daily | none:74 | 14 |
| multi_tenant | 17 | daily | none:17 | 6 |
| portal_services | 21 | daily | none:21 | 7 |
| secure_score | 8 | daily | none:8 | 7 |
| sentinel_precision | 16 | daily | none:16 | 0 |
| streaming | 1 | 6h | none:1 | 0 |
| threat_analytics | 20 | 6h | 0Based:1 / none:19 | 4 |
| vulnerability_management | 32 | daily | 0Based:8 / 1Based:3 / none:21 | 12 |
| **Subtotal Phase 1** | **509** | | | **120** |

**Non-Defender portals (v0.2.0+ scope):**

| Portal | Sub-areas | Endpoints | Live | Auth |
|---|---:|---:|---:|---|
| entra-b2c | 1 | 5 | 0 | Bearer (needs verification — looks like stub) |
| entra-ibiza-iam | 32 | 234 | 43 | Bearer (`c44b4083`) |
| entra-idgov | 1 | 14 | 0 | Bearer |
| entra-iga | 1 | 9 | 2 | Bearer |
| entra-pim | 1 | 14 | 0 | Bearer |
| exchange | 1 | 41 | 16 | Cookie |
| intune-autopatch | 1 | 49 | 0 | Bearer |
| intune-portal | 1 | 5 | 0 | Bearer (looks like stub) |
| m365-admin | 24 | 251 | 82 | Bearer (`4765445b`) |
| m365-apps-config | 1 | 22 | 4 | Bearer |
| m365-apps-inventory | 1 | 25 | 0 | Bearer |
| m365-apps-services | 1 | 8 | 1 | Bearer |
| power-platform | 9 | 244 | 6 | Bearer |
| purview | 19 | 127 | 20 | Cookie (`80ccca67`) |
| purview-portal | 0 | 0 | 0 | Cookie |
| security-copilot | 1 | 32 | 2 | Bearer |
| sharepoint | 1 | 35 | 0 | Cookie |
| teams | 1 | 98 | 58 | Bearer (`12128f48`) |
| viva | 1 | 5 | 0 | Bearer (looks like stub) |
| **Subtotal** | **96** | **1218** | **234** | |

**Stub-looking portals (need verification before Phase 0 closes):** entra-b2c (5 paths), intune-portal (5), viva (5), m365-apps-services (8), entra-iga (9), entra-idgov (14), entra-pim (14) — confirm their nodoc YAMLs really only have this few paths, or whether we missed YAML files.

---

## 5. Critical-path verification matrix (disk-verified)

User mandated coverage of: device timeline, ASR rules, custom rules, suppression rules, device telemetry. All verified present:

| Capability | Path | Sub-area | Slug | Method | ReadSemantics |
|---|---|---|---|---|---|
| **Device timeline (events)** | `/mtp/mdeTimelineExperience/machines/{MachineId}/events` | `endpoint_devices` | `GetMachineTimelineEvents` | GET | read |
| Device timeline (cache warm) | `/mtp/mdeTimelineExperience/machines/{MachineId}/prefetch` | `endpoint_devices` | `PrefetchMachineTimeline` | POST | unknown (recommend `read` — cache idempotent) |
| IP timeline | `/mtp/mdeTimelineExperience/ips/{IpAddress}/events` | `endpoint_devices` | `GetIpTimelineEvents` | GET | read |
| ASR rule tenant-state | `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies` | `endpoint_configuration` | `ListSecurityPolicies` | GET | read |
| ASR policy filters | `/mtp/unifiedExperience/mde/configurationManagement/mem/securityPolicies/filters` | `endpoint_configuration` | `GetSecurityPolicyFilters` | GET | read |
| Device policies | `/mtp/unifiedExperience/mde/configurationManagement/mem/device/{MachineId}/policies` | `endpoint_configuration` | `ListDevicePolicies` | GET | read |
| Advanced Features (24 toggles) | `/mtp/settings/GetAdvancedFeaturesSetting` | `endpoint_configuration` | `GetAdvancedFeaturesGet` | GET | read |
| Custom Collection rules | `/mtp/customDataCollection/rules` | `endpoint_configuration` | `ListCustomCollectionRules` | GET | read |
| Custom Collection rule (write — EXCLUDE) | `/mtp/customDataCollection/rules/{RuleId}` | `endpoint_configuration` | `UpdateCustomCollectionRule` | PUT | **write — must exclude** |
| MDIoT magellan features | `/mtp/mdiotSettingsService/settings/v2/MagellanFeatures` | `endpoint_configuration` | `GetMagellanFeatures` | GET | read |
| MDIoT discovery tags | `/mtp/mdiotSettingsService/settings/DiscoveryEnabledTags` | `endpoint_configuration` | `GetDiscoveryEnabledTags` | GET | read |
| Suppression rules | `/mtp/suppressionRulesService/suppressionRules` | `configuration` | `ListSuppressionRules` | GET | read |
| Suppression rules builtin hash | `/mtp/suppressionRulesService/suppressionRules/builtInRulesHash` | `configuration` | `GetBuiltInSuppressionRulesHash` | GET | read |
| NDR rules engine | `/mtp/ndr/rulesengine/rules` | `configuration` | (verify slug) | GET | read |
| XSPM asset rules | `/mtp/xspmatlas/assetrules` | `configuration` | `GetAssetRules` | GET | read |
| Web Content Filtering policies | `/mtp/responseApiPortal/webcategory/policies` | `configuration` | `ListWebCategoryPolicies` | GET | read |
| Critical asset classification | `/mtp/xspmatlas/criticalAssetClassification` | `configuration` | `ListCriticalAssetClassifications` | GET | read |

---

## 6. State-mutating endpoints in catalogue (22) — MUST EXCLUDE from Phase 1 manifest

| Sub-area | Slug | Action it performs |
|---|---|---|
| cloud_apps | UpdateUsageInfo | update usage info |
| configuration | SetMcasPreviewFeatures | toggle MCAS preview features |
| configuration | SetPreviewFeatures | toggle preview features |
| endpoint_configuration | SetAdvancedFeatures | toggle the 24 ASR/Tamper Protection/EDR-in-block-mode/Live-Response/etc. flags |
| endpoint_configuration | UpdateCustomCollectionRule | edit a custom collection rule |
| endpoint_devices | InvokeAction | run a machine action (isolate, scan, collect package) |
| endpoint_devices | SetAssetValue | tag device asset value |
| endpoint_devices | SetCriticalityLevel | tag device criticality |
| endpoint_devices | SetExclusionState | set device exclusion |
| endpoint_devices | SetRbacGroup | move device to RBAC group |
| endpoint_devices | SetTag | add/remove device tag |
| exposure_management | RunHuntingQuery | run KQL hunting query |
| files | CreateSampleCollectionRequest | request sample collection from device |
| multi_tenant | RunHuntingQuery | cross-tenant KQL hunting query |
| portal_services | InvokeAdminCommand | run admin command |
| threat_analytics | UpdateOutbreakUserState | update user state for an outbreak |
| (+ 6 in identity / sentinel_precision TBD via Annotate-ReadSemantics pass) | | |

These remain in catalogue (forensic record) but `ReadSemantics: 'write'` will exclude them from `manifests/defender.psd1`.

---

## 7. Tools inventory (`xdrlograider-v2/tools/` — 19 scripts)

**Working (offline analysis/mining):**
- `Build-AuthResearchCatalogue.ps1` — generate per-portal _AUTH_RESEARCH.json
- `Build-CatalogueMasterIndex.ps1` — aggregate _CATALOGUE_INDEX.md
- `Build-LiveAuditReport.ps1` — generate _LIVE_AUDIT_REPORT.md
- `Capture-References.ps1` — mine nodoc YAML → metadata.json + nodoc.yml
- `Discover-PortalMsalConfig.ps1` — mine _postLogin/_buildConfig MSAL config
- `Enrich-AllPortals-ValueProps.ps1` — annotate value props per sub-area
- `Enrich-CrossReferences.ps1` — link to Microsoft official API equivalents
- `Enrich-Entities-Parsing-Value.ps1` — tag Sentinel-entity column hints
- `Enrich-PerEndpointCatalogue.ps1` — detect pagination/time-filter/entities/cadence
- `Finalize-CatalogueWithNodocAuth.ps1` — backfill _AUTH_RESEARCH from nodoc x-ms-*
- `Show-FinalSummary.ps1` — print catalogue summary

**Working (online probes — operator-run, NOT CI):**
- `Debug-PurviewProbe.ps1` — purview-specific auth diag
- `Inspect-FailingPortalAuth.ps1` — diagnose 4xx/5xx in auth chain
- `Probe-EstsauthSilentToken.ps1` — silent prompt=none refresh test
- `Probe-MsalPortalAuth.ps1` — generic MSAL probe
- `Probe-PortalEndpoints-V2.ps1` — **current** senior-edition probe (per-portal auth map + nodoc-param-aware + 10-SuccessKind classifier)
- `Test-MultiPortalAuth.ps1` — batch auth test across 20 portals

**Deprecated / blocked:**
- `Probe-PortalEndpoints.ps1` — superseded by `-V2`; mark obsolete
- `Reverse-Include-StateEndpoints.ps1` — **VIOLATES locked rules** (reverse-included the 3 wholesale-excluded sub-areas); **pending deletion per user directive**

**Pending creation:**
- `Annotate-ReadSemantics.ps1` — bulk-tag every metadata.json with `ReadSemantics: 'read'|'write'|'unknown'` (read-only)
- `Verify-ValueProps.ps1` — emit `_VALUE_PROP_VERIFICATION.md` mapping each value-prop claim to concrete slug

---

## 8. Module audit (v1 reuse vs v2 fork)

### v1 modules (`xdrlograider/src/Modules/`, 7 modules — Phase 1 lineage)

| v1 module | Action | Reason |
|---|---|---|
| `Xdr.Common.Auth` | **REUSE_AS_IS** | Portal-agnostic. Takes -ClientId + -PortalHost. Public: Get-EntraEstsAuth, Get-XdrAuthFromKeyVault, Resolve-EntraInterruptPage |
| `Xdr.Common.Manifest` | **REUSE_AS_IS** | Multi-portal forward-compat. Public: Get-XdrEndpointManifest, Get-XdrCategoryTableName, Get-XdrNodocCategorySlug |
| `Xdr.Common.Telemetry` | **REUSE_AS_IS** | Portal-agnostic AI senders (Trace, CustomEvent, CustomMetric, Exception, Dependency) |
| `Xdr.Connector.Orchestrator` | **REUSE_AS_IS** | L4 portal router. Hardcode Defender-only for Phase 1; v0.2.0 adds dispatch table |
| `Xdr.Sentinel.Ingest` | **REUSE_AS_IS** | 14 publics: Send-ToLogAnalytics, Write-Heartbeat, checkpoints, DLQ, tier-state, tenant capability |
| `Xdr.Common.AuthV2` | **NEW FORK** | Already at `xdrlograider-v2/src/Modules/Xdr.Common.AuthV2/Private/Complete-TotpMfa-V2.ps1` (MaximumRedirection=30 fix for SharePoint). Needs psd1/psm1 + public exports added. |
| `Xdr.Defender.Auth` | **REUSE_AS_IS or minor FORK** | Connect-DefenderPortal + Get-DefenderSccauth + Invoke-DefenderPortalRequest + Test-DefenderPortalAuth + Update-XsrfToken. Minor fork if multi-tenant FA needed. |
| `Xdr.Defender.Client` | **FORK_FOR_V2** | v1 violates 4 locked rules: SuccessKind classification (4 values), RawResponseBody capture, manifest-driven naming (Defender_*_CL), per-sub-area integration. v2 rewrite required. |

### Phase 1 module structure (target — v2)

```
xdrlograider-v2/src/Modules/
├── Xdr.Common.Auth/                     # COPY from v1
├── Xdr.Common.AuthV2/                   # ✓ exists; needs psd1/psm1
│   └── Private/Complete-TotpMfa-V2.ps1  # ✓ MaxRedirection=30
├── Xdr.Common.Manifest/                 # COPY from v1
├── Xdr.Common.Telemetry/                # COPY from v1
├── Xdr.Common.PortalMap/                # NEW: registry of {clientId, redirect, audience, headers} per portal
│   └── Public/Get-PortalAuthMaterials.ps1
├── Xdr.Connector.Orchestrator/          # COPY from v1
├── Xdr.Defender.Auth/                   # COPY from v1 (minor fork if multi-tenant FA)
├── Xdr.Defender.Client/                 # NEW FORK from v1
│   └── Public/
│       ├── Invoke-DefenderEndpoint.ps1   # 4-SuccessKind + RawResponseBody + manifest-driven naming
│       ├── Invoke-DefenderSubAreaPoll.ps1
│       └── Get-DefenderManifestEntry.ps1
└── Xdr.Sentinel.Ingest/                 # COPY from v1
```

---

## 9. Auth research per portal (all 20 — `_AUTH_RESEARCH.json` present)

Confirmed: all 20 portals have `references/<portal>/_AUTH_RESEARCH.json` with clientId / audience / API base / headers / auth method.

Auth bucket distribution:
- **A-cookie** (sccauth + XSRF): defender, purview, purview-portal, exchange, sharepoint — proven unattended in v1
- **B-bearer** (Azure AD interactive → token): entra-ibiza-iam, entra-idgov, entra-iga, entra-pim, intune-autopatch, intune-portal, m365-admin, m365-apps-{config,inventory,services}, power-platform, security-copilot, teams, viva
- **C-bearer** (B2C-tenant scoped): entra-b2c

Phase 1 GA only uses **A-cookie / defender**. Other portals = v0.2.0+ research.

---

## 10. Phase 0 completeness checklist — DONE

- [x] **A. Catalogue revert** — `references/defender/{advanced_hunting,alerts_incidents,live_response}/` deleted (34 endpoints) + `tools/Reverse-Include-StateEndpoints.ps1` deleted. Final: **509 endpoints across 18 Defender sub-areas**.
- [x] **B. ReadSemantics annotation** — `tools/Annotate-ReadSemantics.ps1` ran over 1727 metadata.json files. Defender result: 492 read · 17 write · 0 unknown. `references/defender/_READ_SEMANTICS_AUDIT.md` emitted.
- [x] **C. Unknown resolution** — 19 POTENTIAL_READ + 1 POTENTIAL_WRITE auto-classified via semantic-override prefixes (Count|Aggregate|Autocomplete|Has|Is|Generate|GoHunt|Prefetch → read; Log → write). Zero unknowns remain.
- [x] **D. Value-prop verification** — `tools/Verify-ValueProps.ps1` ran. `references/_VALUE_PROP_VERIFICATION.md` shows:
  - **Critical paths:** 16/17 PRESENT (1 label mismatch — coverage is real, my assumed slug-name was wrong)
  - **v1 → v2 cross-reference:** 67/72 v1 streams mapped (5 unmapped: 2 in AH/LR wholesale-exclusions = expected; 3 are path drift — Microsoft renamed `mdeCustomCollection`→`customDataCollection`, deprecated `k8sMachineApi` prefix, `autoIr` PUA path moved)
  - **Net-new value:** 426 read endpoints v2 catalogue covers that v1 never ingested
- [x] **E. Stub-portal verification** — all 7 stub portals (entra-b2c, intune-portal, viva, m365-apps-services, entra-iga, entra-idgov, entra-pim) confirmed to genuinely contain only `openapi.yml` (no missing sub-area YAMLs)
- [x] **F. Master indexes regenerated** — `_CATALOGUE_INDEX.md` · `_LIVE_AUDIT_REPORT.md` · `_FULL_CATALOGUE.md` reflect post-revert 1727/116 totals (was 1761/119)
- [x] **G. Consolidated doc updated** — this file (counts + decisions reflected)
- [x] Memory wired with all locked rules + deep-audit findings + Phase 0 completion state
- [x] Phase 1 entry gate: PASSED. Ready to begin Phase 1 (manifest builder + DCR JSON × 18 + FA scaffolds × 19 + ARM template).

### Phase 0 gap-tracking (deferred to v0.2.0+)

1. **AH/AI portal-internal aggregations** — Microsoft Graph covers basic CRUD only; portal-internal case management / risk factors / audit history / incident graph / saved queries / community queries / dashboard summaries / disruption summary are gaps Microsoft does NOT cover. Re-evaluate when Graph beta `detectionRule` GA + Defender XDR case-management public API ship.
2. **Path drift (3 v1 streams)** — Microsoft renamed `mdeCustomCollection`→`customDataCollection`, deprecated `k8sMachineApi/.../skuReport`, moved `autoIr/ui/properties/` (PUA). v2 catalogue uses current paths from nodoc. v1 production may need migration when next deployed.
3. **July 2026 Azure Sentinel portal retirement** — re-run nodoc-capture in H2 2026 to capture any new unified-portal endpoints.

---

## 11. Phase 1 build artifacts (what to create AFTER Phase 0 gate passes)

| Artifact | Type | Generator | Count |
|---|---|---|---|
| `manifests/defender.psd1` | per-endpoint manifest | `tools/Build-Manifest.ps1` (NEW) reads catalogue + ReadSemantics filter | 1 (~491 read entries) |
| `deploy/dcrs/Defender_<sub-area>_dcr.json` | DCR stream + transformKql | `tools/Build-DcrJson.ps1` (NEW) | 18 (one per sub-area) |
| `deploy/dcrs/XdrConnectorHealth_dcr.json` | DCR for heartbeat table | hand-authored | 1 |
| `deploy/mainTemplate.json` | ARM orchestration | hand-authored | 1 |
| `deploy/createUiDefinition.json` | Solution Gallery UX | hand-authored | 1 |
| `deploy/parameters.json` | param defaults | hand-authored | 1 |
| `src/functions/Defender-<sub-area>/{run.ps1,function.json}` | per-sub-area FA timer | `tools/Build-FunctionApp.ps1` (NEW) | 18 |
| `src/functions/ConnectorHeartbeat/{run.ps1,function.json}` | 5-min heartbeat | hand-authored | 1 |
| `src/profile.ps1` | FA module preload | hand-authored | 1 |
| `.github/workflows/ci.yml` | offline PR gates (PSSA + Pester + ARM-TTK + manifest schema) | hand-authored | 1 |
| `.github/workflows/release.yml` | cosign keyless OIDC signing + GitHub Release | hand-authored | 1 |
| `.github/workflows/validate-solution.yml` | Sentinel Content Hub validator | hand-authored | 1 |
| `tests/unit/*.Tests.ps1` | Pester gates (manifest schema, ReadSemantics filter, projection coverage, DCR consistency, EntityIdStrategy contract, EmptyNotes regression) | hand-authored | 6+ |
| `deploy/compiled/sentinelContent.json` | parsers + analytic rules + workbooks + hunting queries | `tools/Build-SentinelContent.ps1` (NEW) | 1 |

---

## 12. 2026 deprecation timeline (track these)

| Date | What | Impact on us |
|---|---|---|
| April 2026 | Legacy `microsoft.graph.alert` (v1.0) REMOVED; `tiIndicator` beta REMOVED | None — we don't use these (Graph alerts excluded entirely per scope) |
| July 2026 | Azure Portal Sentinel UI retires → all Sentinel customers redirected to Defender portal | Connector API surface unchanged; new portal-internal endpoints may emerge under unified namespace — re-run nodoc capture in H2 2026 |
| 1 February 2027 | Legacy MDE hunting endpoints (`api.securitycenter.microsoft.com/api/advancedqueries/run`, `api.security.microsoft.com/api/advancedhunting/run`) STOP RETURNING DATA | None for us (AH excluded); flag for any operator scripts that still use these |

---

## 13. Cadence + production scale (per sub-area, after revert)

| Sub-area | Cadence | Production-tenant scale | Rate-limit risk | Delta-poll priority |
|---|---|---|---|---|
| action_center | 10min | 100-10K events | LOW | medium |
| attack_simulator | daily | 10-1K | LOW | low |
| cloud_apps | daily | 10K+ audit/day (MCAS) | HIGH | critical |
| configuration | daily | 100-10K | LOW | low |
| data_lake | daily | 1-10 | LOW | none |
| endpoint_configuration | daily | 10-1K policies | LOW | low |
| endpoint_devices | daily | 10K-1M rows | HIGH (first poll) | critical |
| entity_pivots | weekly | per-entity | depends | depends |
| exposure_management | 1h | 1K-100K rows | MEDIUM | high |
| files | 6h | varies | MEDIUM | medium |
| identity | daily | 1K-100K | MEDIUM | high |
| multi_tenant | daily | 10-1K tenants | LOW | low |
| portal_services | daily | 1-100 | LOW | none |
| secure_score | daily | 1-100 | LOW | none |
| sentinel_precision | daily | varies | MEDIUM | medium |
| streaming | 6h | 1-10 | LOW | none |
| threat_analytics | 6h | 100-1K | LOW | low |
| vulnerability_management | daily | 10K-500K | HIGH (paginated) | critical |
