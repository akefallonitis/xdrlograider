function Invoke-MDETierPoll {
    <#
    .SYNOPSIS
        Polls every endpoint in a given tier (P0-P3, P5-P7), batches rows to Log
        Analytics via DCE, persists per-stream checkpoints, and returns aggregate
        counters.

    .DESCRIPTION
        Called once per timer-function invocation. Encapsulates the repetitive
        loop pattern that previously lived in every `poll-p<tier>/run.ps1` file:

          1. Read endpoints.manifest.psd1 filtered by -Tier.
          2. For each stream in the tier:
             a. If the manifest entry has `Filter`, read the per-stream checkpoint
                via Get-CheckpointTimestamp and pass it as -FromUtc.
             b. Call Invoke-MDEEndpoint -Stream $s (+ -FromUtc if filterable).
             c. Send rows to DCE via Send-ToLogAnalytics.
             d. On success, write a fresh checkpoint via Set-CheckpointTimestamp.
             e. On per-stream failure, record the error and continue (other streams
                in the tier still get their chance).
          3. Return a counter object consumable by Write-Heartbeat.

        This function does NOT handle auth-selftest gating (caller must check via
        Get-XdrAuthSelfTestFlag before invoking), connection setup (caller
        manages Session lifecycle), or heartbeat emission (caller decides how to
        surface the result).

    .PARAMETER Session
        PortalSession from Connect-MDEPortal.

    .PARAMETER Tier
        Tier to poll. Must match a 'Tier' value in endpoints.manifest.psd1.

    .PARAMETER Config
        Hashtable/pscustomobject with the connector's runtime config. Required keys:
          DceEndpoint, DcrImmutableId, StorageAccountName, CheckpointTable.

    .PARAMETER IncludeDeferred
        DEPRECATED — v0.1.0-beta.1 removed the `Deferred` flag in favour of
        `Availability` (live|tenant-gated|role-gated). Every entry is attempted
        by default; tenant-gated/role-gated streams 4xx gracefully and produce
        zero rows without failure. The switch is retained for back-compat.

    .OUTPUTS
        [pscustomobject] with fields:
          StreamsAttempted  [int]
          StreamsSucceeded  [int]
          StreamsSkipped    [int]   (always 0 post v0.1.0-beta.1; retained for compat)
          RowsIngested      [int]
          Errors            [hashtable]  (stream-name → error message)

    .EXAMPLE
        # Typical timer body
        $result = Invoke-MDETierPoll -Session $session -Tier 'P0' -Config $config
        Write-Heartbeat -FunctionName $fnName -Tier 'P0' `
            -StreamsAttempted $result.StreamsAttempted `
            -StreamsSucceeded $result.StreamsSucceeded `
            -RowsIngested     $result.RowsIngested
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)]
        [ValidateSet('P0', 'P1', 'P2', 'P3', 'P5', 'P6', 'P7')]
        [string] $Tier,
        [Parameter(Mandatory)] $Config,
        [switch] $IncludeDeferred
    )

    $manifest = Get-MDEEndpointManifest
    $tierStreams = @(
        $manifest.Values |
            Where-Object { $_.Tier -eq $Tier } |
            Sort-Object Stream
    )

    if ($tierStreams.Count -eq 0) {
        Write-Warning "Invoke-MDETierPoll: no streams declared for Tier '$Tier' in manifest"
        return [pscustomobject]@{
            StreamsAttempted = 0
            StreamsSucceeded = 0
            StreamsSkipped   = 0
            RowsIngested     = 0
            Errors           = @{}
        }
    }

    $streamsAttempted = 0
    $streamsSucceeded = 0
    $streamsSkipped   = 0
    $totalRows = 0
    $errors = @{}

    foreach ($entry in $tierStreams) {
        $stream = $entry.Stream

        # v0.1.0-beta.1: `Deferred` flag is deprecated. Every entry in the manifest
        # has a documented wire contract and is attempted every poll cycle.
        # tenant-gated / role-gated streams 4xx gracefully — caught by the try
        # below, producing zero rows without failing the tier. Back-compat: if an
        # older manifest still carries Deferred=$true and the caller passes
        # -IncludeDeferred:$false, we honour that too.
        if ((-not $IncludeDeferred.IsPresent) -and $entry.ContainsKey('Deferred') -and $entry.Deferred) {
            $streamsSkipped++
            Write-Verbose "Invoke-MDETierPoll Tier='$Tier' Stream='$stream' skipped (legacy Deferred=true)"
            continue
        }

        $streamsAttempted++
        try {
            $invokeArgs = @{ Session = $Session; Stream = $stream }

            # Incremental fetch: if this endpoint supports server-side filtering,
            # pass the last-success timestamp.
            if ($entry.ContainsKey('Filter') -and $entry.Filter) {
                $since = Get-CheckpointTimestamp `
                    -StorageAccountName $Config.StorageAccountName `
                    -TableName          $Config.CheckpointTable `
                    -StreamName         $stream
                if ($since) {
                    $invokeArgs['FromUtc'] = $since
                } else {
                    # First run — default to last hour so we don't over-pull history
                    $invokeArgs['FromUtc'] = [datetime]::UtcNow.AddHours(-1)
                }
            }

            $rows = Invoke-MDEEndpoint @invokeArgs
            if ($rows -and $rows.Count -gt 0) {
                $result = Send-ToLogAnalytics `
                    -DceEndpoint    $Config.DceEndpoint `
                    -DcrImmutableId $Config.DcrImmutableId `
                    -StreamName     "Custom-$stream" `
                    -Rows           $rows
                $totalRows += [int]$result.RowsSent
            }
            # Checkpoint update regardless of row count — "we ran successfully".
            Set-CheckpointTimestamp `
                -StorageAccountName $Config.StorageAccountName `
                -TableName          $Config.CheckpointTable `
                -StreamName         $stream
            $streamsSucceeded++
        } catch {
            $errors[$stream] = $_.Exception.Message
            Write-Warning "Invoke-MDETierPoll Tier='$Tier' Stream='$stream' failed: $_"
        }
    }

    return [pscustomobject]@{
        StreamsAttempted = $streamsAttempted
        StreamsSucceeded = $streamsSucceeded
        StreamsSkipped   = $streamsSkipped
        RowsIngested     = $totalRows
        Errors           = $errors
    }
}
