# Custom-detection rule coverage — research dossier (Gate G5)

**Generated:** 2026-05-12 UTC. Read-only synthesis from 3 parallel deep-audit agents (nodoc grep + v1 manifest mining + Microsoft API research + WebFetch FalconForce/XDRInternals/Infernux/CloudBrothers).

**User question:** "customdetection have separate internal endpoint please make sure we have all we need."

**Verdict: NO separate internal endpoint exists outside the wholesale-excluded `advanced_hunting` sub-area.** Three sources independently confirm. Microsoft Graph beta `detectionRules` provides external API access but is unstable for production CI/CD per published evaluations.

---

## Source-by-source evidence

### Source 1 — Nodoc OpenAPI specifications (vendored read-only)

Grepped every YAML in `xdrlograider/.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/*.yml` (21 sub-area files) for: `customDetect`, `detectionRule`, `hostedDetection`, `scheduledDetection`, `mtpDetection`, `defenderDetections`, `unifiedDetection`, `streamingDetection`, `rules/unified`, `analyticRule`, `detectorRule`, `xdrDetections`.

**Matches found (custom detection-specific paths):**

| Path | Method | Sub-area | Status |
|---|---|---|---|
| `/mtp/huntingService/rules/unified` | GET | `advanced_hunting` | **WHOLESALE-EXCLUDED** (sub-area dropped) |
| `/mtp/huntingService/rules/streamingDetectionCompatibleRules` | GET | `advanced_hunting` | **WHOLESALE-EXCLUDED** |

**Non-matches (other "rules" endpoints — different features, already in catalogue):**

| Path | Sub-area | What it is |
|---|---|---|
| `/mtp/ndr/rulesengine/rules` | `configuration` | NDR asset-rule engine (not detection rules) |
| `/mtp/customDataCollection/rules` | `endpoint_configuration` | MDE Custom Data Collection (telemetry rules, not detection) |
| `/mtp/xspmatlas/assetrules` | `configuration` | XSPM asset classification rules |
| `/mtp/suppressionRulesService/suppressionRules` | `configuration` | Alert suppression rules |
| `/mtp/responseApiPortal/webcategory/policies` | `configuration` | Web content filtering rules |

**Conclusion:** No separate custom-detection-rule path outside `advanced_hunting`. The only candidates are the 2 paths inside the wholesale-excluded sub-area.

### Source 2 — v1 endpoints.manifest.psd1 (72 streams)

Grep for "detection" / "detect" / "Description" blocks across the 72 v1 stream entries.

**v1 stream covering custom detection:**

| v1 Stream | v1 Path (normalized) | v1 Tier | v1 Category | v2 Status |
|---|---|---|---|---|
| `MDE_CustomDetections_CL` | `/mtp/huntingService/rules/unified` | Configuration | Configuration and Settings | UNMAPPED in v2 (sub-area dropped) |

**v1 description (from manifest header):**
> "Tenant-defined custom detection rules (KQL-driven scheduled hunts that mint alerts)."
> "Filter: fromDate | Pagination: pageIndex-based, pageSize=200, maxPages=50"

This is the SAME path as nodoc Source 1 — confirms there is no separate v1 stream pointing to a different internal endpoint.

### Source 3 — Postman defender collection

`xdrlograider/.internal/nodoc-reference/postman/collections/defender.collection.json` — searched for "Custom detection", "detection rule", "Custom_Detection" in name + url fields.

Matches inside `advanced_hunting` folder only:
- "List unified custom detection rules" → `/mtp/huntingService/rules/unified`
- "List streaming detection compatible rules" → `/mtp/huntingService/rules/streamingDetectionCompatibleRules`

No other Postman entries for custom detection in `endpoint_configuration`, `configuration`, `portal_services`, or any other in-scope sub-area.

### Source 4 — XDRInternals (`github.com/MSCloudInternals/XDRInternals`)

Public PowerShell module wrapping the Defender portal apiproxy. README and cmdlets list:
- `Get-XdrCustomDetection` — wraps `/mtp/huntingService/rules/unified`
- No cmdlet wraps a separate internal endpoint outside huntingService

Confirms the v1 + nodoc finding.

### Source 5 — DefenderHarvester (`github.com/olafhartong/DefenderHarvester`, archived July 2024)

The pre-hardening reference tool documented `MdeCustomDetectionState` as one of its 11 endpoint categories. The paths it used were variants of:
- `securitycenter.windows.com/api/customdetections` (legacy MDE REST — now retired)
- `security.microsoft.com/apiproxy/mtp/huntingService/rules/*` (the same portal route)

