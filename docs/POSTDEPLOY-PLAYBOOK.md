# Post-deployment playbook

**Pre-req**: you've run `pwsh ./tools/Prove-EndToEnd.ps1 -Skip 'deploy,postdeploy'` and Phase 1 (offline) + Phase 2 (pre-deploy live) are both green. If either failed, don't deploy yet.

This playbook covers every concrete check you run **AFTER** clicking Deploy-to-Azure, in order. Each step has an explicit success criterion + what-to-do-if-it-fails.

---

## Step 0 — Click Deploy-to-Azure (≈ 5 min wall clock)

1. Open your target subscription in a tenant where the service account (created per `docs/GETTING-AUTH-MATERIAL.md`) exists and is enrolled.
2. Click the **Deploy to Azure** badge in the README, or run:
   ```powershell
   az deployment group create `
       --resource-group xdrlr-prod-rg `
       --template-file deploy/compiled/mainTemplate.json `
       --parameters deploy/compiled/mainTemplate.parameters.json
   ```
3. Fill in the wizard:
   - **Project prefix**: e.g. `xdrlr`
   - **Workspace RG / name**: existing Sentinel workspace (cross-RG writes supported)
   - **Auth method**: CredentialsTotp (v1.0 default) or Passkey
   - **Service account UPN**: the enrolled svc account
   - **Runtime location**: same as workspace (avoid cross-region egress)
4. Wait for green checkmark — typically 3–5 minutes.

**Success**: ARM deployment reports `Succeeded`. Resources created: Function App + plan + Key Vault + Storage + DCE + DCR + App Insights + role assignments.

**If it fails**:
- `AuthorizationFailed` → deployer identity needs Owner (or Contributor + User Access Administrator) on the connector RG, plus Log Analytics Contributor + Microsoft Sentinel Contributor on the workspace RG. See `docs/PERMISSIONS.md`.
- `Workspace not found` → you're targeting the wrong workspace RG; re-run with correct names.
- `Key Vault name already exists` → tweak the project prefix; names are globally unique.

---

## Step 1 — Upload auth material into Key Vault (≈ 1 min)

```powershell
Connect-AzAccount     # if not already signed in
pwsh ./tools/Initialize-XdrLogRaiderAuth.ps1 `
    -KeyVaultName  <deployed-kv-name>      `
    -AuthMethod    CredentialsTotp         `
    -Upn           svc-xdrlr@contoso.com   `
    -Password      (Read-Host -AsSecureString) `
    -TotpBase32    'YOUR-BASE32-SEED'
```

**Success**: script prints `Secret 'mde-portal-auth-v1' created` + a test retrieval works.

**If it fails**:
- `Forbidden 403` on Key Vault → your signed-in identity doesn't have `Key Vault Secrets Officer` on the deployed KV. Owner on the RG inherits this.
- `Invalid UPN format` → use full `name@tenant.com`, not alias only.
- `TOTP seed failed validation` → `docs/GETTING-AUTH-MATERIAL.md` Step 2 — the seed is usually a 16 or 32 char base32 string without spaces.

---

## Step 2 — Wait for first timer cycle (~15 minutes)

The `validate-auth-selftest` timer fires at :05/:20/:35/:50 past the hour. Once it produces a green flag in the checkpoint table, the other timers un-gate.

**Success check** (run after 20 min):
```powershell
# 2a. Function App status
az functionapp show --name <fa-name> --resource-group xdrlr-prod-rg --query state
# Expect: "Running"

# 2b. Auth self-test flag in storage
$sa = az storage account show --name <storage-name> --resource-group xdrlr-prod-rg --query name -o tsv
az storage entity show `
    --table-name connectorCheckpoints `
    --partition-key auth-selftest `
    --row-key latest `
    --account-name $sa `
    --auth-mode login
