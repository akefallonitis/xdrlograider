# Runbook · Troubleshooting + KQL pack

First move is always the tool, not ad-hoc queries: `tools/Verify-DeployedConnector.ps1 -AllOps` runs the 12
postdeploy dimensions (D0 module-load → D12 V3 surface) with the correct windows and verdicts. This runbook is
for drilling into what the tool flags. All queries run against the **App Insights component** (`xdrlr-ai-*`),
workspace-mode table names (`AppTraces` / `AppEvents` / `AppExceptions`) — the same names the tool uses.

## The signal model (what writes what)
- **Host pipeline (always reliable):** every `Write-Host` lands in `AppTraces`. Load-bearing host lines:
  `[XdrDefenderRefresh] Cycle started`, `[cycle] Cycle.Completed`, `[XdrDefenderActivity] Started/Completed`,
  `[Entry.Poll.Exception] …` (full message + position + stack), `[Capability.OpUnavailable] …`, `Boot.VersionProbe`.
- **Custom events (`AppEvents`, scrubbed):** `Entry.Poll.Started/Succeeded/Failed`, `Entry.Poll.BoundaryDeduped`,
  `Entry.Poll.CycleBudgetReached`, `Capability.OpUnavailable`, `Breaker.Opened/Closed`, `Checkpoint.Reset`,
  `Auth.Reauth.Triggered/Succeeded`, `Defender.Auth.T2.Succeeded`, `Defender.Auth.T3.Started/Succeeded`,
  `DCE.Ingest.Chunked`, `Ingest.RowClamped`, `Ingest.Dlq.Queued`, `Cycle.ActivityCapped`, heartbeats.
  The telemetry secret-scrubber redacts sccauth/cookie/xsrf/token/seed/kmsi/… keys before send.
- **Exceptions (`AppExceptions`):** typed portal exceptions. Classification (from `Invoke-XdrPortalHttp`):
  401/440 → `AuthChainBroken` (self-heals, should NOT persist) · 403/404 + 400-InvalidProxyPrefix → capability
  posture (NOT errors) · other 4xx → `XdrPortalTerminalException` (DLQ + breaker) · 429/5xx/transport →
  `XdrPortalTransientException` (retried, Retry-After honored).

## Drill-downs
**Is the deployed build current?**
```kusto
AppEvents | where Name == 'Boot.VersionProbe' | top 1 by TimeGenerated
| project TimeGenerated, GitCommit = tostring(Properties.GitCommit)
```
Compare with `git rev-parse HEAD` — or just run `tools/Verify-DeployedVersion.ps1` (exit 2 = drift).

**Why did an op land 0 rows?** In order:
1. Posture? `AppEvents | where Name == 'Capability.OpUnavailable' | summarize count() by tostring(Properties.OperationKey)` —
   posture is correct behavior on tenants lacking the product (fail-open by design); not a bug.
2. Cadence gate? `AppEvents | where Name == 'Entry.CadenceNotDue.Skipped'` — op not due yet.
3. Poll failed? `AppEvents | where Name == 'Entry.Poll.Failed' | project TimeGenerated, Properties` — carries
   StatusCode + ResponseBody clip; cross-read the `[Entry.Poll.Exception]` AppTraces line for the stack.
4. Rows landed but columns empty? **Schema drop.** Run `tools/Assert-LiveSchemaParity.ps1` — if live table/DCR
   columns ≠ repo schema (case-sensitive), Azure Monitor silently drops mismatched columns. Fix via the surgical
   schema path (`tools/Onboard-CategorySurgical.ps1 -Apply`), never a full redeploy.

**Auth health (steady state = T1 cache + rare T2; TOTP only at KMSI expiry ~90d):**
```kusto
AppEvents | where Name in ('Auth.Reauth.Triggered','Defender.Auth.T2.Succeeded','Defender.Auth.T3.Started')
| summarize count() by Name, bin(TimeGenerated, 1h)
```
Persistent `T3.Started` = KMSI not surviving (check KV `TotpSecret`, account MFA state). Persistent
`Auth.Reauth.Triggered` without `T2.Succeeded` = portal rejecting the re-mint → read the Step1-8 AppTraces
markers (`[Defender.Auth.StepN]`) for the breaking stage.

