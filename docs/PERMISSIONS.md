# Permissions reference

Consolidated reference for every permission XdrLogRaider needs — at setup time, at runtime, and across cross-RG scenarios. Think of this as "the table to scroll through before filing an access-request ticket".

## TL;DR — who needs what

| Activity | Who | Minimum role | Where |
|---|---|---|---|
| Click Deploy-to-Azure + fill wizard | Deployer (human) | **Contributor** or **Owner** | Target RG (connector) |
| Deploy custom tables cross-RG to workspace | Deployer (human) | **Log Analytics Contributor** or **Contributor** | Workspace RG |
| Upload auth secrets via helper | Deployer (human) | **Key Vault Secrets Officer** | Deployed KV (inherited from Contributor/Owner on the connector RG) |
| Create Entra service account | Entra admin | **User Administrator** | Entra tenant |
| Assign read-only roles to service account | Entra admin | **Privileged Role Administrator** | Entra tenant |
| Read ingested data | SOC analyst | **Microsoft Sentinel Reader** (or **Log Analytics Reader**) | Workspace |
| Enable analytic rules post-deploy | SOC author | **Microsoft Sentinel Contributor** | Workspace |

**Nothing requires Global Administrator.** Everything above is standard security/cloud admin-level delegation.

## Setup-time permissions (one-off)

### Azure subscription (deployer)

| Role | Scope | Reason |
|---|---|---|
| `Contributor` or `Owner` | Connector RG | Create FA/Plan/KV/Storage/DCE/DCR/AI and write role assignments |
| `Log Analytics Contributor` (or `Contributor`) | Workspace RG | Write custom tables into the workspace (via cross-RG nested deployment) |
| `Key Vault Secrets Officer` | Deployed KV | Upload auth secrets (`mde-portal-upn`, `mde-portal-password`, `mde-portal-totp`, or `mde-portal-passkey`). Inherited from Contributor/Owner on the RG. |

**Tenant policy gotcha**: some enterprise tenants block `Microsoft.Authorization/roleAssignments/write` for Contributors via Azure Policy. In that case, request `User Access Administrator` on the connector RG — the ARM template's `role-assignments.bicep` needs it to wire the FA's MI to KV/Storage/DCR.

### Entra ID (identity admin — typically the same person or a separate ticket)

| Role | Reason |
|---|---|
| `User Administrator` | Create the dedicated service account (e.g. `svc-xdrlr@tenant.onmicrosoft.com`). Disable password expiry on this account so the connector can run unattended indefinitely. |
| `Privileged Role Administrator` | Assign `Security Reader` (Entra built-in) + `Defender XDR Analyst` (Defender RBAC). Both read-only. No Global Admin needed. |

### Self-service (acts as the service account)

1. Sign in to `https://mysignins.microsoft.com` **as the service account**
2. Enrol a second authenticator or generate a software passkey (see [GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md))
3. Copy the Base32 TOTP secret or passkey JSON — this goes into Key Vault via the helper in Step 4

## Runtime permissions (the Function App's own identity)

The ARM template creates a **System-Assigned Managed Identity (SAMI)** on the Function App. It's wired with the minimum permissions to operate — nothing more:

| Role | Scope | What the FA does with it |
|---|---|---|
| `Key Vault Secrets User` | Deployed KV | `Get-AzKeyVaultSecret` on `mde-portal-*` secrets (read-only) |
| `Storage Table Data Contributor` | Deployed Storage Account | Read `auth-selftest` flag; write per-stream checkpoints + `MDE_Heartbeat_CL`-bound rows via table API |
| `Monitoring Metrics Publisher` | Deployed DCR | POST JSON batches to the DCE via Logs Ingestion API |

**What the FA CANNOT do**:
- Modify KV secrets / create new secrets (only `User`, not `Officer`)
- Read other Key Vaults, Storage Accounts, or DCRs
- Touch resources outside the connector RG (no cross-RG / cross-subscription access)
- Call Microsoft Graph or any other Azure API beyond the 3 above
- Modify any resource in the Sentinel workspace (it talks to the workspace only via DCR-mediated ingestion)

## Portal permissions (the service account's delegated identity)

These live in the Entra tenant and Defender XDR portal. The Function App uses these credentials to authenticate AS the service account when calling `security.microsoft.com`:

| Role | Type | What it grants on security.microsoft.com |
|---|---|---|
| `Security Reader` | Entra built-in | Tenant security config read: ASR rules, AV, PUA, exclusions, data-export settings, RBAC, critical assets, XSPM data, etc. |
| `Defender XDR Analyst` | Defender RBAC (MDE) | AIR decisions (read), Action Center history, alerts, custom detections (read), hunting (read) |

Both are **read-only**. Even if the service account's credentials were stolen, the blast radius is limited to read access on security posture. No write / no remediation / no mailbox / no user impersonation.

**Do NOT** grant any of these:
- `Global Administrator`, `Security Administrator`, or any `*Administrator` role
- Write-capable Defender roles (`Defender XDR Operator`, `Incident Manager`, etc.)
- Any Graph permission

## Cross-RG deployment scenarios

### Scenario A: Workspace in same RG as deployer

Simplest — deployer has Contributor on one RG, workspace is in that RG too. No extra action.

### Scenario B: Workspace in a different RG (same subscription)

Deployer needs:
- `Contributor` on connector RG (main deploy target)
- `Log Analytics Contributor` (or `Contributor`) on workspace RG (for cross-RG custom tables + sentinel content deployment)

### Scenario C: Workspace in a different subscription (same tenant)

Same as B, but the deployer's credentials need to cover BOTH subscriptions:
- `Contributor` on connector-RG's subscription
- `Log Analytics Contributor` on workspace-RG's subscription

If the deployer identity isn't granted in the workspace's subscription, the cross-RG nested deployment fails with `AuthorizationFailed` on `Microsoft.OperationalInsights/workspaces/tables/write`. Solution: the workspace's subscription admin grants the deployer a scoped role on just the workspace's RG.

### Scenario D: Workspace in a separate tenant

**Not supported in v1.0.** DCR destinations must live in the same tenant as the DCE + DCR. If you need true multi-tenant, deploy a separate XdrLogRaider instance per tenant.

## Audit trail

All Azure-side actions are logged by default. Recommended extras:
- **Key Vault diagnostic settings** → send to workspace (track MI secret reads)
- **Storage diagnostic settings** → send to workspace (track checkpoint writes)
- **FA App Insights** → already wired; `traces` table shows every `Invoke-MDEEndpoint` call + auth chain events

All portal-side actions by the service account appear in Entra sign-in logs + MDE audit logs under the service-account UPN — visible in Sentinel if you've enabled those connectors.

## Rotation

| What rotates | Frequency | Action |
|---|---|---|
| sccauth cookie (auth session) | ~50 min cache | **None** — auto-refreshed by connector using KV creds |
| TOTP code | Every 30 sec | **None** — computed by connector from KV seed (RFC 6238) |
| Service-account password | Per your org policy | 1) reset in Entra, 2) re-run `Initialize-XdrLogRaiderAuth.ps1` |
| TOTP seed (Base32) | Rare (re-enrolment) | 1) re-enrol via `mysignins.microsoft.com`, 2) re-run helper |
| Passkey | Rare (revocation) | 1) re-generate, 2) re-run helper with new JSON |
| FA Managed Identity | Never — tied to FA resource | No action |

Only the **user-supplied** credentials (password / TOTP seed / passkey) ever need human rotation. All Azure-side auth (KV, Storage, DCR) is handled by the MI and needs zero rotation.