# Expect: Success=true row with recent Timestamp
```

**If no flag after 30 min**:
- Check Function App logs in Azure Portal → Functions → `validate-auth-selftest` → Monitor → invocations.
- Common failure: AADSTS error in the stack trace → credentials wrong, TOTP seed wrong, or MFA not registered on the service account.
- Run locally for fast feedback:
  ```powershell
  $env:XDRLR_ONLINE = 'true'
  pwsh ./tests/Run-Tests.ps1 -Category local-online
  ```
  If this passes locally but the FA fails, it's an Azure-side issue (KV access, MI role, DCE reachability).

---

## Step 3 — Verify ingestion started (≈ 15 more minutes)

After Step 2 + one more hour (for the `poll-p0-compliance-1h` timer to fire), run:

```powershell
$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_RG = 'xdrlr-prod-rg'
$env:XDRLR_TEST_WORKSPACE = '<your-workspace>'
pwsh ./tests/Run-Tests.ps1 -Category e2e
```

**Success**: every assertion green:
- `resource group contains Function App / Key Vault / DCE / DCR / Storage` ✓
- `MDE_Heartbeat_CL has rows in the last hour` ✓
- `MDE_AuthTestResult_CL shows latest Success=true` ✓
- `MDE_AdvancedFeatures_CL has at least one row` ✓
- `at least 3 P0 streams have ingested rows` ✓
- per-tier coverage asserted ✓
- `No repeated auth failures in Application Insights traces (last 1h)` ✓
- `parser functions / hunting queries / workbook` all deployed ✓

**If per-tier test shows fewer populated streams than expected**:
- **Expected baseline**: 25 of 45 streams populate immediately (validated by pre-deploy audit). 10 streams are marked `Deferred=true` in the manifest because their paths/body schemas are still under research — they will NOT emit rows until the manifest is updated in a follow-up commit.
- **To see which are deferred**: `pwsh -c "(Get-MDEEndpointManifest).Values | Where { `$_.Deferred } | Select Stream, DeferReason"`
- **To poll them anyway for research**: `Invoke-MDETierPoll -IncludeDeferred` (not used by timer functions).

---

## Step 4 — Watch the first 24 hours

For the first day, monitor these KQL queries in the workspace (paste into Log Analytics):

### 4a. Heartbeat health
```kql
MDE_Heartbeat_CL
| where TimeGenerated > ago(2h)
| summarize PerTier = makeset(Tier), Runs = count() by FunctionName, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```
**Expect**: 9 function names present (heartbeat-5m, validate-auth-selftest, 7× poll-p*). Each poll-p* should appear at its scheduled cadence.

### 4b. Auth health
```kql
MDE_AuthTestResult_CL
| where TimeGenerated > ago(24h)
| summarize Successes = countif(Success == true), Failures = countif(Success == false) by bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```
**Expect**: Successes > 0, Failures = 0 most hours. Occasional single-hour failure is OK (TOTP timing race); sustained failures are not.

### 4c. Per-stream ingestion counts
```kql
union isfuzzy=true MDE_*_CL
| where TimeGenerated > ago(24h)
| summarize Rows = count() by $table
| order by Rows desc
```
**Expect**: ~25 populated tables. Zero-row tables are either deferred (expected) or disabled features on your tenant.

### 4d. Function errors
```kql
FunctionAppLogs
| where TimeGenerated > ago(24h)
| where Level == "Error"
| summarize count() by Message
| order by count_ desc
| take 20
```
**Expect**: empty or only `per-stream failure isolation` warnings (benign). Any AADSTS9000410 / AADSTS50126 / "sccauth not issued" → stop; fix before continuing.

---

## Step 5 — Lock it in (when confident)

After 48 hours of green heartbeats + stable ingestion:

1. **Enable analytic rules** in Sentinel. The solution ships them disabled. Open each rule in `Microsoft Sentinel → Analytics → Active rules` and toggle Enabled.
2. **Pin the dashboards** (`MDE Compliance Dashboard`, `MDE Exposure Dashboard`, `MDE Audit Dashboard`) to your Sentinel workspace.
3. **Set up alerting** on heartbeat staleness:
   ```kql
   MDE_Heartbeat_CL
   | where TimeGenerated > ago(2h)
   | summarize LastSeen = max(TimeGenerated) by FunctionName
   | where LastSeen < ago(1h)
   ```
   → analytic rule with 1-hour scheduled frequency, alerts if any function stops emitting.
4. **Set up rotation reminders** per `docs/PERMISSIONS.md` Rotation table:
   - Service account password (per your org policy) — re-run `Initialize-XdrLogRaiderAuth.ps1` after each change.
   - TOTP seed (rare) — only if you re-enrol in Authenticator.

---

## Ongoing: iterate on the 27 deferred streams

The manifest ships with 25 verified streams + 27 marked for follow-up. To enable one:

1. Identify which path / body shape is needed — use `tests/integration/Audit-Endpoints-Live.ps1` to probe manually, or capture a browser HAR and inspect.
2. Edit `src/Modules/XdrLogRaider.Client/endpoints.manifest.psd1` — remove `Deferred = $true` (and adjust `Path`/`Method`/`Body` if needed).
3. Run `pwsh ./tools/Build-SentinelContent.ps1` to refresh compiled ARM.
4. Run `pwsh ./tests/Run-Tests.ps1 -Category all-offline` — tests catch drift automatically.
5. Push + rebuild artefacts:
   ```powershell
   pwsh ./tools/Build-SentinelSolution.ps1 -Version 1.0.2
   git tag v1.0.2 && git push --tags
   ```
6. Either re-deploy or use zip-deploy to push the updated Function App without a full re-ARM:
   ```powershell
   az functionapp deployment source sync --name <fa-name> --resource-group xdrlr-prod-rg
   ```

---

## One-glance red flags

| Symptom | Likely cause | Fix |
|---|---|---|
| `MDE_Heartbeat_CL` empty after 30 min | FA not running / MI not granted | Check FA `state` + 3 role assignments on MI |
| `MDE_AuthTestResult_CL.Success = false` | Credentials mismatch / TOTP seed wrong | Re-run `Initialize-XdrLogRaiderAuth.ps1` with corrected values |
| Only 1-2 streams populated | Auth working but endpoints 4xx/5xx | Expected — 25/52 is today's baseline; iterate on deferred set |
| `AADSTS9000410` in logs | ProcessAuth ContentType regression | Should not happen in v1.0+ — file bug |
| `AADSTS50058` in logs | Tenant rejects the ESTS cookie (rare) | Add service account to a CA policy exemption for named location |
| HTTP 440 storms in logs | Auto-reauth loop broken | Should not happen in v1.0+ — verify `Invoke-MDEPortalRequest` patch applied |
| `Row exceeds 900 KB` warning | Single row hit DCE size limit | Benign; row skipped, logged. Investigate if it's a specific stream always hitting this |

---

## The single-command post-deploy proof

```powershell
$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_RG = 'xdrlr-prod-rg'
$env:XDRLR_TEST_WORKSPACE = 'your-workspace'
pwsh ./tools/Prove-EndToEnd.ps1 -Skip 'offline,predeploy,deploy'
```

Runs Phase 4 only. Green → you're good. Red → the specific assertion tells you which health check failed + what to check.
