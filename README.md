# XdrLogRaider

Microsoft Sentinel data connector for **Microsoft Defender XDR portal-internal telemetry** — the `security.microsoft.com` apiproxy surface Microsoft does not publish a public Graph or MDE API for. 493 read endpoints across 18 nodoc sub-areas → 19 DCRs → 18 `Defender_<Sub>_CL` workspace tables + 1 `XdrConnectorHealth_CL` operational table.

## Deploy

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fakefallonitis%2Fxdrlograider%2Fmain%2Fdeploy%2FcreateUiDefinition.json)

Pre-built signed artifacts on the [Releases](https://github.com/akefallonitis/xdrlograider/releases) page (cosign keyless OIDC).

## Verify

```powershell
pwsh ./tools/Verify-Deploy.ps1 -ResourceGroup <rg>
```

14-phase markdown report at `tests/results/verify-deploy-<utc>.md`. ConnectorHeartbeat lands the card on **Connected** within 10 minutes of first fire.

## Deploy with a Contributor-only identity

The Deploy-to-Azure button uses your interactive Azure RBAC, so this section only applies when deploying via a service principal or pipeline identity that has **Contributor on the RG but not User Access Administrator**. In that case ARM cannot write the 3 role assignments to the FA's SystemAssigned managed identity.

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

## Pre-deploy preflight (operator-local)

```powershell
pwsh ./tools/Preflight-Local.ps1                # offline: Pester + custom validators + Sentinel V2 lint
pwsh ./tools/Preflight-Local.ps1 -IncludeOnline # adds live TOTP + Passkey + TenantContext probe via tests/.env.local
```

Section **7b** of Preflight runs `az deployment group validate` against your subscription when `$env:XDRLR_PREFLIGHT_RG` + `$env:XDRLR_PREFLIGHT_WORKSPACE_ID` are set — this catches ARM expression-evaluation bugs (substring length, dependsOn form, parameter shape) that the offline JSON-shape tests cannot.
