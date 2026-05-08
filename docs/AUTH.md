# Authentication

XdrLogRaider supports two unattended, auto-refreshing auth methods for `security.microsoft.com` portal API access. The connector never prompts interactively after initial setup.

## Method matrix

| Method | User provides | Auto-refresh | MFA strength | CA posture survivability |
|---|---|---|---|---|
| Credentials + TOTP | UPN, password, TOTP Base32 secret | Yes (TOTP regenerates codes) | Satisfies "Require MFA" | Fails "Require phishing-resistant MFA" + "Require compliant device" |
| Software Passkey | Passkey JSON bundle | Yes (ECDSA signing) | Satisfies "Require phishing-resistant MFA" (FIDO2) | Fails "Require compliant device" only |

## Credentials + TOTP

**Setup**:
1. Enroll Microsoft Authenticator for the service account via Entra UI
2. Click "I want to use a different authenticator app" to reveal the Base32 secret
3. Copy the Base32 secret (20-32 chars, A-Z/2-7 alphabet)

**Auth chain**:
1. POST UPN + password to `login.microsoftonline.com/common/login`
2. MFA challenge → submit TOTP code (generated per RFC 6238)
3. Receive ESTSAUTHPERSISTENT cookie
4. GET `security.microsoft.com/` → redirects issue sccauth + XSRF-TOKEN
5. Use sccauth for API calls; rotate XSRF per response

**Rotation**: password change = re-upload secrets via `Initialize-XdrLogRaiderAuth.ps1`. TOTP secret is permanent until rotated.

## Software Passkey

**Setup**:
1. Generate an ECDSA-P256 keypair externally (see "Bring your own passkey" section below)
2. Register with Entra as a FIDO2 security key for the service account
3. Save as JSON: `{ upn, credentialId, privateKeyPem, rpId }`

**Auth chain**:
1. GET `login.microsoftonline.com/common/GetCredentialType?username=...`
2. Receive FIDO2 challenge
3. Sign challenge with ECDSA-P256 per W3C WebAuthn §7.2
4. POST assertion back
5. Receive ESTSAUTHPERSISTENT
6. Exchange at `security.microsoft.com` for sccauth + XSRF
7. Use sccauth for API calls

**Rotation**: re-register passkey in Entra → export new JSON → re-upload. Old credentialId can be removed from Entra security info.

## Conditional Access compatibility

The connector uses real Entra sign-in flow — Conditional Access policies apply normally. **No bypass is performed.** TOTP and Passkey both satisfy "Require MFA". The only hard blocker is **device-compliance / hybrid-join** policies because the Function App outbound IP is not a managed device.

| Policy control | Credentials+TOTP | Passkey | Operator action if enforced |
|---|---|---|---|
| Require MFA | Pass (TOTP satisfies) | Pass (FIDO2 satisfies) | **No action needed** — both methods satisfy MFA |
| Require phishing-resistant MFA | Fail | Pass | Use Passkey method |
| Require compliant device | **Fail** | **Fail** | **Exclude the service account** from this policy |
| Require hybrid join | **Fail** | **Fail** | **Exclude the service account** from this policy |
| Block legacy auth | Pass (modern flow) | Pass | No action needed |
| Sign-in risk policies | May trigger | May trigger | Add FA outbound IPs to a named location OR exclude the SA |

**TL;DR for typical tenants**: TOTP + Passkey both satisfy MFA — **CA is not a blocker on its own**. The single common scenario that needs operator action is **device-compliance / hybrid-join**: exclude the connector service account from those policies. The XdrOps-ServiceAccountAnomalousSignIn analytic rule monitors the SA for compromise patterns (anomalous country/IP/device, failed-then-success cred-stuffing, sign-in outside poll cadence) — operator MUST enable it post-deploy as the security-boundary control.

### Required CA exemption (most tenants)

Even on tenants that don't require phishing-resistant MFA, an unattended service account that signs in every 10 minutes will trigger interactive-MFA prompts unless the SA is explicitly **excluded** from policies that target "all users":

1. Entra → Protection → Conditional Access → your interactive-MFA policy → Exclude → Users → add the connector SA (`svc-xdrlr-...@...`).
2. (Optional) Add a named-location IP rule allowing the Function App's outbound IPs (Portal → Function App → Networking → Outbound IPs).
3. Verify post-deploy: `App Insights customEvents | top 1 by TimeGenerated desc` should show `Success=true Stage=complete` within 10 min of the first timer fire.

If sign-in fails post-deploy with `AADSTS50076` (MFA required) or `AADSTS50079` (proof up required), the SA wasn't excluded — fix the policy and re-fire `(auth chain — see App Insights customEvents)` (`Function App → Functions → (auth chain — see App Insights customEvents) → Test/Run`).

**Why this matters for production**: an interactive-MFA prompt on a programmatic flow is the #1 cause of "auth-test green for an hour then suddenly red" — the policy fired during a refresh cycle. Document the exemption AT DEPLOY TIME so you don't troubleshoot it at 3 AM.

## Service account governance

