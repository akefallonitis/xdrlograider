# Prior research & acknowledgments

XdrLogRaider stands on the shoulders of the security-research community that first mapped
Microsoft Defender XDR's undocumented, portal-internal `/apiproxy/*` surface. This project is a
**production-grade consumer** of that surface — it did not discover it. The work below made
XdrLogRaider possible and is gratefully acknowledged. All acknowledged projects are used under
their respective MIT licenses.

> **Nature of the surface.** Everything discussed here concerns *undocumented, unsupported*
> Microsoft APIs that may change or break without notice. XdrLogRaider inherits that caveat and is
> **not** a Microsoft product.

---

## 1. DefenderHarvester — the pioneer, and the motivation

[**DefenderHarvester**](https://github.com/olafhartong/DefenderHarvester) by
[Olaf Hartong](https://github.com/olafhartong) (MIT, © 2023) was the pioneering public tool to
demonstrate that the rich telemetry behind the Microsoft Defender portal — data with no public REST
API and largely absent from the Unified Audit Log — could be harvested through the portal's internal
service APIs and shipped to a SIEM (Microsoft Sentinel / Splunk). It is the direct intellectual
motivation for this project. Its technical background is documented in the FalconForce write-up
[*Microsoft Defender for Endpoint Internals 0x05 — Telemetry for sensitive actions*](https://medium.com/falconforce/microsoft-defender-for-endpoint-internals-0x05-telemetry-for-sensitive-actions-1b90439f5c25).

DefenderHarvester's own README now carries this notice (verified upstream):

> *"Microsoft has added additional protection on the service APIs this tool is leveraging. This
> prevents us from bypassing the API proxy and essentially kills this tool for now. I'm
> investigating a workaround."*

**That hardening of the `/apiproxy` layer is precisely the gap XdrLogRaider is built to close.**
DefenderHarvester worked by *bypassing* the API proxy; Microsoft's added protection broke that
approach. XdrLogRaider takes the opposite path: rather than bypassing the proxy, it authenticates
**through** the portal the way the browser does — a headless, MFA-satisfying delegated sign-in that
yields a valid portal session — so the proxy serves it exactly as it serves the interactive portal.
The technique DefenderHarvester pioneered is preserved; the way in has moved from *around* the proxy
to *through* it.

---

## 2. XDRInternals — the auth-flow and endpoint groundwork

[**XDRInternals**](https://github.com/MSCloudInternals/XDRInternals) by **Fabian Bader** and
**Nathan McNulty** (MIT, © 2025 · ~124★) is the community PowerShell module that most thoroughly
documents programmatic access to the Defender XDR portal APIs, exposed as `Get-Xdr*` cmdlets. It
publicly establishes the delegated, browser-style sign-in flows that make headless access possible —
the Entra **ESTS** cookie chain, **passkey/FIDO2**, **TOTP** / phone sign-in, **TAP** (Temporary
Access Pass), and **KMSI**-backed SSO — alongside its pagination, time-filter, and sub-portal
routing conventions.

XdrLogRaider's own authentication is **implemented in-tree** (it does not import XDRInternals, call
its cmdlets, or take it as a dependency), but its approach to the portal-internal sign-in flow —
the ESTS cookie chain with **TOTP** and **passkey/FIDO2** MFA (the two methods it implements) — **adapts
the community-established patterns that XDRInternals documents**, and it cross-validates its per-operation manifests (pagination strategy, time-filter
naming, sub-portal mapping) against the same conventions. The consolidated cross-reference lives
under [`references/cross-source/xdrinternals/`](../references/cross-source/xdrinternals/).

---

## 3. nodoc — the endpoint-surface authority

XdrLogRaider's endpoint catalogue is grounded in the community **nodoc** OpenAPI specifications for
the Microsoft portal-internal surfaces. For Defender (`security.microsoft.com/apiproxy`), the
verified nodoc spec enumerates **576 portal-internal paths** organised into **14 `x-tagGroups`** —
Alerts & Incidents, Advanced Hunting, File Investigation, Endpoint Management, Vulnerability
Management, Identity, Configuration, Exposure Management, Analytics & Data, Secure Score, Operations,
Portal Services, Attack Simulation, and Cloud Apps — with a documented sub-portal proxy-routing table
(`/mtp/`, `/mdi/`, `/mcas/`, `/mtoapi/`, …).

This is the authoritative reference for **path, method, and sub-portal routing** from which our
per-operation catalogue is derived and against which every shipped operation is checked. XdrLogRaider
ships **11** of those groups as **read-only** categories (AnalyticsData, AttackSimulation, CloudApps,
Configuration, EndpointManagement, ExposureManagement, Identity, Operations, PortalServices,
SecureScore, VulnerabilityManagement). The three excluded groups — **Alerts & Incidents**,
**Advanced Hunting**, and **File Investigation / Live Response** — are deliberately out of scope
because Microsoft already documents supported public APIs for them (Incidents, Advanced Hunting, and
Streaming), so there is no gap for this connector to fill.

The reference corpus is **not Defender-only**. The derivation engine is portal-agnostic, and the
repository carries nodoc OpenAPI + Postman references for a broad span of Microsoft portals — Entra
(IAM / PIM / IGA / ID-Governance / B2C), Microsoft 365 Admin, Purview, Teams, Intune, Exchange,
SharePoint, Power Platform, Viva Engage, and Security Copilot — as the **documented expansion
surface**. Defender is the surface that ships today; the others are the roadmap the same engine can
onboard without code changes. See [`references/openapi/`](../references/openapi/) and
[`references/postman/`](../references/postman/).

---

## 4. The `/apiproxy` auth model that makes it work

What ultimately makes *unattended* collection possible is the Defender portal's internal `/apiproxy`
delegated-auth model. A browser-emulation credential plus a second factor (TOTP or passkey) drives an
Entra ID sign-in whose **KMSI (Keep-Me-Signed-In)** persistent cookie yields the portal's `sccauth`
session credential, which the proxy honours for `/apiproxy/*` reads. XdrLogRaider automates this
end-to-end and refreshes it silently — turning a one-off, interactive harvest into a durable,
hands-off data feed:

1. **Delegated sign-in** — credential + MFA (TOTP seed or passkey PEM) against Entra ID, satisfied
   headlessly, emulating the browser flow the portal expects.
2. **KMSI persistence** — the 90-day Keep-Me-Signed-In cookie is captured so subsequent cycles reuse
   an established session rather than re-prompting.
3. **`sccauth` session** — exchanged for the portal session credential the `/apiproxy` layer accepts.
4. **Silent refresh** — the connector renews the session on its own; a full headless re-auth is only
   needed when the KMSI window lapses (roughly four times per year).

Because collection happens *through* the proxy with a legitimate portal session, XdrLogRaider is not
defeated by the same proxy hardening that stopped the bypass approach.

---

## What this offers

Prior tools proved the *idea* — that Defender's portal-internal telemetry can be harvested. Most are
single-operator, single-run command-line harvesters that push to a SIEM and stop when the session or
the API changes. XdrLogRaider is a different class of thing: a **deployable, unattended, production
Microsoft Sentinel data connector** engineered to run for years without a hand on it.

| Capability | A one-off harvester | XdrLogRaider |
|---|---|---|
| **Auth** | Interactive login per run; breaks on cookie / MFA rotation | **Unattended delegated auth** — Creds+TOTP and Passkey/FIDO2 (the two implemented methods), each yielding a portal cookie (`sccauth`) or a bearer token, with **silent KMSI 90-day SSO refresh** — full headless re-auth ~4×/year. Further methods (ESTS/`sccauth` input, TAP, device code, client credentials) are planned, not yet implemented |
| **Scope** | Hardcoded set of endpoints | **Dynamically-curated surface** — operations derived from the nodoc OpenAPI corpus, never a hardcoded count; new operations / categories / portals activate by manifest, no engine change |
| **Product / tenant fit** | Assumes one tenant's licensing | **Dynamic product & tenant discovery** — each operation capability-gates and lights up only when the tenant licenses the underlying product (MDE / MDI / MDVM / MDCA / XSPM …) |
| **Data quality** | Raw JSON dumped to a table | **Exactly-once, typed ingestion** — one typed Sentinel row per Defender event, full raw response retained per row, client-side dedup that holds across restarts and redeploys |
| **Deployment** | Clone + env vars + run | **One-click Deploy-to-Azure** ARM — provisions Key Vault, Storage, App Insights, DCE/DCR, the Function App, and the Sentinel content package in the customer's own subscription |
| **Operations** | Fire-and-forget | **Self-hosted & observable** — Durable Functions timer → orchestrator → fan-out, per-cycle correlation-id telemetry, circuit breaker + DLQ, single-flight via blob lease |
| **Detection value** | Data only | **Paired detections** — every collection surface ships with Sentinel analytic (KQL) content, so the data is actionable, not merely stored |

### In short

- **A connector, not a script.** It installs as a first-class Microsoft Sentinel data connector
  (V3 `dataConnectorDefinitions` + `contentPackages`), shows a Connected card in the gallery, and
  writes to native `Defender_<Category>_CL` tables that Sentinel queries directly.
- **Dynamic everything, hardcoded nothing.** Portal, category, product-gating, and the operation
  surface are all data-driven and dynamically curated from the reference corpus — the catalogue
  grows without touching source. Because the engine is portal-agnostic, the same pipeline can onboard
  any Microsoft portal already present in `references/` (Entra, M365, Purview, Teams, Intune, …).
- **Unattended by design.** After a single interactive bootstrap it runs itself: silent SSO refresh,
  self-healing 401/440 re-auth, and no operator in the steady state.
- **Read-only and least-privilege.** No manifest operation carries an action verb; the build-time
  scope validator rejects any write / isolate / approve / delete path.
- **Detection-engineering ready.** Purple-team and detection teams get typed, queryable,
  exactly-once telemetry for portal surfaces that otherwise have no supported export path — with
  paired KQL detections shipped alongside.

---

## Attribution & licenses

| Project | Author(s) | License | Repository |
|---|---|---|---|
| **DefenderHarvester** | Olaf Hartong | MIT (© 2023) | <https://github.com/olafhartong/DefenderHarvester> |
| **XDRInternals** | Fabian Bader · Nathan McNulty (MSCloudInternals) | MIT (© 2025) | <https://github.com/MSCloudInternals/XDRInternals> |
| **nodoc OpenAPI** | nodoc (community) | community spec | see [`references/openapi/`](../references/openapi/) |

XdrLogRaider is itself released under the [MIT License](../LICENSE). These upstream projects interact
with undocumented, unsupported Microsoft APIs that may change without notice; the same disclaimer
applies to XdrLogRaider. It is an independent, community project and is **not affiliated with,
endorsed by, or supported by Microsoft**.

---

*Maintainer: **Alex Kefallonitis** · [al.kefallonitis@gmail.com](mailto:al.kefallonitis@gmail.com) ·
[LinkedIn](https://www.linkedin.com/in/alex-kefallonitis-3a8739a7)*
