function Get-XdrAuthSelfTestFlag {
    <#
    .SYNOPSIS
        Reads the auth-selftest flag (set by first successful poll-* sign-in via
        Set-XdrAuthSelfTestFlag).

    .DESCRIPTION
        Production timer functions gate their work on this flag — they refuse to
        run real polling until the implicit selftest produces a Success=true
        checkpoint row. This prevents runaway 401 storms when auth material is
        misconfigured.

        The checkpoint row's schema (written by Set-XdrAuthSelfTestFlag):
          PartitionKey = 'auth-selftest'
          RowKey       = 'latest'
          Success      = $true / $false
          Stage        = 'complete' / 'fatal' / etc.
          TimeUtc      = last write time (ISO 8601)
          Reason       = optional diagnostic on failure

        Default mode (no switch) returns [bool] — $true iff the row exists with
        Success=$true. Backwards-compatible with pre-cooldown callers.

        -ReturnRow mode returns the full [pscustomobject] (or $null if absent).
        Callers needing cooldown-TTL logic require this — the v0.1.0-beta
        post-deploy cooldown gate in Invoke-TierPollWithHeartbeat reads the
        row to compute (now - TimeUtc) for retry-after-expiry behaviour.

    .PARAMETER StorageAccountName
        Name of the storage account hosting the checkpoint table.

    .PARAMETER CheckpointTable
        Name of the checkpoint table (typically 'connectorCheckpoints').

    .PARAMETER ReturnRow
        Return the full row pscustomobject instead of just [bool]. $null when
        the row doesn't exist yet (first-deploy bootstrap state).

    .OUTPUTS
        [bool] — default mode; $true iff Success=$true
        [pscustomobject] — when -ReturnRow; $null if absent

    .EXAMPLE
        if (-not (Get-XdrAuthSelfTestFlag -StorageAccountName $sa -CheckpointTable 'cp')) {
            Write-Warning 'auth self-test has not passed'
            return
        }

    .EXAMPLE
        $row = Get-XdrAuthSelfTestFlag -StorageAccountName $sa -CheckpointTable 'cp' -ReturnRow
        if ($null -ne $row -and $row.Success -eq $false) {
            $age = [datetime]::UtcNow - ([datetime]$row.TimeUtc).ToUniversalTime()
            if ($age.TotalMinutes -lt 30) { return }   # cooldown
        }
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StorageAccountName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointTable,

        [switch] $ReturnRow
    )

    # Iter 13.15: refactored to use Invoke-XdrStorageTableEntity (unified
    # HttpClient-based Storage Table helper). Helper returns $null on 404
    # (row doesn't exist yet on first-deploy bootstrap state).
    try {
        $row = Invoke-XdrStorageTableEntity `
            -StorageAccountName $StorageAccountName `
            -TableName $CheckpointTable `
            -PartitionKey 'auth-selftest' `
            -RowKey 'latest' `
            -Operation Get -ErrorAction Stop

        if ($ReturnRow) {
            return $row
        }
        if ($null -eq $row) {
            # Row doesn't exist yet — auth-selftest hasn't run / hasn't succeeded
            return $false
        }
        return ($row.Success -eq $true)
    } catch {
        Write-Warning "Get-XdrAuthSelfTestFlag: failed to read checkpoint table -- $($_.Exception.Message)"
        if ($ReturnRow) { return $null }
        return $false
    }
}
