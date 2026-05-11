# v0.2.0 Multi-Tenant Function App Scoping Design

> **Scope**: extend XdrLogRaider from single-tenant FA (v0.1.0 GA) to multi-tenant FA where ONE FA polls many tenants concurrently.
>
> **Status**: design draft for v0.2.0; implementation deferred until v0.2.0a-h portal expansion phases are scoped.
>
> **Operator goal**: MSSPs run ONE XdrLogRaider FA polling N customer tenants. Per-tenant secret isolation in KV. Per-tenant XdrTierState rows. Per-tenant cost guardrails. Per-tenant `XdrConnectorHealth_CL` filtering.

## Architectural changes (v0.2.0-infra1)

### 1. Per-tenant secret namespace in Key Vault

**v0.1.0 GA (single-tenant)**:
```
KV secrets:
  mde-portal-auth-method   -> 'totp' | 'passkey' | 'cookies'
  mde-portal-username       -> svc-xdrlr@contoso.com
  mde-portal-password       -> <secret>
  mde-portal-totp-secret    -> <base32>
  mde-portal-passkey        -> <json>
```

**v0.2.0 (multi-tenant)**:
```
KV secrets (per tenant):
  mde-portal-{tenantId}-auth-method
  mde-portal-{tenantId}-username
  mde-portal-{tenantId}-password
  mde-portal-{tenantId}-totp-secret
  mde-portal-{tenantId}-passkey

Plus tenant inventory:
  xdrlr-tenant-list  -> JSON array of {tenantId, displayName, enabledPortals}
```

`Initialize-XdrLogRaiderAuth.ps1` extended with `-TenantId` parameter; seeds per-tenant secrets idempotently.

### 2. XdrTierState PartitionKey extension

**v0.1.0 GA**:
```
PartitionKey = '<Portal>|<Tier>'  // 'Defender|Inventory'
RowKey       = '<Stream>'         // 'MDE_Machines_CL'
```

**v0.2.0 multi-tenant**:
```
PartitionKey = '<TenantId>|<Portal>|<Tier>'  // 'tenant-abc-123|Defender|Inventory'
RowKey       = '<Stream>'                    // unchanged
```

Migration: orchestrator reads existing rows with new PartitionKey format; legacy single-tenant rows (without `<TenantId>` prefix) remain readable for v0.1.0 → v0.2.0 upgrade.

### 3. Connector-Heartbeat aggregation

`XdrConnectorHealth_CL` schema extended with `TenantId` column. Heartbeat aggregator emits per-(TenantId, Portal, Tier) rows.

Sentinel data-connector card `IsConnectedQuery` extended to filter by current workspace's tenant context (via `_ResourceId` or workspace tenant join).

### 4. Per-tenant Xdr-PollOrchestrator dispatch

`Xdr-Refresh` (universal dispatcher) iterates `tenants × enabledPortals × cadenceTiers`:
```powershell
foreach ($tenant in $config.Tenants) {
    foreach ($portal in $tenant.EnabledPortals) {
        foreach ($tier in $cadenceMap.Keys) {
            $key = "$($tenant.TenantId)|$portal|$tier"
            if ($state[$key].nextRunUtc -le $now) {
                Start-NewOrchestration -InputObject @{
                    TenantId = $tenant.TenantId
                    Portal   = $portal
                    Tier     = $tier
                }
            }
        }
    }
}
```

`Xdr-PollOrchestrator` filters manifest by `Portal+Tier`; activity poller reads per-tenant secrets via `Get-XdrAuthFromKeyVault -TenantId $input.TenantId`.

### 5. Per-tenant rate-limit + cost guardrails

Architecture J cost guardrails extended per-tenant:
- `MaxRowsPerTenantPerHour` per stream
- `MaxOrchestrationsPerTenantPerCycle`
- Per-tenant DLQ depth threshold

Operator-tunable via FA env var:
```
XDRLR_PER_TENANT_BUDGETS = '{"tenant-abc": {"maxRowsHour": 50000, "maxOrch": 100}, ...}'
```

### 6. DCR routing per tenant

**Option A (preferred — per-tenant DCRs)**: each tenant has own DCR set + DCE; isolation + per-tenant cost attribution. Cost: 13 DCRs × N tenants.

**Option B (shared DCRs with TenantId col)**: one DCR set; DCR transformKql injects `TenantId` col; downstream Sentinel queries filter by TenantId. Cost: lower; trade-off: tenant data co-mingles in workspace at DCE level (privacy concern for MSSPs).

**Decision (v0.2.0-infra2)**: Option A by default; Option B as opt-in via `XDRLR_DCR_MODE='shared'` env var.

### 7. Per-tenant Sentinel workspace targeting

Multi-tenant FA may write to MULTIPLE Sentinel workspaces (one per customer). DCR `dataFlows[].destinations[]` parameterized per-tenant; ARM template adds `customerWorkspaces` array param.

Per-tenant `dcrImmutableId` lookup via `Get-DcrImmutableIdForStream -TenantId $t -Stream $s`.

## Operator-facing UX changes

### Deploy-to-Azure wizard

