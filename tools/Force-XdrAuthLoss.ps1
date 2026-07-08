#Requires -Version 7.4
<#
.SYNOPSIS
  Φ4.E/Φ4.G2c-3 · operator-side LIVE forced-auth-loss — invalidates the cached portal session so the next FA
  cycle MUST self-heal, driving the Reauth gate (Verify-DeployedConnector Test-XdrGate_Reauth) with real events.

.DESCRIPTION
  The cached session lives in the XdrTierState Storage Table (PartitionKey=<Portal>, RowKey=<UPN> · written by
  Set-XdrCachedSession / read by Get-XdrCachedSession · Xdr.Common.Cache.psm1:142/187). This tool corrupts or
  removes that row from outside the FA so the next TimerTrigger cycle hits a dead/absent session and re-authenticates.

  -Mode Invalidate (default): overwrite Sccauth + Cookie with a sentinel (keeping ExpiresUtc in the FUTURE so the
     FA still USES the row) → the next poll gets HTML-at-JSON / 401 / 440 → AuthChainBroken → the lease-gated
     REAUTH path fires (Auth.Reauth.Triggered → Auth.Reauth.Succeeded). This is the path the Φ4.E self-heal proof
     + the c83fc18 Reauth gate assert. Self-healing by construction: the reauth re-mints + overwrites the row.

  ⚠ WRITE-BACK RACE (live-verified 2026-06-12): a RUNNING FA holds a good session in its in-memory L1 cache and
     periodically writes it THROUGH to this L2 row — so a corruption injected against a running app can be erased
     by the next write-back BEFORE any read hits it (observed: a 98 ms Auth.Connect.Cached cold-start after a
     13-min-stale inject == the corruption was gone). To force the reactive 440 DETERMINISTICALLY, run the
     sequence STOP → Invalidate(while stopped: no write-back) → START — the cold-start then reads the sentinel
     before it can write-back. Running against a live app at best races; at worst no-ops.
  -Mode Delete: remove the session row entirely → the next cycle does a cold full auth (T1-miss → T3). Simpler;
     proves cold re-auth but may NOT exercise the mid-cycle reauth telemetry.

  AUTH: az CLI `--auth-mode login` (AAD) ONLY — the FA storage account has shared-key DISABLED. The standing
  .env.local SP has Storage Table Data Contributor. NEVER a shared key, NEVER az group/keyvault delete-or-purge,
  NEVER --no-wait. Reversible by design (the FA self-heals on the next cycle; nothing is permanently destroyed).

.PARAMETER UPN
  The service-account UPN (the session RowKey). Omit to invalidate EVERY existing session row in the partition.

.PARAMETER Apply
  Without it the tool is DRY-RUN (prints the planned action · mutates nothing). With it, the row is written/removed.
#>
[CmdletBinding()]
param(
    [string] $Portal = 'Defender',
    [string] $UPN,
    [ValidateSet('Invalidate', 'Delete')] [string] $Mode = 'Invalidate',
    [string] $ResourceGroup,    # C-1: ← .env.local XDRLR_CONNECTOR_RG (or pass)
    [string] $StorageAccount,   # C-1: ← .env.local XDRLR_STORAGE_ACCOUNT (or pass)
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = [System.Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

$runMode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Host "[Force-XdrAuthLoss][$runMode] table=XdrTierState SA=$StorageAccount PK=$Portal Mode=$Mode (AAD --auth-mode login · self-heals next cycle)"

# Resolve the target RowKeys (UPNs) whose session to invalidate.
$rowKeys = @()
if ($UPN) {
    $rowKeys = @($UPN)
} else {
    $raw = az storage entity query --account-name $StorageAccount --auth-mode login --table-name XdrTierState `
        --filter "PartitionKey eq '$Portal'" --select RowKey --num-results 1000 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to query XdrTierState (PK=$Portal) via AAD. Ensure the principal has 'Storage Table Data Contributor'. az said: $raw"
        exit 1
    }
    $rowKeys = @(($raw | ConvertFrom-Json).items | ForEach-Object { $_.RowKey } | Where-Object { $_ })
}

if (-not $rowKeys -or $rowKeys.Count -eq 0) {
    Write-Host "[Force-XdrAuthLoss][$runMode] no session rows for PK=$Portal (the FA may not have authenticated yet · nothing to invalidate)."
    exit 0
}

Write-Host "[Force-XdrAuthLoss][$runMode] $($rowKeys.Count) session(s): $($rowKeys -join ', ')"
$failed = 0

foreach ($rk in $rowKeys) {
    if (-not $Apply) {
        Write-Host "    DRY-RUN · would $Mode session PK=$Portal RK=$rk → FA self-heals (reauth/cold-auth) next cycle"
        continue
    }
    if ($Mode -eq 'Delete') {
        $out = az storage entity delete --account-name $StorageAccount --auth-mode login --table-name XdrTierState `
            --partition-key $Portal --row-key $rk 2>&1
    } else {
        # Invalidate: merge a sentinel-invalid Sccauth + Cookie (keep the rest, incl. a future ExpiresUtc) so the
        # FA USES the row, the poll fails auth, and the REAUTH path fires.
        $sentinel = "XDRLR-FORCED-AUTH-LOSS-$([Guid]::NewGuid().ToString('N'))"
        $out = az storage entity merge --account-name $StorageAccount --auth-mode login --table-name XdrTierState `
            --entity "PartitionKey=$Portal" "RowKey=$rk" "Sccauth=$sentinel" "Cookie=sccauth=$sentinel" 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    $Mode ✓ PK=$Portal RK=$rk"
    } else {
        Write-Warning "    $Mode FAILED · RK=$rk · az said: $out"
        $failed++
    }
}

if ($failed -gt 0) { Write-Error "[Force-XdrAuthLoss] $failed/$($rowKeys.Count) $Mode ops FAILED"; exit 1 }
if ($Apply) { Write-Host "[Force-XdrAuthLoss] DONE · $($rowKeys.Count) session(s) $Mode-d · next cycle self-heals · verify with Verify-DeployedConnector (Reauth dim)." }
else { Write-Host "[Force-XdrAuthLoss] DRY-RUN complete · re-run with -Apply to force the auth-loss." }
exit 0
