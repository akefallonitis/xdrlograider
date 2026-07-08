# XDRInternals · Sub-Portal Coverage Reference

> Cross-validation source for `SubPortal` field in per-Op manifest entries · maps Defender XDR workloads to `/apiproxy/<subportal>/` path prefixes.

## Sub-portal → workload mapping (from XDRInternals + Defender XDR portal observed paths)

| SubPortal | Workload | XDRInternals cmdlet prefix | Example /apiproxy path |
|---|---|---|---|
| `mtp` | Defender XDR core (incidents · alerts · streaming config · action center · advanced hunting) | `Get-XdrAdvancedHunting*`, `Get-XdrActionCenter*`, `Get-XdrThreatAnalytics*` | `/apiproxy/mtp/...` |
| `mde` | Defender for Endpoint (devices · machine actions · live response · vulnerability mgmt) | `Get-XdrEndpoint*`, `Get-XdrVulnerability*` | `/apiproxy/mde/...` OR via mtp |
| `mdi` / `aatp` | Defender for Identity (identities · service accounts · lateral movement) | `Get-XdrIdentity*` | `/apiproxy/mdi/...` or `/apiproxy/aatp/...` |
| `mcas` | Defender for Cloud Apps (activity · policies · discovery · governance) | `Get-XdrCloudApps*` | `/apiproxy/mcas/...` |
| `mdc` | Defender for Cloud (cloud security posture · ASR rules · regulatory compliance) | `Get-XdrCloudSecurity*` (limited coverage) | `/apiproxy/mdc/...` |
| `mdvm` | Defender Vulnerability Management (advisories · remediations · baselines) | `Get-XdrVulnerability*` (overlap with mde) | `/apiproxy/mdvm/...` |
| `xspm` | Microsoft Security Exposure Management (attack paths · choke points · entry points · targets) | `Get-XdrAttackSurface*`, `Get-XdrXspm*` | `/apiproxy/xspm/...` |
| `multitenant` / `mto` | Multi-tenant management (cross-tenant access · MTO settings) | `Get-XdrMto*` | `/apiproxy/multitenant/...` |
| `portalservices` | Portal infrastructure (RBAC · user prefs · session · onboarding) | various | `/apiproxy/portalservices/...` |

## Per-Operation SubPortal derivation rule

For a given `/apiproxy/<X>/<path>` Operation:
1. The 2nd path segment IS the SubPortal value (e.g. `/apiproxy/mtp/streamingapi/...` → SubPortal=`mtp`)
2. Set in manifest: `SubPortal = '<X>'`
3. `New-XdrRequestUrl` in Xdr.Common.Runtime.psm1 line 209-219 builds the full URL using SubPortal + Path

## Coverage map vs our v0.1.0 active scope

| SubPortal | v0.1.0 active polling? | Why |
|---|---|---|
| `mtp` | ✅ ACTIVE (Defender portal) | Primary v0.1.0 scope |
| `mde` | ✅ ACTIVE if exposed via mtp | Defender for Endpoint via mtp |
| `mdi`, `mcas`, `mdc`, `mdvm`, `xspm`, `multitenant`, `portalservices` | ⚠ MAY be active per-Op | Each Operation declares its SubPortal · runtime routes via `New-XdrRequestUrl` |
| (Entra portal) | ❌ scaffolded · IsActive=$false | v0.2.0 (Connect-EntraPortal scaffolded fail-fast) |
| (Intune portal) | ❌ scaffolded · IsActive=$false | v0.2.0 |
| (Purview portal) | ❌ scaffolded · IsActive=$false | v0.2.0 |
| (SecurityCopilot portal) | ❌ scaffolded · IsActive=$false | v0.2.0 |

## Auth dispatch is portal-level (Xdr.Common.Auth.Register-XdrPortalHandler)

Note: SubPortal is a path-routing concept within Defender · NOT a portal in the auth sense.

The `Portal` field in manifest = top-level portal (Defender · Entra · Intune · Purview · SecurityCopilot) · drives auth handler dispatch.
The `SubPortal` field = `/apiproxy/<X>/` path segment · drives URL building (within Defender portal session).

For v0.1.0: All Operations in `manifests/Defender/*.psd1` have `Portal = 'Defender'` and various `SubPortal` values (mtp · mde · mdi · etc.) · all use the same Defender cookie + KMSI session.
