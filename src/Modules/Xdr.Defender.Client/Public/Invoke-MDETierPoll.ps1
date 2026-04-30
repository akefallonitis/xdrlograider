function Invoke-MDETierPoll {
    <#
    .SYNOPSIS
        Polls every endpoint in a given cadence tier (fast | exposure | config |
        inventory | maintenance), batches rows to Log Analytics via DCE, persists
        per-stream checkpoints, and returns aggregate counters.

    .DESCRIPTION
        Called once per timer-function invocation. Encapsulates the repetitive
        loop pattern that previously lived in every `poll-<tier>/run.ps1` file:

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
        PortalSession from Connect-DefenderPortal.

    .PARAMETER Tier
        One of fast | exposure | config | inventory | maintenance. Must match
        a 'Tier' value in endpoints.manifest.psd1.

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
        $result = Invoke-MDETierPoll -Session $session -Tier 'fast' -Config $config
        Write-Heartbeat -FunctionName $fnName -Tier 'fast' `
            -StreamsAttempted $result.StreamsAttempted `
            -StreamsSucceeded $result.StreamsSucceeded `
            -RowsIngested     $result.RowsIngested
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)]
        [ValidateSet('fast', 'exposure', 'config', 'inventory', 'maintenance')]
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
    $totalGzipBytes = 0
    $errors = @{}

    # Reset the portal-module cumulative 429 counter so the Rate429Count we
    # surface to the Heartbeat reflects THIS tier's pressure only. Skip if the
    # reset function isn't available (unit-test contexts that don't import
    # Xdr.Defender.Auth) — functional test suites always import both modules.
    if (Get-Command -Name Reset-XdrPortalRate429Count -ErrorAction SilentlyContinue) {
        Reset-XdrPortalRate429Count
    }

    # iter-14.0 Phase 14B: reuse the auth-chain CorrelationId stamped by
    # Connect-DefenderPortal so per-stream Stream.Polled events stitch onto
    # the same end-to-end transaction view as the auth chain that produced
    # the session. Falls back to a fresh GUID per tier-poll for sessions
    # built via Connect-DefenderPortalWithCookies.
    $tierCorrelationId = if ($Session.PSObject.Properties['CorrelationId'] -and $Session.CorrelationId) {
        [string]$Session.CorrelationId
    } else {
        [Guid]::NewGuid().ToString()
    }

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

        # Per-call jitter — spread load off portal burst-detection. 80-320 ms per
        # stream adds ~1-5 s to a typical 15-stream tier poll (well inside the
        # 10-min Function App timeout) while avoiding DoS-pattern request bursts.
        Start-Sleep -Milliseconds (Get-Random -Minimum 80 -Maximum 320)

        $streamsAttempted++
        $streamStartedUtc = [datetime]::UtcNow
        $streamRowsEmitted = 0
        $streamSuccess = $false
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
                $streamRowsEmitted = [int]$result.RowsSent
                if ($result.PSObject.Properties['GzipBytes']) {
                    $totalGzipBytes += [long]$result.GzipBytes
                }
            }
            # Checkpoint update regardless of row count — "we ran successfully".
            Set-CheckpointTimestamp `
                -StorageAccountName $Config.StorageAccountName `
                -TableName          $Config.CheckpointTable `
                -StreamName         $stream
            $streamsSucceeded++
            $streamSuccess = $true
        } catch {
            $errors[$stream] = $_.Exception.Message
            Write-Warning "Invoke-MDETierPoll Tier='$Tier' Stream='$stream' failed: $_"
        }
        # iter-14.0 Phase 14B: per-stream completion event (success OR failure).
        # Pairs with the AuthChain.* events on the same OperationId so operators
        # can read end-to-end timing in App Insights' transaction view.
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            $streamLatencyMs = [int]([datetime]::UtcNow - $streamStartedUtc).TotalMilliseconds
            Send-XdrAppInsightsCustomEvent -EventName 'Stream.Polled' -OperationId $tierCorrelationId -Properties @{
                Stream       = $stream
                Tier         = $Tier
                RowsEmitted  = $streamRowsEmitted
                LatencyMs    = $streamLatencyMs
                Success      = [string]$streamSuccess
            }
        }
    }

    # Read the cumulative 429 count from Xdr.Defender.Auth for this tier.
    $rate429 = 0
    if (Get-Command -Name Get-XdrPortalRate429Count -ErrorAction SilentlyContinue) {
        $rate429 = [int](Get-XdrPortalRate429Count)
    }

    return [pscustomobject]@{
        StreamsAttempted = $streamsAttempted
        StreamsSucceeded = $streamsSucceeded
        StreamsSkipped   = $streamsSkipped
        RowsIngested     = $totalRows
        Errors           = $errors
        Rate429Count     = $rate429
        GzipBytes        = $totalGzipBytes
    }
}
