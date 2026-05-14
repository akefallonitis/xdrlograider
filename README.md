# XdrLogRaider

Microsoft Sentinel data connector for **Microsoft Defender XDR portal-internal telemetry** — the `security.microsoft.com` apiproxy surface Microsoft does not publish a public Graph or MDE API for. **493 read endpoints across 18 nodoc sub-areas → 19 DCRs → 18 `Defender_<Sub>_CL` workspace tables + 1 `XdrConnectorHealth_CL` operational table.**

PowerShell 7.4 Function App on Y1 Linux Consumption (cost-optimal; EP1+ opt-in) with 4 Durable Functions (Xdr-Refresh · Xdr-PollOrchestrator · Xdr-PollStream · Connector-Heartbeat). SystemAssigned managed identity for KV / Storage Table / DCE access — no service-principal secrets stored anywhere.

## Prerequisites

| Resource | Notes |
|---|---|
| Azure subscription with an existing Microsoft Sentinel workspace | The workspace can be in a different RG / subscription from the connector RG — pass its full resource ID. |
| Empty (or near-empty) RG to host the connector | New ARM deployment creates: 1 Function App, 1 App Service Plan, 1 Storage account, 1 Key Vault, 1 Application Insights, 1 DCE, 19 DCRs. ~$0–5/mo idle on Y1. |
| Defender XDR service account (UPN) with read-only access to Defender XDR portal | The connector signs into `security.microsoft.com` as this account every ~50 min and harvests the apiproxy endpoints. Use a dedicated SA (not a human admin) — KMSI keeps the session alive 90 days. |
| One of: TOTP base32 seed (paired in Microsoft Authenticator) OR Passkey JSON (FIDO2 credential exported from the SA) | Required to satisfy Conditional Access. The connector replays the second factor unattended. |
| Identity with RBAC to deploy ARM + grant role assignments | Owner or Contributor + User Access Administrator on the connector RG. If you only have Contributor, use the "Deploy with a Contributor-only identity" flow below. |

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FcreateUiDefinition.json)

The button loads a 3-step wizard (workspace, auth, advanced). Fill in:

1. **Workspace** — pick an existing Sentinel-enabled Log Analytics workspace.
2. **Service account & auth** — UPN, auth method (Password+TOTP or Passkey), and the matching secrets. The wizard uploads them to a fresh Key Vault provisioned by the same deployment.
3. **Advanced** — Function App SKU (Y1 default), workspace table retention days, GitHub release tag (`latest` = the auto-refreshed stable tag — see "How releases work" below).

