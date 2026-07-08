# Runbook · DLQ drain + replay

Rows that could not be ingested are NEVER silently dropped — they land in the `XdrIngestDlq` storage table
(terminal 4xx immediately; transients after retry exhaustion; network faults too). Healthy steady state is an
EMPTY DLQ (postdeploy dimension D9).

## Inspect
PartitionKey = `<Portal>_<Category>` · RowKey = `yyyyMMddHHmmssfff-<guid8>` (chronological). Columns:
`DcrId`, `StreamName`, `RowCount`, `Reason`, `ErrorBody` (clipped 8KB), `RowsB64` (the failed batch,
base64(JSON-array)), `QueuedUtc`. Read via Azure Storage Explorer or `az storage entity query` with MSI auth.

**The 60KB caveat (important):** `RowsB64` is truncated at 60,000 chars to fit the 64KB property limit. A large
failed batch may therefore be PARTIAL in the DLQ row. The DLQ's primary value is the *signal + reason*; the
*data* recovery path for CURSOR ops is a checkpoint rewind (below), which re-fetches from the source of truth —
the portal — rather than trusting a possibly-truncated payload.

## Triage by Reason
- `Terminal HTTP 4xx` — contract problem (schema/stream mismatch is the classic: run
  `tools/Assert-LiveSchemaParity.ps1` first; a 413 means the row-clamp failed to fit a pathological row —
  check `Ingest.RowClamped` events and the op's RawJson sizes).
- `Transient ... after N retries` — DCE/network outage window; rows are re-fetchable.

## Replay
Preferred (CURSOR ops): fix the root cause → `tools/Save-XdrCheckpointReset.ps1` (operator-override reason) to
rewind the op's cursor to before the failure window → next cycle re-fetches and re-ingests. Exactly-once
boundary keys make the overlap safe; on a non-empty table mind the re-baseline rules (rollback runbook §3).
Direct re-POST of decoded `RowsB64` to the DCE is possible for small complete batches (decode → POST to the
DCR stream with an MSI token) but is the fallback, not the norm — prefer re-fetch.

## After drain
Delete the processed DLQ rows (operator action, explicit), re-run `Verify-DeployedConnector` D9, and confirm
the op's POPULATED + count==dcount checks over the replayed window.
