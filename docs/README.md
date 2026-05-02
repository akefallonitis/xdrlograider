# Documentation Index

Welcome to XdrLogRaider docs. Each page targets a specific audience.

## For anyone deploying

- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Step-by-step install with the 8-step flow
- **[DEPLOY-METHODS.md](DEPLOY-METHODS.md)** — v0.1.0-beta single supported path (Deploy-to-Azure URL); CLI/Bicep/Content Hub return in v0.2.0
- **[PERMISSIONS.md](PERMISSIONS.md)** — Consolidated permissions reference (setup + runtime + cross-RG scenarios)
- **[GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md)** — How to obtain a TOTP Base32 secret / passkey / cookies for the service account (read this BEFORE running `Initialize-XdrLogRaiderAuth.ps1`)
- **[AUTH.md](AUTH.md)** — Auth methods, Conditional Access compatibility, rotation
- **[UNATTENDED-AUTH.md](UNATTENDED-AUTH.md)** — How the connector authenticates without a human, at any worker/cold-start
- **[BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md)** — How to generate a passkey JSON
- **[POSTDEPLOY-PLAYBOOK.md](POSTDEPLOY-PLAYBOOK.md)** — Optional advanced post-deploy verification (the simple operator flow only needs the Sentinel Data Connectors blade going Connected — see [README.md step 3](../README.md#3-confirm-green))
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — Symptom → cause → fix
- **[UPGRADE.md](UPGRADE.md)** — Migration guidance between releases
- **[COST.md](COST.md)** — Per-tier ingestion + compute costs

## For SOC / detection engineering

- **[STREAMS.md](STREAMS.md)** — Catalogue of all 45 telemetry streams
- **[STREAMS-REMOVED.md](STREAMS-REMOVED.md)** — Streams removed in earlier releases (with evidence)
- **[SCHEMA-CATALOG.md](SCHEMA-CATALOG.md)** — Per-stream typed-column reference for KQL authors
- **[QUERY-MIGRATION-GUIDE.md](QUERY-MIGRATION-GUIDE.md)** — Migrating queries from `RawJson` extraction to typed columns
- **[WORKBOOKS.md](WORKBOOKS.md)** — What each workbook shows
- **[DRIFT.md](DRIFT.md)** — KQL drift model, parsers, tuning
- **[ANALYTIC-RULES.md](ANALYTIC-RULES.md)** — Each rule: purpose, query, tuning
- **[ANALYTIC-RULES-VETTING.md](ANALYTIC-RULES-VETTING.md)** — Pre-enable vetting + tuning narratives per rule
- **[HUNTING-QUERIES.md](HUNTING-QUERIES.md)** — Analyst-facing query catalogue

## For operators

- **[RUNBOOK.md](RUNBOOK.md)** — Daily checks, incident response, secret rotation
- **[OPERATIONS.md](OPERATIONS.md)** — SRE runbook + App Insights KQL cookbook
- **[SECURITY.md](../SECURITY.md)** — Threat model, secret handling

## For contributors

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Component overview, diagrams, data flow
- **[PORTAL-COOKIE-CATALOG.md](PORTAL-COOKIE-CATALOG.md)** — Per-portal cookie + OIDC-callback reference for adding a new portal in v0.2.0+
- **[CONTRIBUTING.md](../CONTRIBUTING.md)** — Dev setup, coding standards, PR flow
- **[TESTING.md](TESTING.md)** — The four-quadrant test model (offline / local-online / e2e) + how to run each
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
