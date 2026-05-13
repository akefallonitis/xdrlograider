# XdrLogRaider

Microsoft Sentinel data connector for **Microsoft Defender XDR portal-internal telemetry**. Polls 493 read endpoints across 18 nodoc sub-areas (action_center, attack_simulator, cloud_apps, configuration, data_lake, endpoint_configuration, endpoint_devices, entity_pivots, exposure_management, files, identity, multi_tenant, portal_services, secure_score, sentinel_precision, streaming, threat_analytics, vulnerability_management) and ingests results into 18 `Defender_<Sub>_CL` workspace tables plus 1 `XdrConnectorHealth_CL` operational table via DCE/DCR Logs Ingestion.

This is the apiproxy surface Microsoft does **not** publish a public Graph or MDE API for — the connector closes that gap for SOC operators who need first-class hunting/detection over portal-only signals.

| | |
|---|---|
| **Status** | v0.1.0 GA |
| **Telemetry source** | `security.microsoft.com` apiproxy (sccauth + XSRF cookie chain via Entra TOTP / Passkey unattended) |
| **Hosting** | Azure Function App on PowerShell 7.4 — Y1 Linux Consumption default · EP1/EP2/EP3 opt-in |
| **Identity** | System-Assigned Managed Identity (SAMI) |
| **Topology** | 4 PowerShell Durable Functions (Xdr-Refresh · Xdr-PollOrchestrator · Xdr-PollStream · Connector-Heartbeat) |
| **Output** | DCE/DCR → 18 `Defender_<Sub>_CL` data tables + 1 `XdrConnectorHealth_CL` heartbeat table |
| **Release signing** | cosign keyless OIDC (Sigstore Fulcio + Rekor) |

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json)

The button launches the Azure Portal **Custom deployment** wizard pre-loaded with `deploy/mainTemplate.json` + `deploy/createUiDefinition.json` from the latest `main`. Wizard prompts (3 steps):

1. **Sentinel workspace** — select an existing Sentinel-enabled Log Analytics workspace.
2. **Service account & auth** — service account UPN + auth method (`credentials_totp` or `passkey`); optionally upload password / TOTP seed / passkey JSON inline (Key Vault soft-delete is on; secrets can also be uploaded post-deploy).
3. **Advanced** — Function App plan SKU (Y1 default), retention, GitHub release tag, role-assignment opt-out for Contributor-only deploy identities.

Defaults to the `latest` release. To pin a version, change the **Release tag** field to e.g. `v0.1.0`.

## Architecture (1-paragraph)

`Xdr-Refresh` fires every minute, reads the `XdrTierState[RowKey='__schedule__']` Storage Table rows, and starts a Durable orchestration for every `(Portal, Tier)` pair whose `NextRunUtc` has elapsed. `Xdr-PollOrchestrator` reads the manifest for that `(Portal, Tier)`, runs a pre-flight circuit-breaker check, and fans out one `Xdr-PollStream` activity per stream. Each activity authenticates via SAMI → Key Vault → `Connect-DefenderPortal` (50-min session cache), runs `Invoke-MDEEndpoint -EntryKey <subarea::slug>`, ingests rows via `Send-ToLogAnalytics` (DCE → DCR with gzip + 429-retry + 413-split + DLQ), and writes a `Set-XdrTierStateRow ByProperties` row carrying the 4-value `SuccessKind` (`live` · `live-empty` · `rate-limited` · `error`) + `LicenseHint`. Independently, `Connector-Heartbeat` fires every 5 minutes, reads the aggregate state, and emits one heartbeat row to `XdrConnectorHealth_CL` with lean Notes JSON (`cardState`, `dlqDepth`, `openCircuits`, `fatalError`); the Sentinel data-connector card's `connectivityCriteria` queries that table for freshness.

## Operator quick-start

