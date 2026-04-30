# Troubleshooting

Symptom → cause → fix for common issues.

## Deployment issues

### "Deploy to Azure" button goes to a blank page
**Cause**: the linked `mainTemplate.json` URL returned 404 or the repo is private.
**Fix**: verify `deploy/compiled/mainTemplate.json` exists on the `main` branch or the pinned tag. If the repo is still private, make it public or use Azure Portal → "Deploy a custom template" → upload the file directly.

### ARM deployment fails with `ResourceNotFound` on the workspace
**Cause**: `existingWorkspaceId` points at a workspace that doesn't exist or is in another tenant.
**Fix**: verify the resource ID (Portal → workspace → Overview → JSON view → `id`). Cross-RG and cross-subscription within the same tenant are supported; cross-tenant is not.

### ARM deployment fails with `AuthorizationFailed` on `Microsoft.Authorization/roleAssignments/write`
**Cause**: your tenant restricts role-assignment writes to Owners / User Access Administrators.
**Fix**: request **Owner** on the target RG OR `Contributor` + `User Access Administrator`. See [PERMISSIONS.md](PERMISSIONS.md).

### ARM deployment fails with `AuthorizationFailed` on `Microsoft.OperationalInsights/workspaces/tables/write`
**Cause**: you don't have write access to the workspace's RG (you're Owner on the connector RG but not on the workspace RG).
**Fix**: request `Log Analytics Contributor` on the workspace RG. See [PERMISSIONS.md](PERMISSIONS.md) Scenario B/C.

### ARM deployment fails at DCR step with "region mismatch"
**Cause**: the `workspaceLocation` wizard field doesn't match the actual workspace region.
**Fix**: check the workspace's region in Portal → Overview → Location. Redeploy with the correct value in the wizard dropdown.

### ARM deployment fails at Key Vault step
**Cause**: soft-deleted Key Vault with the same name exists in the subscription.
**Fix**: `az keyvault purge --name <name> --location <region>` then redeploy.

### Function App times out during first run
**Cause**: module dependencies installing from `requirements.psd1` on cold start (legacy pre-iter-13 behavior). v0.1.0-beta iter 13+ ships pre-bundled modules under `Modules/` so this should NOT happen.
**Fix**: wait ~10 minutes. Check Function App → Monitor → Invocations. If still stuck, restart the Function App.

### Function App fails every invocation with "Failed to install function app dependencies (Managed Dependencies / Legion)"
**Cause**: Linux Consumption "Legion" runtime (Microsoft's current compute platform for Y1 PowerShell function apps) does NOT support Managed Dependencies. If `requirements.psd1` lists Az modules + `host.json` `managedDependency.Enabled = true`, every function load throws:
```
Failed to install function app dependencies. Error: 'Managed Dependencies is not
supported in Linux Consumption on Legion. Please remove all module references
from requirements.psd1 and include the function app dependencies with the
function app content.'
```
**Symptoms downstream of this bug**: heartbeat sporadic (3 of 24 5-min bins), no AuthChain.Completed events in App Insights customEvents, 44 of 47 tables empty, App Insights `AppExceptions` shows 200+ exceptions/h with this exact message.
**Fix**: redeploy from `v0.1.0-beta` tag (post iter 13). Iter 13 ships:
- `requirements.psd1` empty (module references removed)
- `host.json` `managedDependency.Enabled = false`
- Az.Accounts/Az.KeyVault/Az.Storage bundled INSIDE `function-app.zip` under `Modules/` via `Save-Module` in `release.yml`
- New release-time + Pester regression gates lock the invariants
**Reference**: [Microsoft official guidance — Including modules in app content](https://aka.ms/functions-powershell-include-modules) + [GitHub Issue #944](https://github.com/Azure/azure-functions-powershell-worker/issues/944).
**Forward-compat**: same approach is required by Flex Consumption (Microsoft's strategic Y1 replacement, retiring Linux Consumption Sept 30 2028).

### Function App fails at cold start with "profile.ps1 FATAL — missing required environment variable(s)"
**Cause**: one or more of the 8 app settings the FA needs (`KEY_VAULT_URI`, `DCE_ENDPOINT`, etc.) has been deleted or mutated manually.
**Fix**: redeploy the ARM template (it re-sets all 8 app settings). If you just want to patch, go to Portal → Function App → Configuration → Application settings and re-add the missing key. The error message names the exact variable. See [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure) for related diagnosis.

## Auth chain issues

See also: [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure) for the full per-stage diagnostic table.

### AuthChain.AADSTSError event in App Insights customEvents (Entra-side failure)
**Cause**: login.microsoftonline.com failed.
**Possible fixes**:
- Password expired → reset + re-upload
- TOTP secret wrong → re-enroll authenticator + re-upload
- Conditional Access blocked sign-in → check Entra sign-in logs, add named-location exception
- Account locked → unlock in Entra

### AuthChain.Completed event missing; sccauth not issued (portal-side failure)
**Cause**: Entra sign-in succeeded but portal exchange failed.
**Possible fixes**:
- Service account missing Security Reader role → grant role
- Tenant doesn't have Defender XDR licensed → licensing issue
- Portal endpoint being hardened by Microsoft → file `portal_endpoint_broken` issue

### Sample-call returned 403 in customEvents AuthChain.* (service-account roles missing)
**Cause**: auth worked but probe endpoint returned 403.
**Possible fixes**:
- Service account needs additional role (Defender Analyst)
- Tenant has restricted access to the portal API
- Probe endpoint has been hardened; swap probe URL

## Ingestion issues

### Streams report 0 rows ingested despite Success=true
**Cause**: Endpoint returns empty response (legitimately nothing to report).
**Fix**: Normal. Config tables have 0 change = 0 new rows.

### Ingestion returns HTTP 401 from DCE
**Cause**: Function App MI doesn't have Monitoring Metrics Publisher role on the DCR.
**Fix**: check `Microsoft.Authorization/roleAssignments` scoped at the DCR resource. Re-run ARM if missing.

### Ingestion returns HTTP 403 from DCE
**Cause**: role assignment propagation (can take up to 15 min after deployment).
**Fix**: wait 15 min, or force-restart Function App.

## Workbook issues

### Workbook shows "No data for these queries"
**Cause**: ingestion not yet producing rows, or time range too narrow.
**Fix**: check `MDE_Heartbeat_CL` has entries; widen time range.

### KQL error: "Failed to resolve table or column expression named 'MDE_AdvancedFeatures_CL'"
**Cause**: custom table not yet created in Log Analytics (created by ARM deployment).
**Fix**: re-run ARM deployment to create tables. Wait up to 15 min for Log Analytics to propagate.

### Workbook parser function error: "The function 'MDE_Drift_Inventory' was not found"
**Cause**: Sentinel savedSearches not yet created (Parsers/ not deployed).
**Fix**: Deploy parsers manually via `az monitor log-analytics saved-search create` or re-run the solution deployment.

## Analytic rule issues

### Rule shows "Query failed" in Sentinel
**Cause**: Parser dependency not deployed, or syntax error in pinned KQL.
**Fix**: run the rule query in Log Analytics directly to get the error. Fix and update the YAML.

### Rule not firing despite drift events in Log Analytics
**Cause**: `queryFrequency` hasn't elapsed since deployment, or `triggerOperator`/`triggerThreshold` mismatched.
**Fix**: manually trigger the rule from Sentinel UI to verify logic.

## Connector UI issues

### Sentinel → Data Connectors doesn't show XdrLogRaider
**Cause**: the `solution-*` cross-RG nested deploy did not run (workspace permissions, race condition, or an early-rolled mainTemplate from before iteration 12). The connector appears via a `Microsoft.OperationalInsights/workspaces/providers/dataConnectors` resource of kind `GenericUI` (apiVersion `2021-03-01-preview` — canonical for community FA-based connectors per Trend Micro Vision One reference, verified in Azure-Sentinel master 2026-04-26) plus its parent `contentPackages` Solution and the `DataConnector` metadata back-link.
**Fix**:
1. Confirm the deployed `mainTemplate.json` SHA matches `raw.githubusercontent.com/akefallonitis/xdrlograider/v0.1.0-beta/...` (older versions used `kind: StaticUI` which Sentinel's UI blade indexer treats differently for non-Microsoft publishers, leaving the card hidden).
2. Run `pwsh ./tools/Validate-ArmJson.ps1` on the deployed template — it asserts the `solution-*` nested deploy is present with `kind=GenericUI` + `apiVersion=2021-03-01-preview` + `extensionResourceId()`-form metadata parentId.
3. Check the deployment history in your workspace RG for a `solution-<suffix>` deployment status. Re-run the ARM template if it's missing.
4. Verify the workspace IS Sentinel-enabled (`Microsoft.SecurityInsights/onboardingStates` exists).

### Function App in "Runtime: Error" state — no functions loaded
**Cause**: pre-iter-12 builds shipped `function-app.zip` with a `functions/` wrapper directory. Azure Functions PowerShell runtime walks the zip ROOT for function dirs containing `function.json`. With the wrapper, runtime found 0 functions → "Runtime: Error", 0 heartbeat rows, hidden connector card.
**Fix**: redeploy from `v0.1.0-beta` tag (post iter 12). The current `function-app.zip` is flat — 9 function dirs at root, no wrapper, no `local.settings.json*` stowaways. Verified by `tests/unit/FunctionAppZip.Structure.Tests.ps1` (Pester gate) + `release.yml` post-build assertion.

### Connector card shows "Not connected"
**Cause**: `MDE_Heartbeat_CL` has no rows in the last hour.
**Fix**: check Function App is running; check self-test has passed.

### Sentinel Content Hub shows "DEPRECATED" tag on XdrLogRaider — duplicate entries visible
**Cause**: Sentinel `contentPackages` resources live in the WORKSPACE RG, not the connector RG. Deleting the connector RG (`xdrlograider`) does NOT remove the workspace-side Solution; it persists. If a previous iteration deployed with a different `contentId` (e.g., iter-11 used `'xdrlograider'`, iter-12+ uses `'community.xdrlograider'`), BOTH packages persist in Content Hub. Sentinel auto-flags duplicate-displayName solutions as DEPRECATED to nudge cleanup.

**Per Microsoft official docs** ([Sentinel Solution lifecycle](https://learn.microsoft.com/en-us/azure/sentinel/sentinel-solution-deprecation)):
> "Solutions marked as DEPRECATED are no longer supported by their respective providers."

The tag normally comes from the publisher (manual via Marketplace) OR from Microsoft Content Hub auto-scanning. For our case it's the auto-scan triggered by duplicate displayNames + missing canonical fields.

**Fix (manual cleanup before redeploy)**:

```powershell
# 1. List ALL XdrLogRaider Solution packages in the workspace
$ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName <workspace-rg> -Name <workspace-name>
$token = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
if ($token -is [System.Security.SecureString]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
$headers = @{ Authorization = "Bearer $token" }

$packagesUri = "https://management.azure.com$($ws.ResourceId)/providers/Microsoft.SecurityInsights/contentPackages?api-version=2023-04-01-preview"
$pkgs = Invoke-RestMethod -Uri $packagesUri -Headers $headers -Method Get
$pkgs.value | Where-Object { $_.properties.displayName -eq 'XdrLogRaider' } |
    Select-Object @{n='Id';e={$_.name}}, @{n='ContentId';e={$_.properties.contentId}}, @{n='Version';e={$_.properties.version}}

# 2. Delete each old package (and its associated metadata, dataConnectors, content)
foreach ($p in @('xdrlograider', 'community.xdrlograider', '<other-stale-id>')) {
    $delUri = "https://management.azure.com$($ws.ResourceId)/providers/Microsoft.SecurityInsights/contentPackages/$p`?api-version=2023-04-01-preview"
    Invoke-RestMethod -Uri $delUri -Headers $headers -Method Delete -ErrorAction SilentlyContinue
}

# 3. Also delete the corresponding dataConnectors + metadata back-links
$dcUri = "https://management.azure.com$($ws.ResourceId)/providers/Microsoft.SecurityInsights/dataConnectors/XdrLogRaiderInternal?api-version=2021-03-01-preview"
Invoke-RestMethod -Uri $dcUri -Headers $headers -Method Delete -ErrorAction SilentlyContinue
```

**Or (UI cleanup — slower but safer)**:

1. Sentinel → Content Hub → search "XdrLogRaider" → ALL matching entries
2. For each: Manage → Uninstall (Microsoft's UI handles cascade delete of metadata)
3. Wait 2-3 min for indexer to settle

**Then redeploy from `v0.1.0-beta` tag** — iter-13+ now ships canonical fields (`description` plain text, `categories.verticals`, `isPreview`/`isNew`), preventing the DEPRECATED auto-tag on fresh installs. Iter-13 also locks `contentId='community.xdrlograider'` (qualified) so future version bumps won't create displayName-collision duplicates.

**Permanent prevention** (iter 13 hardening):
- New `tools/Validate-ArmJson.ps1` gate: `description` (plain text) MUST be present + `categories.verticals` MUST be defined
- `contentId` is now stable (`community.xdrlograider`) — won't change between v0.1.0-beta → v0.1.0 GA → v1.0.0
- `docs/UPGRADE.md` documents the cleanup-before-rename procedure for any future displayName / contentId changes

## Cost issues

### Ingestion costs higher than expected
**Cause**: high-volume stream (commonly `MDE_DataExportSettings_CL` for tenants with many export configs, `MDE_XspmAttackPaths_CL` for wide attack surface).
**Fix**: increase cadence for that stream; see [COST.md](COST.md).

### Function App execution count spiked
**Cause**: Stuck timer keeps retrying.
**Fix**: check App Insights → Failures. If a specific endpoint is 100%-failing, disable that stream in the tier poller pending investigation.

## App Insights structured logging

The connector emits structured `customEvents` for the auth chain and per-stream poll. Use these when `AppExceptions` / `AppTraces` doesn't surface enough context.

### "Auth fails but I can't see why in App Insights"
**Cause**: structured event missing — earlier deployments emitted `Write-Warning` strings without structured fields.
**Fix**: query `customEvents | where name == 'AuthChain.AADSTSError'` — every AADSTS-coded throw emits a structured event with `AADSTSCode`, `Method`, `Upn`, `Stage`, and `Message` in `customDimensions` BEFORE rethrowing.

```kql
customEvents
| where timestamp > ago(24h) and name == 'AuthChain.AADSTSError'
| project timestamp, AADSTSCode = tostring(customDimensions.AADSTSCode), Method = tostring(customDimensions.Method), Stage = tostring(customDimensions.Stage)
```

### "Operations look disconnected — I can't trace one auth attempt end-to-end"
**Cause**: `operation_Id` not propagated by an older build.
**Fix**: every Connect-DefenderPortal invocation generates a `CorrelationId` GUID stamped on the session and reused by Invoke-DefenderPortalRequest + Invoke-MDETierPoll. Filter `customEvents` and `traces` on `operation_Id == '<guid>'` for end-to-end stitching.

### "AuthChain.AADSTSError or RateLimited events are missing from KQL"
**Cause**: AI adaptive sampling is dropping events under load (default 5 events/sec/instance).
**Fix**: redeploy from a current build — `APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES = AuthChain.AADSTSError;AuthChain.RateLimited;AuthChain.BoundaryMarker` is in the FA appSettings. Verify via Portal → Function App → Configuration.

### "Send-XdrAppInsights* not exporting / unit tests fail"
**Cause**: `Xdr.Sentinel.Ingest.psd1` `FunctionsToExport` must list all 4 entry points; `Xdr.Sentinel.Ingest.psm1` exports them via the manifest's list (the bundle file `Send-XdrAppInsightsEvent.ps1` contains all 4).
**Fix**: re-run `./tests/Run-Tests.ps1 -Category all-offline` and check the `Logging.iter14.Tests.ps1` suite output.

### "Secret leaked into App Insights customDimensions"
**Cause**: caller passed a key in `-Properties` that matches `password|totpBase32|sccauth|xsrfToken|passkey|privateKey` (case-insensitive) but redaction failed.
**Fix**: redaction is in `ConvertTo-XdrAiSafeProperties` (private helper). Test gate `Logging.NoSecretsLeaked` covers all 6 keys; if a new secret type appears, ADD it to `$script:XdrAiSecretKeyPattern` in `Send-XdrAppInsightsEvent.ps1` AND extend the test.

## Getting help

1. Search existing issues on the repo
2. File a `bug_report` with tenant-redacted logs
3. For portal endpoint hardening: file `portal_endpoint_broken`
4. For security vulnerabilities: GitHub Security Advisories (see SECURITY.md)
