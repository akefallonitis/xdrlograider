# Roadmap

Forward-looking plan. Numbered milestones are gates, not dates. Each version
has a **graduation criterion** — the bar that must clear before the next
milestone starts. Shipping bar is: every endpoint reference-verified AND
live-captured 200 against a real admin account; every deployment flow
end-to-end unit-tested + offline-tested + preflight-gated; every breaking
change documented in CHANGELOG.md + UPGRADE.md.

## v0.1.0-beta (current — pending tag)

Complete-beta release. Production-hardened on all dimensions the plan scoped:

- **45 portal-only streams** (36 live-verified against full-access admin account
  on 2026-04-27 after the path-research audit corrected
  `MDE_CustomCollection_CL` /model→/rules per XDRInternals canonical source),
  8 tenant-feature-gated (MDI / MCAS / TVM / Intune AV / MDO / Custom Collection),
  1 deprecated (`MDE_StreamingApiConfig_CL` collides with `MDE_DataExportSettings_CL`).
- **Auth**: CredentialsTotp + Passkey auto-refresh for unattended production;
  DirectCookies retained as laptop-only test path (KV writer refuses cookies
  as a production secret). 429 Retry-After honoured, session TTL 3h30m.
- **DCE efficiency**: gzip compression (5-10× bandwidth), 413 split-and-retry,
  Rate429Count + GzipBytes surfaced in `MDE_Heartbeat_CL.Notes`.
- **Function App**: 9 timers consolidated via `Invoke-TierPollWithHeartbeat`
  (-315 LoC dup), App Insights sampling tuned, Az.Monitor bloat removed.
- **Content Hub compliant**: Data Connector lists all 47 tables, 14 analytic
  rules ship `enabled: false`, 9 hunting queries carry `author`/`version`/`tags`
  metadata, custom tables explicit `plan: 'Analytics'`, BUG #4 `ConfigChangesByUpn`
  join rewritten.
- **Forward-scalable**: manifest `Defaults.Portal` + timer-helper `-Portal`
  parameter so v0.2.0+ can add `admin.microsoft.com`/`entra.microsoft.com`
  portals without touching `Xdr.Portal.Auth` or `XdrLogRaider.Ingest`.
- **Test coverage**: 1063 offline pass / 0 fail / 33 skip; preflight gate
  (8 sections) returns PRE-DEPLOY READY: YES; live capture 33 `live`-tagged
  streams return 200 against admin account.

**Graduation criterion → v0.1.0 GA**: 30-day tenant soak with:
- ≥99% per-tier success for `live` streams
- `MDE_Heartbeat_CL.Notes.rate429Count = 0` in steady state
- `GzipBytes / RowsIngested < 0.2` (80% compression)
- 0 fatal heartbeats
- Auth self-test green for 30 consecutive days
- 3/3 auth methods (CredsTotp + Passkey + DirectCookies-test) live-verified once

## v0.1.0 GA (after soak)

Scope: stabilisation only. Bug fixes observed during soak. No new streams.
Sentinel Content Hub submission prep.

**Graduation criterion → v0.2.0**: clean 30-day GA soak on ≥1 tenant; no
P0/P1 bugs in backlog; README deploy-button pinned to GA tag.

## v0.2.0 — expansion + multi-portal foundation

Scope: **additive only** — no breaking changes to v0.1.0 manifest. Use the
forward-scalable `Portal=` infrastructure laid down in v0.1.0-beta.

- **+15-20 new streams** from `docs/CANDIDATE-STREAMS-V0.2.0.md` (researched
  during v0.1.0-beta development). Candidates include:
  - `MDE_XspmTopEntryPoint_CL` (XSPM atlas, scenario `AttackPathOverview_get_attack_paths_top_entry_points`)
  - `MDE_AdvancedHuntingUserHistory_CL` (auditing)
  - `MDE_DatalakeDatabase_CL` + `MDE_DatalakeTableSchema_CL`
  - `MDE_DeviceRbacGroup_CL` + `MDE_DeviceRbacGroupScope_CL`
  - `MDE_ConfigurationCriticalAsset_CL` (+ Schema)
  - `MDE_TvmRemediationTasks_CL` (proactive remediation tracking)
  - `MDE_NdrSensorConfig_CL` (Network Detection)
