# Security considerations — an unattended, always-on access account

Be honest about what this deploys: a **standing, non-interactive Entra identity with persistent read access to your Defender XDR tenant**, whose password and MFA secret sit in a Key Vault your Function App can read 24/7. That is a useful detection-engineering capability *and* a credential you must govern. This page is the honest posture and the guardrails.

---

## The core caveat

- **It is unattended.** No human is in the loop on any sign-in. A stolen KMSI/`sccauth` cookie, or a leaked Key Vault secret, is usable silently until it expires or you rotate it.
- **Security Reader is over-privileged for this use.** Take the simple path and this always-on account can read *every* security surface in the tenant — vastly more than the ~120 audit/posture read operations the connector needs. On an unattended credential, that larger blast radius is a real risk, not a formality. Prefer the least-privilege **Defender Unified RBAC** role in [RBAC.md](RBAC.md). If you accept Security Reader, accept it *knowingly* and compensate with the monitoring below.
- **These are undocumented internal APIs.** Microsoft may change or break the `/apiproxy/*` surface without notice. Treat the connector as best-effort and keep an eye on its health telemetry.

---

## It MUST be monitored

Treat this account as a watched service identity, not fire-and-forget.

1. **Sign-in logs.** Alert on this UPN's interactive and non-interactive sign-ins from unexpected IPs/locations, new device/user-agent, or MFA-method changes. The connector's sign-ins should originate only from your Function App's egress — anything else is suspect.
2. **Anomalous access.** Alert on the account reading surfaces *outside* the shipped categories, or a spike in volume — a sign the credential is being used for something other than the connector.
3. **The connector's own auth telemetry.** Every cycle emits an Application Insights event with a correlation id, the auth tier used (KMSI steady-state vs. a full re-auth), and capability-gate (403) outcomes. A full re-auth firing far more than ~4×/year, or unexpected 403 patterns, is your early-warning signal.
4. **Key Vault access.** Enable Key Vault diagnostic logging. The **only** principal that should read `ServicePassword`/`TotpSecret`/`PasskeyPem` is the Function App's SAMI. Any other reader is an incident.

---

## Recommended guardrails

- **Least-privilege first.** Deploy with the custom Defender Unified RBAC read role ([RBAC.md](RBAC.md)); widen one read permission at a time, and only when a category you want is 403-gated. Never grant write/admin.
- **Conditional Access scoping.** Put the account in a CA policy that (a) restricts sign-in to a **named location** = your Function App's egress IP(s), and (b) blocks legacy auth. This turns a stolen cookie used from elsewhere into a blocked sign-in. Do *not* subject it to interactive-MFA-every-time — it cannot answer a prompt. Its MFA is the enrolled TOTP/passkey the connector satisfies headlessly; lean on location + monitoring instead of interactive prompts.
- **Credential rotation.** Rotate on a schedule and on any suspicion — see [runbooks/secret-rotation.md](runbooks/secret-rotation.md):
  - **Password:** change in Entra → `az keyvault secret set` on `ServicePassword` (value via STDIN/file, never on the command line) → restart the Function App.
  - **TOTP seed:** re-enroll the Software OATH token at mysignins → set the new base32 in Key Vault → restart the Function App. The old seed dies the instant Entra re-enrolls.
  - **Passkey PEM:** generate a new key pair, register it on the account, set the new PEM in Key Vault, restart the Function App.
  - Never echo a secret value into a terminal, log, or commit. The telemetry scrubber redacts secret-shaped keys, but do not rely on it — just never print them.
- **Isolate the identity.** Cloud-only account, no roles beyond the read role, no membership in admin groups, excluded from break-glass, distinct from any human.
- **Scope the vault.** Keep the SAMI at **Key Vault Secrets User** only; keep Storage shared-key access disabled; do not add other readers to the vault.
- **Bound the data.** Set Log Analytics table retention to your policy. The connector retains the full raw response per row, so treat the workspace as holding sensitive Defender audit data.

---

## Bottom line

This is authorized purple-team / detection-engineering tooling, and it is deliberately read-only. The residual risk is the *standing unattended credential* — govern it with least-privilege RBAC, Conditional Access location-scoping, sign-in + Key Vault + connector-telemetry monitoring, and scheduled rotation. If you run it with Security Reader instead of the least-privilege role, you have chosen a larger blast radius and owe it correspondingly tighter monitoring.

---
*Maintainer: Alex Kefallonitis · al.kefallonitis@gmail.com · <https://www.linkedin.com/in/alex-kefallonitis-3a8739a7>*
