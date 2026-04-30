function Get-XdrAuthSelfTestFlag {
    <#
    .SYNOPSIS
        Checks whether the auth-selftest flag setter (first successful poll-* sign-in) has successfully signed into
        the Defender XDR portal at least once.

    .DESCRIPTION
        Production timer functions gate their work on this flag — they refuse to run
        real polling until the self-test timer has produced a Success=true checkpoint
        row. This prevents runaway 401 storms when auth material is misconfigured.

        The checkpoint table row is written by (first successful poll-* sign-in) with:
          PartitionKey = 'auth-selftest'
          RowKey       = 'latest'
          Success      = $true/$false
          TimeUtc      = last run time

        Any failure reading the table (missing table, permissions, etc.) returns $false
        so timers fail closed rather than polling with bad credentials.

    .PARAMETER StorageAccountName
        Name of the storage account hosting the checkpoint table.

    .PARAMETER CheckpointTable
        Name of the checkpoint table (typically 'connectorCheckpoints').

    .OUTPUTS
        [bool] — $true iff the self-test has produced a successful run row.

    .EXAMPLE
        if (-not (Get-XdrAuthSelfTestFlag -StorageAccountName $config.StorageAccountName -CheckpointTable $config.CheckpointTable)) {
            Write-Warning 'auth self-test has not passed'
            return
        }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointTable
    )

    # Iter 13.15: refactored to use Invoke-XdrStorageTableEntity (unified
    # HttpClient-based Storage Table helper). Replaces inline Invoke-RestMethod
    # block. Helper returns $null on 404 (row doesn't exist yet) so we map that
    # to $false (gate not yet flipped on first deploy).
    try {
        $row = Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $CheckpointTable `
            -PartitionKey 'auth-selftest' `
            -RowKey 'latest' `
            -Operation Get -ErrorAction Stop

        if ($null -eq $row) {
            # Row doesn't exist yet — auth-selftest hasn't run / hasn't succeeded
            return $false
        }
        return ($row.Success -eq $true)
    } catch {
        Write-Warning "Get-XdrAuthSelfTestFlag: failed to read checkpoint table -- $($_.Exception.Message)"
        return $false
    }
}
