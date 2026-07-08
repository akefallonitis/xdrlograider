# XdrLogRaider · Xdr.Common.Lease module
#
# Purpose: MutexStore primitive · server-enforced distributed mutex for single-flight gating.
#
# Why Azure Blob Lease (not a Table row, not in-process Mutex):
#   - Azure Blob Lease is a purpose-built distributed mutex with server-enforced atomicity.
#     Acquire returns 201 + lease-id atomically; 409 if held. No read-then-write race window.
#   - 60s default duration auto-expires on worker crash (no deadlock).
#   - Cross-instance: works across all FA workers in the App Service Plan, unlike in-process
#     System.Threading.Mutex which is per-process only.
#   - Table-row read-then-write (the prior `Add-AzTableRow -UpdateExisting` approach) has a
#     TOCTOU window: two workers can both observe an expired lease, both attempt to upsert,
#     both succeed. That race is real in our N=10 fan-out under T3+TOTP first-cycle conditions.
#
# Resource model:
#   - Container `leases` in the FA storage account (provisioned by ARM mainTemplate.json).
#   - One empty blob per logical lease key (e.g. "auth__Defender__svc-acct@contoso.com").
#   - Blob name = sanitized ResourceKey (':' → '__' so blob name stays URL-safe).
#
# Public API (drop-in for the prior Lock-XdrSingleFlight / Unlock-XdrSingleFlight pair):
#   Lock-XdrSingleFlight    -ResourceKey -LeaseTtlSeconds  → lease-id or $null (contended)
#   Renew-XdrSingleFlight   -ResourceKey -LeaseToken       → bool (extend a held lease mid-drain · N3)
#   Unlock-XdrSingleFlight  -ResourceKey -LeaseToken       → bool

Set-StrictMode -Version Latest

$script:LeaseContainer = 'leases'

function script:ConvertTo-XdrLeaseBlobName {
    param([Parameter(Mandatory)][string] $ResourceKey)
    # Blob names allow most chars but disallow some control chars and have a 1024-byte limit.
    # ':' and '/' work but ':' isn't pleasant to type/log. Replace ':' with '__' for readability.
    return ($ResourceKey -replace ':', '__')
}

function Lock-XdrSingleFlight {
    <#
    .SYNOPSIS
    Acquire single-flight lease for $ResourceKey. Returns lease-id on success, $null if contended.

    .DESCRIPTION
    Atomic by Azure Blob Lease protocol — no read-then-write race. On worker crash, the lease
    auto-expires after $LeaseTtlSeconds; another worker can then acquire.

    .PARAMETER ResourceKey
    Logical lease key (e.g. "auth::Defender::svc@contoso.com"). Translated to a blob name
    by replacing ':' with '__'. Same key always maps to same blob → only one holder at a time.

    .PARAMETER LeaseTtlSeconds
    Azure Blob Lease duration: 15-60s, or -1 for infinite (don't use -1; worker crash = deadlock).
    Default 60s — covers any single T3 OAuth+TOTP burn (~5-10s typical).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceKey,
        [int] $LeaseTtlSeconds = 60
    )
    if ($LeaseTtlSeconds -lt 15 -or $LeaseTtlSeconds -gt 60) {
        throw "LeaseTtlSeconds must be between 15 and 60 (Azure Blob Lease limit). Got $LeaseTtlSeconds."
    }
    $blobName = ConvertTo-XdrLeaseBlobName -ResourceKey $ResourceKey
    try {
        return (Acquire-XdrBlobLease -Container $script:LeaseContainer -BlobName $blobName -LeaseDurationSeconds $LeaseTtlSeconds)
    } catch {
        Write-Warning "[Lease] Acquire failed for $ResourceKey : $($_.Exception.Message)"
        return $null
    }
}

function Unlock-XdrSingleFlight {
    <#
    .SYNOPSIS
    Release lease for $ResourceKey using the lease-id returned by Lock-XdrSingleFlight.

    .DESCRIPTION
    Azure requires the lease-id to release — prevents spoofing. If the lease already expired
    server-side (worker took >TTL), the release returns 409 which we treat as success
    (the resource is no longer held by us).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ResourceKey,
        [Parameter(Mandatory)] [string] $LeaseToken
    )
    $blobName = ConvertTo-XdrLeaseBlobName -ResourceKey $ResourceKey
    try {
        return (Release-XdrBlobLease -Container $script:LeaseContainer -BlobName $blobName -LeaseId $LeaseToken)
    } catch {
        Write-Warning "[Lease] Release failed for $ResourceKey : $($_.Exception.Message)"
        return $false
    }
}

function Renew-XdrSingleFlight {
    <#
    .SYNOPSIS
    Renew an already-held single-flight lease for $ResourceKey, extending its TTL by another lease window.
    Returns $true on success; $false if the lease was lost (expired / stolen) or the renew call failed.

    .DESCRIPTION
    The poll body can run FAR longer than the 15-60s Azure Blob Lease cap (multi-page drains, slow portal,
    retries with backoff). Without renewal the lease silently expires mid-drain → a concurrently-fired next
    cycle for the SAME Op can acquire it and double-ingest (the N3 exactly-once hole). Call this periodically
    during a long hold, well before the TTL elapses (e.g. every ~40s on a 55s lease). A $false return means
    single-flight is NO LONGER guaranteed: the caller MUST stop and surface it (fail-loud) — never keep
    ingesting under a lost lease.

    .PARAMETER ResourceKey
    The SAME logical lease key passed to Lock-XdrSingleFlight (maps to the same blob).

    .PARAMETER LeaseToken
    The lease-id returned by Lock-XdrSingleFlight. Azure requires it to renew (anti-spoof).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ResourceKey,
        [Parameter(Mandatory)] [string] $LeaseToken
    )
    $blobName = ConvertTo-XdrLeaseBlobName -ResourceKey $ResourceKey
    try {
        return (Renew-XdrBlobLease -Container $script:LeaseContainer -BlobName $blobName -LeaseId $LeaseToken)
    } catch {
        Write-Warning "[Lease] Renew failed for $ResourceKey : $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Lock-XdrSingleFlight, Unlock-XdrSingleFlight, Renew-XdrSingleFlight
