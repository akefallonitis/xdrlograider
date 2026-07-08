#Requires -Version 7.4
<#
.SYNOPSIS
  Φ4.E/Φ4.G2a · operator-side LIVE checkpoint reset for the Operations pilot (the clean-baseline + exactly-once
  predecessor that previously had NO runnable entrypoint — Override-XdrSync -ResetCursor only PRINTED instructions).

.DESCRIPTION
  Writes the SAME XdrCheckpoint reset row the in-FA runtime fn Save-XdrCheckpointReset
  (Xdr.Common.Runtime.psm1:1613) writes, from outside the FA, so the next TimerTrigger cycle re-emits from a
  clean baseline (SNAPSHOT full re-emit · CURSOR re-poll from start) and fires immediately (LastUpdatedUtc=''
  → G-Cadence treats it as first-cycle-ever).

  Reset row (EXACT mirror of the runtime contract · table XdrCheckpoint · PartitionKey="<Portal>_<Category>" ·
  RowKey=OperationKey · Insert-Or-Replace):
    Cursor='' · WindowStartUtc='' · WindowEndUtc='' · LastUpdatedUtc='' · LastItemCount=0 ·
    CorrelationId=<guid> · ResetReasonAnnotation=<reason> · ResetUtc=<iso8601> · SchemaVersion=1
  Invariant: a reset REWINDS, never advances (matches the runtime · operator intent wins).

  AUTH: az CLI with `--auth-mode login` (AAD) ONLY — the FA storage account has shared-key DISABLED
  (allowSharedKeyAccess=false); every checkpoint tool (this, Force-XdrFullCycle, Force-XdrAuthLoss) is on the
  AAD data-plane path. The running principal needs `Storage Table Data Contributor` (the standing .env.local
  SP has it at RG scope — role inventory verified 2026-06-11). NEVER uses a shared key, NEVER deletes/purges,
  NEVER touches KeyVault/ARM.

.PARAMETER OperationKey
  Reset ONE op (e.g. ActionCenter.GetHistory). Omit to reset EVERY existing checkpoint row in the partition
  (the whole Category's pilot ops) — the Φ4.E "reset the Operations ops ONCE" clean baseline.

.PARAMETER Apply
  Without it the tool is DRY-RUN (prints every planned reset · mutates nothing). With it, the rows are written.
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $Category = 'Operations',
    [string] $OperationKey,
    [string] $ResourceGroup,    # C-1: ← .env.local XDRLR_CONNECTOR_RG (or pass)
    [string] $StorageAccount,   # C-1: ← .env.local XDRLR_STORAGE_ACCOUNT (or pass)
    [ValidateSet('first-validate', 'schema-change', 'timefilter-change', 'ingestionmode-change', 'operator-override')]
    [string] $Reason = 'operator-override',
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$partitionKey = "${Portal}_${Category}"
# C-1 (2026-06-18): resolve estate from .env.local (the established source) when not passed — a public tool must not
# bake in the maintainer's deployment. Pass -StorageAccount / -ResourceGroup to override.
if (-not $StorageAccount -or -not $ResourceGroup) {
    $envLocal = Join-Path (Resolve-Path "$PSScriptRoot\..").Path '.env.local'
    if (Test-Path $envLocal) {
        $ev = @{}; Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]\w*)\s*=\s*(.+)$') { $ev[$Matches[1]] = $Matches[2].Trim().Trim('"') } }
        if (-not $StorageAccount) { $StorageAccount = $ev['XDRLR_STORAGE_ACCOUNT'] }
        if (-not $ResourceGroup)  { $ResourceGroup  = $ev['XDRLR_CONNECTOR_RG'] }
    }
}
if (-not $StorageAccount) { throw 'XDRLR_STORAGE_ACCOUNT missing from .env.local (or pass -StorageAccount)' }
if (-not $ResourceGroup)  { throw 'XDRLR_CONNECTOR_RG missing from .env.local (or pass -ResourceGroup)' }

$mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Host "[Save-XdrCheckpointReset][$mode] table=XdrCheckpoint SA=$StorageAccount PK=$partitionKey reason=$Reason (AAD --auth-mode login · shared-key-off-safe)"