Create a **dedicated** Entra user with:
- UPN pattern: `svc-xdrlr-<tenant>@<domain>.onmicrosoft.com`
- **No default admin roles**
- Required roles: `Security Reader` + `Microsoft Defender Analyst` (read-only)
- Password: strong, documented in KV, rotated quarterly
- MFA: TOTP or passkey (matching chosen method)
- Sign-in session revocation: enabled (for future compromise response)

Review quarterly:
- Service account sign-in logs (should show only this IP/UA)
- Key Vault secret access logs
- Role assignments (no privilege creep)

## Security model

- Secrets never leave Key Vault (Function App MI reads at runtime)
- No secrets in code, ARM payload, or deployment history
- Helper script transmits secrets only to Key Vault, never to security.microsoft.com
- Function App self-test is the single source of truth for "auth works"
- XSRF cookie rotates per-response per Microsoft's portal implementation
- sccauth rotates ~hourly; automatic re-auth on cache expiry

## Why not client credentials / managed identity?

Microsoft public APIs (Graph, MDE REST) support client credentials + MI. But the **portal APIs** under `/apiproxy` require user context (sccauth cookie, not Bearer token). There is no Microsoft-documented way for a service principal to acquire sccauth.

For data available via the public APIs, use Microsoft's official Sentinel connectors instead — XdrLogRaider specifically covers what those can't.

## Bring your own passkey (Software Passkey JSON schema)

XdrLogRaider accepts a software (non-hardware) passkey for the service account. You generate this externally and provide the JSON to the setup helper.

### Required JSON schema

```json
{
  "upn": "svc-xdrlr@your-tenant.onmicrosoft.com",
  "credentialId": "<base64url-encoded credential ID from Entra registration>",
  "privateKeyPem": "-----BEGIN EC PRIVATE KEY-----\n<your ECDSA-P256 private key>\n-----END EC PRIVATE KEY-----",
  "rpId": "login.microsoft.com"
}
```

- `upn` — the service account UPN (must match the user the credential was registered for)
- `credentialId` — opaque base64url identifier Entra returned during registration
- `privateKeyPem` — ECDSA-P256 private key in PEM format, unencrypted, with literal `\n` line separators preserved
- `rpId` — relying party ID; for Entra logins use `login.microsoft.com`

### Generation paths

Three known-working paths, pick any. **All require one-time browser interaction to register with Entra.**

- **Path A** — [Yubico python-fido2](https://github.com/Yubico/python-fido2) software-authenticator mode (cross-platform). See community example scripts for the browser-relay pattern.
- **Path B** — [XDRInternals PowerShell module](https://github.com/MSCloudInternals/XDRInternals) software-passkey setup. Export the keypair + credentialId + UPN to the JSON schema above.
- **Path C** — Hardware-key export (not recommended). Some FIDO2 keys allow private-key export via vendor-specific tools (e.g., Yubico enterprise edition with config locking disabled). Breaks most hardware keys' security model — only with a dedicated automation key.

### Security considerations

- Passkey JSON file contains a **private key** — treat as a secret.
- After uploading to Key Vault via `Initialize-XdrLogRaiderAuth.ps1`, **delete the local file**: `Remove-Item ./my-passkey.json`
- Passkeys are per-user — one passkey for `svc-xdrlr@contoso.com` cannot authenticate any other account.
- Rotation: re-register a fresh passkey in Entra, generate a new JSON, re-run the setup helper. Revoke the old credentialId in Entra security info.

### Testing your passkey

Before uploading to production Key Vault, verify the passkey works locally:

```powershell
$env:XDRLR_TEST_UPN = 'svc-xdrlr@test.onmicrosoft.com'
$env:XDRLR_TEST_AUTH_METHOD = 'Passkey'
$env:XDRLR_TEST_PASSKEY_PATH = './my-passkey.json'
$env:XDRLR_ONLINE = 'true'
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

Expected: all 5 `Auth-Chain-Live.Tests.ps1` tests pass. See `tests/README.md` for full local-online test flow.

### FAQ

- **Can I use Windows Hello as a passkey?** No — Windows Hello private keys are sealed by TPM and cannot be exported for unattended use.
- **Can I use my personal YubiKey?** Typically no — consumer YubiKeys do not expose private-key export. You'd need a dedicated software passkey.
- **What curve is required?** ECDSA-P256 (secp256r1 / prime256v1). Entra supports other curves but the connector is implemented against P256 specifically.
- **Is this FIDO2 certified?** No — software simulation of a FIDO2 authenticator. Entra accepts it because it implements the WebAuthn assertion format correctly, but it would not be accepted by FIDO2-certified relying parties requiring hardware-attested authenticators.

### References

- [W3C WebAuthn Level 2 §7.2](https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion) — assertion verification spec
- [FIDO2 / CTAP2](https://fidoalliance.org/specifications/) — client-to-authenticator protocol
- [Microsoft FIDO2 authentication methods API](https://learn.microsoft.com/en-us/graph/api/resources/fido2authenticationmethod) — Entra-side registration
