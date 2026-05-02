# Deployment Guide

Full walk-through from nothing to a working XdrLogRaider deployment.

> **Scope** of this template: it deploys the **connector** (Function App + KV + Storage + DCE + DCR + App Insights + Sentinel content) and adds **47 custom tables + a Data Connector UI card** to your **existing** Sentinel workspace via cross-RG nested deployments. It does **NOT** create or modify your workspace itself.

## Prerequisites

### Identities + roles
| What you need | Where | Why |
|---|---|---|
| **Contributor** (or Owner) on the target RG | Azure subscription | Deploys connector resources (FA/KV/Storage/DCE/DCR/AI) + role assignments |
| **Log Analytics Contributor** (or Contributor) on the workspace RG | Workspace subscription | Creates the 47 custom tables + Data Connector UI card as workspace sub-resources (cross-RG supported) |
| **User Administrator** | Entra ID | Creates the read-only service account |
| **Privileged Role Administrator** | Entra ID | Grants `Security Reader` + `Defender XDR Analyst` to the service account |
| **Key Vault Secrets Officer** (inherited from Contributor/Owner) | The deployed KV | Upload auth secrets via `Initialize-XdrLogRaiderAuth.ps1` |
| **Microsoft Sentinel Reader** on the workspace | Workspace | Verify post-deploy via KQL |

See [PERMISSIONS.md](PERMISSIONS.md) for the consolidated reference + cross-RG scenarios.

### Required resources you already have
1. **Azure subscription** — with the RBAC above
2. **Existing Sentinel-enabled Log Analytics workspace** (**REQUIRED**) — can be in any RG of any subscription in the same tenant. This template does **not** create one.
3. **Dedicated Entra service account** (see [AUTH.md](AUTH.md) + [GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md))
4. **TOTP Base32 secret** OR **software passkey JSON** — see [GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md)

### Tools
- **Azure CLI 2.50+** or **Cloud Shell** — to run the post-deploy helper
- **PowerShell 7.4+** on a local machine (if running the helper locally)

## Deployment topology (what gets deployed where)

The deploy creates resources in **two distinct scopes**:

```
┌── Target RG (you pick in the wizard) ────────────────────────┐
│   Connector-local resources:                                  │
│     - Function App (PowerShell 7.4, System-Assigned MI)       │
│     - App Service Plan (Consumption Y1 by default)            │
│     - Key Vault                                               │
│     - Storage Account + connectorCheckpoints table            │
│     - Application Insights (workspace-based)                  │
│     - Data Collection Endpoint   (in WORKSPACE region)        │
│     - Data Collection Rule       (in WORKSPACE region)        │
│     - 3 role assignments on the FA's MI:                      │
│         · KV Secrets User      on the new KV                  │
│         · Storage Table Data Contributor  on the new Storage  │
│         · Monitoring Metrics Publisher    on the new DCR      │
└───────────────────────────────────────────────────────────────┘
                           │
                           │ cross-RG nested deployments (2)
                           ▼
┌── Workspace RG (where your existing Sentinel workspace lives)─┐
│     - 47 custom tables in the workspace (45 telemetry +       │
│       MDE_Heartbeat_CL + App Insights customEvents)               │
│     - Sentinel Data Connector UI card                         │
│     - 6 KQL parsers + 6 workbooks + 14 analytic rules +       │
│       9 hunting queries (via sentinelContent.json)           │
└───────────────────────────────────────────────────────────────┘
```

**Regional note**: DCE + DCR MUST be in the same region as your workspace (Azure Monitor constraint). The connector-local FA/KV/Storage/AI can be in any region.

## Pre-deploy validation gate

PR builds run an **`az deployment group what-if`** validation against a real Azure subscription before any code that touches `deploy/compiled/mainTemplate.json` lands on `main`. This catches deploy-time constraint violations the Azure Resource Provider only surfaces when it actually evaluates the template — `InvalidTemplate`, `InvalidTransformOutput`, `Conflict`, `BadRequest`, `Failed` change-set entries — and which static ARM-TTK + schema-shape Pester tests cannot detect.

The job uses a service principal with Contributor on a dedicated empty RG (or the connector RG). It does **NOT** run a real deploy — only what-if. The synthetic RG and any what-if metadata is cleaned up after the test.

To enable the gate on your fork, configure these GitHub Secrets:

