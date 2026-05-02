# Unattended authentication

> **Audience**: operators who want to understand how XdrLogRaider authenticates to the Defender XDR portal **without a human in the loop** for the lifetime of the deployment, what fails, and how it recovers.
>
> **TL;DR**: TOTP and Software Passkey at the **Entra layer** are the unified primitive — same auth function, same operator credentials, applies to every Microsoft 365 portal. Per-portal session cookies are *containers*, not auth methods. The connector handles cookie expiration via a 50-minute proactive cache evict + 3h30m proactive TTL refresh + 401/440 reactive re-auth.

## Why "unattended" matters

A scheduled-poll connector has to re-authenticate on its own. Every 50 minutes the Defender portal's `sccauth` cookie expires. Every 4 minutes the `XSRF-TOKEN` rotates. Every cold-start of a new Azure Functions worker starts with no cached session. **There is no human to type a password or tap a TOTP code at any of those moments.** The connector must derive the auth material itself — at any time, on any worker, in any region.

XdrLogRaider achieves this with **two unattended primitives**:

| Primitive | What it solves | What it can't solve |
|---|---|---|
| **TOTP (RFC 6238)** | TOTP secret stored in Key Vault; HMAC-SHA1 over the current 30-second time window mints a fresh 6-digit code on demand | Tenants enforcing phishing-resistant CA: TOTP is rejected as not-phishing-resistant |
| **Software Passkey (FIDO2 ECDSA-P256)** | PEM-encoded private key + WebAuthn credential ID stored in KV; signs Entra's challenge per W3C WebAuthn §7.2 | None known on Microsoft portals — passkey passes phishing-resistant CA on every portal that accepts FIDO2 |

Operators choose one at deploy time via the `authMethod` parameter. The choice applies tenant-wide; can be changed by re-running `Initialize-XdrLogRaiderAuth.ps1` and re-deploying.

## How it works (the auth chain)

```
                           Function App worker
                       ┌─────────────────────────┐
                       │ poll-inventory-1d   │ (timer fires)
                       └────────────┬────────────┘
                                    │
                                    ▼
                  ┌──────────────────────────────────────┐
                  │ L4 Xdr.Connector.Orchestrator (v0.2.0)│
                  │  Routes to Defender L3 today          │
                  └────────────┬─────────────────────────┘
                               │ -Stream MDE_AdvancedFeatures_CL
                               ▼
                  ┌──────────────────────────────────────┐
                  │ L3 Xdr.Defender.Client                │
                  │  Invoke-MDEEndpoint                   │
                  └────────────┬─────────────────────────┘
                               │ -Session, GET path
                               ▼
                  ┌──────────────────────────────────────┐
                  │ L2 Xdr.Defender.Auth                  │
                  │  Connect-DefenderPortal               │ (cache)
                  │   ├─ if cache hit (<50min) → return   │
                  │   └─ if cold/stale ↓                  │
                  │      Get-EntraEstsAuth (L1)           │
                  │      Get-DefenderSccauth (L2 verify)  │
                  │  Invoke-DefenderPortalRequest         │ (XSRF refresh + 401/440 reauth + 429 retry)
                  └────────────┬─────────────────────────┘
                               │
                               ▼
                  ┌──────────────────────────────────────┐
                  │ L1 Xdr.Common.Auth (portal-generic)   │
                  │  Get-EntraEstsAuth                    │
                  │   1. GET portal/ (302 chain)          │
                  │   2. Parse $Config from login.html    │
                  │   3. Method-specific:                 │
                  │       Complete-CredentialsFlow        │
                  │         + Complete-TotpMfa            │
                  │       OR Complete-PasskeyFlow         │
                  │   4. Resolve-EntraInterruptPage       │
                  │   5. Submit-EntraFormPost             │
                  └────────────┬─────────────────────────┘
                               │ KV secret access via SAMI
                               ▼
                  ┌──────────────────────────────────────┐
                  │ Get-XdrAuthFromKeyVault (L1)          │
                  │  Reads <prefix>-upn / -password /     │
                  │  -totp / -passkey from Azure Key Vault│
                  └──────────────────────────────────────┘
```

**Layer responsibilities**:

