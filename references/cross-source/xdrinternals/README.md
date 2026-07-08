# XDRInternals Cross-Source Reference

> **Provenance · scope discipline**: This directory consolidates patterns from `https://github.com/MSCloudInternals/XDRInternals` for **cross-validation of TimeFilter + Pagination + sub-portal coverage ONLY**. XDRInternals is **NOT** used as a runtime pattern source · **NOT** used as an auth pattern source · **NOT** a dependency. Per operator binding: "XDRInternals = TimeFilter + Pagination + sub-portal coverage REFERENCE ONLY · NEVER auth pattern source".

## What XDRInternals is

Community PowerShell module exposing Microsoft Defender XDR portal APIs as `Get-Xdr*` cmdlets. Maintained by MSCloudInternals · unofficial · community-driven · disclaims Microsoft affiliation. Useful for cross-validating per-Operation manifest fields against another open-source consumer of the same `/apiproxy/*` endpoints.

## What we use it for

| Use case | Status |
|---|---|
| Pagination patterns (PageSize · -All · continuation token names) | ✅ Reference (see `pagination-patterns.md`) |
| TimeFilter patterns (-LastNDays · $filter · OData syntax) | ✅ Reference (see `timefilter-patterns.md`) |
| Sub-portal coverage map (cmdlet → workload mapping) | ✅ Reference (see `sub-portal-coverage.md`) |
| Operation cmdlet inventory (cross-check OpenAPI operationIds) | ✅ Reference (see `cmdlet-inventory.md`) |
| Auth patterns (Connect-XdrByCredential · headless login) | ❌ **NOT used** · operator binding · we implement auth in-tree per existing module structure |
| Runtime dispatch / cache / state | ❌ **NOT used** · we have our own modules |

## How we use it per-Operation

In Step 3 of the 6-step research-implement-verify methodology (canonical plan §5.1):
1. Research live capture (clean repo `references/live/`)
2. Cross-check Postman (`references/postman/defender.collection.json`)
3. Cross-check OpenAPI (`references/openapi/nodoc-defender-xdr/specification/<cat>.yml`)
4. **Cross-check XDRInternals** (this directory)
   - Confirm cmdlet exists for the Operation
   - Confirm pagination strategy matches our manifest Pagination field
   - Confirm TimeFilter naming matches our TimeFilterParam field
   - Confirm SubPortal mapping is consistent

If XDRInternals contradicts our derivation: investigate · re-verify live capture · adjust if XDRInternals is correct.

## What we do NOT do

- Do not import their auth flows
- Do not call into their cmdlets at runtime
- Do not depend on their module at build time
- Do not copy their HTTP wire format (we derive ours from RAW live captures · NOT from their implementation)
- Do not assume their Cadence values for our Operations (semantic derivation per Operation · not inheritance)

## Source

- GitHub: https://github.com/MSCloudInternals/XDRInternals
- License: MIT (per their repo)
- Consolidated UTC: 2026-06-02

## Files in this directory

- `README.md` (this file)
- `pagination-patterns.md` · cursor names · PageSize · -All flag behavior · continuation token shapes
- `timefilter-patterns.md` · -LastNDays · $filter · OData syntax variants
- `sub-portal-coverage.md` · cmdlet → workload (MDE · MDI · MCAS · MDVM · XSPM · Advanced Hunting · etc) mapping
- `cmdlet-inventory.md` · representative cmdlet list per workload (cross-reference for our OpenAPI operationIds)
