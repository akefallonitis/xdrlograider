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

### Auth self-test failure (MDE_AuthTestResult_CL.Success=false)

**Symptom**: most recent row of `MDE_AuthTestResult_CL` shows `Success=false`. All tier pollers refuse to run (they gate on the flag) so nothing ingests until this resolves.

```kql
MDE_AuthTestResult_CL
| order by TimeGenerated desc
| take 1
| project TimeGenerated, Success, Stage, FailureReason, SampleCallHttpCode
```

**Diagnose by `Stage`**:

| Stage | Most likely cause | First action |
|---|---|---|
| `credentials` | KV read failed | Check FA's MI has `Key Vault Secrets User`; verify secrets exist (`mde-portal-upn`, `mde-portal-password`, `mde-portal-totp` OR `mde-portal-passkey`) |
| `ests-cookie` | Entra sign-in blocked | Check Entra sign-in logs for the service account — look for Conditional Access deny, password expired, or MFA enrolment lapse |
| `sccauth-exchange` | Portal rejected ESTS cookie | Service account lacks portal access — verify Defender RBAC role (`Defender XDR Analyst` or equivalent read role) |
| `sample-call` | HTTP 401/403 on sample endpoint | Service account roles missing — verify both `Security Reader` (Entra) + Defender RBAC are assigned |
| `complete` with `Success=false` | Sample call returned non-200 | Check `SampleCallHttpCode` — 429 = throttled (wait); 5xx = Microsoft transient; 403 = permissions |

**Resolution paths**:
1. **Password expired**: reset in Entra → re-run `Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName <name>`
2. **TOTP seed rotated**: re-enrol at `mysignins.microsoft.com` → re-run helper
3. **Passkey revoked**: re-register → re-run helper
4. **CA policy blocks the SP**: add the service account to the CA exclusion list OR register a named location exception
5. **Never resolves**: follow [TROUBLESHOOTING.md](TROUBLESHOOTING.md) + file a `bug_report` issue

Until fixed, **no data flows** — the auth-selftest gate is intentional (see `docs/ARCHITECTURE.md`), preventing 401 storms on misconfigured auth.

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
