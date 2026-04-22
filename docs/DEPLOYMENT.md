# Deployment Guide

Full walk-through from nothing to a working XdrLogRaider deployment.

## Prerequisites

1. **Azure subscription** with Contributor on the target resource group
2. **Log Analytics workspace** (existing is fine; blank creates a new one)
3. **Sentinel enabled** on the workspace (optional but recommended for data-connector UI)
4. **Azure CLI 2.50+** or Cloud Shell — for post-deploy helper
5. **Dedicated Entra service account** — see [AUTH.md](AUTH.md)
6. **Either** a TOTP secret from Authenticator enrollment **or** a software passkey JSON — see [BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md)

## Step 1 — Click Deploy to Azure

1. Navigate to the [repo README](../README.md)
2. Click the **Deploy to Azure** badge
3. Azure Portal opens the custom deployment wizard

## Step 2 — Fill the wizard

### Basics tab
- **Subscription**: your subscription
- **Resource group**: existing RG or create new
- **Region**: deploy region (recommend same as your Sentinel workspace)
- **Project prefix**: 3-12 alphanumeric (default `xdrlr`)
- **Environment**: `prod` / `staging` / `dev` — used in resource names

### Authentication tab
- **Service account UPN**: the dedicated read-only service account (e.g., `svc-xdrlr@contoso.onmicrosoft.com`)
- **Auth method**:
  - Select `Credentials + TOTP` for simpler tenants
  - Select `Software Passkey` for phishing-resistant-MFA enforced tenants

### Workspace tab
- **Existing workspace ID** (optional): paste your Sentinel-enabled workspace resource ID. Blank creates a new Log Analytics workspace + tables.

### Advanced tab
- **Function App plan**: `Consumption (Y1)` — recommended (free tier for typical workload)
- **Function App version**: `latest` — pulls newest GitHub release

Click **Review + Create**, then **Create**.

## Step 3 — Wait for deployment (~10 min)

The ARM deployment creates:
- Function App (PowerShell 7.4) + App Service Plan + System-assigned Managed Identity
- Key Vault (empty, awaiting secrets)
- Storage Account with `connectorCheckpoints` table
- App Insights
- Log Analytics workspace (if not using existing)
- 55+ custom tables (`MDE_*_CL`) + heartbeat + auth-test tables
- Data Collection Endpoint + Data Collection Rule
- Role assignments (MI → KV Secrets User, Storage Table Data Contributor, DCR Publisher)
- Sentinel Data Connector UI card

## Step 4 — Upload auth secrets

When deployment completes, copy the **Key Vault name** from the output. Then:

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <from-output>
```

The script:
1. Prompts for auth method (unless you pass `-Method`)
2. Collects credentials interactively (no screen capture of plaintext)
3. Validates format (TOTP Base32, passkey JSON schema, UPN format)
4. Uploads secrets to Key Vault

## Step 5 — Wait for self-test

Within ~5 minutes the Function App's `validate-auth-selftest` timer runs.
Check the result:

```kql
MDE_AuthTestResult_CL
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Success, Stage, FailureReason, SampleCallHttpCode
```

Expected: `Success = true, Stage = complete, SampleCallHttpCode = 200`.

If failed, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Step 6 — Verify ingestion

Wait another hour for the first P0 poll cycle to complete, then:

```kql
// Are all P0 streams ingesting?
MDE_Heartbeat_CL
| where Tier == 'P0' and TimeGenerated > ago(2h)
| summarize LastSeen = max(TimeGenerated), Streams = max(StreamsSucceeded) by FunctionName

// First row of any P0 stream
MDE_AdvancedFeatures_CL | take 1
```

## Step 7 — Enable workbooks + analytic rules

The deployment creates the solution but analytic rules ship as Suggested (not Auto-enabled) to avoid alert-fatigue noise. Enable them selectively:

1. Sentinel → Analytics
2. Filter by `XdrLogRaider` rule names
3. Enable each rule after reviewing its query + severity + suppression

Workbooks are deployed ready:

1. Sentinel → Workbooks
2. Open `MDE Compliance Dashboard` → verify panels render without KQL errors

## Upgrade (future releases)

To upgrade to a newer version:

1. Re-deploy the ARM template with a new `functionAppZipVersion`
2. The Function App pulls the new ZIP on restart (auto-restarts when app settings change)
3. New version's CHANGELOG.md lists any schema/breaking changes
4. Compare your tenant's tables vs. new version's `schemas/tables/` — any new streams need custom-table creation (re-running ARM is the simplest path)

## Uninstall

```bash
az group delete --name <your-resource-group>
```

Optional: purge the soft-deleted Key Vault if enabling quick re-deploy:
```bash
az keyvault purge --name <kv-name> --location <region>
```

## Next steps

- [AUTH.md](AUTH.md) — Auth method details + CA compatibility
- [RUNBOOK.md](RUNBOOK.md) — Daily/weekly operator tasks
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — When something breaks
- [WORKBOOKS.md](WORKBOOKS.md) — Workbook descriptions
- [ANALYTIC-RULES.md](ANALYTIC-RULES.md) — Each rule's purpose + tuning
