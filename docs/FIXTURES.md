# Test Fixtures Inventory

> **Purpose**: catalogue all test fixtures shipped with XdrLogRaider for community contributors. Fixtures are the SCHEMA GROUND TRUTH used by ProjectionMap dry-run tests, ARM workspace-table parity tests, and parser KQL fixture tests.
>
> **Source of truth**: live API responses captured via `tools/Capture-EndpointSchemas.ps1` against test tenant + nodoc-derived stubs for tenant-license-gated streams.

## Fixture directory structure

```
tests/fixtures/
├── live-responses/                # 60+ pairs from production-tier capture
│   ├── _capture-summary.json      # canonical SuccessKind verdict per stream
│   ├── MDE_<Stream>_CL-raw.json   # raw HTTP response body
│   └── MDE_<Stream>_CL-ingest.json # post-Expand+Project ingest-shape rows
├── openapi-derived/               # generated from nodoc OpenAPI for tenant-gated streams
│   └── MDE_<Stream>_CL-raw.json   # synthesized example matching nodoc YAML schema
├── sample-snapshots/              # frozen snapshots for drift parser tests
│   └── MDE_<Stream>_CL-snap-{Yn}.json # n-th snapshot for time-window diff
└── (legacy paths)                  # historical fixture accumulations (per .gitignore)
```

## live-responses/ — primary ground truth (60+ pairs)

### Capture methodology

```pwsh
# Operator runs against test tenant with SP creds (.env.local)
pwsh tools/Capture-EndpointSchemas.ps1
```

For each stream in `endpoints.manifest.psd1`:
- Authenticates via SA portal-auth (TOTP / passkey / cookies)
- Issues HTTP GET/POST per manifest path + method
- Captures HTTP status + response body to `<Stream>-raw.json`
- Runs Expand-MDEResponse → ConvertTo-MDEIngestRow → captures the ingest-shape rows to `<Stream>-ingest.json`
- Updates `_capture-summary.json` with verdict per stream (live / live-empty / tenant-gated / error)

### `_capture-summary.json` schema

```json
{
  "captureUtc": "2026-05-09T17:30:00Z",
  "tenant": "<test-tenant-id>",
  "streams": {
    "MDE_Machines_CL": {
      "Path": "/apiproxy/mtp/ndr/machines?...",
      "Method": "GET",
      "HttpStatus": 200,
      "SuccessKind": "live",
      "RowCount": 200,
      "RawBytesCount": 87432,
      "FixturePath": "tests/fixtures/live-responses/MDE_Machines_CL-raw.json"
    },
    "MDE_DCCoverage_CL": {
      "Path": "/apiproxy/aatp/api/sensors/domainControllerCoverage",
      "Method": "GET",
      "HttpStatus": 404,
      "SuccessKind": "tenant-gated",
      "Reason": "MDI not provisioned in this tenant",
      "FixturePath": "tests/fixtures/openapi-derived/MDE_DCCoverage_CL-raw.json"
    },
    "...": "..."
  }
}
```

### What's covered (60+ pairs)

| Tier | Streams captured live | Streams openapi-derived |
|---|---|---|
| ActionCenter | MDE_ActionCenter_CL · MDE_PendingActions_CL | MDE_DeviceTimeline_CL (per-machine fanout) |
| XspmGraph | 18/18 streams (all live in lab tenant) | — |
| Configuration | 14/16 streams live | 2 (CustomCollection / CloudAppsConfig — tenant-license-gated) |
| Inventory | 18/21 streams live | 3 (DCCoverage / IdentityAlertThresholds / RemediationAccounts — MDI not provisioned) |
| Maintenance | 1/2 streams live | 1 (StreamingApiConfig — DEPRECATED) |
| **Total** | **49+ live + 7 live-empty** | **6 openapi-derived** |

## openapi-derived/ — fallback for license-gated streams (Architecture E)

### Why this exists

