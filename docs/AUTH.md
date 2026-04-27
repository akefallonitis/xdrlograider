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
1. Generate an ECDSA-P256 keypair externally (see [BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md))
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

| Policy control | Credentials+TOTP | Passkey |
|---|---|---|
| Require MFA | Pass (TOTP satisfies) | Pass (FIDO2 satisfies) |
| Require phishing-resistant MFA | **Fail** | Pass |
| Require compliant device | **Fail** | **Fail** |
| Require hybrid join | **Fail** | **Fail** |
| Block legacy auth | Pass (login flow is modern) | Pass |
| Sign-in risk policies | May trigger (no device) | May trigger (no device) |

If your tenant requires compliant device, run the Function App on an Arc-enabled managed endpoint OR document a named-location CA exception for the service account's service-principal IP. See [RUNBOOK.md](RUNBOOK.md).

### Required CA exemption (most tenants)

Even on tenants that don't require phishing-resistant MFA, an unattended service account that signs in every 10 minutes will trigger interactive-MFA prompts unless the SA is explicitly **excluded** from policies that target "all users":

1. Entra → Protection → Conditional Access → your interactive-MFA policy → Exclude → Users → add the connector SA (`svc-xdrlr-...@...`).
2. (Optional) Add a named-location IP rule allowing the Function App's outbound IPs (Portal → Function App → Networking → Outbound IPs).
3. Verify post-deploy: `MDE_AuthTestResult_CL | top 1 by TimeGenerated desc` should show `Success=true Stage=complete` within 10 min of the first timer fire.

If sign-in fails post-deploy with `AADSTS50076` (MFA required) or `AADSTS50079` (proof up required), the SA wasn't excluded — fix the policy and re-fire `validate-auth-selftest` (`Function App → Functions → validate-auth-selftest → Test/Run`).

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