# Resolve the target RowKeys (OperationKeys) to reset.
$rowKeys = @()
if ($OperationKey) {
    $rowKeys = @($OperationKey)
} else {
    # Enumerate every existing checkpoint row in the partition = the Category's live ops.
    $raw = az storage entity query --account-name $StorageAccount --auth-mode login --table-name XdrCheckpoint `
        --filter "PartitionKey eq '$partitionKey'" --select RowKey --num-results 1000 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to query XdrCheckpoint (PK=$partitionKey) via AAD. Ensure the principal has 'Storage Table Data Contributor'. az said: $raw"
        exit 1
    }
    $parsed = $raw | ConvertFrom-Json
    $rowKeys = @($parsed.items | ForEach-Object { $_.RowKey } | Where-Object { $_ })
}

if (-not $rowKeys -or $rowKeys.Count -eq 0) {
    Write-Host "[Save-XdrCheckpointReset][$mode] no checkpoint rows found for PK=$partitionKey (nothing to reset · the FA may not have run a cycle yet)."
    exit 0
}

Write-Host "[Save-XdrCheckpointReset][$mode] $($rowKeys.Count) op(s) to reset: $($rowKeys -join ', ')"
$nowIso = (Get-Date).ToUniversalTime().ToString('o')   # stamp time (Date.Now allowed here — operator tool, not a workflow)
# Storage data-plane AAD token for the Table REST insert-or-replace. We write via REST (not `az storage entity
# insert`) because a fanout-child RowKey like 'GetPostureOversightInitiative|easm' carries a '|' that leaks to
# cmd.exe as a pipe through az.cmd (live-caught 2026-06-19: 9/23 Exposure resets failed · "'easm' is not recognized
# as an internal or external command"). REST takes the key URL-encoded in the entity address — no shell re-parsing,
# robust for every special char in a composite entity-fanout key.
$stTok = az account get-access-token --resource https://storage.azure.com/ --query accessToken -o tsv 2>$null
if (-not $stTok) { Write-Error '[Save-XdrCheckpointReset] could not acquire a storage data-plane token'; exit 1 }
$failed = 0

foreach ($rk in $rowKeys) {
    $cid = [Guid]::NewGuid().ToString()
    if (-not $Apply) {
        Write-Host "    DRY-RUN · would reset PK=$partitionKey RK=$rk → Cursor='' · LastUpdatedUtc='' (rewind · fires next cycle)"
        continue
    }
    # Insert-Or-Replace the EXACT runtime reset shape via the Table data-plane REST API. Empty strings = rewind.
    # REST (not az CLI) so a '|' in a fanout-child RowKey can't leak to cmd.exe as a pipe (see the token note above).
    # The address keys are URL-encoded; Edm types are inferred from the JSON (0/1 → Edm.Int32, '' → Edm.String).
    $pkAddr = [uri]::EscapeDataString($partitionKey)
    $rkAddr = [uri]::EscapeDataString($rk)
    $url = "https://$StorageAccount.table.core.windows.net/XdrCheckpoint(PartitionKey='$pkAddr',RowKey='$rkAddr')"
    $entBody = @{ Cursor=''; WindowStartUtc=''; WindowEndUtc=''; LastUpdatedUtc=''; LastItemCount=0; CorrelationId=$cid; ResetReasonAnnotation=$Reason; ResetUtc=$nowIso; SchemaVersion=1 } | ConvertTo-Json -Compress
    try {
        $null = Invoke-RestMethod -Method Put -Uri $url -Headers @{ Authorization = "Bearer $stTok"; 'x-ms-version' = '2019-02-02'; Accept = 'application/json;odata=nometadata'; 'Content-Type' = 'application/json' } -Body $entBody -TimeoutSec 60 -ErrorAction Stop
        Write-Host "    RESET ✓ PK=$partitionKey RK=$rk · CorrelationId=$cid"
    } catch {
        Write-Warning "    RESET FAILED · RK=$rk · REST said: $($_.Exception.Message)"
        $failed++
    }
}

if ($failed -gt 0) { Write-Error "[Save-XdrCheckpointReset] $failed/$($rowKeys.Count) resets FAILED"; exit 1 }
if ($Apply) { Write-Host "[Save-XdrCheckpointReset] DONE · $($rowKeys.Count) op(s) reset · next TimerTrigger re-emits from clean baseline." }
else { Write-Host "[Save-XdrCheckpointReset] DRY-RUN complete · re-run with -Apply to write the reset rows." }
exit 0
