# Contributor Onboarding (1-day ramp-up)

Welcome! This guide gets you from `git clone` to **first PR-ready commit** in a single day.

## Day 1 — Local environment setup (~1 hour)

### Prerequisites
- PowerShell 7.4+ (`pwsh --version`)
- Az PowerShell modules (`Az.Accounts`, `Az.Resources`, `Az.OperationalInsights`, `Az.KeyVault`, `Az.Storage`)
- Pester 5.7.1+ (`Install-Module Pester -MinimumVersion 5.7.1`)
- PSScriptAnalyzer (`Install-Module PSScriptAnalyzer`)
- `gh` CLI authenticated (`gh auth status`)

### Clone + install hooks
```pwsh
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider

# CRITICAL: install pre-commit hook (chains 6 stages mirroring CI)
pwsh tools/Install-GitHooks.ps1
```

The pre-commit hook chains:
1. **Pyramid** — full Pester offline test suite (~6-8 min; 187+ tests / 0 fail at v0.1.0 GA baseline)
2. **WiringAudit** — 12-edge × 72 streams manifest→DCR→table→pipeline connectivity
3. **Validate-ArmJson** — ARM semantic validation (cross-RG dependsOn, parameter usage)
4. **Validate-Manifest** — schema + uniqueness gates
5. **Audit-DcrSchema** — 4-layer DCR integrity
6. **PSScriptAnalyzer** — Errors-only across `src/` + `tools/` + `tests/`

## Day 1 — Run the full local gauntlet (~10 min)

```pwsh
# Pyramid (offline tests; ~6-8 min)
pwsh tests/Run-Tests.ps1 -Category all-offline

# Pre-Commit-Check (chains all 6 stages above; ~6-10 min)
pwsh tools/Pre-Commit-Check.ps1

# Optional: ARM what-if (requires SP creds in tests/.env.local)
pwsh tests/Run-Tests.ps1 -Category whatif
```

**Expected**: all green. If any fail, first install missing PowerShell modules, then re-run.

## Day 1 — Understand the architecture (~30 min)

Read in order:
1. `README.md` — project overview + Deploy-to-Azure UX
2. `docs/ARCHITECTURE.md` — 4-function topology + 13 DCRs + 5 cadence tiers + canonical Schema Unification
3. `docs/STREAMS.md` — 72-stream catalog (per-tier + per-category)
4. `docs/SCHEMAS.md` — canonical Sentinel Entity Type contract (cross-table + cross-portal correlation)
5. `docs/RUNBOOK.md` — operator playbook (6 procedures)

## Day 1 — Pick your first contribution (~4 hours)

Recommended starter PRs:

### Easy (~30 min)
- Doc typo fix
- Add a new sample query to `docs/QUERIES.md` (operator KQL cookbook)
- Add a comment-based help section to a tool in `tools/` that's missing one

### Medium (~2-4 hr)
- Add a new mock-based test for an uncovered code path (see `tests/results/coverage-all-offline.xml` for top missed lines)
- Fix a minor stale-claim reference flagged by `docs/V010X-PATCH-BACKLOG.md`
- Improve a workbook panel hover-text per `docs/V010X-PATCH-BACKLOG.md` v0.1.0.4

### Hard (~1+ day; coordinate with maintainer)
- Add a new Defender stream (manifest entry + DCR streamDecl + workspace col + transformKql + per-stream Pester test)
- Implement v0.1.0.5 Pester parallelism
- Implement v0.1.0.6 post-deploy-verify auto-trigger

## Day 1 — Submit your first PR

```pwsh
git checkout -b feat/your-change
# ... make changes ...
git add ...
git commit -m "feat(area): your change

Why: <reason>
What: <change>
Verify: <test>
"
# Pre-commit hook auto-runs Pre-Commit-Check chain
git push origin feat/your-change

# Open PR
gh pr create --title "..." --body "..."
```

CI runs: secret-scan → lint → unit-tests → static-validate → deploy-whatif → auto-recompile → auto-rezip → coverage → summary.

## Key files for new contributors

| File | Purpose |
|---|---|
| `src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1` | Single source of truth for all 72 streams (paths + auth + UnwrapProperty + ProjectionMap + Tier + Category) |
| `src/Modules/Xdr.Defender.Client/Endpoints/_EndpointHelpers.ps1` | `Expand-MDEResponse` + `ConvertTo-MDEIngestRow` (post Phase A: auto-discovery defensive code at L304-380) |
| `src/Modules/Xdr.Defender.Client/Public/Invoke-MDEEndpoint.ps1` | 1-cmdlet dispatcher for all 72 streams |
| `src/functions/*/run.ps1` | 4 FA functions (Connector-Heartbeat / Xdr-Refresh / Xdr-PollOrchestrator / Xdr-PollStream) |
| `tools/Pre-Commit-Check.ps1` | 6-stage local gate (mirrors CI) |
| `deploy/compiled/mainTemplate.json` | Hand-authored ARM template (NOT auto-generated; edits here = deployment changes) |
| `sentinel/parsers/MDE_Drift_*.kql` | 4 cadence-tier KQL drift parsers |

## Where to ask questions

- GitHub Issues: https://github.com/akefallonitis/xdrlograider/issues
- Operator runbook: `docs/RUNBOOK.md`
- Architecture deep-dive: `docs/ARCHITECTURE.md`
- Plan history: `.claude/plans/immutable-splashing-waffle.md` (extensive; for context on past architectural decisions)
