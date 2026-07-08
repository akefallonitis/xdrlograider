# Runbook · Rollback

Scope: revert a bad code deploy or a bad category onboard on the SELF-DEPLOYED estate. Hard rules first:
**never `az group delete` · never `--no-wait` · role assignments are NEVER deleted by any rollback step ·
`Sysmon_CL` and anything not deployed by this solution is never touched.**

## 1 · Roll back the FA code package (most common)
The FA runs whatever `WEBSITE_RUN_FROM_PACKAGE` points at. `tools/Deploy-FaPackageLocal.ps1` prints the
**revert anchor** (the previous URL) before every repoint — keep that output.
- To the previous GitHub release: set `WEBSITE_RUN_FROM_PACKAGE` to the prior tag's
  `releases/download/<tag>/function-app.zip` URL, set `XDRLR_GIT_COMMIT_SHA` to that tag's SHA, then restart
  the FA **synchronously** and poll state=Running (the deploy tools do exactly this; reuse them).
- Verify: `tools/Verify-DeployedVersion.ps1` (deployed Boot.VersionProbe SHA == intended), then
  `tools/Verify-DeployedConnector.ps1` D0.

## 2 · Roll back a category onboard (table/DCR added by mistake)
ARM Incremental cannot delete. Reverse order, each step operator-confirmed:
1. Remove the FA appsetting `XDRLR_DCR_<PORTAL>_<CATEGORY>` (merge-set without it) → dispatcher G-Provisioned
   skips the category next cycle (no code change needed).
2. Optionally delete the DCR, then the table (explicit `az monitor data-collection rule delete` /
   `az monitor log-analytics workspace table delete`) — **only on explicit per-item operator word**; the
   role assignment on the DCR is left for ARM cleanup semantics (deleting the DCR orphans the scoped
   assignment harmlessly; we never delete role assignments directly).
3. Re-run `tools/Verify-DeployedConnector.ps1` + the live-estate reconcile to confirm intended state.

## 3 · Roll back a checkpoint (re-poll a window)
`tools/Save-XdrCheckpointReset.ps1` (or `Override-XdrSync.ps1 -ResetCursor`) writes the reset row
(reason-annotated, `LastUpdatedUtc` cleared → fires next cycle). Reset NEVER advances a cursor — only rewinds.
WARNING: on a non-empty table a reset re-ingests the window → duplicates unless you purge first or the
adopt-live-frontier invariant (WS4) is deployed. Purge-then-reset is the documented re-baseline procedure.

## 4 · Failed ARM deployment (nested/what-if surprises)
A Failed deployment that rolled back leaves prior state intact — confirm with
`az deployment group show -n <name>` + `tools/Assert-LiveSchemaParity.ps1` before any re-run.
`tools/Rollback-ArmDeployment.ps1` is the manual aid for inspecting/cleaning a partially-applied deployment's
resources (plan-only by default). The known failure class — `RoleAssignmentExists` rolling back a bundled
schema change — is structurally avoided by the surgical path (schema-only, role-free); if you hit it on the
one-click template, re-run after WS4's idempotent-roles hardening, never hand-delete the role.

## 5 · Secrets gone wrong
Wrong KV secret (ServicePassword/TotpSecret/PasskeyPem): set the new value in KV — the runtime reads KV via
MSI with a 30-min L1 TTL; restart the FA to force immediate pickup. Never echo values; see secret-rotation.
