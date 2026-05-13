# Auth research consolidation — Phase 0 deliverable

Generated: 2026-05-12 16:20:55 UTC. Sources: nodoc OpenAPI specs + Postman collections + getting-started auth models + v1 Xdr.Common.Auth + this session's live-probe evidence.

## Goal

Per-portal unattended auth for a single SA using **TOTP** OR **Passkey** (W3C WebAuthn L2 ECDSA-P256). No SP, no public Microsoft API (Graph/MDE REST), no browser at runtime. ESTSAUTHPERSISTENT cookie (90-day KMSI) + refresh_token enable silent renewal without re-issuing TOTP.

## Auth method matrix (per [v1 AUTH.md](../../xdrlograider/docs/AUTH.md))

| CA control | CredentialsTotp | Passkey | Operator action |
|---|---|---|---|
| Require MFA | Pass | Pass | None |
| Require phishing-resistant MFA | **Fail** | Pass | **Use Passkey method** |
| Require compliant device | Fail | Fail | Exclude SA from policy |
| Require hybrid join | Fail | Fail | Exclude SA from policy |
| Block legacy auth | Pass | Pass | None |

**Both methods supported.** Operator picks per their CA strictness. TOTP simpler to set up; Passkey survives phishing-resistant MFA.

## Unattended-auth architecture (v2 — replaces v1's 50-min full re-auth)

```
Bootstrap per portal (one-time, ~5 sec):
  GET /oauth2/v2.0/authorize?client_id=<portal-client>&redirect_uri=<registered>&response_mode=query
       &scope=<resource>/.default+offline_access+openid+profile
       &code_challenge=<S256(verifier)>&code_challenge_method=S256
    -> SA cred POST + TOTP (or Passkey assertion)
    -> KMSI ack (LoginOptions=1)
    -> ESTSAUTHPERSISTENT cookie (Expires +90d)
    -> form_post lands at redirect_uri with ?code=...
  POST /oauth2/v2.0/token grant_type=authorization_code + Origin:<portal-host> + PKCE verifier
    -> access_token + refresh_token (resource-scoped)
  Store {refresh_token} in KV; the SPA client_id+audience+headers are static per portal.

Steady-state (every ~50 min during access_token validity, NO TOTP):
  POST /oauth2/v2.0/token grant_type=refresh_token + Origin:<portal-host>
    -> fresh access_token (rotated refresh_token)
  GET <api-host>/<endpoint> Authorization:Bearer <access_token> <portal-specific-headers>
    -> JSON data

Recovery (~85 days, KMSI expiring soon):
  Run bootstrap. ~5 sec. Operator-scheduled.
```

## Per-portal status

| Portal | Bucket | ClientId | Audience | Status |
|---|---|---|---|---|
| defender | A-cookie | ✓ | ✓ | proven-v1-production-live |
| entra-b2c | C-azure-ad-bearer | ✓ | ✓ | audience known; tenantId query param required per nodoc |
| entra-ibiza-iam | C-azure-ad-bearer | ✓ | ✓ | FULLY-PROVEN-LIVE-JSON-DATA-RETURNED this session |
| entra-idgov | C-azure-ad-bearer | ✓ | ✓ | audience known; client likely shared |
| entra-iga | C-azure-ad-bearer | ✓ | ✓ | audience known; client likely shared |
| entra-pim | C-azure-ad-bearer | ✓ | ✓ | audience known from nodoc; client likely shared with Entra IAM |
| exchange | A-cookie | ✓ | ✓ | proven-session-16-live-endpoints |
| intune-autopatch | B-bearer | ✓ | ✓ | auth-chain-pattern-shared-with-intune; audience known |
| intune-portal | B-bearer | ✓ | pending | session-proven-auth-chain-end-to-end; code+access_token+refresh_token obtained; API audience TBD |
| m365-admin | A-cookie+B-bearer-hybrid | ✓ | ✓ | cookie-chain-works-via-Exchange-client; bearer-side pending audience |
| m365-apps-config | B-bearer | pending | pending | headers known; client + audience pending |
| m365-apps-inventory | B-bearer | pending | pending | same as m365-apps-config |
| m365-apps-services | B-bearer | pending | pending | same as m365-apps-config |
| power-platform | B-bearer-multi-audience | ✓ | ✓ | multi-audience pattern known; per-host audience map pending |
| purview | A-cookie | ✓ | ✓ | proven-v1-and-session |
| purview-portal | A-cookie+silent-token | ✓ | ✓ | auth-chain-proven; same-origin-token-mint-pending |
| security-copilot | B-bearer-multi-host | pending | pending | auth-chain-pattern-known; multi-host audience discovery pending |
| sharepoint | A-cookie+digest | pending | ✓ | auth-chain-pattern-known; tenant-host + digest pending |
| teams | B-bearer-regional | pending | pending | auth-chain-pattern-known; regional-discovery step required |
| viva | B-bearer-PKCE+Bayeux | pending | ✓ | scope-known; client discovery + Bayeux relay handshake pending |

## What's proven live

- **defender** (v1 production, ~3 months): 120 live endpoints, full TOTP+sccauth chain
- **purview**: 20 live endpoints via session-cookie + same TOTP chain
- **exchange**: 16 live endpoints via .AspNetCore.Cookies + x-requested-with
- **intune-portal**: TOTP chain -> authorization_code (1504 chars) -> access_token (2495) + refresh_token (1456) -> silent refresh OK; API token-audience requires per-portal discovery
- **entra**: same chain as intune via shared c44b4083 client
- **entra-ibiza-iam**: FULL END-TO-END -- TOTP -> access_token (ADIbizaUX-scoped) -> silent refresh -> `GET main.iam.ad.ext.azure.com/api/ViralSubscriptions` -> HTTP 200 + real JSON `[{"targetClass":"User",...}]`

## Pending discovery (per portal, text-only — no browser)

For each Bucket B/C portal: ClientId + Audience + portal-specific Headers. Sources to mine:
- nodoc OpenAPI servers (audience hints in baseUrl)
- nodoc getting-started auth model per family (headers documented)
- nodoc Postman collection auth + sample headers
- portal SPA HTML static analysis (clientId GUIDs visible in inline JS)
- this session's c44b4083 finding — covers Azure-AD-app SPAs (Intune/Entra family/Power Platform likely)

## KV secret schema per portal

```
<portal>-upn        (always)
<portal>-password   (CredentialsTotp method)
<portal>-totp       (CredentialsTotp method; Base32)
<portal>-passkey    (Passkey method; JSON {upn,credentialId,privateKeyPem,rpId})
<portal>-refresh    (long-lived refresh_token; steady-state polling)
```