Lab tenants don't license every Defender XDR feature (MDI / TVM-Premium / MCAS / MDE-Plan2). For streams that return 4xx in lab, the canonical schema reference is the nodoc OpenAPI spec.

### Generation tool: `tools/Generate-FixtureFromOpenApi.ps1`

```pwsh
# Generate stub from nodoc YAML for a license-gated stream
pwsh tools/Generate-FixtureFromOpenApi.ps1 `
    -Stream MDE_DCCoverage_CL `
    -NodocSpec '.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/identity.yml'
```

Reads the response schema for the canonical path; synthesizes a sample JSON matching schema (with realistic field types + values per `example:` tags); writes to `tests/fixtures/openapi-derived/<Stream>-raw.json`.

### License-gated stubs shipped

| Stream | License gate | nodoc spec source |
|---|---|---|
| MDE_DCCoverage_CL | MDI required | `identity.yml:1042` |
| MDE_IdentityAlertThresholds_CL | MDI required | `identity.yml:487` |
| MDE_RemediationAccounts_CL | MDI required | `identity.yml:301` |
| MDE_SecurityBaselines_CL | TVM-Premium | `vulnerability_management.yml:556` |
| MDE_CloudAppsConfig_CL | MCAS required | `cloud_apps.yml:222` |
| MDE_CustomCollection_CL | MDE-Plan2 | `endpoint_configuration.yml:541` |

These stubs ensure ProjectionMap parsing tests (`tests/unit/Manifest.ProjectionResolution.Tests.ps1`) run end-to-end on any tenant.

## sample-snapshots/ — drift parser test fixtures

Frozen snapshots for `tests/kql/Parsers.Fixture.Tests.ps1` to verify drift parsers correctly classify Added/Removed/Modified across time windows.

```
tests/fixtures/sample-snapshots/
├── MDE_AdvancedFeatures_CL-snap-T0.json    # baseline
├── MDE_AdvancedFeatures_CL-snap-T1.json    # +1 feature toggled
├── MDE_AdvancedFeatures_CL-snap-T2.json    # -1 feature removed
└── ... (per-stream drift scenarios)
```

Drift parser KQL invocation in tests:
```kql
MDE_Drift_Configuration({TimeRange:value}, 6h)
| where SourceName == 'MDE_AdvancedFeatures_CL'
| where ChangeType == 'Modified'
```

## Cross-portal catalogues (v0.2.0+ research)

~2,037 operations audited across 20 portal nodoc spec dirs (Defender + Entra + Purview + M365 Admin + Intune + Power Platform + Comms + Security Copilot). Reference material is tracked internally under `.internal/.archive/nodoc-sweeps/CrossPortalCatalog-*.md` until v0.2.0 multi-portal work begins; out of v0.1.0 GA operator scope.

## Other tests/online/ artifacts

| File | Purpose |
|---|---|
| [`NodocCatalogSweep-V010Final.md`](../tests/online/NodocCatalogSweep-V010Final.md) | 17-stream final v0.1.0 GA inclusion list (post-curation from 595 nodoc ops) |
| [`NodocCandidates-LiveTested-V010Final.md`](../tests/online/NodocCandidates-LiveTested-V010Final.md) | Per-candidate live-test verdicts (live / live-empty / tenant-gated / error) for new stream additions |
| [`NodocCandidates-CuratedV011.json`](../tests/online/NodocCandidates-CuratedV011.json) | 171 candidate streams curated for v0.1.0.x patches |
| [`NodocPostReadCandidates-2026-05-08.json`](../tests/online/NodocPostReadCandidates-2026-05-08.json) | post-read candidates (read-only endpoints filtered) |
| [`NodocUncoveredGet-2026-05-08.json`](../tests/online/NodocUncoveredGet-2026-05-08.json) | 270 uncovered GET endpoints (gap analysis) |
| [`Wiring-Matrix-2026-05-09.md`](../tests/online/Wiring-Matrix-2026-05-09.md) | per-stream 12-edge wiring audit matrix (manifest → DCR → workspace → parser → content) |
| [`PreflightDrift-2026-05-04.md`](../tests/online/PreflightDrift-2026-05-04.md) | live preflight drift detection results |
| `CapturePreflight.Tests.ps1` | Pester test wrapping `tools/Capture-EndpointSchemas.ps1` for CI use |

