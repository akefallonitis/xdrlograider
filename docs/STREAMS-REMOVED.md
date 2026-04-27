# Removed + deprecated streams

Streams that appeared in earlier releases but do NOT ship in `v0.1.0-beta.1` (removed) or are tagged `Availability='deprecated'` for cleanup in v0.2.0. Each has evidence against XDRInternals, nodoc, and DefenderHarvester.

---

## iter-13.8 deprecation (1 — path renamed by Microsoft)

| Stream | Manifest path | Deprecation reason |
|---|---|---|
| `MDE_StreamingApiConfig_CL` | `/apiproxy/mtp/streamingapi/streamingApiConfiguration` | Returns 404 on live audit. Per XDRInternals `Get-XdrStreamingApiConfiguration.ps1`, the canonical surface is `/apiproxy/mtp/wdatpApi/dataexportsettings` — but that path is already used by `MDE_DataExportSettings_CL` (which returns 200). The two streams describe the same underlying configuration. Marked `Availability='deprecated'` in iter-13.8 rather than removed so that operators can complete one full upgrade cycle and downstream parsers/analytic-rules can be cleanly removed in v0.2.0 without leaving dangling references. |

**Read substitute**: `MDE_DataExportSettings_CL` (already in manifest, live).

If your tenant has a feature that makes any of these callable (with a correct read-only path + body + headers), open an issue + PR with evidence — happy to add.

---

## v0.1.0-beta.1 removals (2 — write endpoints)

These endpoints exist in the portal but are **write (Set-*) paths**, not reads. Calling them as reads with an empty body returns 400, and calling them with a filled body corrupts tenant data (reassigns criticality/asset-value labels fleet-wide). No public read counterpart exists in any research source. Removed for data-safety.

| Stream | Path | Evidence |
|---|---|---|
| `MDE_CriticalAssets_CL` | `POST /apiproxy/mtp/ndr/machines/criticalityLevel` | XDRInternals `Set-XdrEndpointDeviceCriticalityLevel.ps1:67-70` — body `{ CriticalityLevel: int, DeviceIds: string[] }`. Write semantics. |
| `MDE_DeviceCriticality_CL` | `POST /apiproxy/mtp/ndr/machines/assetValues` | XDRInternals `Set-XdrEndpointDeviceAssetValue.ps1:53-56` — body `{ AssetValue: 'Low'\|'Normal'\|'High', SenseMachineIds: string[] }`. Write semantics. |

**Read substitute** for both: XSPM hunting queries via `MDE_Drift_P3Exposure` parser against `MDE_AssetRules_CL` (already in manifest, live).

---

## v1.0.2 removals (5 — no public portal API)

These appeared in v1.0.0/v1.0.1 as unverified placeholders. Evidence-based audit confirmed the features exist only in Intune / Microsoft Graph `deviceManagement` — which is explicit non-scope for this connector (XDR portal only per project charter).

| Stream | Placeholder path (v1.0.1) | Real surface |
|---|---|---|
| `MDE_AsrRulesConfig_CL` | `/securescore/categories` (placeholder) | Intune `deviceConfigurations` / Graph `/deviceManagement/endpointProtectionConfigurations` |
| `MDE_AntiRansomwareConfig_CL` | `/securescore/categories` (placeholder) | Same — Intune device config |
| `MDE_ControlledFolderAccess_CL` | `/securescore/categories` (placeholder) | Same |
| `MDE_NetworkProtectionConfig_CL` | `/securescore/categories` (placeholder) | Same |
| `MDE_ApprovalAssignments_CL` | `/securescore/categories` (placeholder) | Intune / SCCM policy framework |

Research sources checked (all negative for a portal-only read path):
- **nodoc** (github.com/nathanmcnulty/nodoc) — 576 portal paths; none cover these.
- **XDRInternals** (github.com/MSCloudInternals/XDRInternals) — 150 paths; none cover these.
- **DefenderHarvester** (github.com/olafhartong/DefenderHarvester) — 12 classic MDE endpoints; none cover these.

**Consequence**: covering these 5 config surfaces would require extending the connector to `graph.microsoft.com` — a separate auth model and a scope creep away from "portal-only telemetry".

---

## Not removed — just tenant-gated or role-gated

17 streams are **in the v0.1.0-beta.1 manifest** with correct wire contract but do not return rows on a tenant without the requisite feature / role:

- 15 `tenant-gated`: activate when the tenant provisions the feature (MDI sensors, MTO, Intune connector, Streaming API, TVM add-on, etc). See `docs/STREAMS.md` for the full list + activation criteria.
- 2 `role-gated`: activate when the service account's role is elevated (Defender XDR Operator for `MDE_CustomCollection_CL`; MCAS Administrator for `MDE_CloudAppsConfig_CL`).

These are not in this document because they ship — they just produce zero rows until your tenant state changes. That is expected v0.1.0-beta.1 behaviour and is NOT a bug.

---

## How to propose adding a removed stream back

If you find evidence a stream above has a real read path in the portal that we missed:

1. Capture the HTTP trace from DevTools → Network in the portal (F12).
2. Confirm it's a GET or a POST with a documented body (XDRInternals or nodoc).
3. Open an issue with the path + method + sample response shape (PII-scrubbed).
4. Optional: a PR adding the manifest entry + fixture.
