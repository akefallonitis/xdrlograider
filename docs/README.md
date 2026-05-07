# Documentation Index

Welcome to XdrLogRaider docs (v0.1.0 GA). Each page targets a specific audience.

## For anyone deploying

- **[DEPLOYMENT.md](DEPLOYMENT.md)** — Step-by-step install with the 8-step flow
- **[PERMISSIONS.md](PERMISSIONS.md)** — Consolidated permissions reference (setup + runtime + cross-RG scenarios)
- **[GETTING-AUTH-MATERIAL.md](GETTING-AUTH-MATERIAL.md)** — How to obtain a TOTP Base32 secret / passkey / cookies for the service account (read this BEFORE running `Initialize-XdrLogRaiderAuth.ps1`)
- **[AUTH.md](AUTH.md)** — Auth methods, Conditional Access compatibility, rotation
- **[UNATTENDED-AUTH.md](UNATTENDED-AUTH.md)** — How the connector authenticates without a human, at any worker/cold-start
- **[BRING-YOUR-OWN-PASSKEY.md](BRING-YOUR-OWN-PASSKEY.md)** — How to generate a passkey JSON
- **[POSTDEPLOY-PLAYBOOK.md](POSTDEPLOY-PLAYBOOK.md)** — Optional advanced post-deploy verification (the simple operator flow only needs the Sentinel Data Connectors blade going Connected — see [README.md step 3](../README.md#3-confirm-green))
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — Symptom → cause → fix

## For SOC / detection engineering

- **[STREAMS.md](STREAMS.md)** — Catalogue of all 65 telemetry streams (64 active + 1 deprecated; includes per-stream operational matrix appendix auto-derived from manifest)
- **[SCHEMA-CATALOG.md](SCHEMA-CATALOG.md)** — Per-stream typed-column reference for KQL authors
- **[SCHEMA.md](SCHEMA.md)** — KQL meta-format used by SCHEMA-CATALOG (see SCHEMA-CATALOG for per-stream typed cols)
- **[OPERATOR-KQL-PACK.md](OPERATOR-KQL-PACK.md)** — Canned operator queries + snapshot vs drift pattern guide
- **[WORKBOOKS.md](WORKBOOKS.md)** — What each workbook shows
- **[DRIFT.md](DRIFT.md)** — KQL drift model, parsers, tuning
- **[ANALYTIC-RULES.md](ANALYTIC-RULES.md)** — Each rule: purpose, query, tuning
- **[ANALYTIC-RULES-VETTING.md](ANALYTIC-RULES-VETTING.md)** — Pre-enable vetting + tuning narratives per rule
- **[HUNTING-QUERIES.md](HUNTING-QUERIES.md)** — Analyst-facing query catalogue

## For operators

- **[RUNBOOK.md](RUNBOOK.md)** — Daily checks, incident response, secret rotation
- **[OPERATIONS.md](OPERATIONS.md)** — SRE runbook + App Insights KQL cookbook
- **[INGEST-FAILURE-MODES.md](INGEST-FAILURE-MODES.md)** — DCE failure paths, DLQ semantics, retry/backoff
- **[TELEMETRY.md](TELEMETRY.md)** — App Insights surface (AppRequests, AppDependencies, AppExceptions, AppTraces, AppEvents, AppMetrics)
- **[SECURITY-NOTES.md](SECURITY-NOTES.md)** — Threat model, secret handling
- **[../SECURITY.md](../SECURITY.md)** — Vulnerability disclosure policy

## For contributors

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Component overview, diagrams, data flow, separation-of-concerns (operator workspace vs SRE AppInsights vs XdrOps bridge rules)
- **[PORTAL-COOKIE-CATALOG.md](PORTAL-COOKIE-CATALOG.md)** — Per-portal cookie + OIDC-callback reference for adding a new portal in v0.2.0+
- **[../CONTRIBUTING.md](../CONTRIBUTING.md)** — Dev setup, coding standards, PR flow, SemVer, conventional-commits
- **[TESTING.md](TESTING.md)** — The four-quadrant test model (offline / local-online / e2e / 1-week observation) + how to run each
- **[RELEASE-PROCESS.md](RELEASE-PROCESS.md)** — How releases are cut + cosign + SBOM
- **[SENTINEL-SOLUTION-SUBMISSION.md](SENTINEL-SOLUTION-SUBMISSION.md)** — How to submit this connector to the Azure-Sentinel/Solutions/ Content Hub
- **[MULTI-PORTAL.md](MULTI-PORTAL.md)** — v0.2.0+ Entra/Purview/Intune expansion plan
- **[HOSTING-PLANS.md](HOSTING-PLANS.md)** — Linux Y1 Consumption baseline + premium-tier upgrade path
- **[REFERENCES.md](REFERENCES.md)** — Every source cited, with context
- **[ROADMAP.md](ROADMAP.md)** — v0.2.0+ features

## Reading order for a new contributor

1. [REFERENCES.md](REFERENCES.md) — background research
2. [ARCHITECTURE.md](ARCHITECTURE.md) — component overview
3. [AUTH.md](AUTH.md) — the one complicated part
4. [STREAMS.md](STREAMS.md) — what data flows through
5. [DRIFT.md](DRIFT.md) — how drift detection works
6. [../CONTRIBUTING.md](../CONTRIBUTING.md) — dev loop