## Privacy + secrets

- All fixtures auto-redacted via `tests/online/CapturePreflight.Tests.ps1` PII redaction gate
- No customer-identifiable data in fixtures (tenant IDs masked)
- No SA credentials / tokens / cookies in fixtures
- `.gitignore` covers `tests/.env.local` (SP creds) + `.internal/` (research-grade non-public refs)

## Refresh cadence

| Fixture type | Trigger | Tool |
|---|---|---|
| `live-responses/` | Manual (operator runs `Capture-EndpointSchemas.ps1` post-deploy) + nightly via `online-preflight.yml` workflow | `tools/Capture-EndpointSchemas.ps1` |
| `openapi-derived/` | On manifest change (when new tenant-gated stream added) | `tools/Generate-FixtureFromOpenApi.ps1` |
| `sample-snapshots/` | When drift parser test scenarios need to evolve | manual + `tools/Build-DriftSnapshot.ps1` (deferred to v0.1.0.x) |

## How fixtures wire into tests

| Test class | Fixture source | Verifies |
|---|---|---|
| `tests/unit/Manifest.ProjectionResolution.Tests.ps1` | `live-responses/<Stream>-raw.json` + `openapi-derived/<Stream>-raw.json` | Per-stream ProjectionMap dry-run extraction; every typed col target resolves on real response |
| `tests/arm/Live.WorkspaceTable.SchemaParity.Tests.ps1` | live workspace KQL `getschema` | DCR-declared cols exist in workspace table (catches B2-class silent drops) |
| `tests/kql/Parsers.Fixture.Tests.ps1` | `sample-snapshots/<Stream>-snap-T*.json` | Drift parsers correctly classify Added / Removed / Modified |
| `tests/unit/PathDriftAgainstResearch.Tests.ps1` | `_capture-summary.json` | Manifest paths match nodoc canonical paths |

## Adding fixtures for a new stream

```pwsh
# 1. Live-test the endpoint
pwsh tools/Capture-EndpointSchemas.ps1 -StreamFilter 'MDE_<NewStream>_CL'

# 2. If 4xx response, generate openapi-derived stub
pwsh tools/Generate-FixtureFromOpenApi.ps1 `
    -Stream 'MDE_<NewStream>_CL' `
    -NodocSpec '.internal/nodoc-reference/specifications/nodoc-defender-xdr/specification/<spec>.yml'

# 3. (Optional) build drift snapshots for parser tests
# Manual edits to sample-snapshots/<Stream>-snap-T*.json

# 4. Run pyramid
pwsh tests/Run-Tests.ps1 -Category all-offline
```

## References

- Capture tool: [`tools/Capture-EndpointSchemas.ps1`](../tools/Capture-EndpointSchemas.ps1)
- OpenAPI fixture generator: [`tools/Generate-FixtureFromOpenApi.ps1`](../tools/Generate-FixtureFromOpenApi.ps1)
- ProjectionMap dry-run: [`tests/unit/Manifest.ProjectionResolution.Tests.ps1`](../tests/unit/Manifest.ProjectionResolution.Tests.ps1)
- Schema parity: [`tests/arm/Live.WorkspaceTable.SchemaParity.Tests.ps1`](../tests/arm/Live.WorkspaceTable.SchemaParity.Tests.ps1)
- Manifest source: [`src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1`](../src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1)
- Architecture E (OpenAPI fixture generator): see [Plan SECTION FINAL.MASTER](../.claude/plans/immutable-splashing-waffle.md)
