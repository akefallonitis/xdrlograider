# ASR Configuration — portal-internal endpoint capture (2026-06-25)

## Harvest gap closed
ASR (Attack Surface Reduction) RULES per-device/per-rule config state was a CONFIRMED harvest
gap: the only ASR signal in the catalogue was the single boolean
`EnableCustomAsrAdvancedProcessTermination` toggle inside
`EndpointConfiguration.GetAdvancedFeaturesGet` (`/settings/GetAdvancedFeaturesSetting`) — a
feature flag, NOT the rule set. The actual ASR rule state lives in the Defender portal ASR
report (`security.microsoft.com/asr?viewid=configuration`), served by the TVM analytics service.

Captured 2026-06-25 from the operator's authenticated portal session (read-only, operator-
directed) via the browser Performance resource log (`performance.getEntriesByType('resource')`).

## Endpoints  (SubPortal: mtp · service: tvm/analytics/asrconfiguration)
1. `GET /apiproxy/mtp/tvm/analytics/asrconfiguration/MachineSecurityStates`
   - Per-MACHINE ASR security state (the "Device configuration overview" table).
   - NaturalKey candidate: machineId / deviceId.  IngestionMode: SNAPSHOT.
2. `GET /apiproxy/mtp/tvm/analytics/asrconfiguration/configurationstates?asrRuleIds=<csv-guids>`
   - Per-RULE aggregated config state across the fleet (rule list + status per rule).
   - NaturalKey candidate: asrRuleId.  IngestionMode: SNAPSHOT.
   - PARAM `asrRuleIds` = the PORTAL supplies these GUIDs itself (we are portal-internal — NOT
     from MS docs / official API). Captured 3 (e6db77e5/9e6c4e1f/56a863a9) = the "Standard
     protection" subset; the "All" view sends the full set. DO NOT hardcode a GUID list.
   - LIKELY REDUNDANT with MachineSecurityStates (which already carries per-rule state per
     machine) → a dedup/value decision at onboarding from the captured shapes, NOT a GUID hunt.

PRIMARY ASR op = `MachineSecurityStates` (NO params · per-machine per-rule ASR state · clean ship).
SHAPE SOURCE = the FA's own cookie-auth probe at onboarding (live-capture · ASR is not in
postman/openapi, so the live body IS the resource per the schema-from-resources waterfall; the
Chrome MCP blocked the credentialed body-fetch, but the FA's server-side session is unblocked).

## Connector route mapping (matches existing mtp ops)
Portal `/apiproxy/mtp/<svc>/<op>`  →  catalogue `Path: /tvm/analytics/asrconfiguration/<op>`,
`SubPortal: mtp` (same shape as the shipped `EndpointConfiguration.GetAdvancedFeaturesGet`).

## Observed data (lab tenant, device "blackhat" — from portal screenshots)
Overall configuration: "Rules off"; block/audit/warn = 0; Rules turned off = 18; Not applicable = 2.
Per-rule status: Off (most) / Not Applicable (Block Webshell creation for Servers; Block execution
of files from Remote Monitoring & Management tools).

## Why no live body here
The credentialed browser fetch of the response body was blocked by the Chrome MCP anti-exfil guard
(cookie/query-string-bearing response). By design — the typed projection + exactly-once key are
derived server-side by Build-Catalogue's live probe (SP token), NOT from a browser capture.

## Onboarding plan (next cataloguing increment)
- Category: ExposureManagement (TVM) — service is `tvm/analytics`. Confirm placement in §4.A.
- Add both ops to curation.json (nodoc-defender-xdr) → Build-Catalogue → live probe (SP token)
  captures shape → typed projection + exactly-once keys → §4.A 10-axis audit → ship gate →
  ONE consolidated commit → push → CI → deploy → postdeploy §4.B → manual multi-axis audit.
- Capability gate: SP 403/404 on tvm/analytics/asrconfiguration ⇒ cap-gate + SHIP per the
  dynamic-multitenant lock (lab-absence ≠ product-absence), NOT a de-ship.
