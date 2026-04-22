# Troubleshooting

Symptom → cause → fix for common issues.

## Deployment issues

### "Deploy to Azure" button goes to a blank page
**Cause**: the linked `mainTemplate.json` URL returned 404 or is not publicly accessible.
**Fix**: verify `deploy/compiled/mainTemplate.json` exists on the `main` branch or the pinned tag. Regenerate via the release workflow.

### ARM deployment fails at Key Vault step
**Cause**: soft-deleted Key Vault with the same name exists in the subscription.
**Fix**: `az keyvault purge --name <name> --location <region>` then redeploy.

### Function App times out during first run
**Cause**: module dependencies installing from `requirements.psd1` on cold start.
**Fix**: wait ~10 minutes. Check Function App → Monitor → Invocations. If still stuck, restart the Function App.

## Auth chain issues

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
**Cause**: `dataConnectorDefinitions` resource not deployed, or workspace is not Sentinel-enabled.
**Fix**: verify `data-connector.bicep` module ran; check Log Analytics has Microsoft Sentinel solution installed.

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
