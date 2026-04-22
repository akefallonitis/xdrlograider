# Documentation Index

Welcome to XdrLogRaider docs. Each page targets a specific audience.

## For anyone deploying

- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Step-by-step install, with screenshots
- **[GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md)** — How to obtain a TOTP Base32 secret / passkey / cookies for the service account (read this BEFORE running `Initialize-XdrLogRaiderAuth.ps1`)
- **[AUTH.md](AUTH.md)** — Auth methods, Conditional Access compatibility, rotation
- **[BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md)** — How to generate a passkey JSON
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — Symptom → cause → fix
- **[COST.md](COST.md)** — Per-tier ingestion + compute costs

## For SOC / detection engineering

- **[STREAMS.md](STREAMS.md)** — Catalogue of all 55 telemetry streams
- **[WORKBOOKS.md](WORKBOOKS.md)** — What each workbook shows
- **[DRIFT.md](DRIFT.md)** — KQL drift model, parsers, tuning
- **[ANALYTIC-RULES.md](ANALYTIC-RULES.md)** — Each rule: purpose, query, tuning
- **[HUNTING-QUERIES.md](HUNTING-QUERIES.md)** — Analyst-facing query catalogue

## For operators

- **[RUNBOOK.md](RUNBOOK.md)** — Daily checks, incident response, secret rotation
- **[SECURITY.md](../SECURITY.md)** — Threat model, secret handling

## For contributors

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Component overview, diagrams, data flow
- **[CONTRIBUTING.md](../CONTRIBUTING.md)** — Dev setup, coding standards, PR flow
- **[RELEASE-PROCESS.md](RELEASE-PROCESS.md)** — How releases are cut
- **[SENTINEL-SOLUTION-SUBMISSION.md](SENTINEL-SOLUTION-SUBMISSION.md)** — How to submit this connector to the Azure-Sentinel/Solutions/ Content Hub
- **[REFERENCES.md](REFERENCES.md)** — Every source cited, with context
- **[ROADMAP.md](ROADMAP.md)** — v1.1+ features

## Reading order for a new contributor

1. [REFERENCES.md](REFERENCES.md) — background research
2. [ARCHITECTURE.md](ARCHITECTURE.md) — component overview
3. [AUTH.md](AUTH.md) — the one complicated part
4. [STREAMS.md](STREAMS.md) — what data flows through
5. [DRIFT.md](DRIFT.md) — how drift detection works
6. [CONTRIBUTING.md](../CONTRIBUTING.md) — dev loop
