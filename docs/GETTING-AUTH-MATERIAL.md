# Getting auth material

Step-by-step for each supported auth method, from the perspective of a regular user setting up the connector for the first time.

## Before you start

Create a **dedicated service account** in your Entra tenant:

1. Entra admin center → **Users** → **New user**
2. UPN suggestion: `svc-xdrlr@<your-tenant>.onmicrosoft.com`
3. Set a strong password (save it somewhere you can paste from later)
4. Assign roles: **Security Reader** + **Defender XDR Analyst** (both read-only)

Use this service account for the rest of the setup. **Don't use your own admin account** — the connector impersonates whoever is enrolled.

## Method 1: Credentials + TOTP (recommended for most tenants)

This is the simplest. The connector auto-refreshes indefinitely.

### Step 1: Sign in as the service account

In a private browser window, go to https://mysignins.microsoft.com and sign in as `svc-xdrlr@<your-tenant>.onmicrosoft.com` using the password you set above.

If Entra prompts for MFA setup on first sign-in, complete it with the Microsoft Authenticator app first — just to satisfy the initial enrollment. We'll add a second TOTP authenticator below.

### Step 2: Add the TOTP authenticator

1. Click **Add sign-in method** → **Authenticator app**
2. Entra shows a screen offering to set up "Microsoft Authenticator"
3. Click the link **"I want to use a different authenticator app"** below the default option
4. Entra now shows:
   - A QR code
   - **Plus a text string labeled "Secret"** — a 20-32 character string using only letters A-Z and digits 2-7

### Step 3: Save the Base32 secret

**This is the critical step.** Copy the text string (the "Secret") to a secure location.

Example: `JBSWY3DPEHPK3PXPJBSWY3DPEHPK`

This is what the connector uses. It's the same secret that authenticator apps store — the math for generating 6-digit codes is public (RFC 6238), so any software with the secret can produce the same codes.

### Step 4: Also scan the QR (optional but recommended)

Use any authenticator app (Microsoft Authenticator, Google Authenticator, 1Password, etc.) to scan the QR code. Now both the connector AND your app can generate codes. Entra doesn't care which one you (or the connector) use — both produce identical codes from the same secret.

### Step 5: Finish Entra's "verify" step

Entra will ask you to enter a code to confirm enrollment worked. Enter the code your authenticator app shows. Done.

### Step 6: Paste into the connector

You now have three pieces:
- **UPN**: `svc-xdrlr@<your-tenant>.onmicrosoft.com`
- **Password**: the password you set
- **TOTP Base32 secret**: the string you copied in step 3

Either:

**Option A — in helper script**:
```powershell
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <kv-name>
# Pick method 1 (Credentials + TOTP) when prompted
# Paste the three values
```

**Option B — for local testing**:
```powershell
Copy-Item tests/.env.local.example tests/.env.local
# Edit tests/.env.local with your values
# Then:
pwsh ./tests/Run-Tests.ps1 -Category local-online
```

## Method 2: Software Passkey

Use this if your tenant requires phishing-resistant MFA. More complex to set up.

See [BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md) for full instructions — short version: use python-fido2 or XDRInternals to generate a software passkey, register it with Entra, export as JSON.

## Method 3: Direct Cookies (testing only)

Fastest path to "see it working", but **not unattended** (cookies expire in ~1h).

1. Sign into https://security.microsoft.com as the service account in Chrome/Edge
2. F12 → Application tab → Cookies → `https://security.microsoft.com`
3. Copy:
   - `sccauth` value
   - `XSRF-TOKEN` value
4. Paste into helper or `tests/.env.local`

Only use this to verify the data pipeline works before setting up real auto-refresh.

## What about push notifications, SMS, Windows Hello?

These cannot be automated:

| Method | Why it can't be automated |
|---|---|
| Microsoft Authenticator push | Requires a human tap on the phone |
| SMS code | Requires reading an SMS |
| Phone call | Requires answering a phone |
| Windows Hello | Private key sealed by TPM, can't be exported |
| Hardware YubiKey | Same — hardware holds the private key |

**Important**: even if your tenant requires any of these for interactive logins, you can still **additionally register** a TOTP authenticator or a software passkey on the service account, and the connector will use that. The service account will have multiple MFA methods — the connector picks the one it can automate.

## Verification

After configuring:

```kql
// Wait 5 min, then check:
MDE_AuthTestResult_CL
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Success, Stage, FailureReason
```

Expected: `Success = true, Stage = complete`.

If failed, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Rotation (when credentials change)

- **Password expired**: reset in Entra → re-run `Initialize-XdrLogRaiderAuth.ps1` with the new password
- **TOTP secret rotated**: re-enroll authenticator (repeat steps 1-5 above) → re-run helper
- **Passkey rotated**: re-register → re-run helper
- **sccauth expired** (DirectCookies only): re-capture from browser → re-run helper

Rotation is the only manual step required during normal operation — for CredentialsTotp and Passkey, the connector auto-refreshes the sccauth cookie and XSRF token continuously while the underlying password/secret/key remains valid.
