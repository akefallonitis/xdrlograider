# Bring your own passkey

XdrLogRaider accepts a software (non-hardware) passkey for the service account. You generate this externally and provide the JSON to the setup helper.

## Required JSON schema

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

## Generation paths

Three known-working paths, pick any. **All require one-time browser interaction to register with Entra.**

### Path A — python-fido2 CLI (recommended, cross-platform)

[Yubico python-fido2](https://github.com/Yubico/python-fido2) provides a software authenticator mode.

```bash
pip install fido2
# Then follow community example scripts for the browser-relay pattern
```

See community example scripts in [python-fido2 discussions](https://github.com/Yubico/python-fido2/discussions) for the browser-relay pattern.

### Path B — XDRInternals passkey setup

If you already use the [XDRInternals PowerShell module](https://github.com/MSCloudInternals/XDRInternals), follow their software-passkey setup. Export the keypair + credentialId + UPN to the JSON schema above.

### Path C — Hardware-key export (not recommended)

Some hardware FIDO2 keys allow private-key export via vendor-specific tools (e.g., Yubico's enterprise edition with config locking disabled). This breaks most hardware keys' security model. Only do this with a dedicated key designated for automation use.

## Security considerations

- The passkey JSON file contains a **private key**. Treat as a secret.
- After uploading to Key Vault via `Initialize-XdrLogRaiderAuth.ps1`, **delete the local file**:
  ```powershell
  Remove-Item ./my-passkey.json
  ```
- Passkeys are per-user: one passkey for `svc-xdrlr@contoso.com` cannot authenticate any other account
- Rotation: re-register a fresh passkey in Entra, generate a new JSON, re-run the setup helper. Revoke the old credentialId in Entra security info.

## Testing your passkey

Before uploading to the production Key Vault, verify the passkey works locally:

```powershell
$env:XDRLR_TEST_UPN = 'svc-xdrlr@test.onmicrosoft.com'
$env:XDRLR_TEST_AUTH_METHOD = 'Passkey'
$env:XDRLR_TEST_PASSKEY_PATH = './my-passkey.json'
$env:XDRLR_ONLINE = 'true'

pwsh ./tests/Run-Tests.ps1 -Category local-online
```

Expected: all 5 `Auth-Chain-Live.Tests.ps1` tests pass.

See [tests/README.md](../tests/README.md) for full local-online test flow.

## FAQ

**Can I use Windows Hello as a passkey?**
No. Windows Hello private keys are sealed by TPM — they cannot be exported for unattended use.

**Can I use my personal YubiKey?**
Typically no — consumer YubiKeys do not expose private-key export. You'd need a dedicated software passkey.

**What curve is required?**
ECDSA-P256 (secp256r1 / prime256v1). Entra supports other curves but the connector is implemented against P256 specifically.

**Is this FIDO2 certified?**
No — this is a software simulation of a FIDO2 authenticator. Entra accepts it because it implements the WebAuthn assertion format correctly, but it would not be accepted by FIDO2-certified relying parties that require hardware-attested authenticators.

## References

- [W3C WebAuthn Level 2 §7.2](https://www.w3.org/TR/webauthn-2/#sctn-verifying-assertion) — assertion verification spec
- [FIDO2 / CTAP2](https://fidoalliance.org/specifications/) — client-to-authenticator protocol
- [Microsoft FIDO2 authentication methods API](https://learn.microsoft.com/en-us/graph/api/resources/fido2authenticationmethod) — Entra-side registration
