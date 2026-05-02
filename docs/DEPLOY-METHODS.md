# Deployment methods — v0.1.0-beta

> **TL;DR** — v0.1.0-beta ships a single supported deployment path: the
> **Deploy to Azure** button in the [README](../README.md). It loads the
> hand-authored ARM template directly from `deploy/compiled/mainTemplate.json`.
> CLI-driven and Bicep-source workflows return in v0.2.0 alongside multi-portal
> expansion.

## v0.1.0-beta — single source of truth

| Property | Value |
|---|---|
| Source of truth | `deploy/compiled/mainTemplate.json` (hand-authored ARM, matches Microsoft Sentinel Solutions repo pattern) |
| Wizard | `deploy/compiled/createUiDefinition.json` |
| Function App package | `function-app.zip` from the matching GitHub release (`/releases/latest/download/function-app.zip`) |
| Hosting plan | Y1 Linux Consumption (see [HOSTING-PLANS.md](HOSTING-PLANS.md)) |

## Deploy

1. Make sure prerequisites are in place — see [README.md](../README.md#0-prerequisites-one-time).
2. Click **Deploy to Azure** in the [README](../README.md). Azure Portal opens with the wizard pre-loaded.
3. Fill in the wizard fields:
   - Project prefix (3–12 lowercase chars), env tag, target RG
   - Existing Sentinel-enabled workspace resource ID + region
   - Service-account UPN, auth method (CredentialsTotp / Passkey)
   - Optional secret-upload (uploads to Key Vault as part of the deploy)
4. Click **Review + create** → **Create**. Deploy runs ~5 min.
5. Run the post-deploy auth bootstrap:
   ```powershell
   git clone https://github.com/akefallonitis/xdrlograider
   cd xdrlograider
   ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <KeyVaultName from deploy outputs>
   ```
6. Wait 5–10 min for the Heartbeat timer + first-cadence-tier polls to fire. Verify per
   the KQL queries in the [README](../README.md#3-verify-ingestion).

## Private-repo / private-Bicep workflow

The Deploy-to-Azure button uses `raw.githubusercontent.com` URLs and requires the repo
to be public for Azure Portal to fetch the templates.

For private-repo deployment without making the repo public:
- Azure Portal → **Deploy a custom template** → **Load template from file** with
  `deploy/compiled/mainTemplate.json` + `deploy/compiled/createUiDefinition.json`
  (or the equivalents inside the Solution ZIP from a GitHub Release asset).
- Override the `packageUrl` template variable to point at a pre-uploaded copy of
  `function-app.zip` (Azure Blob SAS, Azure DevOps artifact URL, internal package
  registry, etc.). The Function App runtime fetches the zip via
  `WEBSITE_RUN_FROM_PACKAGE`; any URL Azure Functions can `GET` will work.

## How `WEBSITE_RUN_FROM_PACKAGE` works here

The Function App runs directly from the zipped release — it does **not** unpack into the
FA filesystem. Official Azure pattern documented at
[Run functions from deployment package](https://learn.microsoft.com/en-us/azure/azure-functions/run-functions-from-deployment-package).

ARM sets:
```
WEBSITE_RUN_FROM_PACKAGE=https://github.com/akefallonitis/xdrlograider/releases/latest/download/function-app.zip
```

The FA runtime:
1. On cold start, GETs that URL (unauthenticated)
2. Mounts the zip read-only as a virtual filesystem
3. Executes `profile.ps1` → loads modules → timer-triggered functions fire per their cron

GitHub acts as a CDN (edge-cached globally). No egress cost; no separate blob storage to
provision.

**Repo visibility requirement**: the repo MUST be public for the default `packageUrl` to
resolve. A private repo returns 404 on unauthenticated `GET` → FA cold start fails →
no heartbeats → no ingestion. For private deploys, override `packageUrl` per the section
above.

## Roadmap

v0.2.0 reintroduces:
- CLI-driven deploys (`az deployment group create` / `New-AzResourceGroupDeployment`)
  with explicit parameter files.
- Bicep-source-direct deploys (`_artifactsLocation` parameter pattern) for tenants who
  want to compose with existing Bicep modules.
- Sentinel Content Hub install (after Microsoft publishes the Solution Gallery listing).

See [ROADMAP.md](ROADMAP.md#v020--multi-portal-expansion--new-streams).
