# Contributing to XdrLogRaider

Thanks for your interest in contributing. This project is community-driven and open to PRs of any size from day one.

## Quick links

- [Good first issues](https://github.com/akefallonitis/xdrlograider/labels/good%20first%20issue) — curated starter tasks
- [Roadmap](docs/ROADMAP.md) — v1.1+ features open for contribution
- [References](docs/REFERENCES.md) — background reading before diving in
- [Architecture](docs/ARCHITECTURE.md) — high-level component overview

## Development setup

### Prerequisites

- PowerShell 7.4+ (Windows, Linux, or macOS)
- Azure CLI 2.50+ (for deployment testing)
- Bicep CLI (for ARM template changes)
- [Pester](https://pester.dev/) 5.0+ (`Install-Module Pester -Force -Scope CurrentUser`)
- [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) (`Install-Module PSScriptAnalyzer -Force -Scope CurrentUser`)

### Clone and bootstrap

```powershell
git clone https://github.com/akefallonitis/xdrlograider
cd xdrlograider
./tests/Run-Tests.ps1 -Category unit
```

All unit tests should pass. If not, open an issue with the failing output.

## Local test loop

```powershell
# Fast: unit tests only (<1 min, fully mocked)
./tests/Run-Tests.ps1 -Category unit

# Static validation: KQL + workbooks + ARM (<30s)
./tests/Run-Tests.ps1 -Category validate

# Everything offline (what CI runs)
./tests/Run-Tests.ps1 -Category all-offline

# Live integration (requires test tenant + env vars)
$env:XDRLR_ONLINE = 'true'
$env:XDRLR_TEST_KV = 'test-kv-name'
./tests/Run-Tests.ps1 -Category integration
```

## Coding standards

### PowerShell

- PowerShell 7+ only — no Windows PowerShell 5.1 compatibility required
- Cmdlet names use approved verbs (`Get-Verb` to check)
- Every public function has comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`)
- Use `$script:` scope for module state, never global variables
- No `Write-Host` in module code — use `Write-Verbose`, `Write-Warning`, `Write-Error`
- Structured errors: `Write-Error -ErrorRecord $_` or `throw [System.Exception]::new(...)`

### Naming

- Modules: `Xdr.Portal.Auth`, `XdrLogRaider.<Component>`
- Tables (Log Analytics): `MDE_<Category>_CL` (all portal-only telemetry)
- Heartbeat/diagnostic tables: `MDE_Heartbeat_CL`, `MDE_AuthTestResult_CL`
- KQL parsers (functions): `MDE_Drift_P<N><Category>`
- Workbooks: `MDE_<Purpose>Dashboard.json`
- Analytic rules: `MDE_<Event>_Detection.json`

### KQL

- Parsers as `.kql` files in `sentinel/parsers/` — one parser per file
- Always test against fixture snapshots in `tests/fixtures/sample-snapshots/`
- Include a `// SYNOPSIS:` comment at the top of each file
- Default time windows: 24h for workbook defaults, explicit `ago()` for rules

### Bicep

- Modular: one Bicep file per Azure resource category in `deploy/modules/`
- Parameterize everything — no hard-coded names, sizes, or regions
- Always provide parameter descriptions via `@description('...')`
- Use `@allowed([...])` for enumerated values
- Output only what downstream modules need

## Adding a new telemetry stream

Follow this checklist when proposing a new `MDE_*_CL` stream:

1. **Research & justify** — file a `new_stream_request` issue first with:
   - Endpoint path (e.g., `/api/ine/...`)
   - Why public Graph/Defender/MDE APIs don't cover it
   - Sample response JSON (redacted)
   - Proposed table name + schema
   - Proposed cadence tier (P0-P7)
2. **Add endpoint wrapper** in `src/Modules/XdrLogRaider.Client/Endpoints/`
3. **Add table schema** in `schemas/tables/`
4. **Add DCR stream** to `schemas/dcr-streams.json`
5. **Add Bicep table resource** in `deploy/modules/custom-tables.bicep`
6. **Register in tier poller** — add to `src/functions/poll-<tier>/run.ps1` endpoint list
7. **Add fixture snapshot** for drift testing in `tests/fixtures/sample-snapshots/`
8. **Add drift-parser coverage** if compliance-relevant
9. **Document** in `docs/STREAMS.md` (full entry: endpoint, schema, cadence, sample data, meaning)
10. **Unit test** the endpoint wrapper — positive + error paths

## Pull request flow

1. Fork and branch — `feature/my-change`, `fix/bug-name`, `docs/updates`
2. Make changes following coding standards above
3. Run `./tests/Run-Tests.ps1 -Category all-offline` locally — must pass
4. Commit with conventional-commit-style message (`feat:`, `fix:`, `docs:`, `test:`, `chore:`)
5. Open PR using the template — fill in every section
6. CI must pass on all 3 OS
7. One approving review required
8. Squash-merge preferred; rebase-merge OK for multi-commit features

## Reporting a portal endpoint breakage

When Microsoft hardens an endpoint we use, use the **Portal endpoint broken** issue template. Include:

- Stream name affected (e.g., `MDE_DataExportSettings_CL`)
- Endpoint path (from `src/Modules/XdrLogRaider.Client/Endpoints/`)
- Last known working date
- Current error (from App Insights or a live test)
- Any observed Microsoft communication (MSRC, release notes, etc.)

We aim to remove or rework broken endpoints within 14 days of a confirmed break.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure.

## License

By contributing, you agree your contributions are licensed under the MIT License (see [LICENSE](LICENSE)).