```powershell
# 1. Pre-deploy: sanity check + live auth probe (optional)
pwsh ./tools/Preflight-Local.ps1            # 8-section offline gate
pwsh ./tools/Probe-Auth-Local.ps1           # TOTP/Passkey + TenantContext + Custom Collection live probe via .env.local

# 2. Deploy (Portal wizard via the button above, OR CLI):
az login
az group create --name <rg> --location <region>
az deployment group create --resource-group <rg> `
  --template-file deploy/mainTemplate.json `
  --parameters @deploy/parameters.json `
  --parameters releaseTag=v0.1.0 `
               serviceAccountUpn=<upn> `
               existingWorkspaceId=<workspace-resource-id> `
               authMethod=credentials_totp

# 3. Upload secrets if you skipped them in the wizard
az keyvault secret set --vault-name <kv> --name defender-password --value <pwd>
az keyvault secret set --vault-name <kv> --name defender-totp     --value <base32-seed>
az keyvault secret set --vault-name <kv> --name defender-upn      --value <upn>
az keyvault secret set --vault-name <kv> --name defender-auth-method --value credentials_totp

# 4. Verify deployment (14-phase markdown report at tests/results/verify-deploy-<utc>.md)
pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>
```

After `Verify-Deploy.ps1` reports `Heartbeat fired last 10 min = OK`, the Sentinel data-connector card flips to **Connected** automatically within 15 minutes.

## Repository layout

```
manifests/defender.psd1                Phase 0 source-of-truth — 493 endpoints across 18 sub-areas
deploy/
  mainTemplate.json                    ARM template (Y1 default · SAMI · 19 DCRs · 19 workspace tables · 3 role assignments)
  createUiDefinition.json              Portal wizard (3 steps · Y1 first · TOTP/Passkey)
  parameters.json                      Placeholder parameter values for CLI deploy
  sentinelContent.json                 Sentinel Solution V2 data-connector card
  dcrs/                                19 per-sub-area DCR JSONs (regenerable)
src/
  host.json                            functionTimeout=00:10:00 · Durable Task Hub name · AppInsights sampling
  profile.ps1                          Connect-AzAccount -Identity + module imports
  Modules/                             7 modules (Xdr.Common.Auth/Manifest/Telemetry/Connector.Orchestrator/Defender.Auth/Defender.Client/Sentinel.Ingest)
  functions/                           4 hand-authored Durable Functions
references/                            Phase 0 design + Defender endpoint metadata (PII-scrubbed)
tests/                                 165 mocked Pester tests · unit + arm + kql · 24.11% coverage
tools/                                 Build-* generators · Validate-* gates · Probe-Auth-Local · Preflight-Local · Verify-Deploy
.github/workflows/                     ci.yml (offline gates) · release.yml (cosign keyless OIDC) · validate-solution.yml
```

## Releases

Pre-built signed artifacts are on the **[Releases](https://github.com/akefallonitis/xdrlograider/releases)** page. Each release includes `function-app.zip`, `mainTemplate.json`, `createUiDefinition.json`, `parameters.json`, `sentinelContent.json`, and an SPDX SBOM — every file accompanied by a Sigstore cosign signature (`.sig`) and ephemeral cert (`.cert`).

Verify any artifact:

```bash
cosign verify-blob --certificate <file>.cert --signature <file>.sig <file>
```

## Sentinel Content Hub

The shipped `deploy/sentinelContent.json` is a Sentinel V2 `Microsoft.SecurityInsights/dataConnectors` ARM template — it provisions the connector card in the operator's workspace after `Deploy to Azure`. It is **not** a Content Hub gallery listing; that requires a separate PR to [`Azure/Azure-Sentinel/Solutions/`](https://github.com/Azure/Azure-Sentinel/tree/master/Solutions) by the maintainer and is on the v0.4.0 roadmap.

## Forward-compat (v0.2.0+)

The **same 4 Durable functions** scale to N portals — per-portal change is isolated to one manifest (`manifests/<portal>.psd1`) + one auth/client module pair (`Xdr.<Portal>.Auth` + `Xdr.<Portal>.Client`) + N DCRs/tables + 5 KV secrets. ~30 min to onboard a new portal once its Phase 0 nodoc capture is done.

MSSP multi-tenant uses `<tenantId>-<portal>-<secret>` KV prefix (already parameterised in `Get-XdrAuthFromKeyVault -SecretPrefix`). XdrTierState extends to 3-tuple PartitionKey `<TenantId>|<Portal>|<Tier>` — no orchestration code changes required.

## License

MIT (see [LICENSE](LICENSE) when published).
