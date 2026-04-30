# Drift model

XdrLogRaider computes drift in **pure KQL at query time**, not in the connector code. Benefits:

- Connector stays stateless (no prior-snapshot storage, no diff code)
- Drift semantics tunable per workbook / analytic rule without redeploy
- Each consumer (workbook, rule, hunting query) can optimize its drift query for its data shape
- No `MDE_Drift_CL` table to maintain; drift is always computed fresh

## Six category parsers

Each parser is a callable KQL function (savedSearch with Category `Functions`):

- `MDE_Drift_Inventory(lookback, window)` — 19 P0 tenant-config streams, field-level diff
- `MDE_Drift_Configuration(lookback, window)` — 7 P1 integration streams, field-level diff
- `MDE_Drift_Configuration(lookback, window)` — 7 P2 RBAC/asset streams, field-level diff
- `MDE_Drift_Exposure(lookback, window)` — 8 P3 XSPM streams, **set-diff** (added/removed entities)
- `MDE_Drift_Inventory(lookback, window)` — 5 P5 MDI streams, field-level diff
- `MDE_Drift_Configuration(lookback, window)` — 4 P7 metadata streams, field-level diff

**No P6 parser** — P6 (action center, threat analytics) is audit log, not drift.

## Output columns

All field-level parsers return rows with:

| Column | Description |
|---|---|
| `TimeGenerated` | Timestamp of current snapshot |
| `StreamName` | Which `MDE_*_CL` table |
| `EntityId` | Entity (e.g., ASR rule ID, feature name) |
| `FieldName` | JSON property that changed |
| `OldValue` | Value at SnapshotPrevious |
| `NewValue` | Value at SnapshotCurrent |
| `SnapshotPrevious` | Timestamp of prior snapshot |
| `SnapshotCurrent` | Same as TimeGenerated |
| `ChangeType` | `Added` / `Removed` / `Modified` |

`MDE_Drift_Exposure` (set-diff) omits `FieldName`, `OldValue`, `NewValue` at field level — `OldValue`/`NewValue` hold the full RawJson at entity level.

## How parsers work

Each parser:

1. Unions the streams it covers with `withsource=_Table`
2. Filters to `lookback` window
3. Summarizes `arg_max(TimeGenerated, *)` per `(StreamName, EntityId)` to get "current"
4. Same for `previous` (between `ago(lookback)` and `ago(window)`)
5. Joins current vs previous on `(StreamName, EntityId)`
6. `hash(tostring(TypedBag))` comparison (where `TypedBag = pack_all() - metaCols` over the manifest-projected typed columns) for a fast inequality check
7. `mv-apply` over `bag_keys` to enumerate field-level diff
8. Project to the output schema

## Usage patterns

### In a workbook
```kql
MDE_Drift_Inventory(24h, 1h)
| summarize Changes = count() by StreamName, bin(TimeGenerated, 1h)
| render timechart
```

### In an analytic rule (ASR downgrade)
```kql
MDE_Drift_Inventory(2h, 15m)
| where StreamName == "MDE_AsrRulesConfig_CL"
| where FieldName == "mode"
| where OldValue == "Block" and NewValue in ("Audit", "Off")
```

### Cross-category drift with audit-log attribution
```kql
union
  (MDE_Drift_Inventory(7d, 1h)  | extend Category = "P0"),
  (MDE_Drift_Configuration(7d, 30m)   | extend Category = "P1"),
  (MDE_Drift_Configuration(7d, 1d)  | extend Category = "P2")
| join kind=leftouter (
    AuditLogs
    | where Category in ("PolicyManagement", "DefenderXdrSettings")
    | where TimeGenerated > ago(7d)
    | project AuditTime = TimeGenerated,
              ChangedBy = tostring(InitiatedBy.user.userPrincipalName),
              AuditTarget = tostring(TargetResources[0].displayName)
  ) on $left.EntityId == $right.AuditTarget
| project TimeGenerated, Category, StreamName, EntityId, FieldName, OldValue, NewValue, ChangedBy
```

## Performance

- Default window 24h across 19 P0 streams = ~500 rows scanned per workbook load
- Parsers don't materialize — re-computed on every call
- For wide windows (30d+), consider creating materialized views per category
- Fixture-based parser tests in `tests/kql/Parsers.Tests.ps1` validate correctness

## Cost

Drift queries are read-only. Log Analytics charges for ingestion (write) + scanned data (query on some tiers). Configuration streams are low-volume (~50-200 MB/day all tiers), so both ingestion and scan costs are minimal. See [COST.md](COST.md).

## Adding a new drift rule

Drift rules are just Sentinel analytic rules that query a parser. No connector change needed.

1. Write the query filtering the parser output for your condition
2. Save as `sentinel/analytic-rules/<RuleName>.yaml`
3. Follow the YAML schema in existing rules
4. Validate: `pwsh ./tests/Run-Tests.ps1 -Category validate`

## Changing drift semantics

Field-level diff granularity can be tuned in the parser itself:
- Skip certain fields (e.g., `TimeGenerated` on nested objects)
- Normalize values (e.g., strip timestamps from JSON)
- Change hash strategy

Edit `sentinel/parsers/MDE_Drift_*.kql`, regenerate the solution, redeploy.
