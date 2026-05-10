# Bring Your Own Software Passkey (BYOP)

> **TL;DR**: Generate a software passkey JSON for your service account using the Microsoft authenticator-style WebAuthn flow, store it in Key Vault as `mde-portal-passkey`, and the connector's auth chain uses it as a fully unattended MFA-satisfying second factor for service-account portal sign-in.

This doc explains how to generate, encode, and seed a software passkey for the dedicated service account that XdrLogRaider uses to authenticate to the Defender XDR portal (`security.microsoft.com`). The passkey is one of two unattended-MFA paths supported by the connector — the other is RFC 6238 TOTP (see [`docs/AUTH.md`](AUTH.md)).

## Why a software passkey?

- **WebAuthn is RP-attested**: the portal accepts a registered public-key credential as proof-of-possession of the device that registered it. This satisfies Conditional Access "require MFA" + "require compliant device" combinations that pure-TOTP cannot.
- **No phone needed**: software passkey lives as a JSON blob in Key Vault, signed/verified entirely in-process by the Function App at sign-in time.
- **Auto-rotates**: the connector signs each authentication challenge with the registered private key on demand; no operator intervention required.
- **Better DR posture**: passkey JSON is portable across Function App redeploys, KV migrations, regional moves.

## Prerequisites

- Dedicated service account (`svc-xdrlr@…`) with `Security Reader` (Entra) + `Defender XDR Analyst` (Defender RBAC) roles
- Browser-side: Chrome/Edge with WebAuthn support (any modern browser)
- A workstation you trust to generate + temporarily store the registration material

## Step 1 — Register the passkey at `mysignins.microsoft.com`

1. Sign in as the service account (one-time interactive flow)
2. Navigate to **Security info** → **Add sign-in method** → **Security key (passkey)** → **USB / device-based**
3. Browser prompts WebAuthn registration ceremony — accept; the browser generates an asymmetric keypair and submits the public key + attestation to Entra
4. Entra returns a registration confirmation; record the `credentialId` shown (32-byte base64url string)

## Step 2 — Export the passkey JSON

The connector stores the passkey as a JSON blob with the following shape:

```json
{
  "credentialId": "base64url-encoded credential ID from Entra registration",
  "publicKey": {
    "kty": "EC",
    "crv": "P-256",
    "x": "base64url-encoded X coordinate",
    "y": "base64url-encoded Y coordinate"
  },
  "privateKey": {
    "kty": "EC",
    "crv": "P-256",
    "d": "base64url-encoded private scalar"
  },
  "rpId": "login.microsoftonline.com",
  "userHandle": "base64url-encoded user handle from Entra"
}
```

Use the helper at `tools/Generate-PortalPasskey.ps1` (interactive, runs the WebAuthn ceremony in PowerShell using the Microsoft.Identity.Client SDK) to produce this JSON. **Run on a trusted workstation only.** The private key never leaves your control.

## Step 3 — Seed Key Vault

```powershell
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <KV-from-deploy>
# Helper prompts for: UPN, password, auth method (passkey or totp), and the JSON file path
```

The helper writes the secret as `mde-portal-passkey` (versioned). The Function App MI reads it via `Get-XdrAuthFromKeyVault` at first sign-in and caches the parsed structure for the configurable TTL (default 60 min).

## Step 4 — Validate

After the next poll cycle, check:

```kql
AppEvents
| where TimeGenerated > ago(1h)
| where Name == 'AuthChain.Completed'
| where Properties contains 'passkey'
| order by TimeGenerated desc
| take 5
```

A successful row confirms the passkey-driven sign-in completed end-to-end. If you see `AuthChain.AADSTSError` with `Method=passkey` instead, see [docs/AUTH.md](AUTH.md) and [docs/RUNBOOK.md](RUNBOOK.md) → "Auth chain failure".

## Rotation

Software passkeys don't expire by themselves but your organization's CA policy or device-compliance requirements may force re-registration. To rotate:

1. Repeat steps 1-3 with the new ceremony — Key Vault stores the new version, old version becomes inactive
2. Restart the Function App (Stop+Start) to invalidate the cached auth bundle and pick up the new secret version
3. Validate via the KQL query above

## Security considerations

- **Private key custody**: the JSON contains a private scalar. Treat it like a credential. Store ONLY in Key Vault (never in source, never in CI vars, never in `.env` files).
- **Workstation trust**: the WebAuthn ceremony in step 2 happens on a workstation you trust. If that workstation is compromised, the passkey it generated is compromised.
- **Service account scope**: the passkey is bound to one Entra account. If the service account is compromised (per [docs/RUNBOOK.md](RUNBOOK.md) "Service account compromised" procedure), rotate this passkey too.
- **CA exclusion is NOT required**: TOTP + Passkey both satisfy the standard "require MFA" CA condition. Only "require compliant device" or "require hybrid-join" require explicit SA exclusion (see [docs/PERMISSIONS.md](PERMISSIONS.md)).

## Companion docs

- [`docs/AUTH.md`](AUTH.md) — both auth methods explained + CA compatibility + rotation
- [`docs/GETTING-AUTH-MATERIAL.md`](GETTING-AUTH-MATERIAL.md) — TOTP vs passkey decision tree + acquisition paths
- [`docs/RUNBOOK.md`](RUNBOOK.md) — auth chain failure incident response
- [`docs/PERMISSIONS.md`](PERMISSIONS.md) — full permissions matrix for service account + Function App MI + operator
- [`docs/SECURITY.md`](../SECURITY.md) — vulnerability disclosure + rotation cadence