- **L1 Xdr.Common.Auth** is portal-generic. It knows how to talk to `login.microsoftonline.com`. It does NOT know about specific portals — callers pass `-ClientId` (Defender's `80ccca67-…` today; v0.2.0 portals will pass theirs) and `-PortalHost` (`security.microsoft.com` today).

- **L2 Xdr.Defender.Auth** knows the Defender-specific cookie names (`sccauth`, `XSRF-TOKEN`) + the portal's TenantContext probe path. It wraps L1 with the `Connect-DefenderPortal` cache and the `Invoke-DefenderPortalRequest` retry/refresh logic. v0.2.0 sibling modules (`Xdr.Purview.Auth`, `Xdr.Intune.Auth`, `Xdr.Entra.Auth`) follow the same template — only their cookie names + client IDs differ.

- **Backward-compat shim** `Xdr.Defender.Auth` re-exports `Connect-DefenderPortal`, `Invoke-DefenderPortalRequest`, `Test-DefenderPortalAuth`, `Get-XdrAuthFromKeyVault`, `Connect-DefenderPortalWithCookies` as wrappers that delegate to the L2 functions. Existing operator scripts that call MDE-prefixed names keep working unchanged.

## What the connector handles automatically

| Failure mode | Recovery |
|---|---|
| **Worker cold-start, no cached session** | First call hits cache miss; full L1 auth chain runs; session cached for 50min |
| **50-minute cache age** | Connect-DefenderPortal evicts proactively; next call re-auths |
| **3h30m approaching ~4h sccauth TTL** | Invoke-DefenderPortalRequest checks `Session.AcquiredUtc`; forces fresh auth before the request |
| **100-request count threshold** | Same proactive refresh path; bounds replay-window risk |
| **HTTP 401 / 440 mid-request** | Catch + reauth + retry once with fresh session |
| **HTTP 429 Too Many Requests** | Honour `Retry-After` header (or default 5s × attempt) + jitter; up to 3 retries; then throw `[MDERateLimited]` for caller |
| **TOTP duplicate-code (operator-mid-window submission collision)** | Wait for next 30-second window; retry; up to 3 attempts |
| **Entra interrupt page (KMSI / CMSI / ConvergedProofUpRedirect)** | `Resolve-EntraInterruptPage` walks each page automatically up to 10 hops |
| **`form_post` submission to portal OIDC callback** | `Submit-EntraFormPost` parses the form action URL from response HTML and POSTs the fields automatically |
| **TenantContext probe failure (transient network)** | Logged at Verbose; downstream call still succeeds; tenant ID resolves on next call |

## What the connector does NOT handle (operator must intervene)

| Failure mode | Operator action |
|---|---|
| **Service-account password rotated** | Re-run `Initialize-XdrLogRaiderAuth.ps1` to upload the new password to Key Vault; restart the FA |
| **Conditional Access policy newly blocks the SA** | Audit your CA policies; either exclude the SA from the offending policy (with appropriate compensating controls) OR switch to passkey auth method |
| **TOTP secret invalidated** | Re-enrol TOTP at `mysignins.microsoft.com`, capture the new Base32 secret, re-run `Initialize-XdrLogRaiderAuth.ps1` |
| **Passkey credential revoked** | Same — re-enrol passkey, regenerate the JSON bundle, re-upload |
| **Account locked (50053)** | Operator decides: unlock manually OR wait the lockout window OR rotate to a fresh SA |
| **Account disabled (50057)** | Operator must re-enable the SA in Entra |
| **Microsoft changes the auth chain** | The connector ships a defensive `Resolve-EntraInterruptPage` for known interrupts plus an UNKNOWN-pgid diagnostic warning. If a new interrupt appears, capture the App Insights warning and open a GitHub Issue with the offending HTML response so the maintainers can add a handler |

## How to verify your auth chain works

Run the (auth chain — see App Insights customEvents) timer manually (or wait for its hourly fire):

```powershell
# In Azure portal: Function App → Functions → (auth chain — see App Insights customEvents) → Code+Test → Run
```

Then check the result:

```kql
App Insights customEvents
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Method, PortalHost, Upn, Success, Stage, FailureReason, SampleCallHttpCode, SampleCallLatencyMs
```

Expected on a healthy deployment:

| Field | Expected |
|---|---|
| Success | `true` |
| Stage | `complete` |
| SampleCallHttpCode | `200` |
| SampleCallLatencyMs | < 5000 (typically ~500–1500) |
| FailureReason | empty |

If `Success=false`, the `Stage` field tells you which step failed:

| Stage | What happened | Where to look |
|---|---|---|
| `auth-chain` | L1 Get-EntraEstsAuth or L2 Get-DefenderSccauth threw | App Insights `traces` for the Connect-DefenderPortal call's correlation ID; check `FailureReason` |
| `sample-call` | Auth succeeded but the TenantContext probe failed | Same — usually 401 (auth invalidated mid-test) or 5xx (Microsoft-side blip) |

## Multi-portal forward-compat (v0.2.0+)

The L1/L2 auth split delivers the foundation for multi-portal expansion in v0.2.0:

| Portal | L2 module | Status |
|---|---|---|
| Defender XDR (`security.microsoft.com`) | `Xdr.Defender.Auth` | shipped in v0.1.0-beta |
| Microsoft Purview (`compliance.microsoft.com`) | `Xdr.Purview.Auth` | ⏳ v0.2.0 (likely shares Defender's `sccauth` — verify on first capture) |
| Microsoft Intune (`intune.microsoft.com`) | `Xdr.Intune.Auth` | ⏳ v0.2.0 |
| Microsoft Entra (`entra.microsoft.com`) | `Xdr.Entra.Auth` | ⏳ v0.2.0 |

Adding each new portal in v0.2.0 = ~10 lines (cookie name + OIDC callback + portal client ID) per [docs/PORTAL-COOKIE-CATALOG.md](PORTAL-COOKIE-CATALOG.md). Same TOTP / Passkey work for every portal — operators use one credential bundle.

## See also

- [docs/AUTH.md](AUTH.md) — auth method deep-dive (CA compatibility, rotation strategies)
- [docs/PORTAL-COOKIE-CATALOG.md](PORTAL-COOKIE-CATALOG.md) — L2 template for v0.2.0 portal additions
- [docs/CONDITIONAL-ACCESS-COMPATIBILITY.md](CONDITIONAL-ACCESS-COMPATIBILITY.md) — TOTP × Passkey × CA policy matrix
- [docs/GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md) — how to obtain TOTP / passkey / cookies from a service account
- [docs/PERMISSIONS.md](PERMISSIONS.md) — service-account roles + SAMI roles + cross-RG considerations
- [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) — symptom → fix runbook
