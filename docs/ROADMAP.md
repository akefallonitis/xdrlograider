# Roadmap

## v1.0 (current)
- 52 portal-only streams across 7 compliance tiers
- Two unattended auth methods (Credentials+TOTP, Passkey)
- 6 KQL drift parsers
- 6 workbooks
- 14 analytic rules
- 9 hunting queries
- Full docs + CI (unit + validate + integration + e2e)

## v1.1 (planned)
- `Register-Passkey.ps1` — automated software passkey generation + Entra registration
- Test-MDEConnectorAuth.ps1 — standalone local auth validator (supplement to FA self-test)
- Additional P0 streams based on community `new_stream_request` input
- Parser performance: materialized views for 30d+ workbook windows

## v1.2 (planned)
- Submission to Azure-Sentinel/Solutions/ Content Hub — see [SENTINEL-SOLUTION-SUBMISSION.md](SENTINEL-SOLUTION-SUBMISSION.md)
- Solution generator integration
- Automated testing against multiple tenant variations

## v2.0 (future — contribution welcome)
- Multi-tenant mode (single Function App ingesting from N tenants)
- Hot-swap auth methods (switch methods without redeploy)
- Additional portal coverage (Intune, Purview, Entra, M365 Admin) — **planned as separate repos** reusing `Xdr.Portal.Auth`:
  - `intune-internals-connector`
  - `purview-internals-connector`
  - `entra-internals-connector`
  - `mda-internals-connector`
  - `m365admin-internals-connector`

## Community requests

File `feature_request` issues for new workbooks, analytic rules, or hunting queries. The bar for inclusion:

- Addresses compliance, drift, or posture use case
- Query tested on at least 1 real tenant
- Follows existing naming + schema conventions
- Unit-tested

See [CONTRIBUTING.md](../CONTRIBUTING.md).
