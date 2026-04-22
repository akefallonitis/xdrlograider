# Operator runbook

Daily, weekly, and quarterly operational tasks for XdrLogRaider.

## Daily (2 min)

```kql
// Is the connector alive?
MDE_Heartbeat_CL
| where TimeGenerated > ago(1h)
| summarize LastSeen = max(TimeGenerated) by FunctionName
| extend AgeMinutes = datetime_diff("minute", now(), LastSeen)

// Is auth healthy?
MDE_AuthTestResult_CL
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Success, Stage, FailureReason

// Any P0 streams failing silently?
MDE_Heartbeat_CL
| where TimeGenerated > ago(2h) and Tier == 'P0'
| summarize Success = max(StreamsSucceeded), Attempted = max(StreamsAttempted) by FunctionName
| where Success < Attempted
```

## Weekly (10 min)

- Review `MDE_Drift_P0Compliance(7d, 1h)` — any unexpected changes?
- Review `sentinel/analytic-rules/*` firings — tune false positives
- Check Azure cost report for XdrLogRaider RG — any spikes?
- Verify service account hasn't been modified: `MDE_Drift_P2Governance(7d, 1d) | where EntityId contains service-account-upn`

## Monthly

- Run `./tests/Run-Tests.ps1 -Category local-online` to verify auth chain still works
- Review CHANGELOG.md for upstream fixes — upgrade if behind
- Rotate service account password (if using Credentials+TOTP) and re-run `Initialize-XdrLogRaiderAuth.ps1`

## Quarterly

- Review service account RBAC (still minimum necessary?)
- Review Key Vault access logs (only Function App MI accessing secrets?)
- Review named-location CA exception (if applicable) still scoped correctly
- Verify Function App is on a supported PowerShell version
- Regenerate software passkey if approaching registration anniversary (organizational policy)

## Incident response

### Auth chain broken (MDE_AuthTestResult_CL shows Success=false)

1. Identify failure stage: `ests-cookie` = sign-in issue; `sccauth-exchange` = portal access issue; `sample-call` = permissions/403
2. Check Entra sign-in logs for the service account — is there a CA block?
3. Reset service account password if expired; re-run helper
4. If passkey: verify credential is still registered in Entra security info
5. If persistent, check [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

### Specific stream endpoint broken (Microsoft hardened it)

1. Identify via `MDE_Heartbeat_CL | extend e = tostring(parse_json(Notes).errors) | where isnotempty(e)`
2. File `portal_endpoint_broken` issue with repo — see template
3. Workaround: remove the broken stream from the tier poller temporarily
4. Wait for release with fix / removal

### Ingestion cost spike

1. `Usage | where DataType startswith "MDE_" | summarize GBs = sum(Quantity) / 1000 by DataType | order by GBs desc`
2. Identify the noisy stream
3. Increase `cadence` parameter for that stream in the ARM / Bicep, redeploy
4. Consider adding hash-based dedupe in the endpoint wrapper

### Service account compromised

1. Disable the service account in Entra
2. Revoke all active sessions: `Revoke-MgUserSignInSession`
3. Purge Key Vault secrets: `Remove-AzKeyVaultSecret`
4. Create new service account + creds + passkey
5. Re-run `Initialize-XdrLogRaiderAuth.ps1`
6. Review `MDE_Drift_*` for the period of compromise — look for policy changes made by the compromised account

## Contact

- Repo: https://github.com/akefallonitis/xdrlograider
- Issues: use the templates (`bug_report`, `portal_endpoint_broken`, `new_stream_request`, `feature_request`)
- Security: private disclosure via GitHub Security Advisories (see SECURITY.md)
