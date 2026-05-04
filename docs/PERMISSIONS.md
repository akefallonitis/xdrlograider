# Permissions reference

Consolidated reference for every permission XdrLogRaider needs — at setup time, at runtime, at test time, and across cross-RG scenarios. Think of this as "the table to scroll through before filing an access-request ticket".

## TL;DR — who needs what

| Activity | Who | Minimum role | Where |
|---|---|---|---|
| Create Entra service account | Entra admin | **User Administrator** | Entra tenant |
| Assign read-only roles to service account | Entra admin | **Privileged Role Administrator** | Entra tenant |
| Enrol TOTP / software passkey for the service account | Whoever signs in as it | n/a (self-service) | mysignins.microsoft.com |
| Click Deploy-to-Azure + fill wizard | Deployer | **Owner** (recommended) OR **Contributor** + **User Access Administrator** | Target RG (connector) |
| Cross-RG write of custom tables + Sentinel content | Deployer | **Log Analytics Contributor** + **Microsoft Sentinel Contributor** | Workspace RG (or workspace itself) |
| Upload auth secrets via helper | Deployer | **Key Vault Secrets Officer** | Deployed KV (inherited from Owner/Contributor on the connector RG) |
| Read ingested data | SOC analyst | **Microsoft Sentinel Reader** (or **Log Analytics Reader**) | Workspace |
| Enable analytic rules post-deploy | SOC author | **Microsoft Sentinel Contributor** | Workspace |
| Run `tests/Run-Tests.ps1 -Category local-online` on your laptop | Dev | n/a — uses service-account credentials directly | Local machine |
| Run `tests/Run-Tests.ps1 -Category e2e` post-deploy | Dev / operator | **Log Analytics Reader** on workspace | Your own `Connect-AzAccount` session (no SP) |

**Nothing requires Global Administrator.** Everything above is standard security/cloud admin-level delegation.

## Setup-time permissions (one-off per tenant)

### Azure subscription (the deployer)

**Simplest — use Owner**:
| Role | Scope | Reason |
|---|---|---|
| **Owner** | Connector RG | All Azure resource creation + role assignments (survives Azure Policy restrictions on `Microsoft.Authorization/roleAssignments/write`) |
| **Owner** *(or Log Analytics Contributor + Microsoft Sentinel Contributor)* | Workspace RG | Write 47 custom tables, savedSearches (parsers + hunting queries), workbooks, and analytic rules via cross-RG nested deployments |

