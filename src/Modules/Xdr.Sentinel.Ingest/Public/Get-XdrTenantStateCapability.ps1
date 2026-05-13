function Get-XdrTenantStateCapability {
    <#
    .SYNOPSIS
        Reads cached tenant capability flags from Storage table XdrTenantState.

    .DESCRIPTION
        Architecture I (Plan R++++++++++): fast lookup of tenant capability flags
        without re-querying MDE_TenantContext_CL each orchestration. Returns the
        latest snapshot written by Set-XdrTenantStateCapability (typically refreshed
        daily on the Inventory cadence).

        Returns a hashtable with capability flags + LastRefreshUtc + LicenseTier +
        Region. Returns $null if the row doesn't exist (caller handles missing
        cache gracefully - polls anyway, no short-circuit).

        Per AMEND-1 #5: capability detection is WARNING-ONLY - never short-circuit
        polling. Use this output to enrich operator-visible context, NOT to gate.

    .PARAMETER StorageAccountName
        FA's Storage account.

    .PARAMETER TableName
        Storage table name. Default: 'XdrTenantState'.

    .PARAMETER TenantId
        Azure AD tenant GUID.

    .OUTPUTS
        Hashtable with capability flags OR $null if not cached yet.

    .EXAMPLE
        $cap = Get-XdrTenantStateCapability -StorageAccountName 'xdrlrst' `
            -TenantId $env:AZURE_TENANT_ID
        if ($cap -and -not $cap.IsMdiActive) {
            Write-Verbose "Tenant lacks MDI - MDI streams will return 4xx; this is expected."
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StorageAccountName,
        [string] $TableName = 'XdrTenantState',
        [Parameter(Mandatory)] [string] $TenantId
    )

    try {
        $row = Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName          $TableName `
            -PartitionKey       'Capability' `
            -RowKey             $TenantId `
            -Operation          'Get'
        if ($null -eq $row) { return $null }
        return $row
    } catch {
        if ("$($_.Exception.Message)" -match 'TableNotFound|404|ResourceNotFound') {
            # Table or row missing — caller treats as "no cache yet"
            return $null
        }
        throw
    }
}
