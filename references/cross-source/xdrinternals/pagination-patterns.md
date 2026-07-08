# XDRInternals · Pagination Patterns Reference

> Cross-validation source for `Pagination` and `PaginationParam` fields in `manifests/Defender/<cat>.psd1` per-Operation entries. Consulted in Step 3 of the per-Op 6-step methodology.

## Observed patterns

### Pattern 1 · `-PageSize <int>` explicit size

Example: `Get-XdrEndpointDevice -PageSize 50`

Implementation: query parameter on the request URL. Server returns up to N items.

Maps to our manifest fields:
- `Pagination = 'pageIndex'` OR `'cursor'` (depends on whether server returns explicit page number OR continuation token)
- `PaginationParam = 'pageSize'` (or whatever the server expects · live-verify)

### Pattern 2 · `-All` flag for automatic continuation

Example: `Get-XdrIdentityIdentity -All`

Implementation: XDRInternals internally iterates continuation tokens until exhausted. The `-All` flag triggers this loop.

Our equivalent: `Invoke-XdrEntryPoll` loop in `Xdr.Common.Runtime.psm1` with `loopGuard 1000`. Continuation extracted via `Get-XdrNextCursor` using `PaginationCursorPath`.

Common continuation token names (from XDRInternals + Microsoft REST patterns):
- `nextLink` (legacy)
- `@odata.nextLink` (OData v4)
- `continuationToken`
- `nextPageToken`
- `nextLink.url` (nested)

Our manifest field:
- `PaginationCursorPath = '$.nextLink'` or `'$.@odata.nextLink'` or `'$.continuationToken'` (live-verify per Operation)

### Pattern 3 · Page index (offset-based)

Example: `Get-XdrAuditLog -Page 2` (hypothetical · pattern present in some XDRInternals cmdlets)

Implementation: explicit page number increments per request.

Our manifest:
- `Pagination = 'pageIndex'`
- `PaginationParam = 'pageIndex'` (or `'page'` · live-verify)
- `New-XdrRequestUrl` increments `$Page` parameter automatically (see Xdr.Common.Runtime.psm1 line 232)

## What XDRInternals does NOT clarify

- Exact server response when last page is reached (empty array? `nextLink: null`? omitted property?)
- Rate-limit / throttle handling per page
- Maximum page size accepted by each endpoint

→ For these · we rely on LIVE captures (`references/live/`) and per-Op live test in Phase 8 post-deploy.

## Mapping to our 4 Pagination values

| Manifest `Pagination` | When to use |
|---|---|
| `none` | singleObject or bareArray response · no pagination needed |
| `cursor` | server provides continuation token (nextLink · continuationToken) · CURSOR IngestionMode |
| `pageIndex` | offset-based page increments · stateless |
| `odata` | OData `$skip` + `$top` semantics |

Each per-Op manifest entry sets exactly one Pagination value · NEVER hardcoded · always derived from live response shape + cross-validated against XDRInternals cmdlet if available.