**Fine-grained alternative** (if you can't get Owner):
| Role | Scope | Covers |
|---|---|---|
| **Contributor** | Connector RG | Create FA/Plan/KV/Storage/DCE/DCR/AI |
| **User Access Administrator** | Connector RG | Role assignments for the FA's Managed Identity (3× on KV/Storage/DCR) |
| **Log Analytics Contributor** | Workspace RG | Write 47 custom tables + savedSearches |
| **Microsoft Sentinel Contributor** | Workspace | Write analytic rules, hunting queries, workbooks, data-connector UI card |
| **Key Vault Secrets Officer** | Deployed KV | Upload auth secrets — inherited if you're Contributor/Owner on the RG |

**Why two roles on the workspace**:
- `Log Analytics Contributor` covers the data-plane objects: workspace tables (`Microsoft.OperationalInsights/workspaces/tables/write`) + saved searches (parsers + hunting queries use `savedSearches`).
- `Microsoft Sentinel Contributor` covers Sentinel-specific resources: analytic rules (`Microsoft.SecurityInsights/alertRules/write`), Solution package (`Microsoft.OperationalInsights/workspaces/providers/contentPackages/write`), data-connector card (`Microsoft.OperationalInsights/workspaces/providers/dataConnectors/write` of kind `GenericUI` — canonical for community FA-based connectors), DataConnector metadata link (`.../metadata/write`), workbooks (`Microsoft.Insights/workbooks/write`).

Owner on the workspace RG implicitly grants both.

### Entra ID (identity admin)

| Role | Reason |
|---|---|
| `User Administrator` | Create the dedicated service account (e.g. `svc-xdrlr@tenant.onmicrosoft.com`). Disable password expiry so the connector runs unattended indefinitely. |
| `Privileged Role Administrator` | Assign `Security Reader` (Entra built-in) + `Defender XDR Analyst` (MDE RBAC). Both read-only. |

### Self-service enrolment (act AS the service account)

1. Sign in to `https://mysignins.microsoft.com` **as the service account**
2. Enrol a TOTP authenticator (see `docs/GETTING-AUTH-MATERIAL.md` Method 1) OR generate a software passkey (see `docs/BRING-YOUR-OWN-PASSKEY.md`)
3. Copy the Base32 TOTP secret (or passkey JSON) — this is what `Initialize-XdrLogRaiderAuth.ps1` uploads into Key Vault

## Runtime permissions (the Function App's own identity)

The ARM template creates a **System-Assigned Managed Identity (SAMI)** on the Function App. It's wired with exactly **7** narrowly-scoped role assignments, all created automatically by `deploy/compiled/mainTemplate.json` (under `Microsoft.Authorization/roleAssignments` resources):

| Role | Scope | Count | What the FA does with it |
|---|---|---|---|
| `Key Vault Secrets User` (`4633458b-17de-408a-b874-0445c86b69e6`) | Deployed KV | 1 | `Get-AzKeyVaultSecret` on `mde-portal-*` secrets (read-only) |
| `Storage Table Data Contributor` (`0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3`) | Deployed Storage Account | 1 | Read `auth-selftest` flag; write per-stream checkpoints + heartbeat rows + DLQ |
| `Monitoring Metrics Publisher` (`3913510d-42f4-4e42-8a64-420c390055eb`) | Each DCR | 5 | POST JSON batches to the DCE via Logs Ingestion API (one per DCR sharing the DCE) |

**What the FA CANNOT do**:
- Modify KV secrets / create new secrets (it's `User`, not `Officer`)
- Read other Key Vaults, Storage Accounts, or DCRs
- Touch resources outside the connector RG (no cross-RG access)
- Call Microsoft Graph or any other Azure API beyond the 3 above
- Modify any resource in the Sentinel workspace (ingestion is DCR-mediated)

## Portal permissions (the service account in Defender XDR)

These live in the Entra tenant + MDE RBAC. The Function App authenticates AS the service account when calling `security.microsoft.com`.

### ⚠️ Critical: least-privilege is mandatory for unattended service accounts

A connector that runs unattended for 30+ days with stored credentials has a different threat model from an interactive admin. Over-privileged unattended accounts are the single highest-blast-radius credential class in any tenant. Use these two **read-only** roles and nothing else:

| Role | Type | What it grants |
|---|---|---|
| `Security Reader` | Entra built-in | Tenant security config read: ASR rules, AV, PUA, exclusions, data-export settings, RBAC, critical assets, XSPM, etc. |
| `Defender XDR Analyst` | MDE RBAC | AIR decisions (read), Action Center history, alerts, custom detections (read), hunting (read) |

Both are **read-only**. Blast radius if credentials leak: the attacker reads (does not modify) the same data the connector ingests. Compare to the over-privileged alternatives:

| Role | Why people pick it | Why it's wrong here |
|---|---|---|
| `Security Administrator` | "I want everything to just work" | Write capability — leak = attacker disables AV, suppresses alerts, exfiltrates via DEX |
| `Global Administrator` | "Most permissive, no debugging" | Tenant takeover on credential leak |
| `Defender XDR Operator` | "Need Action Center detail" | Can dismiss alerts, run live response, isolate machines |

**Do NOT** grant any of these. The connector has zero use for write capability. If you currently have the SA on `Security Administrator`, **downgrade to `Security Reader` now** — the 36 live endpoints continue returning 200, no functionality regression.

### Tenant features / endpoint surfaces required for the gated streams

Ten streams ship with `Availability = 'tenant-gated'`. They return 4xx because the tenant doesn't have the underlying feature **provisioned** (or the underlying portal endpoint isn't surfaced for this tenant), NOT because the SA lacks a role. **Role elevation does not activate them** — even Security Administrator (which auto-grants Full Access in MCAS per Microsoft Learn) returned 403/404/400/500 for these in our live audit:

| Stream | Required tenant feature / surface | Live audit status (Security Admin SA) |
|---|---|---|
| `MDE_AntivirusPolicy_CL` | Intune / MEM integration with MDE | 400 — request rejected without Intune connection |
| `MDE_TenantAllowBlock_CL` | Defender for Office 365 (E5 Security) | 500 — feature endpoint not active |
| `MDE_DCCoverage_CL`, `MDE_IdentityAlertThresholds_CL`, `MDE_RemediationAccounts_CL` | Microsoft Defender for Identity sensors deployed | 404 — `/aatp/api/...` paths not present without MDI |
| `MDE_StreamingApiConfig_CL` | MDE Streaming API enabled in settings | 404 — Streaming API surface not configured |
| `MDE_SecurityBaselines_CL` | Threat & Vulnerability Mgmt baseline profiles created | 400 — endpoint requires at least one baseline |
| `MDE_CustomCollection_CL` | MDE Custom Collection model surface licensed/provisioned (E5/P2) | 403 — feature surface not present even with Security Administrator |
| `MDE_CloudAppsConfig_CL` | MCAS active in tenant + `/apiproxy/mcas/cas/api/v1/settings` proxy alive | 403 — proxy path likely retired; MCAS native API lives on `<tenant>.portal.cloudappsecurity.com` |
| `MDE_DeviceTimeline_CL` | Tenant entitlement gated; surfaces when XDR Hunter unified timeline is provisioned (feature-flag dependent per tenant region + Defender license tier) | First-capture-pending — activates once a recent device timeline query is available |
| `MDE_MachineActions_CL` | At least one machine action invoked in tenant (Live Response session, isolation, AV scan, etc.); hybrid surface — public `/api/machineactions` covers metadata, portal exposes per-step Live Response script output + AIR linkage not in public API | First-capture-pending — empty until a machine action is invoked |

These activate **automatically** when the customer enables the corresponding feature — no manifest change, no redeploy. The connector keeps attempting them and surfaces the 4xx via heartbeat metadata.

**Why no `role-gated` category in iter 13.8+**: live evidence (Security Administrator SA → still 403 on the 2 previously-tagged role-gated streams) plus Microsoft Learn confirming Security Administrator auto-grants Full Access in MCAS proves the gate is *tenant-feature*, not *role*. The two streams stay in the manifest (they cost nothing to attempt) but operators should not chase additional role grants — those won't fix the 403.

### Operational posture for unattended SAs

| Concern | Mitigation |
|---|---|
| Password rotation | Set "Password never expires" (or extend > poll cadence). Rotate manually when org policy mandates → re-run `Initialize-XdrLogRaiderAuth.ps1` |
| Conditional Access blocking sign-in | Add an exclusion for the SA on policies that require interactive MFA. The connector handles TOTP programmatically; CA-mandated WebAuthn / FIDO2 will block it |
| Sign-in alerts noise | Document the SA in your IDM as a service identity so SOC doesn't page on every cookie refresh |
| Credential storage | KV-only (managed identity reads). No creds in env vars, code, ARM params, or repo. `Initialize-XdrLogRaiderAuth.ps1` is the only path that handles them in plaintext (briefly, on the operator's laptop) |
| Cookie reuse | sccauth caches ~50 min; refresh uses TOTP from KV. No persistent session anywhere |
| Audit | Entra sign-in logs + MDE audit logs show every SA action. Enable both feeds in Sentinel for visibility |

## Testing permissions (dev-time, CI-time)

See [`TESTING.md`](TESTING.md) for the full four-quadrant testing setup.

### Local testing (your laptop → real portal)
- Uses the same service account's credentials (UPN + password + TOTP seed, OR passkey JSON, OR DirectCookies)
- Lives in `tests/.env.local` (gitignored)
- No Azure RBAC needed — doesn't touch Azure infrastructure

### Post-deploy e2e verification (from your laptop)
- Uses your own `Connect-AzAccount` session — no SP, no stored creds
- Your Azure account needs `Log Analytics Reader` on the workspace
- Set env vars: `XDRLR_ONLINE=true`, `XDRLR_TEST_RG`, `XDRLR_TEST_WORKSPACE`
- Run: `pwsh ./tests/Run-Tests.ps1 -Category e2e`

**CI does not run online tests.** GitHub Actions has no Azure credentials by design. The entire test-against-live-tenant path is laptop-only.

### Operator post-deploy "is it working?" check

After the deploy + `Initialize-XdrLogRaiderAuth.ps1` complete, the **Sentinel
Data Connectors blade** is the source of truth: the **XdrLogRaider** card flips
to **Connected** within 5–10 minutes of the first successful poll. That's it —
no CLI tools to run.

Underlying signal: the connector writes a row to `MDE_Heartbeat_CL` every
5 minutes; the data-connector's `connectivityCriterias` query reads it and
flips the card. If the card stays **Disconnected** for >15 minutes after
`Initialize-XdrLogRaiderAuth.ps1`, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Cross-RG deployment scenarios

### Scenario A: Workspace in same RG as deployer
Simplest — Owner on one RG covers everything.

### Scenario B: Workspace in a different RG (same subscription)
Deployer needs:
- `Owner` (or `Contributor` + `User Access Administrator`) on connector RG
- `Log Analytics Contributor` + `Microsoft Sentinel Contributor` on workspace (RG-inherited OK)

### Scenario C: Workspace in a different subscription (same tenant)
Same as B, but the deployer's credentials need to cover BOTH subscriptions.

If the deployer identity isn't granted in the workspace's subscription, the cross-RG nested deployment fails with `AuthorizationFailed` on `Microsoft.OperationalInsights/workspaces/tables/write`. Solution: the workspace's subscription admin grants the deployer a scoped role on just the workspace's RG.

### Scenario D: Workspace in a separate tenant
**Not supported in v1.0.** DCR destinations must live in the same tenant as the DCE + DCR. If you need true multi-tenant, deploy a separate XdrLogRaider instance per tenant.

## Audit trail

All Azure-side actions are logged by default. Recommended extras:
- **Key Vault diagnostic settings** → send to workspace (track MI secret reads) **(OPTIONAL — operator enables manually if desired; xdrlograider does NOT auto-configure KV diagnostics per the principle of least operator surprise. Per directive 37: each tenant has different cost/compliance constraints; operator decides per-environment.)**
- **Storage diagnostic settings** → send to workspace (track checkpoint writes) **(OPTIONAL)**
- **FA App Insights** → already wired; `traces` table shows every `Invoke-MDEEndpoint` call + auth chain events

All portal-side actions by the service account appear in Entra sign-in logs + MDE audit logs — visible in Sentinel if you've enabled those connectors.

## Rotation

| What rotates | Frequency | Action |
|---|---|---|
| sccauth cookie (auth session) | ~50 min cache | **None** — auto-refreshed using KV creds |
| TOTP code | Every 30 sec | **None** — computed from KV seed (RFC 6238) |
| Service-account password | Per your org policy | 1) reset in Entra, 2) re-run `Initialize-XdrLogRaiderAuth.ps1` |
| TOTP seed (Base32) | Rare (re-enrolment) | 1) re-enrol via `mysignins.microsoft.com`, 2) re-run helper |
| Passkey | Rare (revocation) | 1) re-generate, 2) re-run helper with new JSON |
| FA Managed Identity | Never — tied to FA resource | No action |

Only the **user-supplied** credentials (password / TOTP seed / passkey) ever need human rotation. All Azure-side auth (KV, Storage, DCR) is handled by the MI and needs zero rotation.