**Hardening status:** Microsoft added apiproxy protection in July 2024. DefenderHarvester is dead. The portal-cookie route (sccauth+XSRF) used by v2 still works for the apiproxy paths, but those paths are inside `advanced_hunting`.

### Source 6 — FalconForce MDE Internals (Olaf Hartong)

- **0x04 (Timeline)**: documents `detectionDeviceTimeline/machines` endpoint — this is DEVICE TIMELINE, not detection rules. Already in v2 `endpoint_devices` sub-area at slug `GetMachineTimelineEvents`.
- **0x05 (Sensitive actions)**: focuses on Action Center + machineactions API; no separate custom-detection endpoint mentioned.
- **0x06 (Custom Collection, Nov 2025)**: introduces MDE Custom Collection (DeviceCustom* tables — `DeviceProcessEvents`, `DeviceNetworkEvents`, etc.). This is **TELEMETRY COLLECTION** (different feature from detection rules). FalconForce's Go tool uses portal HTTP at `security.microsoft.com/securitysettings/endpoints/custom_collection/` — no apiproxy path published.

**No FalconForce article mentions a separate custom-detection-rule apiproxy endpoint outside huntingService.**

### Source 7 — CloudBrothers / NathanMcNulty blog research

- CloudBrothers (Fabian Bader): blog posts on sccauth/XSRF auth chain, Tamper Protection limits, MDE Device Health. **No separate custom-detection endpoint** documented.
- NathanMcNulty (nodoc author): blog "Defender AutoConfig" — wraps the same `/mtp/huntingService/*` paths. **No separate endpoint** mentioned.

### Source 8 — Infernux (Mikael Frydlund) — Graph beta detectionRules

Infernux published the most operationally-detailed evaluation of Microsoft's external Graph beta API for custom detection rules:

- **Endpoint:** `https://graph.microsoft.com/beta/security/rules/detectionRules` (List, Get, POST, PATCH, DELETE)
- **Auth:** Bearer token, scope `CustomDetection.ReadWrite.All` (application) or delegated (Security Admin/Operator/Manage Security Settings)
- **Schema:** displayName, isEnabled, queryCondition.queryText (KQL), schedule.period (NRT | 1H | 3H | 12H | 24H), detectionAction.alertTemplate (title, description, severity, category, recommendedActions, mitreTechniques, impactedAssets), detectionAction.responseActions[] (16 types)
- **Asset types covered:** Device, User, Mailbox
- **Quotas:** 10–100 calls/min, 1500–1800/hr

**Critical Infernux quality assessment (verbatim from `infernux.no/blog/defenderxdr-cdrmodule/`):**
> "Implementing a full push/pull CI/CD pipeline will probably not work in its current form."

Beta-grade issues documented:
- `impactedAssets` required on create but GET returns 0–N assets randomly
- Internal 500 errors on Graph cmdlet POST/PATCH; bearer token method more reliable than `Invoke-MgGraphRequest`
- Response actions limited (no automation rules / playbooks)
- No firm GA date as of May 2026

### Source 9 — Live probe (operator-pending)

This dossier flags 5 candidate paths for operator-run live probe with TOTP credentials. NOT yet executed (operator-pending in plan mode):

| Candidate path | Why probe | Expected outcome |
|---|---|---|
| `/mtp/scheduledHuntingRules/*` | Plausible naming if Microsoft moved the surface | Likely 404 |
| `/mtp/customDetection/rules` | Direct name guess | Likely 404 |
| `/mtp/responseApiPortal/detectionRules` | responseApiPortal hosts other rule types | Likely 404 |
| `/mtp/sccManagement/.../detections` | SCC management surface | Likely 404 |
| Path discovered via portal DevTools when user navigates Custom Detection page | Discovery via Microsoft portal Network tab | Definitive proof of where the surface lives in 2026 |

---

## Cross-reference matrix