**Duplication check (the done-bar invariant):**
```kusto
Defender_<Category>_CL | summarize rows=count(), keys=dcount(ActionId) // CURSOR ops: rows == keys
```
SNAPSHOT ops re-land the full set each cadence by design — judge per-poll, not cross-cycle.

## Exactly-once known limitations (audit 2026-06-12 · bounded · GA hardening for high-churn expansion ops)
Client-side exactly-once (high-water + boundary natural-keys + EO2 intra-cycle dedup) is sound for the pilot.
Four bounded edges remain, all near-zero probability on a static/low-churn op (e.g. Action Center history) and
all caught by the postdeploy `count==dcount` gate — fix them before onboarding a HIGH-CHURN CURSOR op:
- **B3/EO4 (pageIndex paging under mutation):** a CURSOR op draining >250 pages in ONE multi-cycle drain while
  rows arrive/are deleted mid-drain can re-serve or skip a row across the resume boundary (descending pageIndex
  shifts as page-1 grows). Also surfaces as a TotalCountPath premature stop if the server Count moves mid-drain.
  **Fix:** cursor-/keyset-based pagination (page by `cursor < lastSeen`) instead of page index — immune to insertion.
- **EO5 (incomplete NaturalKey):** a boundary row whose composite key has a null component (`''`) cannot be
  deduped and may re-ingest. **Fixed (2026-06-18):** the runtime now derives a content-hash RecordId from RawJson
  (`$script:XdrContentHash`) for any op with no proven NaturalKey, so a keyless re-ingest dedups by content and the
  verifier's ExactlyOnce gate blocks on that RecordId per-cycle. (Pilot ops carry their own key, e.g. `ActionId`.)
- **EO6 (future-dated cursor):** a clock-skew/poison row with a cursor far in the future would advance the
  frontier past `now` and silently drop legit rows until wall-clock catches up. **Fix:** clamp the frontier max to
  `now()+skew`. (Pilot cursor fields are historical event times, so this cannot occur today.)
Detect any real occurrence: `Defender_<Category>_CL | summarize n=count(), d=dcount(RecordId) by Operation`
— a CURSOR op with `n != d` is a duplication signal; investigate against these four causes.

## Auth resilience — the KMSI-transparent self-heal (live-verified 2026-06-12)
A 90-day `ESTSAUTHPERSISTENT` (KMSI) cookie makes the short-lived `sccauth` almost incidental: if `sccauth`
goes bad, the portal's own SSO re-issues a fresh one server-side on the next `/apiproxy` call — the client
never sees a 401/440, so `Auth.Reauth.Triggered` does NOT fire and **no TOTP is burned**. Verified by injecting
a sentinel `sccauth` into the live `XdrTierState` row: the FA kept ingesting (Discovery/TenantContext/GetHistory
all 200) with **zero TOTP** while the cached `sccauth` was provably garbage.
- **Consequence for the Reauth gate:** it stays INCONCLUSIVE on a healthy tenant — the reactive-440 path is a
  *fallback* for when KMSI ITSELF dies, and you cannot force it without also killing KMSI (→ T3 + TOTP). That
  is correct, honest behaviour, not a gap. T2/T3 fire only on genuine KMSI expiry (~90d) or its KV-secret loss.
- **`Force-XdrAuthLoss` write-back race:** corrupting the L2 row against a RUNNING app can be erased by the
  app's in-memory→L2 write-through before any read. To force a real auth-loss deterministically, run
  STOP → `-Mode Invalidate` (while stopped) → START. Even then, healthy KMSI may absorb it transparently.

**DLQ:** `AppEvents | where Name == 'Ingest.Dlq.Queued'` then the dlq-drain runbook. **Breaker:**
`AppEvents | where Name == 'Breaker.Opened'` — opens after 5 consecutive failures, half-opens after 15 min;
a breaker that re-opens repeatedly means a terminal contract error → fix at the source, never throttle.

**Cycle liveness:** `AppTraces | where Message startswith '[cycle] Cycle.Completed'` — present every timer tick.
Absent + no `Cycle started` = host down (check FA state); `Cycle started` without `Cycle.Completed` = orchestration
fault → search `OrchestrationFailureException` in AppExceptions and the RAW-INPUT diagnostic lines.
