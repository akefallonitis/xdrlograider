# Security notes — xdrlograider

> Threat model, per-hosting-plan residual risk, and Marketplace v1.2 hardening roadmap.
> Living document — updated each release window.

## Threat model

The xdrlograider connector polls Microsoft Defender XDR portal endpoints unattended 24/7 from an Azure Function App. The attack surfaces:

| Surface | Attacker capability | Mitigation |
|---|---|---|
| Function App env vars (app settings) | Any identity with `Microsoft.Web/sites/config/list/action` (FA Contributor) reads them via Azure Portal or ARM | `hostingPlan = flex-fc1` removes secrets from env vars (full MI); operators on Y1 must tightly scope FA Contributor |
| Storage Account Key extraction | If the key is in env vars, the attacker bypasses ALL data-plane RBAC | `flex-fc1` / `premium-ep1` do NOT put the key in env vars (full MI); on Y1 the content-share connection string still has the key (Microsoft platform limit) |
| Key Vault secrets | SAMI has `Key Vault Secrets User` — read-only on secrets only | `enableKeyVaultDiagnostics: true` (default) sends audit logs to Sentinel; alert on access from non-FA identities |
| sccauth cookie replay | If FA process is compromised within 50-min cache window, attacker replays cookie | 50-min cap (default); `portalSessionRotationMinutes` parameter (v0.3.0) lets high-security operators tighten to 10 min |
| Service-account credential exfiltration | Attacker reads `mde-portal-auth` from KV → has UPN + password + TOTP secret | Use `authMethod = passkey` for origin-bound signatures (smaller blast radius); rotate password on operator's tenant policy cadence (60–90 days) |
| ZIP supply chain | Attacker tampered Function App ZIP on GitHub | SHA256 manifest emission + verification on every release |
| PSGallery supply chain | Attacker tampered Az.* modules on PSGallery | GPG-signed checksum verification of pinned Az module set |

## Privilege escalation chain (active on `consumption-y1`)

```
1. Attacker compromises any identity with FA Contributor RBAC (much lower bar than Storage/RG Owner)
2. Reads WEBSITE_CONTENTAZUREFILECONNECTIONSTRING app setting → extracts Storage Account Key
3. Storage Account Key bypasses ALL Azure RBAC on the storage account
4. Writes attacker code to the Files share that hosts the FA runtime mount
5. Next FA cold start runs attacker code as SAMI
6. SAMI reads `mde-portal-auth` from Key Vault
7. Attacker has Defender XDR service-account credentials → tenant compromise
```

CWE-269. Severity HIGH. **Closed when `hostingPlan != consumption-y1`.**

## Per-plan residual risk

| Plan | Residual risk | Mitigation if you must use this plan |
|---|---|---|
| `consumption-y1` | Privilege-escalation chain above (active) | Tightly scope FA Contributor — only deployment automation accounts; require break-glass approval for human-user FA Contributor |
| `flex-fc1` | None on the storage path. Public network access still on (default) | Set `restrictPublicNetwork: true` if VNet is configured |
| `premium-ep1` | Same as flex-fc1 + always-warm | Same |

## What we do (legitimate auth, not bypass)

The connector uses the upstream **XDRInternals** auth chain pattern — credentials → ESTSAUTH → sccauth — running every 50 min. This goes **through** Conditional Access (legitimate sign-in event in Entra), not around it.

We do **NOT** use cookie-persistence / PRT-abuse bypass techniques (e.g., the cloudbrothers / Yuya Chudo / Dirk-jan Mollema research). SOC analysts running detection rules for those bypass techniques will not false-positive on our sign-in pattern.

| Aspect | xdrlograider (legitimate) | Bypass technique (attack) |
|---|---|---|
| sccauth reuse window | ≤50 min (then refresh) | Days–weeks |
| Goes through Conditional Access | ✓ Every 50 min | ✗ Never |
| Produces SignInLogs entries | ✓ ~30/day | ✗ None |
| Triggers anomalous-token-reuse detections | ✗ No | ✓ Yes (intended target) |
| Uses `x-ms-RefreshTokenCredential` PRT abuse | ✗ No | ✓ Yes |

## Marketplace v1.2 hardening roadmap

When xdrlograider goes to Microsoft Marketplace:

| Change | New default |
|---|---|
| `hostingPlan` default | `consumption-y1` → `flex-fc1` |
| `restrictPublicNetwork` default | `false` → `true` |
| `entraAuthAllowedSourceIps` parameter | (new — operator scopes Entra sign-in to FA outbound IPs) |
| Publisher certificate | Required (EV code-signing in release.yml) |
| CodeQL gate | High-severity blocking |
| SBOM | SPDX 2.3 + CycloneDX 1.5 emitted by release.yml |
| Validation lab | `deploy/validation-lab.bicep` for Microsoft reviewers |

Operators upgrading from v0.1.0-beta to v1.2 keep their explicit parameter values. Default flips only affect new deploys.

## Operator action items

### v0.1.0-beta operators (today)

1. Choose `hostingPlan` consciously (see [HOSTING-PLANS.md](HOSTING-PLANS.md))
2. Tightly scope FA Contributor RBAC (only deployment automation accounts; no human standing access)
3. Verify `enableKeyVaultDiagnostics = true` (default) and confirm KV audit logs are flowing to your Sentinel workspace
4. Run a sample KQL query monthly: `AzureDiagnostics | where Resource startswith "XDRLR-PROD-KV-" and OperationName == "SecretGet" and identity_claim_appid_g != "<FA-SAMI-app-id>"` — alert on any human-user secret access

### v0.1.0 GA promotion checklist

Operators promote from v0.1.0-beta to v0.1.0 GA after a 30-day clean soak. Promotion gate metrics in §5.1 of the canonical plan.

### v1.2 Marketplace operators

When you upgrade to v1.2: review the new defaults (`restrictPublicNetwork: true`, `hostingPlan: flex-fc1`). If you need to keep v0.1.0-beta defaults, set them explicitly in your ARM parameter file.

## Reporting security issues

Please follow the disclosure policy in `SECURITY.md` at the repo root. For confirmed vulnerabilities: file a private GitHub Security Advisory at <https://github.com/akefallonitis/xdrlograider/security/advisories>.

## Related research

- CIS Microsoft Azure Foundations Benchmark v3.0 (Storage 4.4)
- Microsoft Storage Security Baseline
- Microsoft Well-Architected Framework — Security pillar
- Dirk-jan Mollema, "Abusing Azure AD SSO with the Primary Refresh Token" (2020)
- Yuya Chudo, "Bypassing Entra ID Conditional Access Like APT" (2025)
- cloudbrothers.info, "How to avoid Entra Conditional Access via sccauth" (referenced for our differentiation)

These bypass techniques motivate our **legitimate-auth** posture — we re-auth fully every 50 min so we cannot be confused with the attacker pattern.
