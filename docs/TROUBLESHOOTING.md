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
**Cause**: module dependencies installing from `requirements.psd1` on cold start.
**Fix**: wait ~10 minutes. Check Function App → Monitor → Invocations. If still stuck, restart the Function App.

### Function App fails at cold start with "profile.ps1 FATAL — missing required environment variable(s)"
**Cause**: one or more of the 8 app settings the FA needs (`KEY_VAULT_URI`, `DCE_ENDPOINT`, etc.) has been deleted or mutated manually.
**Fix**: redeploy the ARM template (it re-sets all 8 app settings). If you just want to patch, go to Portal → Function App → Configuration → Application settings and re-add the missing key. The error message names the exact variable. See [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure) for related diagnosis.

## Auth chain issues

See also: [RUNBOOK.md § Auth self-test failure](RUNBOOK.md#auth-self-test-failure) for the full per-stage diagnostic table.

### MDE_AuthTestResult_CL shows Stage=ests-cookie, Success=false
**Cause**: login.microsoftonline.com failed.
**Possible fixes**:
- Password expired → reset + re-upload
- TOTP secret wrong → re-enroll authenticator + re-upload
- Conditional Access blocked sign-in → check Entra sign-in logs, add named-location exception
- Account locked → unlock in Entra

### MDE_AuthTestResult_CL shows Stage=sccauth-exchange, Success=false
**Cause**: Entra sign-in succeeded but portal exchange failed.
**Possible fixes**:
- Service account missing Security Reader role → grant role
- Tenant doesn't have Defender XDR licensed → licensing issue
- Portal endpoint being hardened by Microsoft → file `portal_endpoint_broken` issue

### MDE_AuthTestResult_CL shows Stage=sample-call, SampleCallHttpCode=403
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

### Workbook parser function error: "The function 'MDE_Drift_P0Compliance' was not found"
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
**Cause**: the `solution-*` cross-RG nested deploy did not run (workspace permissions, race condition, or an early-rolled mainTemplate from before iteration 5). The connector appears via a `Microsoft.OperationalInsights/workspaces/providers/dataConnectors` resource of kind `StaticUI` plus its parent `contentPackages` Solution and the two `metadata` back-links.
**Fix**:
1. Confirm the deployed `mainTemplate.json` SHA matches `raw.githubusercontent.com/akefallonitis/xdrlograider/v0.1.0-beta/...` (older versions hand-flattened the bicep and dropped the data-connector module entirely).
2. Run `pwsh ./tools/Validate-ArmJson.ps1` on the deployed template — it asserts the `solution-*` nested deploy is present with all 4 inner resources.
3. Check the deployment history in your workspace RG for a `solution-<suffix>` deployment status. Re-run the ARM template if it's missing.
4. Verify the workspace IS Sentinel-enabled (`Microsoft.SecurityInsights/onboardingStates` exists).

### Connector card shows "Not connected"
**Cause**: `MDE_Heartbeat_CL` has no rows in the last hour.
**Fix**: check Function App is running; check self-test has passed.

## Cost issues

### Ingestion costs higher than expected
**Cause**: high-volume stream (commonly `MDE_DataExportSettings_CL` for tenants with many export configs, `MDE_XspmAttackPaths_CL` for wide attack surface).
**Fix**: increase cadence for that stream; see [COST.md](COST.md).

### Function App execution count spiked
**Cause**: Stuck timer keeps retrying.
**Fix**: check App Insights → Failures. If a specific endpoint is 100%-failing, disable that stream in the tier poller pending investigation.

## Getting help

1. Search existing issues on the repo
2. File a `bug_report` with tenant-redacted logs
3. For portal endpoint hardening: file `portal_endpoint_broken`
4. For security vulnerabilities: GitHub Security Advisories (see SECURITY.md)
