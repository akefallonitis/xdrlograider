# Setup — Service Account & Unattended MFA

XdrLogRaider signs in to the Microsoft Defender XDR portal as a **dedicated Entra ID service account**, exactly as an operator's browser would, and satisfies MFA **headlessly** using a secret you export once at enrollment time. The codebase implements **two** credential methods, both **unattended** — and the only two the one-click deploy exposes — **Credentials + TOTP** and **Credentials + Passkey/FIDO2** (see [Auth model](#auth-model-context) below). Pick one.

> **Before you create the account:** this is an always-on, non-interactive identity with standing read access to your Defender XDR tenant. Read [SECURITY-CONSIDERATIONS.md](SECURITY-CONSIDERATIONS.md) first — it must be scoped and monitored like any other standing-access credential.

---

## 1. Create the service account

1. In **Entra ID → Users → New user → Create new user**, create a *cloud-only* account, e.g. `xdrlogreader@yourtenant.onmicrosoft.com`.
2. Set a strong password you control. The deploy stores it in Key Vault; after enrollment you never type it again.
3. Do **not** make it a Global Admin or assign any write/admin role. The connector is strictly read-only — grant only the read role described in [RBAC.md](RBAC.md). Least-privilege **Defender Unified RBAC** is recommended over the broad Security Reader.
4. Keep the account inside a **named-location + monitored** Conditional Access scope. Exclude it from any policy that would force an *interactive* re-proof on every sign-in (it cannot answer a prompt) — see the Conditional Access guidance in [SECURITY-CONSIDERATIONS.md](SECURITY-CONSIDERATIONS.md).

---

## 2a. Unattended MFA — Option A: TOTP (recommended)

TOTP (RFC 6238) is the simplest unattended path: a shared base32 seed the connector uses to compute the 6-digit code on demand.

1. Sign in to <https://mysignins.microsoft.com/security-info> **as the service account**.
2. **Add sign-in method → Authenticator app → I want to use a different authenticator app.** Entra shows a QR code and, via **Can't scan image?**, a **base32 secret key** (e.g. `JBSWY3DPEHPK3PXP…`). **Copy that base32 seed — this is the value you give the deploy.** It is shown only once.
3. Finish enrollment: compute the current code from the seed with any TOTP tool (for example `python -c "import pyotp; print(pyotp.TOTP('<SEED>').now())"`) and enter it. The method registers as a **Software OATH token**.
4. At deploy time set `authMethod = TOTP` and paste the base32 seed into the `totpSecret` parameter (a `securestring` — it goes straight to Key Vault, never to an app setting or a log).

Each auth cycle, the Defender auth handler performs the MFA stage (`BeginAuth → EndAuth(AdditionalAuthData=TOTP) → ProcessAuth`) with a code it derives from this seed. No human, no push notification.

---

## 2b. Unattended MFA — Option B: Passkey / FIDO2

Passkey uses a WebAuthn ECDSA-P256 key pair whose private key you hold. The connector produces the FIDO2 assertion headlessly.

1. Generate an ECDSA-P256 key pair and register the credential as a passkey on the service account (the WebAuthn registration ceremony against `mysignins.microsoft.com`; see the `dev-tools/` helpers for scripted enrollment against a controlled test account).
2. Export the **private key in PEM** form. If your registration flow produced a credential id, store the JSON envelope:

   ```json
   { "credentialId": "…", "privateKeyPem": "-----BEGIN EC PRIVATE KEY-----\n…" }
   ```
3. At deploy time set `authMethod = Passkey` and paste the PEM (or the JSON envelope) into the `passkeyPem` parameter (`securestring` → Key Vault).

Use Passkey when your tenant policy prefers phishing-resistant FIDO2 over a shared OATH seed. Operationally it is equivalent for the connector — both run fully unattended.

---

## 3. Deploy

Click **Deploy to Azure** and provide:

| Parameter | Value |
|---|---|
| `workspaceResourceId` | Resource ID of your Sentinel-enabled Log Analytics workspace |
| `serviceAccountUpn` | The UPN of the account from step 1 |
| `servicePassword` | Its password (`securestring`) |
| `authMethod` | `TOTP` or `Passkey` |
| `totpSecret` | The base32 seed (`securestring`, TOTP mode) |
| `passkeyPem` | The private-key PEM / JSON envelope (`securestring`, Passkey mode) |

ARM provisions a fresh Key Vault, writes all three secrets into it (`ServicePassword`, `TotpSecret`, `PasskeyPem`), and grants the Function App's system-assigned managed identity **Key Vault Secrets User** so it can read them at runtime. No secret is ever placed in an app setting or a log. See [CRED-FLOW.md](CRED-FLOW.md) for exactly where each value lands.

---

## Auth model (context)

Two credential methods are **implemented today**, both **unattended** (KMSI 90-day SSO): **Credentials + TOTP** and **Passkey / FIDO2**. Each drives the portal sign-in to obtain a portal **cookie** (`sccauth`, for Defender/Purview) or a **bearer token** (auth-code + PKCE + `refresh_token`, for Entra/Intune/Security Copilot). The five further methods below are described in the design but are **not yet implemented** — do not rely on them.

| # | Method | API surface | Status | Unattended |
|---|--------|-------------|--------|------------|
| 1 | Credentials + TOTP                 | Portal cookie / bearer | ✅ **Implemented** ← deploy | yes (KMSI 90d) |
| 2 | Passkey / FIDO2                    | Portal cookie / bearer | ✅ **Implemented** ← deploy | yes (KMSI 90d) |
| 3 | ESTS cookie (operator-supplied)    | Portal-internal | ⛔ Not implemented (planned) | — |
| 4 | TAP (Temporary Access Pass)        | Portal-internal | ⛔ Not implemented (planned) | — |
| 5 | Direct sccauth (operator-supplied) | Portal-internal | ⛔ Not implemented (planned) | — |
| 6 | Device code                        | Official OAuth  | ⛔ Not implemented (planned) | — |
| 7 | Client credentials                 | Official OAuth  | ⛔ Not implemented (planned) | would be (app-only) |

In steady state the connector rides **cookie + KMSI 90-day SSO**. A full headless login (method 1 or 2) fires only ~4×/year per UPN, when KMSI expires.

---
*Maintainer: Alex Kefallonitis · al.kefallonitis@gmail.com · <https://www.linkedin.com/in/alex-kefallonitis-3a8739a7>*
