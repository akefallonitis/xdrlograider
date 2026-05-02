function Set-XdrAuthSelfTestFlag {
    <#
    .SYNOPSIS
        Writes the auth-selftest flag row consumed by Get-XdrAuthSelfTestFlag.

    .DESCRIPTION
        Counterpart writer to Get-XdrAuthSelfTestFlag. Upserts a single row
        in the connector checkpoint table:
          PartitionKey = 'auth-selftest'
          RowKey       = 'latest'
          Success      = $true / $false (caller-provided)
          Stage        = caller-provided ('complete', 'aadsts-error', etc.)
          TimeUtc      = current UTC
          Reason       = optional caller-provided diagnostic

        Called from Invoke-TierPollWithHeartbeat after the implicit auth-selftest
        completes (i.e., after Connect-DefenderPortal returns), so the gate read
        by Get-XdrAuthSelfTestFlag flips on the first successful poll-* sign-in.
        This closes the v0.1.0-beta first-deploy deadlock where every poll-* would
        skip with "auth not validated" because the gate was never written.

    .PARAMETER StorageAccountName
        Name of the storage account hosting the checkpoint table.

    .PARAMETER CheckpointTable
        Name of the checkpoint table (typically 'connectorCheckpoints').

    .PARAMETER Success
        $true when the implicit selftest passed (sign-in succeeded);
        $false when it failed (caller should set Reason for diagnostics).

    .PARAMETER Stage
        Short label of where in the auth chain we ended ('complete',
        'aadsts-error', 'no-sccauth', etc.). Mirrors the Stage column of
        the legacy MDE_AuthTestResult_CL table; useful for operators
        querying "what stage failed".

    .PARAMETER Reason
        Optional human-readable diagnostic for failures. Empty on success.

    .EXAMPLE
        Set-XdrAuthSelfTestFlag `
            -StorageAccountName 'sa' -CheckpointTable 'connectorCheckpoints' `
            -Success $true -Stage 'complete'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointTable,

        [Parameter(Mandatory)]
        [bool] $Success,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Stage,

        [string] $Reason = ''
    )

    $entity = @{
        Success = $Success
        Stage   = $Stage
        TimeUtc = ([datetime]::UtcNow.ToString('o'))
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $entity['Reason'] = $Reason
    }

    try {
        Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $CheckpointTable `
            -PartitionKey 'auth-selftest' `
            -RowKey 'latest' `
            -Operation Upsert `
            -Entity $entity -ErrorAction Stop | Out-Null
    } catch {
        # Failing to write the gate flag is non-fatal — caller should still
        # complete its work. We surface a warning so operators can see the
        # write failure in heartbeat / App Insights traces.
        Write-Warning "Set-XdrAuthSelfTestFlag: failed to upsert checkpoint table -- $($_.Exception.Message)"
    }
}
