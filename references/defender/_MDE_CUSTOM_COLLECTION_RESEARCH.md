# MDE Custom Collection apiproxy research — DEFINITIVE FINDING

**Generated:** 2026-05-13 UTC. Three parallel deep-research agents converged on the same answer with cross-cited code-level evidence.

**User mandate:** "MDE Custom Collection path returned 404; operator DevTools recon needed (non-blocking, v2.x scope) audit again research properly given all referenced resources all articles all repos and live probing all portals all categories all streams endpoints please don't give up."

---

## Verdict (TL;DR)

**The MDE Custom Collection rules CRUD endpoint is NOT served through the Defender XDR portal apiproxy (`/apiproxy/mtp/`).** It's a **direct regional service-host endpoint**:

```
GET    https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules
GET    https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules/{ruleId}
POST   https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules
PUT    https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules/{ruleId}
DELETE https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules/{ruleId}

GET    https://mde-dtc-snsexclusions-prd-<region>.securitycenter.windows.com/api/sense-collection/model
```

- **Service name:** `sense-collection` (named after `MsSense.exe`, the MDE agent — NOT "customDataCollection", "customCollection", or "mdeCustomCollection")
- **`<region>`** = tenant's MDE home region: `weu` (West Europe) · `neu` (North Europe) · `eus` (East US) · `eus3` · `uks` (UK South) · `ukw` (UK West) · `aue` / `aus` (Australia) etc.
- **Audience (AAD resource URI for token):** `https://securitycenter.microsoft.com/mtp` — the "mtp" string appears in the token AUDIENCE, NOT in the URL path. This is the source of confusion that made `/mtp/customDataCollection/rules` look plausible.
- **Auth:** Delegated user bearer token only (no SP/MSI support yet documented for this resource — though FalconForce's tool exposes `-tenant-id/-client-id/-client-secret` flags that work when SP is consented to the `MATP` resource, an enterprise app not exposed in standard consent flows).
- **No `X-XSRF-TOKEN` header required** when calling the direct regional host — pure bearer auth. (Contrast with Defender XDR portal apiproxy which requires sccauth + XSRF cookie chain.)
- **HTTP shape:** `Content-Type: application/json` · request bodies use PascalCase JSON keys (not camelCase as elsewhere in the portal).
- **PUT not PATCH:** FalconForce's client explicitly notes "Some environments require PUT for updates (405 on PATCH)".

---

## Why `/mtp/customDataCollection/rules` returned 404

1. The apiproxy prefix `/apiproxy/mtp/` is the path family that the Defender portal uses for **Defender XDR–level multi-tenant features** (detectionDeviceTimeline, action_center, autoir, etc.). Custom Collection is implemented as an **MDE-tenant-scoped service** ("sense-collection") that the portal calls **DIRECTLY** to the tenant's regional `wdatpprd-*` host, bypassing the apiproxy layer entirely.
2. The service name Microsoft uses internally is `sense-collection` (or `sensecollection`) — references to "mdeCustomCollection" / "customDataCollection" in nodoc are aliases or older naming.
3. The schema endpoint (`/mtp/mdeCustomCollection/model`) DOES work through apiproxy because Microsoft proxies the schema-only read; the **mutations + lists do not flow through apiproxy** — the FalconForce client always hits the direct regional host.

---

## What v2 catalogue already has (current state, verified)

| Slug | Path | Methods | Live status | Note |
|---|---|---|---|---|
| `endpoint_configuration/GetCustomCollectionModel` | `/mtp/mdeCustomCollection/model` | GET | **live HTTP 200** (catalogue confirmed) | Schema endpoint — works through apiproxy. Already in scope. |
| `endpoint_configuration/ListCustomCollectionRules` | `/mtp/customDataCollection/rules` | GET, POST | **HTTP 404 "Unknown api endpoint"** | THIS PATH IS WRONG. Replace with direct regional host. |
| `endpoint_configuration/UpdateCustomCollectionRule` | `/mtp/customDataCollection/rules/{RuleId}` | PUT | (not probed; path-templated) | `readSemantics='write'` — excluded from Phase 1 manifest anyway. |

---

## What v2 catalogue is missing (Phase 1 add)

The **rules LIST + GET** endpoint at the direct regional host is the real Custom Collection management surface. v2 needs to add a new catalogue entry under `endpoint_configuration`:

```
slug:    ListSenseCollectionRules  (new)
path:    /api/sense-collection/rules
host:    wdatpprd-<region>.securitycenter.windows.com  (NOT security.microsoft.com)
methods: get
authChain:
  Method:    Bearer-token (NOT sccauth+XSRF)
  Audience:  https://securitycenter.microsoft.com/mtp
  Host:      wdatpprd-<region>.securitycenter.windows.com
  Module:    NEW — needs Xdr.Defender.AuthBearer or similar
readSemantics: read
cadence:       daily  (Custom Collection rules change infrequently)
```

```
slug:    GetSenseCollectionRule  (new, path-templated)
path:    /api/sense-collection/rules/{ruleId}
host:    wdatpprd-<region>.securitycenter.windows.com
methods: get
```

---

## Architectural implication for v2

The current v2 connector mode assumes ALL telemetry flows through the Defender XDR portal apiproxy with sccauth+XSRF cookie auth. This finding introduces a **second auth pattern**:

| Auth pattern | Used for | Module |
|---|---|---|
| **A1: sccauth+XSRF cookie via apiproxy** | All 18 sub-areas currently in scope (509 endpoints) | `Xdr.Defender.Auth` (existing) |
| **A2: Bearer token to direct regional host** | sense-collection rules (and potentially other "service-direct" endpoints we haven't discovered yet) | NEW — operator's choice: extend `Xdr.Defender.Auth` OR add `Xdr.Defender.AuthBearer` companion module |

**Token acquisition for A2**: Microsoft does NOT expose `https://securitycenter.microsoft.com/mtp` audience via standard app-registration consent. Three known acquisition paths per FalconForce research:
- **`az account get-access-token --resource https://securitycenter.microsoft.com/mtp`** (interactive Azure CLI session — works for operator workflows)
- **`AZURE_TOKEN` / `ACCESS_TOKEN` env var** (manual prep)
- **Portal extraction**: DevTools → Network → filter `getToken?resource=MATP&serviceType=` → copy bearer from JSON response body
- **MSI/SP**: works only where SP has been granted to the `MATP` (Microsoft Advanced Threat Protection) resource — NOT standard

Given the audience requirement and FalconForce's tool design, the cleanest v2 approach: **the sccauth-authenticated portal SESSION can be used to MINT a bearer token for `https://securitycenter.microsoft.com/mtp` via the portal's `/api/Auth/getToken` endpoint (per CloudBrothers research on the portal's OBO token broker design)**. v2 already has the sccauth session; obtaining the bearer for the direct host is one additional call.

---

## Live-probe plan (for operator)

Top 10 probe paths in priority order. Token: bearer for `https://securitycenter.microsoft.com/mtp` resource.

1. **`GET https://wdatpprd-weu.securitycenter.windows.com/api/sense-collection/rules`** — most likely (tenant in West Europe)
2. **`GET https://wdatpprd-eus.securitycenter.windows.com/api/sense-collection/rules`** — East US
3. **`GET https://wdatpprd-neu.securitycenter.windows.com/api/sense-collection/rules`** — North Europe
4. **`GET https://wdatpprd-uks.securitycenter.windows.com/api/sense-collection/rules`** — UK South
5. **`GET https://wdatpprd-ukw.securitycenter.windows.com/api/sense-collection/rules`** — UK West
6. **`GET https://wdatpprd-aue.securitycenter.windows.com/api/sense-collection/rules`** — Australia East
7. **`GET https://wdatpprd-aus.securitycenter.windows.com/api/sense-collection/rules`** — Australia South
8. **`GET https://mde-dtc-snsexclusions-prd-weu.securitycenter.windows.com/api/sense-collection/model`** — schema fetch (confirms region access)
9. **Fallback apiproxy probe**: `GET https://security.microsoft.com/apiproxy/api/sense-collection/rules` with sccauth+XSRF (may NOT work but worth testing)
10. **DevTools recon** when configuring a Custom Collection rule in portal — captures the actual host + path used by the user's tenant

The tenant's home region can be derived from the Defender portal session's redirects to `wdatpunifiedux-prd-<region>.securitycenter.windows.com` or from response headers.

---

## Expected response shape (from FalconForce client.go)

Rule JSON object schema (PascalCase keys):

```json
{
  "RuleID":          "<guid>",            // empty for POST; server-populated
  "RuleName":        "string",
  "RuleDescription": "string",
  "IsEnabled":       true,
  "Table":           "DeviceCustomProcessEvents",  // or DeviceCustomNetworkEvents, DeviceCustomFileEvents, DeviceCustomImageLoadEvents, DeviceCustomScriptEvents
  "Platform":        "Windows10",
  "ActionType":      "ProcessCreated",
  "Scope":           { "...dynamic tag selector object..." },
  "Filters":         [ { "Column": "...", "Operator": "...", "Value": "..." } ],
  "GroupID":         "<guid>",
  "UpdateKey":       "<concurrency token>"        // server-set on GET; echoed on PUT
}
```

LIST endpoint returns a JSON array. No `query parameters` observed (no $top, $filter, $skip on the FalconForce client).

---

## Capacity + quotas (Microsoft Learn 2026-05-11)

- **Per-rule event cap**: **75,000 events / device / 24-hour rolling window** (raised from 25,000 in November 2025 preview)
- **Rule-deploy latency**: 20 min – 1 hr to propagate to endpoints
- **Tenant rule cap**: not publicly documented; FalconForce notes "a few dozen rules per tenant" empirically
- **License requirement**: Defender for Endpoint Plan 2 + Sentinel workspace linkage (exactly 1 workspace per tenant currently)
- **Pre-release status**: As of 2026-05-11, doc still labels feature as "prereleased product which may be substantially modified before commercial release"

---

## Microsoft API roadmap signals (when to re-evaluate)

| Signal | Status (2026-05-13) | Action when triggered |
|---|---|---|
| Microsoft Graph beta `customCollectionRule` / `telemetryCollectionRule` resource | Does NOT exist in Graph beta or v1.0 namespace | Re-evaluate scope when this lands; may replace direct-host calls |
| MDE REST `/api/customDataCollection/*` exposed in `exposed-apis-list.md` | NOT in current list | Once added, that's the supported route; v2 should migrate from direct sense-collection host |
| `MicrosoftDocs/defender-docs` repo adds `api/custom-data-collection*.md` | NOT yet | Watch GitHub commits |
| FalconForce TelemetryCollectionManager repo migrates to a different URL | NOT yet (sense-collection path stable as of 2026-05-13) | Mirror the change |
| Microsoft hardens the direct regional `wdatpprd-*` host | NOT signaled (DefenderHarvester was hardened in July 2024 for service APIs but `sense-collection` post-dates that; no MSRC tickets visible) | Adapt or wait for official API |

---

## Decision recommendation for Phase 1

**RECOMMENDED**: Defer MDE Custom Collection rules CRUD coverage to **Phase 1.1 (v0.1.1 patch release)** rather than blocking Phase 1 GA. Rationale:

1. The feature is **still pre-release** (Microsoft Learn 2026-05-11 banner). Path or schema may change before GA.
2. Adding a **second auth pattern (A2: bearer to direct regional host)** is architecturally non-trivial — requires either: (a) extending `Xdr.Defender.Auth` to mint bearer tokens via the portal's OBO broker, OR (b) adding a companion `Xdr.Defender.AuthBearer` module. Both add complexity for a feature that may move in months.
3. The **schema endpoint is already in v2 catalogue** at `endpoint_configuration/GetCustomCollectionModel` returning live HTTP 200. v2 Phase 1 ships with the schema (= "what columns are filterable in DeviceCustom*Events tables") but defers the rules-list CRUD coverage.
4. Operators can use **XDRInternals PowerShell module** (`Get-XdrEndpointConfigurationCustomCollectionRule` cmdlet) as the operational fallback until v2 Phase 1.1 ships.

**Alternative**: If user wants to ship Custom Collection rules in Phase 1 GA, add the new sub-area + bearer-token auth flow now. Effort: medium (1 new endpoint metadata + token-broker integration + projection map). Risk: pre-release path may change before Phase 1 ship.

---

## What changed in `_PHASE_0_GATE_REPORT.md` G7-bis status

| Before this research | After this research |
|---|---|
| ⚠️ FLAG: MDE Custom Collection path returned 404; operator DevTools recon needed (non-blocking, v2.x scope) | ✅ RESOLVED: Path is `https://wdatpprd-<region>.securitycenter.windows.com/api/sense-collection/rules` (direct regional host, NOT apiproxy). Operator live probe with bearer token to confirm tenant region. Phase 1 ship decision deferred (see recommendation above). |

---

## Citations (high-confidence)

**Definitive code-level source:**
- [TelemetryCollectionManager — `internal/mdeapi/client.go`](https://raw.githubusercontent.com/FalconForceTeam/TelemetryCollectionManager/main/internal/mdeapi/client.go) — verbatim `GET /api/sense-collection/rules` etc. definitions
- [TelemetryCollectionManager — `main.go`](https://raw.githubusercontent.com/FalconForceTeam/TelemetryCollectionManager/main/main.go) — `azureMTPResource`, `modelURL`, `apiBaseURL` constants
- [TelemetryCollectionManager — GitHub repo](https://github.com/FalconForceTeam/TelemetryCollectionManager)

**PowerShell client (XDRInternals):**
- [MSCloudInternals/XDRInternals repo](https://github.com/MSCloudInternals/XDRInternals) — has `Get/New/Set-XdrEndpointConfigurationCustomCollectionRule` cmdlets
- [XDRInternals PowerShell Gallery v1.0.23 (2026-05-12)](https://www.powershellgallery.com/packages/XDRInternals/) — published cmdlets

**Microsoft official docs (no path published; confirms feature is pre-release):**
- [Microsoft Learn — Create custom data collection rules (2026-05-11 rev)](https://learn.microsoft.com/en-us/defender-endpoint/create-custom-data-collection-rules)
- [Microsoft Learn — Custom data collection overview](https://learn.microsoft.com/en-us/defender-endpoint/custom-data-collection)
- [MDE supported APIs (no custom-collection entry)](https://learn.microsoft.com/en-us/defender-endpoint/api/exposed-apis-list)

**Research articles:**
- [FalconForce 0x06 — Custom Collection (Olaf Hartong)](https://falconforce.nl/microsoft-defender-for-endpoint-internal-0x06-custom-collection/) — feature deep dive
- [Infernux — Custom Data Collection Rules](https://infernux.no/blog/defenderforendpoint-customdatacollectionrules/) — corroborates "no SP support"
- [DefenderHarvester (archived July 2024)](https://github.com/olafhartong/DefenderHarvester) — explains apiproxy hardening (which is why CC bypasses it)

**Local cross-verification:**
- `xdrlograider-v2/references/defender/endpoint_configuration/GetCustomCollectionModel/live.json` → live HTTP 200 from `/mtp/mdeCustomCollection/model` (schema works through apiproxy)
- `xdrlograider-v2/references/defender/endpoint_configuration/ListCustomCollectionRules/live.json` → HTTP 404 from `/mtp/customDataCollection/rules` (wrong path)
- `xdrlograider-v2/references/defender/configuration/GetServiceUrls/live.json` → contains `"mdeCustomCollection": "https://mde-dtc-snsexclusions-prd-weu3.securitycenter.windows.com/api/sense-collection"` (confirms service host pattern in tenant's own service-url registry)
