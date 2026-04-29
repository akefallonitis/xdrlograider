# Portal cookie catalogue

> **Purpose**: this document captures the per-portal session-cookie + OIDC-callback information that the L2 portal modules (`Xdr.Defender.Auth`, `Xdr.Purview.Auth`, `Xdr.Intune.Auth`, `Xdr.Entra.Auth`) need to know. It is the canonical reference for adding a new portal in v0.2.0+.
>
> **Architecture context**: see [docs/ARCHITECTURE.md](ARCHITECTURE.md) for the full L1/L2/L3/L4 module layout. The short version: L1 `Xdr.Common.Auth` does the Entra-layer auth flow (TOTP/Passkey + ESTSAUTHPERSISTENT cookie); L2 per-portal modules do the portal-specific cookie verification + OIDC callback handling on top of that L1 session.

---

## L1 / L2 boundary

L1 `Xdr.Common.Auth` is **portal-generic** — it knows nothing about specific portals. Its `Get-EntraEstsAuth` function takes:

| Parameter | Provided by | Used for |
|---|---|---|
| `-ClientId` | L2 module's hardcoded constant | Entra public-client app whose ESTS cookie is RP-scoped to the target portal |
| `-PortalHost` | L2 module's hardcoded constant | Initial GET (`https://<host>/`) to capture the OIDC authorize redirect; final form_post nudge if cookies are missing |
| `-Method` | Operator-selected | `CredentialsTotp` or `Passkey` (same across all portals — that's the unification point) |
| `-Credential` | Operator-supplied via Key Vault | upn + (password + totpBase32) OR (passkey JSON) |

L2 per-portal modules add:

| Step | Concern |
|---|---|
| Cookie name verification | Each portal mints a distinct session cookie after the OIDC callback (e.g., Defender's `sccauth`, Intune's portal-specific cookie, etc.) |
| CSRF cookie verification | Each portal mints a distinct CSRF cookie (e.g., Defender's `XSRF-TOKEN` consumed via `X-XSRF-TOKEN` header) |
| OIDC callback path | The portal's own `signin-oidc` (or equivalent) — discovered automatically by parsing the form_post `<form action="...">` from the response HTML |
| Tenant-context probe | Portal-specific endpoint that returns the authenticated tenant ID (auto-resolution; optional) |
| Rate-counter scope | Per-portal 429 counter surfaced to heartbeat (`Get-Xdr<Portal>Rate429Count`) |

---

## Per-portal catalogue

### Defender XDR (`security.microsoft.com`) — L2 module: `Xdr.Defender.Auth` (shipped in v0.1.0-beta)

| Field | Value |
|---|---|
| **Public client ID** | `80ccca67-54bd-44ab-8625-4b79c4dc7775` |
| **Portal host** | `security.microsoft.com` |
| **Session cookie** | `sccauth` |
| **CSRF cookie** | `XSRF-TOKEN` |
| **CSRF header** | `X-XSRF-TOKEN` (URL-decoded value) |
| **OIDC callback** | `/signin-oidc` (auto-discovered from form_post HTML) |
| **TenantContext probe** | `GET /apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true` — returns `AuthInfo.TenantId` |
| **Auth-self-test probe** | TenantContext (above) — most stable Defender endpoint for liveness |
| **Module status** | Implemented — `Connect-DefenderPortal` |

### Microsoft Purview (`compliance.microsoft.com`) — L2 module: `Xdr.Purview.Auth` ⏳ v0.2.0

| Field | Value (predicted; verify in v0.2.0) |
|---|---|
| **Public client ID** | `80ccca67-54bd-44ab-8625-4b79c4dc7775` (likely shares Defender's — Purview is part of M365 Compliance) |
| **Portal host** | `compliance.microsoft.com` |
| **Session cookie** | Likely `sccauth` (shared with Defender per portal heritage) — VERIFY |
| **CSRF cookie** | Likely `XSRF-TOKEN` — VERIFY |
| **OIDC callback** | Auto-discovered from form_post HTML |
| **TenantContext probe** | TBD — may share `/apiproxy/mtp/sccManagement/mgmt/TenantContext` |
| **Module status** | Stub planned for v0.2.0; verification needed against live Purview tenant |

### Microsoft Intune (`intune.microsoft.com`) — L2 module: `Xdr.Intune.Auth` ⏳ v0.2.0

| Field | Value (predicted; verify in v0.2.0) |
|---|---|
| **Public client ID** | `0000000a-0000-0000-c000-000000000000` (Microsoft Intune public client) |
| **Portal host** | `intune.microsoft.com` |
| **Session cookie** | Portal-specific (TBD — Intune does not share Defender's `sccauth`) |
| **CSRF cookie** | Portal-specific (TBD) |
| **OIDC callback** | Auto-discovered from form_post HTML |
| **TenantContext probe** | TBD |
| **Module status** | Stub planned for v0.2.0; full discovery + cookie inspection needed |

### Microsoft Entra (`entra.microsoft.com`) — L2 module: `Xdr.Entra.Auth` ⏳ v0.2.0

| Field | Value (predicted; verify in v0.2.0) |
|---|---|
| **Public client ID** | TBD |
| **Portal host** | `entra.microsoft.com` |
| **Session cookie** | Likely `ESTSAUTH` directly (Entra Admin portal is "closer" to login.microsoftonline.com — may not need a per-portal cookie at all; potentially a SIMPLER L2 module than Defender) |
| **CSRF cookie** | TBD |
| **OIDC callback** | Auto-discovered |
| **TenantContext probe** | TBD |
| **Module status** | Stub planned for v0.2.0 |

---

## Adding a new portal in v0.2.0+ — the L2 template

Every L2 portal module follows the same shape. Adding a new portal is a 1-day file-add operation, NOT a refactor. Here is the canonical template (copy this when adding `Xdr.<Portal>.Auth`):

```
src/Modules/Xdr.<Portal>.Auth/
├── Xdr.<Portal>.Auth.psd1                   # FunctionsToExport: Connect-<Portal>Portal, Get-<Portal>Sccauth, Invoke-<Portal>PortalRequest, Test-<Portal>PortalAuth + (optionally) Connect-<Portal>PortalWithCookies + rate counters
├── Xdr.<Portal>.Auth.psm1                   # Sets module-level $script: state ($SessionCache, $Rate429Count, etc.), defines $script:<Portal>ClientId, dot-sources Public + Private
├── Public/
│   ├── Connect-<Portal>Portal.ps1           # Wraps Get-EntraEstsAuth (L1) + Get-<Portal>Sccauth; caches sessions
│   ├── Connect-<Portal>PortalWithCookies.ps1  # Direct cookie-injection variant (testing-only)
│   ├── Get-<Portal>Sccauth.ps1              # Verify portal cookies + auto-resolve TenantId
│   ├── Invoke-<Portal>PortalRequest.ps1     # Authenticated wrapper (handles 401/440 reauth, 429 retry, TTL rotation, count rotation)
│   ├── Test-<Portal>PortalAuth.ps1          # Diagnostic — full chain + benign probe
│   ├── Get-XdrPortalRate429Count.ps1        # Module-scope counter accessor
│   └── Reset-XdrPortalRate429Count.ps1      # Module-scope counter reset
└── Private/
    └── Update-XsrfToken.ps1                 # Reads CSRF cookie from session jar (or portal-specific equivalent)
```

What changes between portals (only ~10 lines):
- `$script:<Portal>ClientId` constant in `.psm1`
- Default `-PortalHost` in each Public function
- Cookie name(s) verified inside `Get-<Portal>Sccauth.ps1`
- TenantContext probe URL inside `Get-<Portal>Sccauth.ps1`
- Auth-self-test probe URL inside `Test-<Portal>PortalAuth.ps1`

What stays the same (everything else): the entire L1 auth flow (TOTP/Passkey + MFA + interrupts + form_post) is reused via `Get-EntraEstsAuth`. Same operator credentials work across all portals (same TOTP secret / passkey JSON in Key Vault).

---

## Test gates

| Test | What it asserts | Runs against |
|---|---|---|
| `tests/unit/AuthLayerBoundaries.Tests.ps1` | Xdr.Common.Auth contains ZERO Defender-specific strings (sccauth, signin-oidc, security.microsoft.com, sccManagement, mtp/, X-XSRF-TOKEN-*) | `Xdr.Common.Auth` source files |
| `tests/unit/Xdr.Common.Auth.Tests.ps1` | L1 Public + Private functions work in isolation | `Xdr.Common.Auth` |
| `tests/unit/Xdr.Defender.Auth.Tests.ps1` | L2 Defender Public functions work end-to-end | `Xdr.Defender.Auth` (mocks L1) |
| `tests/unit/Xdr.Portal.Auth.Tests.ps1` | Backward-compat shim wrappers delegate correctly | `Xdr.Portal.Auth` |

When adding a new portal in v0.2.0, add `tests/unit/Xdr.<Portal>.Auth.Tests.ps1` mirroring the Defender test structure.

---

## References

- L1 module: [`src/Modules/Xdr.Common.Auth/`](../src/Modules/Xdr.Common.Auth/)
- L2 Defender: [`src/Modules/Xdr.Defender.Auth/`](../src/Modules/Xdr.Defender.Auth/)
- Backward-compat shim: [`src/Modules/Xdr.Portal.Auth/`](../src/Modules/Xdr.Portal.Auth/)
- Architecture overview: [docs/ARCHITECTURE.md](ARCHITECTURE.md)
- Auth deep-dive: [docs/AUTH.md](AUTH.md)
- Conditional Access × auth-method matrix: [docs/CONDITIONAL-ACCESS-COMPATIBILITY.md](CONDITIONAL-ACCESS-COMPATIBILITY.md)
