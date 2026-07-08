# XDRInternals · TimeFilter Patterns Reference

> Cross-validation source for `TimeFilter`, `TimeFilterParam`, `TimeFilterParamEnd` fields in per-Op manifest entries. Used in Step 3 of the 6-step methodology.

## Observed patterns

### Pattern 1 · `-LastNDays <int>` relative window

Example: `Get-XdrCloudAppsActivityTimeline -LastNDays 1`, `Get-XdrCloudAppsActivityTimeline -LastNDays 7`

Implementation: XDRInternals converts to a relative timestamp on the server-side query. Equivalent to `where TimeGenerated > ago(<N>d)` semantics.

Maps to our manifest:
- `TimeFilter = $true`
- `TimeFilterParam = 'since'` OR `'fromDate'` OR `'startTime'` (live-verify · varies per endpoint)
- IngestionMode typically `WINDOW` (explicit start-end) OR `CURSOR` (if combined with continuation)

### Pattern 2 · `$filter` OData query

Example: Advanced Hunting cmdlets accept `$filter=TimeGenerated gt 2026-05-01`

Implementation: OData filter expression passed as URL query parameter.

Maps to our manifest:
- `TimeFilter = $true`
- `TimeFilterParam = '$filter'` (URL-escaped)
- Value format: `<columnName> gt '<ISO 8601 date>'` for greater-than · `ge` for greater-or-equal
- IngestionMode `WINDOW` · checkpoint stores last query end-time

### Pattern 3 · Explicit `startTime` / `endTime` pair

Example: Many Defender XDR endpoints accept `startTime=<ISO8601>&endTime=<ISO8601>`

Maps to our manifest:
- `TimeFilter = $true`
- `TimeFilterParam = 'startTime'`
- `TimeFilterParamEnd = 'endTime'`
- IngestionMode `WINDOW`
- `Resolve-XdrTimeWindow` in Xdr.Common.Runtime.psm1 computes window from checkpoint + cadence

### Pattern 4 · No time filter (SNAPSHOT)

Examples: config-snapshot endpoints (StreamingApi configuration · TenantContext · LicenseReport · etc.)

Maps to our manifest:
- `TimeFilter = $false`
- IngestionMode `SNAPSHOT`
- Poll-all per cadence · no checkpoint advance needed

## Our 3 IngestionMode values + TimeFilter pairing

| IngestionMode | TimeFilter | Cadence semantic | Checkpoint behavior |
|---|---|---|---|
| `SNAPSHOT` | $false | Config/state poll-all per cadence | Last-fired timestamp only |
| `CURSOR` | optional (cold-start only) | Server-provided continuation | Cursor token |
| `WINDOW` | $true (required) | Time-window poll | Last-end timestamp · NO overlap/rewind (high-water + boundary NaturalKey · exactly-once by construction) |

Derived per-Operation from:
- Live response shape (does response include cursor? require date params?)
- OpenAPI parameter declarations (does it document a `since`/`from`/`$filter`?)
- XDRInternals cmdlet signature (does the cmdlet expose `-LastNDays` or similar?)
- Postman example request (does the example URL include time params?)

## Common TimeFilterParam names observed in /apiproxy/* endpoints

- `since`
- `from` / `fromDate` / `fromUtc`
- `startTime` / `startUtc`
- `$filter` (OData)
- `lastNDays`
- `dateRange` (with separate end param `dateRangeEnd`)

For each new Operation: derive from LIVE capture URL params + cross-validate against XDRInternals cmdlet signature if one exists.