- **First non-security portal** (optional, depends on community interest):
  `admin.microsoft.com` for M365 tenant context — uses same `Xdr.Portal.Auth`
  chain (cookie-based), proves the `Portal=` abstraction.
- Optional Durable Functions orchestrator if 30-day GA soak surfaces cold-start
  cost as an actual problem. Default: keep 9 independent timers.
- Time-filter coverage extension: audit non-Filter entries for server-side
  date filter support once live-verified per endpoint (deferred from
  v0.1.0-beta to avoid speculative manifest changes).

**Graduation criterion → v1.0.0**:
- ≥2 external operators × 30-day tenant soak
- ≥90-day cumulative uptime across deployed instances
- 0 critical bugs
- Optional Content Hub submission accepted
- Documentation complete (UPGRADE.md covers every version jump)

## v1.0.0 — production GA

Scope: **certification only**. Microsoft Sentinel Solution submission merged
into `Azure/Azure-Sentinel/Solutions/XdrLogRaider/`. Content Hub listing live.
No functional changes from v0.2.0 except whatever the upstream Azure-Sentinel
PR review mandates.

## Future considerations (post-v1.0, not committed)

- **Additional Microsoft portals** for broader coverage. Each new portal is an
  additive manifest + new timer functions; zero changes to existing ones.
  - `entra.microsoft.com` — Entra ID tenant config + CAP analysis
  - `compliance.microsoft.com` — Purview DLP / eDiscovery config
  - `intune.microsoft.com` — Intune device/policy config (complements
    Defender-side Intune integration)
  - `admin.microsoft.com` — M365 tenant-wide config + licence posture
- **MS Graph Security API complement** — for the endpoints that DO have
  official Graph coverage, offer a Graph-backed alternative that operators
  can opt into. Not a replacement — complementary; Graph + portal give
  broader coverage together than either alone.
- **Microsoft 365 Defender Hunting API** — subscription-scoped advanced
  hunting via Graph. Orthogonal; Sentinel has a built-in connector for this
  already, but shipping our own KQL parsers aligned with the same
  `RawJson`-centric schema lets operators mix `advanced hunting` data with
  `portal-only` data in a single drift workbook.
- **Durable Functions orchestrator** — re-evaluate after production soak
  evidence. If cold-start tax is material, collapse 9 timers to 1 orchestrator
  + 7 activities. Trade-off: loses per-tier App Insights operation isolation.
- **Private endpoints** for Key Vault + Storage + DCE as a wizard toggle —
  required for regulated tenants. Optional post-GA enhancement.
- **Customer-pinned Function App package** — `WEBSITE_RUN_FROM_PACKAGE`
  currently points at GitHub releases; document + first-class support for
  pinning to a private blob (already in `docs/OPERATIONS.md`).

## Non-goals (scope guardrails across all versions)

- **Design C** DCR with typed columns. Design A (RawJson + KQL drift) is
  permanent — unofficial APIs drift; schema-lock loses rows silently.
- **MS Graph Security as primary** — XDR-only scope for the core connector.
  Graph complements but doesn't replace the portal surface area.
- **HAR capture as primary research source** — XDRInternals + nodoc +
  MDEAutomator + DefenderHarvester + live-authenticated capture together
  are sufficient. HAR is a fallback only if a future endpoint emerges that
  none of the four reference sources cover.
- **Premium FA plan as default** — Consumption Y1 stays the default.
  Elastic Premium / App Service Plan documented as opt-in for tenants with
  strict cold-start allergy.
