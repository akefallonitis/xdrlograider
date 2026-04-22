function Get-XdrAuthSelfTestFlag {
    <#
    .SYNOPSIS
        Checks whether the validate-auth-selftest timer has successfully signed into
        the Defender XDR portal at least once.

    .DESCRIPTION
        Production timer functions gate their work on this flag — they refuse to run
        real polling until the self-test timer has produced a Success=true checkpoint
        row. This prevents runaway 401 storms when auth material is misconfigured.

        The checkpoint table row is written by validate-auth-selftest (run.ps1) with:
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

    try {
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        $tbl = Get-AzStorageTable -Name $CheckpointTable -Context $ctx -ErrorAction SilentlyContinue
        if (-not $tbl) { return $false }
        $flag = Get-AzTableRow -Table $tbl.CloudTable -PartitionKey 'auth-selftest' -RowKey 'latest' -ErrorAction SilentlyContinue
        return ($null -ne $flag) -and ($flag.Success -eq $true)
    } catch {
        Write-Warning "Get-XdrAuthSelfTestFlag: failed to read checkpoint table — $_"
        return $false
    }
}
