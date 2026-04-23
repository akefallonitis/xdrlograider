# Deployment methods — all working paths

You have **five supported ways** to deploy XdrLogRaider. Pick the one that matches your operating posture. Each is production-tested and produces the same runtime state.

| # | Method | Time-to-live | Best for |
|---|---|---|---|
| 1 | One-click **Deploy to Azure** (ARM from GitHub release) | ~5 min | First-time users, happy-path demo |
| 2 | `az deployment group create` with release URI | ~5 min | CLI-driven infra, scripted onboarding |
| 3 | PowerShell `New-AzResourceGroupDeployment` | ~5 min | PS-first teams, integrating with existing runbooks |
| 4 | Compile-then-deploy from Bicep source | ~7 min | You want to customise before deploying |
| 5 | Sentinel Content Hub solution install | ~5 min (post-MS-review) | Post-v1.1, when the solution is published in Content Hub |

All methods eventually invoke the same `mainTemplate.json` — the only difference is how the template is sourced.

---

## Method 1 — One-click Deploy to Azure (recommended)

Click the **Deploy to Azure** badge in the main `README.md`. This opens the Azure Portal with:
- `mainTemplate.json` fetched from `https://raw.githubusercontent.com/akefallonitis/xdrlograider/main/deploy/compiled/mainTemplate.json`
- `createUiDefinition.json` fetched from the matching path
- The ARM template's `packageUrl` parameter defaults to `latest`, which resolves to `https://github.com/akefallonitis/xdrlograider/releases/latest/download/function-app.zip`

**Prerequisite**: the xdrlograider repo must be **public** (GitHub returns 404 on unauthenticated fetches of private repo releases). Make the repo public via **Settings → Change visibility**. The source itself contains no secrets — service-account credentials are uploaded post-deploy to Key Vault, never committed.

---

## Method 2 — Azure CLI

```bash
az deployment group create \
    --resource-group xdrlr-prod-rg \
    --template-uri 'https://raw.githubusercontent.com/akefallonitis/xdrlograider/main/deploy/compiled/mainTemplate.json' \
    --parameters \
        projectPrefix=xdrlr \
        existingWorkspaceId='/subscriptions/<SUB>/resourceGroups/<WS-RG>/providers/Microsoft.OperationalInsights/workspaces/<WS-NAME>' \
        serviceAccountUpn='svc-xdrlr@your-tenant.com' \
        authMethod='CredentialsTotp' \
        functionAppZipVersion='1.0.1' \
        githubRepo='akefallonitis/xdrlograider'
```

Parameters map 1:1 to the wizard fields. Set `functionAppZipVersion=latest` to track the most recent release; pin to `1.0.1` for reproducibility.

---

## Method 3 — PowerShell

```powershell
$params = @{
    projectPrefix        = 'xdrlr'
    existingWorkspaceId  = '/subscriptions/<SUB>/resourceGroups/<WS-RG>/providers/Microsoft.OperationalInsights/workspaces/<WS-NAME>'
    serviceAccountUpn    = 'svc-xdrlr@your-tenant.com'
    authMethod           = 'CredentialsTotp'
    functionAppZipVersion = '1.0.1'
    githubRepo           = 'akefallonitis/xdrlograider'
}
New-AzResourceGroupDeployment `
    -ResourceGroupName xdrlr-prod-rg `
    -TemplateUri 'https://raw.githubusercontent.com/akefallonitis/xdrlograider/main/deploy/compiled/mainTemplate.json' `
    -TemplateParameterObject $params
```

Same effect as Method 2 but Az-PowerShell-native.

---

## Method 4 — Bicep source → ARM → deploy

Clone the repo, edit `deploy/main.bicep` if you want to customise (e.g. change Function App SKU from Consumption → Premium), compile, and deploy:

```bash
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider

# Compile Bicep → scratch ARM JSON
az bicep build --file deploy/main.bicep --outfile /tmp/my-template.json

# Deploy the scratch template (NOT the committed mainTemplate.json which is
# hand-authored for the Deploy button — keep them intentionally separate)
az deployment group create \
    --resource-group xdrlr-prod-rg \
    --template-file /tmp/my-template.json \
    --parameters deploy/main.parameters.json
```

**Note**: the committed `deploy/compiled/mainTemplate.json` is the hand-authored ARM that the Deploy button uses. The Bicep source is a reference/starting point — it compiles to a *different* ARM shape (nested-modules) that's harder to embed in a one-click button but fine for CLI deploys.

---

## Method 5 — Sentinel Content Hub (v1.1+)

After Microsoft publishes the solution to Content Hub (see `docs/SENTINEL-SOLUTION-SUBMISSION.md`):

1. In the Sentinel portal: **Content Hub → search "XdrLogRaider" → Install**
2. Wizard runs the same `mainTemplate.json` behind the scenes

**Until then**: the Solution ZIP is built and available as `xdrlograider-solution-1.0.1.zip` in each GitHub release. You can side-load it via:

```bash
# Download the Solution ZIP from GitHub release
curl -LO 'https://github.com/akefallonitis/xdrlograider/releases/download/v1.0.1/xdrlograider-solution-1.0.1.zip'

# Extract + deploy mainTemplate.json from within — same as Method 2
unzip xdrlograider-solution-1.0.1.zip -d xdrlr-solution
az deployment group create \
    --resource-group xdrlr-prod-rg \
    --template-file xdrlr-solution/mainTemplate.json \
    --parameters ...
```

---

## Post-deploy steps (same for all methods)

After **any** of the above produces a `Succeeded` deployment:

1. **Upload auth material** (one-time, ~1 min):
   ```powershell
   pwsh ./tools/Initialize-XdrLogRaiderAuth.ps1 `
       -KeyVaultName <deployed-kv-name> `
       -AuthMethod CredentialsTotp `
       -Upn svc-xdrlr@your-tenant.com `
       -Password (Read-Host -AsSecureString) `
       -TotpBase32 'YOUR-BASE32-SEED'
   ```

2. **Wait 20 min** for first poll cycle.

3. **Verify** via KQL or the automated e2e check (`docs/POSTDEPLOY-PLAYBOOK.md`).

4. Monitor the first 24h (same playbook).

---

## How WEBSITE_RUN_FROM_PACKAGE works here

The Function App runs directly from the zipped release — it does **not** unpack into the FA filesystem. Official Azure pattern documented at [Run functions from deployment package](https://learn.microsoft.com/en-us/azure/azure-functions/run-functions-from-deployment-package).

ARM sets this app setting:
```
WEBSITE_RUN_FROM_PACKAGE=https://github.com/akefallonitis/xdrlograider/releases/download/v1.0.1/function-app.zip
```

The FA runtime:
1. On cold start, GETs that URL (unauthenticated)
2. Mounts the zip read-only as a virtual filesystem
3. Executes profile.ps1 → loads modules → timer-triggered functions fire per their cron

GitHub acts as a CDN (edge-cached globally). No egress cost for you, no provisioning of separate blob storage.

**Repo visibility requirement**: the repo MUST be public. A private repo returns 404 on unauthenticated GET → FA cold start fails silently → all timers show "0 invocations" → no heartbeats → ingestion never starts.

### Alternatives if you need a private release

If your org policy forbids public GitHub, swap the packageUrl parameter in the deploy to:
- An Azure Blob SAS URL (pre-upload function-app.zip there)
- An Azure DevOps artifact URL with a SAS token
- A package published to an internal package registry (Artifactory / Azure Artifacts)

The ARM template exposes `functionAppZipVersion` as a parameter but the underlying `packageUrl` is a template variable — trivial to override if you fork + modify.
