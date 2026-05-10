# Streams removed history

> **TL;DR**: this document is the history log of streams that have been **removed from the manifest** (not just deprecated). Removal is a breaking change — operators querying the workspace tables for those streams will see no new rows after the removal release. Deprecated-but-still-present streams live in [`docs/STREAMS.md`](STREAMS.md) and are filtered out at orchestration time without losing the manifest entry.

## Why "removed" exists as a concept

Three distinct lifecycle states exist for streams in this connector:

1. **`Availability='live'`** — manifest entry is polled on cadence, runtime `SuccessKind` classifies the response (`live`, `live-empty`, `tenant-gated`, `error`).
2. **`Availability='deprecated'`** — manifest entry is preserved (so historical queries still see the stream's typed cols) but orchestrator filters it out — never polled. v0.2.0+ may eventually remove the manifest entry once enough release cycles have passed for operators to migrate.
3. **`removed`** — manifest entry deleted entirely. Workspace table cols may remain in the schema (so historical queries still work against archived rows) but no new data flows. Recorded here.

## Removal policy

- Streams are NOT removed casually. The bar is: (a) underlying portal endpoint demonstrably gone (Microsoft retired it) AND (b) no per-tenant data has flowed for ≥30 days across all observed deployments AND (c) public Microsoft API now exposes the equivalent (operators migrate to that path).
- Removals announced in CHANGELOG.md ≥1 release ahead of the removal commit.
- Removed streams stay in this history log indefinitely so operators investigating historical workspace data can map back to the original source.

## Removal log

### v0.1.0 GA (2026-05-09)

No streams removed. Baseline release.

> Streams considered for removal but kept (with `Availability='deprecated'` instead): `MDE_StreamingApiConfig_CL` (Microsoft retired the portal-side streaming-API config endpoint; the official `dataExportSettings` API replaces it). Operators see the field via `MDE_DataExportSettings_CL` going forward.

### Future removals will be appended here per release.

## Companion docs

- [`docs/STREAMS.md`](STREAMS.md) — current 72-stream catalogue (71 live + 1 deprecated)
- [`CHANGELOG.md`](../CHANGELOG.md) — per-release announcement log
- [`docs/ROADMAP.md`](ROADMAP.md) — what's planned for upcoming releases