| Secret | Purpose |
|---|---|
| `AZ_TENANT_ID` | Entra tenant of the SP |
| `AZ_CLIENT_ID` | SP application id |
| `AZ_CLIENT_SECRET` | SP client secret |
| `AZ_SUBSCRIPTION_ID` | Subscription containing the workspace |
| `WORKSPACE_RG` | RG of the existing Log Analytics workspace |
| `WORKSPACE_NAME` | Name of the existing Log Analytics workspace |
| `WHATIF_RG` *(optional)* | Pre-existing RG the SP has Contributor on; used as the what-if target. If absent, falls back to `CONNECTOR_RG`. |
| `CONNECTOR_RG` *(optional)* | Fallback target RG (typically the operator's existing connector RG). |

The SP needs **Contributor** on the target RG. For full role-assignment validation, additionally grant **User Access Administrator** on the target RG — this lets what-if validate the seven `Microsoft.Authorization/roleAssignments` resources the template creates. Without it, the test transparently strips role-assignments and validates the remaining 23 resources (66 Create / 1 Modify on a fresh deploy), with a clear note in the test log.

Without these secrets the job self-skips with a warning — useful for forks. Run the test locally with:

```powershell
pwsh ./tests/Run-Tests.ps1 -Category whatif
```

(Requires `tests/.env.local` — see [tests/README.md](../tests/README.md).)

## Step 1 — Gather workspace info

Before clicking Deploy, collect these two values:

1. **Workspace resource ID**: Azure Portal → your Log Analytics workspace → Overview → JSON view → `id` field. Format:
   ```
   /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>
   ```
2. **Workspace region**: same Overview blade → Location (e.g. `eastus`, `westeurope`).

## Step 2 — Click Deploy to Azure

Click the **Deploy to Azure** badge in the [repo README](../README.md). Azure Portal opens the custom deployment wizard.

## Step 3 — Fill the wizard

### Basics
- **Subscription**: your Azure subscription
- **Resource group**: pick existing or create new — this is the **target RG** for connector resources. Does **not** need to be the workspace's RG.
- **Connector region**: region for FA/KV/Storage/AI. Defaults to the RG's region.
- **Project prefix**: 3-12 lowercase alphanumeric (default `xdrlr`)
- **Environment**: `prod` / `staging` / `dev` — used in resource names + tags

### Sentinel workspace
- **Workspace resource ID** (REQUIRED): paste the full resource ID from Step 1.
- **Workspace region** (REQUIRED): pick from dropdown to match the workspace's actual region.

### Authentication
- **Service account UPN**: e.g. `svc-xdrlr@contoso.onmicrosoft.com`
- **Auth method**: `Credentials + TOTP` (simpler) or `Software Passkey` (phishing-resistant)

### Advanced (optional)
- **Function App plan**: `Consumption (Y1)` — recommended, within Azure Functions free tier
- **Function App version**: `latest` (pulls newest GitHub Release) or pinned like `1.0.0`
- **GitHub repo**: `akefallonitis/xdrlograider` — only override if you forked

Click **Review + Create**, then **Create**.

## Step 4 — Wait for deployment (~5-10 min)

Azure Portal shows the deployment in progress. You can watch individual modules:
- `tables-<uniq>` → cross-RG custom tables (your workspace RG)
- `sentinelContent-<uniq>` → cross-RG parsers/workbooks/rules (your workspace RG)
- `dce-<uniq>` → DCE + DCR in the target RG (at workspace region)
- `fn-<uniq>` → Function App
- `roles-<uniq>` → 3 MI role assignments

## Step 5 — Upload auth secrets

When deployment completes, copy the **`keyVaultName`** and **`postDeployCommand`** from the Outputs tab. Run the helper (from your local machine or Cloud Shell):

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-output>
```

The script:
1. Prompts for auth method (or pass `-Method credentials_totp` / `-Method passkey`)
2. Prompts for credentials interactively (no plaintext echo)
3. Validates format (TOTP Base32, passkey JSON schema, UPN format)
4. Uploads secrets to Key Vault

## Step 6 — Wait for auth self-test (~5 min)

The `(auth chain — see App Insights customEvents)` timer fires within ~5 min. Check in your workspace:

```kql
App Insights customEvents
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Success, Stage, FailureReason, SampleCallHttpCode
```

**Expected**: `Success = true, Stage = complete, SampleCallHttpCode = 200`.

If failed, see [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Step 7 — Verify ingestion (~1 hour)

Wait for the first P0 poll cycle, then:

```kql
// Are P0 streams ingesting?
MDE_Heartbeat_CL
| where Tier == 'P0' and TimeGenerated > ago(2h)
| summarize LastSeen = max(TimeGenerated), Streams = max(StreamsSucceeded) by FunctionName

// First rows of any P0 stream
MDE_AdvancedFeatures_CL | take 1
```

## Step 8 — Enable workbooks + analytic rules

Analytic rules ship disabled by default (alert-fatigue avoidance). Enable selectively:

1. Sentinel → Analytics
2. Filter by `MDE` prefix (rule names from this connector)
3. Review each rule's query + severity + suppression → enable

Workbooks are deployed ready:

1. Sentinel → Workbooks
2. Open `MDE Compliance Dashboard` → verify panels render

## Upgrade (future releases)

1. Change `functionAppZipVersion` parameter to the new pinned tag (e.g. `0.2.0`) and redeploy. **Do NOT use `latest`** — GitHub `/releases/latest/download/...` excludes pre-release tags by design and resolves to 404, leaving the FA with no code (`Runtime: Error`). Always pin to an explicit semver tag.
2. FA pulls the new ZIP on next restart. App Insights will show the cold-start log.
3. Any new streams in a future release require a redeploy of the ARM template to create the new LA tables + DCR stream declarations.

## Uninstall

```bash
# Remove the connector RG (keeps your Sentinel workspace untouched)
az group delete --name <connector-rg>

# Optional: delete the 54 MDE_*_CL tables from your workspace
# (Azure Portal → workspace → Tables → right-click each → Delete)
# OR via PowerShell per table (Az.OperationalInsights Remove-AzOperationalInsightsTable)

# Optional: purge soft-deleted KV to allow fast re-deploy
az keyvault purge --name <kv-name> --location <region>
```

## Next steps

- [PERMISSIONS.md](PERMISSIONS.md) — Consolidated permissions reference
- [AUTH.md](AUTH.md) — Auth method details + Conditional Access compatibility
- [GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md) — How to obtain TOTP / passkey / cookies
- [RUNBOOK.md](RUNBOOK.md) — Daily/weekly operator tasks + rotation
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Symptom → cause → fix
- [COST.md](COST.md) — Monthly cost model
- [ARCHITECTURE.md](ARCHITECTURE.md) — Component diagram + data flow + trust boundaries