`createUiDefinition.json` adds:
- "Tenant onboarding" step: paste JSON array of `{tenantId, displayName, enabledPortals}`
- Per-tenant workspace resource ID (cross-RG nested deployment per tenant)

### `Initialize-XdrLogRaiderAuth.ps1` extension

```pwsh
# Single-tenant (v0.1.0 GA backward-compat)
Initialize-XdrLogRaiderAuth -KeyVaultName <kv>

# Multi-tenant (v0.2.0)
Initialize-XdrLogRaiderAuth -KeyVaultName <kv> -TenantId tenant-abc-123
Initialize-XdrLogRaiderAuth -KeyVaultName <kv> -TenantId tenant-def-456
# ...
```

### Per-tenant dashboards

NEW workbook `XdrLogRaider_MultiTenantHealth.json` — pivot ConnectorHealth panels by TenantId; identify per-tenant SLO breach.

## Migration path (v0.1.0 GA → v0.2.0)

1. **Deploy v0.2.0 FA** in-place (idempotent ARM redeploy preserves KV secrets)
2. **Re-seed secrets with `-TenantId` param** for primary tenant (matches single-tenant naming via default `-TenantId 'default'`)
3. **Add additional tenants** via `Initialize-XdrLogRaiderAuth -TenantId <new>`
4. **Update tenant inventory secret** (`xdrlr-tenant-list`) to include all tenants
5. **Restart FA** to reload tenant inventory
6. **Verify per-tenant ingestion** via `Defender_<Cat>_CL | summarize by TenantId`

Backward-compat: single-tenant operators continue to work without changes; `-TenantId` defaults to `'default'`.

## Security considerations

- KV per-tenant secrets MUST use distinct PartitionKey + tenant-scoped role assignments (RBAC)
- DCE/DCR per-tenant ingestion endpoints + role assignments MUST be scoped per-tenant (Option A)
- AppInsights customEvents include `TenantId` property for forensic queries
- Service Account (SA) per tenant MUST have read-only Defender XDR Analyst role in EACH tenant
- Cross-tenant access policies (Entra MTO B2B) NOT used; SA is tenant-bound

### Connector card identity collision (`connectorId='XdrLogRaiderInternal'`)

**v0.1.0 GA**: `mainTemplate.json` declares the Sentinel Data Connector card with hardcoded `dataConnectorId='XdrLogRaiderInternal'` (referenced 19× across mainTemplate.json + sentinelContent.json + manifest.json). Single-tenant FA → single workspace → ONE card per workspace, so no collision.

**v0.2.0 multi-tenant collision risk**: One MSSP FA polling N tenants writes to N separate Sentinel workspaces (or N RGs in the MSP control plane). Each workspace independently registers a Data Connector card with the SAME hardcoded `XdrLogRaiderInternal` id. Within a single workspace this is fine (unique by `(workspace, connectorId)` pair), BUT:
1. Cross-workspace audit/inventory queries that filter `where DataConnectorId == 'XdrLogRaiderInternal'` cannot distinguish per-tenant deployment provenance.
2. Microsoft Sentinel Solution Gallery PR review may flag the hardcoded id as multi-deployment-unfriendly.
3. Future Microsoft Sentinel features that key off `dataConnectorId` (e.g., Content Hub multi-deployment management) may collide.

**v0.2.0 fix**: per-tenant connectorId via ARM template parameter:
```json
"parameters": {
  "tenantSuffix": {
    "type": "string",
    "defaultValue": "[uniqueString(resourceGroup().id)]",
    "metadata": { "description": "Per-tenant suffix appended to dataConnectorId for multi-tenant FA deployments. Default = uniqueString(rg) for backward-compat single-tenant." }
  }
}
```
Then `dataConnectorId='[concat('XdrLogRaiderInternal-', parameters('tenantSuffix'))]'`. All 19 references via parameter substitution. Backward-compat: single-tenant deploys use the same default-resolved id (deterministic from RG identity).

**Migration path**: v0.2.0 ARM what-if shows REPLACE on data-connector card resource for existing v0.1.0 GA deploys (operator must re-onboard the card; cleanup script archives old card metadata). Document as breaking change in v0.2.0 release notes.

## Out of scope for v0.2.0

- Per-tenant FA isolation (separate FA per tenant) — operator can choose between shared FA (multi-tenant) and per-tenant FA (full isolation) via deployment params; full per-tenant FA = v1.x marketplace certification path

## Verification gates (per Plan SECTION FINAL.MASTER triple-leg)

### Offline:
- `tests/unit/MultiTenant.SecretNamespace.Tests.ps1` — assert per-tenant KV secret naming convention
- `tests/unit/MultiTenant.PartitionKey.Tests.ps1` — assert XdrTierState PartitionKey format
- `tests/arm/MultiTenant.DcrIsolation.Tests.ps1` — assert DCR resources scoped per tenant (Option A)

### Online:
- ARM what-if `--mode Complete` against multi-tenant subscription: expected per-tenant resource churn

### Live:
- 2-tenant lab deployment: per-tenant ingestion + per-tenant connector card + per-tenant SLO compliance
- 7-day multi-tenant observation: no cross-tenant data leakage; per-tenant Maintenance tier fires once per tenant
