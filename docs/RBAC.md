# RBAC — What the service account needs

The connector is **strictly read-only**. No manifest entry uses an action verb — the scope validator (`tools/Validate-Scope.ps1`) rejects approve/isolate/delete/restart/run and anything but `GET`/read-only `POST` at build time. You therefore only ever grant **read** roles. There are two ways to do it.

> **Honest caveat.** These are *portal-internal* `/apiproxy/*` endpoints. Microsoft does not publicly document which RBAC permission each one checks. The connector's **F18 capability-gate** turns an under-permissioned endpoint into a clean `403 → capability-absent`: the operation is skipped, not crashed. That makes least-privilege **safe to start narrow and widen** — deploy with the recommended read set, watch the connector's auth/capability telemetry for 403s, and grant the next read permission only if a category you actually want is being gated. Do **not** grant write/admin to "make a 403 go away": a 403 on a read op means you are missing a *read* grant, not a write one.

---

## Option 1 — Security Reader (broad, simplest)

Assign the built-in **Security Reader** Entra directory role (or **Global Reader** for the widest read coverage). One assignment covers every category, including the awkward ones (Attack Simulation, Cloud Apps).

- **Pro:** simplest; one assignment; nothing to tune.
- **Con — over-privileged for an unattended account.** Security Reader can read *every* security surface in the tenant — far more than the ~120 audit/posture read operations this connector uses. For a standing, non-interactive credential, that is a materially larger blast radius if the account is ever compromised (see [SECURITY-CONSIDERATIONS.md](SECURITY-CONSIDERATIONS.md)). **Not recommended for production.**

---

## Option 2 — Defender Unified RBAC, least-privilege (RECOMMENDED)

Create a **custom role in Microsoft Defender XDR Unified RBAC** (*Settings → Microsoft Defender XDR → Permissions and roles → Roles*) granting only the **Read** permissions the shipped categories need, and assign it scoped to the data sources you actually ingest.

| Unified RBAC permission (set to **Read**) | Covers these shipped categories |
|---|---|
| **Security operations → Security data → Security data basics (Read)** | Operations (Action Center history), EndpointManagement (device inventory / machine groups / tags), PortalServices, AnalyticsData |
| **Security posture → Posture management (Read)** | ExposureManagement, SecureScore, VulnerabilityManagement (TVM) |
| **Authorization and settings → Security settings → Core security settings (Read)** | Configuration (advanced features, auto-IR properties, data-export & discovery settings) |
| **Authorization and settings → System settings (Read)** | Configuration — tenant context, service-URL and feature surfaces |
| **Authorization and settings → Authorization (Read)** | Configuration RBAC-inventory ops (e.g. `GetCurrentUserRbacRoles`, `ListRbacAadGroups`) |

Where Unified RBAC supports it, scope the role to the specific data sources (Endpoints, Identities, Cloud Apps, …) rather than "all".

> **Validate on your tenant.** Because the `/apiproxy/*` authorization checks are undocumented, treat this mapping as a well-reasoned starting point to confirm against your own tenant's 403 telemetry — not a guaranteed contract.

### Categories that may need a product-specific read role

A few surfaces are not (yet) fully expressed in Unified RBAC read permissions. If you want these categories and see them 403-gated, add the narrow, still read-only role below:

- **Identity** (Defender for Identity dormant-account / service-account audits): ensure the Identities data source is in the role's scope; on tenants still on legacy MDI RBAC, the Security Reader-equivalent MDI read role applies.
- **CloudApps** (Defender for Cloud Apps posture): may require the Cloud Apps read scope / a Defender for Cloud Apps reader role, depending on your tenant's MCAS → Unified-RBAC migration state.
- **AttackSimulation** (Attack Simulation Training reports): historically gated by an Email & collaboration / Attack Simulator read permission rather than the core Defender read set.

If you need *all eleven* categories with a single grant and knowingly accept the broader blast radius, that is exactly the trade-off **Security Reader** makes — treat it as the fallback, not the default.

---

## Recommendation

**Use Option 2 (Defender Unified RBAC, least-privilege).** Grant the five read permissions above, deploy, then let the connector's telemetry tell you if a category you want is being gated — and widen one read permission at a time. Reserve Security Reader for the case where you deliberately want every category and have the compensating monitoring in [SECURITY-CONSIDERATIONS.md](SECURITY-CONSIDERATIONS.md) in place.

---
*Maintainer: Alex Kefallonitis · al.kefallonitis@gmail.com · <https://www.linkedin.com/in/alex-kefallonitis-3a8739a7>*