| Path | nodoc | v1 manifest | Postman | XDRInternals | DefenderHarvester | FalconForce | CloudBrothers | Graph beta | Status |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| `/mtp/huntingService/rules/unified` | ✓ (AH) | ✓ | ✓ (AH) | ✓ | ✓ (hardened) | — | — | — | EXCLUDED (in AH) |
| `/mtp/huntingService/rules/streamingDetectionCompatibleRules` | ✓ (AH) | — | ✓ (AH) | — | — | — | — | — | EXCLUDED (in AH) |
| `/api/customdetections` (legacy MDE REST) | — | — | — | — | ✓ | — | — | — | RETIRED 2024 |
| `graph.microsoft.com/beta/security/rules/detectionRules` | — | — | — | — | — | — | — | ✓ | UNSTABLE beta |
| `/mtp/scheduledHuntingRules/*` | — | — | — | — | — | — | — | — | candidate (probe pending) |
| `/mtp/customDetection/rules` | — | — | — | — | — | — | — | — | candidate (probe pending) |
| `/mtp/responseApiPortal/detectionRules` | — | — | — | — | — | — | — | — | candidate (probe pending) |
| `/mtp/sccManagement/.../detections` | — | — | — | — | — | — | — | — | candidate (probe pending) |

---

## Verdict

**No separate internal custom-detection-rule endpoint exists outside the wholesale-excluded `advanced_hunting` sub-area** based on 8 independent sources (3 vendored + 5 external).

Microsoft's path forward is Graph beta `detectionRules`, which Infernux's published evaluation rates as unstable for production CI/CD as of May 2026. Until Graph beta stabilizes or Microsoft publishes a portal-grade replacement, custom-detection-rule coverage in XdrLogRaider v2 has 3 resolution paths:

| Path | Final catalogue state | Trade-off |
|---|---|---|
| **A: Stay wholesale-excluded** (current state, user directive on 2026-05-12) | 509 endpoints across 18 sub-areas. Custom-detection rule coverage relies on Graph beta `detectionRules` (operators use Microsoft-Graph-Module path; Infernux's CDR PowerShell module documents the workarounds). | Operators get Graph beta instability + lose portal-grade body access (no `impactedAssets` reliability, no automation-rule depth). |
| **B: Carve out 2 paths into new `custom_detection` sub-area** | 511 endpoints across 19 sub-areas. Portal-grade reliability for custom detection rule list + streaming-compat. | Contradicts user's earlier wholesale-exclude directive AND surfaces `advanced_hunting` paths back into catalogue (philosophically inconsistent). |
| **C: Wait for Microsoft Graph beta `detectionRules` to GA** | Defer Phase 1 ship until Graph beta stable. | Phase 1 ships indefinitely later; not aligned with v2 timeline. |

**Recommendation:** Path A (stay excluded). Document Graph beta `detectionRules` + Infernux's CDR PowerShell module as the operator's external-API fallback. Re-evaluate when Microsoft Graph beta promotes to GA OR a portal-grade replacement ships.

**Pending action:** Operator-run live probe of the 5 candidate paths with TOTP via `Probe-PortalEndpoints-V2.ps1` to definitively prove no other internal endpoint exists (or discover one if it does). Until that runs, this dossier represents the strongest read-only conclusion from disk + vendored research + WebFetch.

---

## References

- Microsoft Defender XDR — Custom detection rules: https://learn.microsoft.com/en-us/defender-xdr/custom-detection-rules
- Microsoft Graph beta — detectionRule (Create): https://learn.microsoft.com/en-us/graph/api/security-detectionrule-post-detectionrules?view=graph-rest-beta
- Microsoft Graph beta — security API overview: https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview?view=graph-rest-beta
- Infernux — Defender XDR Custom Detection Rules via Graph API: https://infernux.no/blog/defenderxdr-customdetectionrules/
- Infernux — PowerShell Module for Defender XDR Custom Detection Rules: https://infernux.no/blog/defenderxdr-cdrmodule/
- Mindcore — Microsoft Defender XDR Custom Detection Rules: https://blog.mindcore.dk/2025/07/microsoft-defender-xdr-advanced-hunting-custom-detection-rules/
- XDRInternals (MSCloudInternals): https://github.com/MSCloudInternals/XDRInternals
- DefenderHarvester (archived 2024): https://github.com/olafhartong/DefenderHarvester
- FalconForce MDE Internals 0x06 (Custom Collection): https://medium.com/falconforce/microsoft-defender-for-endpoint-internal-0x06-custom-collection-81fc1042b87c
- Nathan McNulty — Defender AutoConfig: https://nathanmcnulty.com/solutions/defender/defender-autoconfig/

Local sources cross-referenced:
- `xdrlograider/.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/*.yml`
- `xdrlograider/.internal/nodoc-reference/postman/collections/defender.collection.json`
- `xdrlograider/src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1` (72 v1 streams)
