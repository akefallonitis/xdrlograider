# Microsoft Defender XDR API hardening + deprecation timeline

**Generated:** 2026-05-12 UTC. Tracks Microsoft API surface changes that affect XdrLogRaider v2's value-prop horizon. Source-cited per row.

---

## Historical hardening events (past)

| Date | Event | Source | Impact on v2 |
|---|---|---|---|
| **July 2024** | Microsoft hardened the Defender service APIs (`securitycenter.windows.com/api/*`) against bypass | DefenderHarvester (Olaf Hartong) README — repo archived noting "Microsoft has added additional protection on the service APIs this tool is leveraging" | **Validates v2 architecture**: v2 does NOT bypass the apiproxy (the bypass was hardened). Instead v2 USES the apiproxy with sccauth+XSRF cookie auth the way the portal itself does. Hardening doesn't affect v2. |
| **2024–2025** | Microsoft opened Graph beta `/beta/security/rules/detectionRules` for custom-detection-rule CRUD | Microsoft Graph docs + Infernux research | **Partial external coverage** — operators can use Graph beta as fallback for custom detection rules. v2 wholesale-excludes `advanced_hunting` per user directive; Graph beta covers the gap (with caveats — see Instability below). |
| **November 2025** | MDE Custom Collection feature GA (uncapped event capture via `DeviceCustom*` tables) | FalconForce 0x06 article (Olaf Hartong was Microsoft's design partner) | **Path discovered 2026-05-13**: NOT in apiproxy — direct regional host `https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules` with bearer token (audience `https://securitycenter.microsoft.com/mtp`). v2 schema endpoint at `/mtp/mdeCustomCollection/model` works through apiproxy (live HTTP 200). Rules CRUD requires NEW bearer-token auth flow (A2 pattern); deferred to Phase 1.1. See `defender/_MDE_CUSTOM_COLLECTION_RESEARCH.md`. |
| **2026-05-11** | MDE Custom Collection event cap raised 25k → 75k per device per 24h | Microsoft Learn `create-custom-data-collection-rules.md` revision | Document for operators; feature still labeled "prereleased" |
| **January 2026** | Microsoft Security Response Center (MSRC) closed VULN-166872 as "moderate / doesn't meet bar" — sccauth OBO token broker design will NOT be hardened | CloudBrothers MSRC submission timeline | **v2 auth chain stable** — Microsoft is keeping the portal-cookie-as-token-broker design. v2's sccauth+XSRF approach has no expected hardening pressure. |

---

## Upcoming deprecations (future — track these)

| Date | Event | Source | Impact on v2 |
|---|---|---|---|
| **April 2026** | Legacy `microsoft.graph.alert` v1.0 (namespace `microsoft.graph` not `microsoft.graph.security`) REMOVED | Microsoft Graph deprecation docs | **No impact on v2** — `alerts_incidents` is wholesale-excluded; v2 doesn't use Graph alerts API |
| **April 2026** | Legacy beta `tiIndicator` REMOVED → migration to Defender Threat Intelligence resources | Microsoft Graph beta deprecation page | **No impact on v2** — v2 uses portal-internal threat-intel state via `threat_analytics` sub-area (20 endpoints), not legacy `tiIndicator` Graph beta |
| **July 2026** | Azure Portal Sentinel UI retires → all Sentinel customers redirected to unified Defender portal (security.microsoft.com) | Microsoft unified-portal transition docs | **Action required for v2 H2 2026**: re-run `Capture-References.ps1` against unified-portal nodoc to capture any new endpoints that emerge under the unified namespace |
| **1 February 2027** | Legacy MDE hunting endpoints STOP RETURNING DATA: `api.securitycenter.microsoft.com/api/advancedqueries/run` + `api.security.microsoft.com/api/advancedhunting/run` | Microsoft API deprecation announcement | **No impact on v2** — `advanced_hunting` is wholesale-excluded; v2 doesn't use legacy hunting endpoints. **Warn operators** using legacy AH cmdlets to migrate to `graph.microsoft.com/v1.0/security/runHuntingQuery` |

---

## Microsoft Graph beta instability flags (current — informational)

These surfaces exist in Graph beta but Infernux's published evaluations show production-grade quality issues. v2 documents them so operators understand the trade-offs.

| Graph beta surface | Status | Documented issue | Source |
|---|---|---|---|
| `/beta/security/rules/detectionRules` | Beta GA-quality issues | `impactedAssets` required on create but GET returns 0–N assets randomly; internal 500s on Graph cmdlet POST/PATCH; bearer token method more reliable than `Invoke-MgGraphRequest`; "Implementing a full push/pull CI/CD pipeline will probably not work in its current form." | Infernux blog — `infernux.no/blog/defenderxdr-cdrmodule/` |
| `/beta/security/security/simulation` | Beta — Defender XDR Attack Simulator | Partial coverage; campaign config + payload library detail missing | Microsoft Graph docs |
| `/beta/security/security/identities/healthIssues` | Beta — MDI sensor health | Lists health issues but does NOT cover Defender Service Account (DSA) config, alert thresholds, dormant accounts | Microsoft Graph docs + v2 audit |

---

## Microsoft public API coverage gaps (v2 value-prop scope — locked)

External research (Agent C deep audit, 2026-05-12) confirms ≈65% of v2 catalogue surfaces have **no Microsoft public API equivalent** in 2026. These remain the connector's core value-prop and are not expected to be exposed externally on any documented timeline:

| Surface category | Microsoft API status | v2 sub-area | Strategic value |
|---|---|---|---|
| Action Center pending approvals + history (auto-IR audit) | `/api/machineactions` partial (6mo retention, 10k cap) | `action_center` | **HIGH** — only programmatic route to AutoIR approval state |
| Configuration drift (suppression rules, NDR rules, XSPM atlas rules, web category policies, critical-asset classification) | NONE | `configuration` (53 ops) | **HIGH** — compliance + change-control value |
| ASR rule bodies + Advanced Features 24 toggles + Tamper Protection state + Custom Collection rules + MDIoT settings | NONE | `endpoint_configuration` (19 ops) | **HIGH** — endpoint policy audit |
| MTO tenant inventory + cross-tenant workload status | NONE (no Graph MTO API) | `multi_tenant` (17 ops) | **HIGH** — MSSP value |
| XSPM attack paths / chokepoints / posture metrics | Partial — ExposureGraphNodes/Edges via AH KQL; no first-class API | `exposure_management` (42 ops) | **HIGH** — board-grade exposure metrics |
| Secure score per-category historical breakdown | Graph has overall + control profiles only | `secure_score` (8 ops) | **HIGH** — compliance auditor value |
| MDI DSA config + dormant accounts + alert thresholds + LMP | Graph has health/sensors only | `identity` (74 ops) | **HIGH** — MDI platform completeness |
| MCAS app inventory + discovery + OAuth governance | Graph alerts_v2 only | `cloud_apps` (92 ops) | **MEDIUM** — MDA platform completeness |
| Device timeline (61 event types, 180-day retention) | NONE | `endpoint_devices/GetMachineTimelineEvents` | **HIGH** — FalconForce 0x04's documented strongest value-prop |

---

## Re-evaluation triggers (when to re-run nodoc capture + audit)

- **Microsoft Graph beta `detectionRules` GA promotion** — re-evaluate `advanced_hunting` carve-out decision
- **Microsoft publishes MDE Custom Collection apiproxy path** OR operator discovers it via DevTools — add to `endpoint_configuration` and probe
- **July 2026 Azure Sentinel UI retirement** — re-run `Capture-References.ps1` to capture unified-portal endpoints
- **Any Microsoft public API announcement** for Action Center history, MTO inventory, XSPM graph traversal, or per-category secure score — adjust v2 scope accordingly
- **Microsoft hardens the apiproxy layer further** — flag in this timeline + decide on v2's response (no current signal this is coming; CloudBrothers MSRC closure of VULN-166872 suggests Microsoft is keeping the current design)
