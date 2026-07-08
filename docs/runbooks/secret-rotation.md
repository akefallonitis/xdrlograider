# Runbook · Secret rotation

Inventory of every secret this solution touches, where it lives, and how to rotate it. Iron rules:
**never echo a secret value in any terminal/log/commit · rotation is operator-performed · the telemetry
scrubber redacts secret-shaped keys, but don't rely on it — just never print them.**

| Secret | Lives in | Consumed by | Rotate |
|---|---|---|---|
| Service-account password (`ServicePassword`) | Key Vault | T3 auth chain (KV via MSI, 30-min L1 TTL) | Change in Entra → `az keyvault secret set` (value via STDIN/file, not command line) → restart FA |
| TOTP seed (`TotpSecret`) | Key Vault | T3 MFA (RFC 6238) | Re-enroll Software-OATH on the SA at mysignins.microsoft.com → set new base32 in KV → restart FA. Old seed is dead the moment Entra re-enrolls. |
| Passkey (`PasskeyPem`, ECDSA-P256) | Key Vault | Passkey auth flow (FIDO2 assertion) | Generate new keypair → register credential on the SA → set PEM (or JSON {credentialId, privateKeyPem}) in KV → restart FA |
| `.env.local` (lab SP id/secret + local test creds) | repo root, **gitignored + outside the public allowlist** | local tooling only (probes, az login) | Rotate the SP secret in Entra; update the file; never tracked, never pasted |
| Deployment SP | Entra app | `az login --service-principal` for internal sync | Standard SP secret rotation; AuthorizationFailed on any az call = STOP, never retry-escalate |
| sccauth / XSRF / KMSI cookies | runtime caches (L1 memory · L2 state table) | the connector itself | Not operator-rotated — self-healing; to force a clean re-auth: clear the L2 session row + restart (next cycle does T3 once, then KMSI steady-state) |

## Post-history-reset rotation (one-time, after WS6's public force-replace)
The old public history contained lab-tenant captures. After the fresh-root push + GitHub Support purge:
1. Rotate the SA password + re-enroll TOTP (both were never in git, rotate anyway — defense in depth).
2. Rotate the deployment SP secret (`.env.local`).
3. Confirm the new public tree scans clean: `tools/Test-PublicAllowlist.ps1` + the gauntlet secret axes.
