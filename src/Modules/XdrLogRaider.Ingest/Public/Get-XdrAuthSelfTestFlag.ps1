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

    # Iter 13.14: switched from AzTable's Get-AzTableRow to direct REST API.
    # Same root cause as the validate-auth-selftest gate-flag write — AzTable
    # 2.1.0's older Microsoft.Azure.Cosmos.Table SDK doesn't reliably honor
    # New-AzStorageContext -UseConnectedAccount MI auth. Direct REST with
    # Get-AzAccessToken honors MI auth natively.
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
        $tableToken = if ($tokenObj.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
        } else {
            [string]$tokenObj.Token
        }
        $tableUri = "https://$StorageAccountName.table.core.windows.net/$CheckpointTable(PartitionKey='auth-selftest',RowKey='latest')"
        $headers = @{
            Authorization  = "Bearer $tableToken"
            'x-ms-version' = '2020-12-06'
            'x-ms-date'    = [datetime]::UtcNow.ToString('R')
            'Accept'       = 'application/json;odata=nometadata'
        }
        try {
            $row = Invoke-RestMethod -Method Get -Uri $tableUri -Headers $headers -ErrorAction Stop
        } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
            $status = $null
            if ($null -ne $_.Exception -and $_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response -and $_.Exception.Response.PSObject.Properties['StatusCode']) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -eq 404) {
                # Row doesn't exist yet — auth-selftest hasn't run / hasn't succeeded
                return $false
            }
            throw  # other errors propagate
        }
        return ($null -ne $row) -and ($row.Success -eq $true)
    } catch {
        Write-Warning "Get-XdrAuthSelfTestFlag: failed to read checkpoint table (direct REST) -- $($_.Exception.Message)"
        return $false
    }
}
