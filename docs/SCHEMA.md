# Workspace Table Schema Reference

Per-table column reference for the 11 consolidated workspace tables. Operators query these tables directly; this is the source of truth for what columns exist and which streams populate each one.

> **Companion docs**:
> - [`SCHEMA-CATALOG.md`](SCHEMA-CATALOG.md) — per-stream typed-column projections (what each `MDE_<Stream>_CL` SourceName contributes to its Defender_<Category>_CL workspace table)
> - [`STREAMS.md`](STREAMS.md) — narrative tier/cadence catalog
> - [`tests/online/NodocCatalogSweep-V010Final.md`](../tests/online/NodocCatalogSweep-V010Final.md) — canonical 60-stream inclusion list

## How to read this doc

Every consolidated `Defender_<Category>_CL` table receives rows from multiple streams. The `SourceName` column identifies which stream produced each row. To filter per-stream:

```kql
Defender_<Category>_CL
| where SourceName == "MDE_<Stream>_CL"
| project TimeGenerated, EntityId, <columns from your stream>
```

Every row also has `RawJson` (the full source-API response, for forensic queries that bypass the typed-column projection).

## Base columns (every table)

| Column | Type | Source |
|---|---|---|
| `TimeGenerated` | datetime | DCE ingest time |
| `SourceStream` | string | The DCR streamDecl name (e.g. `MDE_X_CL`) |
| `SourceName` | string | The originating stream (DCR `transformKql` injection) |
| `EntityId` | string | Per-stream stable identity from manifest `EntityIdProperty` |
| `RawJson` | dynamic | Full source-API entity (preserved for forensics) |
| `Type` | string | LA-managed |
| `TenantId` | string | LA-managed |

## DCR-to-table mapping (v0.1.0)

13 DCRs, one per consolidated table (with semantic sub-domain split for the two oversized categories):

| DCR | Output table | Streams |
|---|---|---:|
| `xdrlr-dcr-actioncenter` | `Defender_ActionCenter_CL` | 2 |
| `xdrlr-dcr-config-alerts-detection` | `Defender_ConfigurationAndSettings_CL` | 6 |
| `xdrlr-dcr-config-platform-rbac` | `Defender_ConfigurationAndSettings_CL` | 8 |
| `xdrlr-dcr-endpoint-config` | `Defender_EndpointConfiguration_CL` | 9 |
| `xdrlr-dcr-endpoint-device` | `Defender_EndpointDeviceManagement_CL` | 2 |
| `xdrlr-dcr-exposure-attack-surface` | `Defender_ExposureManagement_CL` | 10 |
| `xdrlr-dcr-exposure-posture-score` | `Defender_ExposureManagement_CL` | 7 |
| `xdrlr-dcr-identity` | `Defender_IdentityProtection_CL` | 6 |
| `xdrlr-dcr-multitenant` | `Defender_MultiTenantOperations_CL` | 3 |
| `xdrlr-dcr-streaming-api` | `Defender_StreamingApi_CL` | 2 |
| `xdrlr-dcr-threat-analytics` | `Defender_ThreatAnalytics_CL` | 3 |
| `xdrlr-dcr-vuln-mgmt` | `Defender_VulnerabilityManagement_CL` | 1 |
| `xdrlr-dcr-ops` | `XdrConnectorHealth_CL` | 1 |

**Total**: 13 DCRs / 66 streamDecls (65 streams + 1 ops) / 11 workspace tables.

## Per-stream column rename (v0.1.0)

Where the same column name in different streams referred to different concepts, we renamed per-stream to preserve native types. Source API field names unchanged; only the DCR streamDecl + workspace table column name differ.

| Stream | Original column | Renamed to | Type | Source-API field |
|---|---|---|---|---|
| `MDE_SuppressionRules_CL` | `Action` | `SuppressionAction` | int | `Action` (enum: 1=Allow, 2=Block, ...) |
| `MDE_SuppressionRules_CL` | `Scope` | `SuppressionScope` | int | `Scope` (enum) |
| `MDE_TenantAllowBlock_CL` | `Action` | `AllowBlockAction` | string | `Action` (label: "Allow"/"Block") |
| `MDE_UnifiedRbacRoles_CL` | `Scope` | `RbacScope` | string | `scope` (ARM resource ID) |
| `MDE_UserPreferences_CL` | `Scope` | `PreferenceScope` | string | `Scope` (preference name) |

Other normalizations:
- `MDE_ThreatAnalytics_CL.Tags` / `Keywords`: `string`-joined → `dynamic` (JSON array — matches `MDE_ThreatAnalyticsEnriched_CL.Tags`)
- `MDE_WebContentFiltering_CL.TotalAccessRequests` / `TotalBlockedCount`: `int` → `long` (matches `$tolong` cast hint)

## Data path

```
Source API (Defender XDR portal)
  ↓ (HTTP fetch by Function App)
Function App stream poller (Invoke-MDETierPoll)
  ↓ (Project-EntityField applies manifest ProjectionMap cast hints)
Typed object: { TimeGenerated, SourceStream, EntityId, RawJson, <typed-columns> }
  ↓ (DCE ingest with x-ms-stream-name: Custom-MDE_<Stream>_CL)
Data Collection Rule (DCR)
  ↓ (transformKql: 'source | extend SourceName="MDE_<Stream>_CL"')
Workspace table (Defender_<Category>_CL)
  ↓
Operator KQL queries
```

## Schema integrity gates (CI)

`tests/arm/SchemaConsistency.Tests.ps1` enforces 4 invariants on every PR:

1. **ProjectionMap cast hint = DCR streamDecl column type** (per stream)
2. **Cross-stream type agreement per consolidated table** (no two streams writing to the same `Defender_<Category>_CL` disagree on a column type)
3. **DCR streamDecl column type = workspace table column type** (per dataFlow output stream)
4. **DCR-to-category coverage ≤ 1 category per DCR** (no bucket-fill regression)

Operator-side audit: `pwsh tools/Audit-DcrSchema.ps1` — runs the same 4 invariants without Pester.

## See also

- `src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1` — manifest with per-stream `ProjectionMap`
- `deploy/compiled/mainTemplate.json` — DCR streamDecl + workspace table column definitions
- `tools/Build-DcrSection.ps1` — codegen for the DCR section (run when categories change)
- `docs/STREAMS.md` — full per-stream catalogue with cadence tier + tenant-feature-gating
