# Credential flow — deploy params → Key Vault → Function App SAMI

No secret ever lives in source, in an app setting, or in a log. Values you enter at deploy time are written into a Key Vault, and the Function App reads them at runtime with its **system-assigned managed identity (SAMI)** over the managed-identity REST endpoint — **no `Az` module, no service principal, no client secret**.

```
        ┌──────────────── one-click ARM deploy (mainTemplate.json) ─────────────────┐
        │  You enter (securestring where secret):                                   │
        │    serviceAccountUpn   servicePassword   authMethod                       │
        │    totpSecret  (if TOTP)      passkeyPem  (if Passkey)                     │
        └──────────────┬────────────────────────────────────────────────────────────┘
                       │  ARM writes the three secret values into a fresh Key Vault
                       ▼
        ┌──────────────────────────── Key Vault  (xdrlr-kv-<suffix>) ───────────────┐
        │   ServicePassword    TotpSecret    PasskeyPem      (encrypted at rest)     │
        └──────────────┬────────────────────────────────────────────────────────────┘
                       │  role assignment: FA SAMI → "Key Vault Secrets User"
                       ▼
        ┌──────────────────── Function App  (System-Assigned Managed Identity) ──────┐
        │  App settings hold NON-secret pointers only:                              │
        │    XDRLR_KEYVAULT_NAME · XDRLR_KEYVAULT_URL                                │
        │    XDRLR_SERVICE_ACCOUNT_UPN · XDRLR_AUTH_METHOD                           │
        │                                                                           │
        │  At runtime (Xdr.Common.Cache → Get-XdrCachedSecret), MSI-REST — no Az:    │
        │   1. GET $IDENTITY_ENDPOINT?resource=https://vault.azure.net              │
        │        &api-version=2019-08-01   header X-IDENTITY-HEADER: $IDENTITY_HEADER│
        │        → SAMI access token for the Key Vault data plane                   │
        │   2. GET https://<vault>.vault.azure.net/secrets/<name>?api-version=7.4    │
        │        Authorization: Bearer <token>   → secret value                     │
        │   3. cache in-process, L1 TTL 1800 s (30 min); refetch on expiry          │
        └──────────────┬────────────────────────────────────────────────────────────┘
                       │  Get-XdrCredentials assembles @{ UPN; Password; AuthMethod;
                       │  TotpSeed | PasskeyPem } and the Defender auth handler
                       ▼  drives the portal sign-in (Creds+TOTP / Passkey).
        Defender XDR portal  →  sccauth + XSRF + ESTSAUTHPERSISTENT (KMSI 90d) cookies
                                cached in L1 memory + L2 Storage table (self-healing)
```

## Key properties (all verified in the tree)

- **Zero secrets in code or app settings.** App settings carry only the vault *name/URL*, the service-account UPN, and the auth-method string. The password, TOTP seed, and passkey PEM exist only inside Key Vault and, transiently, in the Function App's process memory after an MSI-authenticated fetch.
- **No service principal, no client secret.** The identity is the Function App's **system-assigned managed identity**. Every downstream call — Key Vault, Storage (Tables/Blob/Queue), and Log Analytics ingestion — uses the same SAMI via the `IDENTITY_ENDPOINT` MSI-REST pattern. `Get-AzAccessToken` appears only as a local-dev fallback and is never on the deployed path.
- **Least Key Vault surface.** The SAMI holds **Key Vault Secrets User** (read secret values) — not Contributor, not a Keys/Certificates officer role. The Storage account has shared-key access disabled (`allowSharedKeyAccess: false`); the vault is the sole secret store.
- **Secrets read only when needed.** The connector's steady state is the cookie/KMSI cache. It re-reads `ServicePassword` plus the seed/PEM from Key Vault only when a full re-auth is required (~4×/year, on KMSI expiry) or when the 30-minute in-process secret cache lapses.

## The seven auth methods (overview)

The deploy exposes the two unattended methods; the auth engine supports seven in total.

| # | Method | API surface | Auto-refresh | Unattended |
|---|--------|-------------|--------------|------------|
| 1 | Credentials + TOTP    | Portal-internal | yes (KMSI 90d) | **yes** ← deploy |
| 2 | Passkey / FIDO2       | Portal-internal | yes (KMSI 90d) | **yes** ← deploy |
| 3 | ESTS cookie           | Portal-internal | no  | no |
| 4 | TAP                   | Portal-internal | no  | no |
| 5 | Direct sccauth        | Portal-internal | no  | no |
| 6 | Device code           | Official OAuth  | no  | no |
| 7 | Client credentials    | Official OAuth  | yes | yes (limited surface) |

See [SETUP.md](SETUP.md) for enrolling the unattended MFA secret, and [SECURITY-CONSIDERATIONS.md](SECURITY-CONSIDERATIONS.md) for governing the resulting standing credential.

---
*Maintainer: Alex Kefallonitis · al.kefallonitis@gmail.com · <https://www.linkedin.com/in/alex-kefallonitis-3a8739a7>*