Pre-built signed artifacts on the [Releases](https://github.com/akefallonitis/xdrlograider/releases) page (cosign keyless OIDC). Every artifact has a `.sig` + `.cert` pair — verification command below.

## Verify

```powershell
pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>
```

15-phase markdown report at `tests/results/verify-deploy-<utc>.md`. ConnectorHeartbeat lands the card on **Connected** within 10 minutes of first fire. Cold-start budget probe (Phase 14) asserts the FA's first invocation completes within 60 seconds.

## Deploy with a Contributor-only identity

If your deploying identity has Contributor on the RG but **not** User Access Administrator (no role-assignment write), ARM cannot grant the 3 RBAC roles the FA's SAMI needs. Use this three-step flow instead:

```powershell
# 1. Deploy without role assignments
az deployment group create `
    --resource-group <rg> `
    --template-file deploy/mainTemplate.json `
    --parameters deployRoleAssignments=false `
    --parameters projectPrefix=xdrlr env=prod workspaceLocation=<region> `
    --parameters serviceAccountUpn=<sa@tenant> authMethod=credentials_totp `
    --parameters existingWorkspaceId=<workspace-resource-id> `
    --parameters githubRepo=akefallonitis/xdrlograider releaseTag=latest

# 2. Then grant the 3 SAMI roles with an identity that DOES have role-write
#    (RG Owner, or a directory admin via PIM). Idempotent + auto-discovers FA/KV/Storage.
pwsh ./tools/Grant-Post-Deploy-Rbac.ps1 -ResourceGroup <rg>

# 3. Verify
pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>
```

## Secret upload (if you skipped the wizard secret fields)

The wizard accepts secrets inline and writes them to KV at deploy time. If you bypassed the inline path or need to rotate later:

```bash
# CredentialsTotp method needs 3 secrets:
az keyvault secret set --vault-name <kv-name> --name defender-upn      --value '<service-account-upn>'
az keyvault secret set --vault-name <kv-name> --name defender-password --value '<service-account-password>'
az keyvault secret set --vault-name <kv-name> --name defender-totp     --value '<TOTP-BASE32-SEED>'   # uppercase, no dashes/spaces (e.g. JBSWY3DPEHPK3PXP)

# Passkey method needs:
az keyvault secret set --vault-name <kv-name> --name defender-upn     --value '<service-account-upn>'
az keyvault secret set --vault-name <kv-name> --name defender-passkey --value '<passkey-json-blob>'   # exported FIDO2 credential, must include {upn, credential}
```

The auth chain validates non-empty values + correct shape on first use. Empty secrets throw a clear error in AppInsights traces naming the offending secret + this exact `az keyvault secret set` command.

## Verify release artifacts (cosign keyless OIDC)

Every release artifact is signed with [Sigstore cosign keyless OIDC](https://docs.sigstore.dev/cosign/keyless/) — no operator setup needed.

```bash
# Install cosign (once)
brew install cosign           # macOS
# or: https://github.com/sigstore/cosign/releases

# Download an artifact + its .sig + .cert
curl -LO https://github.com/akefallonitis/xdrlograider/releases/latest/download/function-app.zip
curl -LO https://github.com/akefallonitis/xdrlograider/releases/latest/download/function-app.zip.sig
curl -LO https://github.com/akefallonitis/xdrlograider/releases/latest/download/function-app.zip.cert

# Verify (Fulcio cert chains back to GitHub Actions OIDC)
cosign verify-blob \
    --certificate function-app.zip.cert \
    --signature function-app.zip.sig \
    --certificate-identity-regexp "https://github.com/akefallonitis/xdrlograider/" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    function-app.zip
```

The same verification works for `mainTemplate.json`, `createUiDefinition.json`, `sentinelContent.json`, `XdrLogRaider-Solution.zip`, and `sbom.spdx.json`.

## Pre-deploy preflight (operator-local)

```powershell
pwsh ./tools/Preflight-Local.ps1                # offline: Pester + custom validators + Sentinel V2 lint
pwsh ./tools/Preflight-Local.ps1 -IncludeOnline # adds live TOTP + Passkey + TenantContext probe via tests/.env.local
```

Section **7b** of Preflight runs `az deployment group validate` against your subscription when `$env:XDRLR_PREFLIGHT_RG` + `$env:XDRLR_PREFLIGHT_WORKSPACE_ID` are set — this catches ARM expression-evaluation bugs (substring length, dependsOn form, parameter shape) that the offline JSON-shape tests cannot.

## How releases work (stable-tag contract)

The `v0.1.0` tag is the **stable refresh tag**, not a frozen snapshot. Every merge to `main` that passes CI triggers `release.yml` automatically, which:

1. Force-updates the `v0.1.0` tag to point at the new commit
2. Rebuilds `function-app.zip` + `mainTemplate.json` + the rest of the artifact set
3. Cosign-signs every artifact
4. Deletes the existing GitHub Release + recreates it (so the homepage badge always shows the current refresh time, not the original publish date)
5. Re-uploads artifacts under `releases/latest/download/*`

The Function App's `WEBSITE_RUN_FROM_PACKAGE` points at `releases/latest/download/function-app.zip`, so a cold-start always pulls the current build with no operator intervention. When a real breaking change requires a tag bump (e.g. v0.2.0 multi-portal), the workflow is re-run manually with the new version.

## Observability

What an operator sees in the first 15 minutes after deploy:

- **Sentinel data-connector card** — flips to "Connected" when `XdrConnectorHealth_CL` has any row from the last 15 minutes (Heartbeat fires every 5 min).
- **`XdrConnectorHealth_CL`** — 5-min heartbeat rows with aggregate liveness, DLQ depth, open-circuit count, and a lean Notes JSON. Includes `ConnectorVersion` + `ConnectorBuildId` columns so you can see exactly which build is running.
- **AppInsights traces** — every poll, every auth attempt, every DCE batch is logged with `OperationId` correlation. Secret values are redacted before emit via `ConvertTo-XdrAiSafeProperties`.
- **AppInsights customMetrics** — `xdr.heartbeat.cardState` (1/0 gauge), `xdr.dlq.pending_count`, `xdr.subarea.circuit_state` (per-EntryKey 0=closed/1=half-open/2=open).
- **`XdrTierState` Storage Table** — per-stream state (LastRunUtc, RowsIngested, SuccessKind, CircuitState, ConsecutiveErrors, LicenseHint). Query with `az storage entity query --account-name <st> --table-name XdrTierState`.
- **`xdrIngestDlq` Storage Table** — failed DCE batches replayed on the next poll. Operator alerts on depth > N.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Card stays "Disconnected" > 15 min after deploy | KV secret empty / missing | `Verify-Deploy.ps1` Phase 4 checks KV+SAMI; the auth chain throws a clear error naming the offending secret with the exact `az keyvault secret set` remediation. Re-run `Grant-Post-Deploy-Rbac.ps1` if RBAC failed. |
| `XdrConnectorHealth_CL` shows `fatalError` populated | State-aggregation crashed; heartbeat row still fires with reason | Check AppInsights traces filtered by `customDimensions.Phase` — the failure mode is named (e.g. `'kv-secret-validate'`, `'state-table-read'`). |
| First poll hits `429 rate-limited` for several cycles | apiproxy throttle on cold-start; circuit-breaker handles it | No action needed if it self-recovers in 5 min. If sustained > 30 min, the circuit-breaker will mark the sub-area `CircuitState=open` for 30 min cooldown. |
| `vulnerability_management` first poll runs hours | 5M-row first poll; multi-cycle pagination | Expected. `LastCompletedPage` checkpoint in `connectorCheckpoints` table resumes across cycles. Default `XDR_MAX_PAGES_PER_CYCLE=50` bounds each activity invocation under the Y1 10-min cap. |
| FA cold-start > 60s | Az.* module import + manifest load latency | `Verify-Deploy.ps1` Phase 14 measures this. If it's a real regression, switch `planSku` to EP1 for a warm worker. |
| `Get-AzAccessToken` throws on first invocation after deploy | IMDS endpoint transient 5xx | profile.ps1 retries 3 attempts with exponential backoff (2s, 4s) then throws terminating. Worker is recycled; next timer fire usually succeeds. |

## Known limitations (v0.1.0)

| Item | Plan target |
|---|---|
| Sentinel content (analytic rules, hunting queries, workbooks, parsers) | v0.3.0 — the pilot has 21 rules + 12 hunting queries + 10 workbooks + 4 drift parsers ready to port |
| Multi-portal (Entra ID, Purview, Intune, etc.) | v0.2.0 — same 4 Durable functions + additive manifests + L2/L3 module pairs |
| MSSP multi-tenant | v0.2.0 — secret prefix becomes `<tenantId>-<portal>-<secret>` |
| Private endpoints + VNet + customer-managed keys | v0.5.0 — production hardening pass |
| PII redaction at the connector layer | Not in roadmap — raw apiproxy responses go to your LA workspace; LA data-residency + workspace-table-level RBAC apply |
| Path-parameter fan-out endpoints (per-MachineId iteration) | v0.1.1 — currently skipped in the activity (harmless) |
| Operator runbook docs in markdown | v0.4.0 — `Preflight-Local` + `Verify-Deploy` markdown reports are the v0.1.0 surface |
| Key Vault purge-protection forced ON | Intentional — operator opts in per tenant compliance policy (purge-protection is irreversible for 90 days). Recommended for production: `az keyvault update --name <kv> --enable-purge-protection true` after deploy. |
| Function App on public network | Public ingress is required for `security.microsoft.com` apiproxy + GitHub releases pull. v0.5.0 evaluates VNet egress + WAF for tenants with strict egress policies. |

## Architecture

| Layer | Module / function | Scope |
|---|---|---|
| L1 — Entra ESTS auth | `Xdr.Common.Auth` (TOTP / Passkey / SharePoint MFA) | shared across portals |
| L1 — Sentinel ingest | `Xdr.Sentinel.Ingest` (DCE batch, DLQ, checkpoints, circuit-breaker state, tier-state) | portal-generic |
| L1 — Telemetry | `Xdr.Common.Telemetry` (5 AppInsights senders + secret redaction) | portal-generic |
| L1 — Manifest | `Xdr.Common.Manifest` (scriptblock-eval loader, 493 entries) | portal-generic |
| L2 — Defender portal cookie auth | `Xdr.Defender.Auth` (sccauth + XSRF-TOKEN, 50-min session cache, 401/429 retry) | Defender-specific |
| L3 — Defender portal client | `Xdr.Defender.Client` (per-EntryKey dispatcher, Custom Collection cmdlets, TenantContext) | Defender-specific |
| L4 — Orchestrator router | `Xdr.Connector.Orchestrator` (portal switchboard for v0.2.0+) | shared |

The 4 Durable functions are portal-agnostic: `Xdr-Refresh` (1-min timer + Durable Client) dispatches per `(Portal, Tier)` schedule rows; `Xdr-PollOrchestrator` reads the manifest for that pair and fans out activities; `Xdr-PollStream` does the actual auth + poll + ingest + checkpoint + tier-state write; `Connector-Heartbeat` (5-min timer, independent) emits liveness rows even when polls are paused.

## License

MIT.
