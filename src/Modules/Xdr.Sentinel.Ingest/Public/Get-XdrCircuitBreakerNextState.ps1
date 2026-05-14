function Get-XdrCircuitBreakerNextState {
    <#
    .SYNOPSIS
        Pure state-machine helper for the per-stream circuit-breaker
        (Decision 18 — 3 consecutive errors -> open + 30-min cooldown).

    .DESCRIPTION
        Given the prior ConsecutiveErrors counter and the current poll's
        SuccessKind (Rule 6: live / live-empty / rate-limited / error), returns
        the next-state triple that gets written back to XdrTierState:

          ConsecutiveErrors  [int]     0 on success-class, +1 on 'error'
          CircuitState       [string]  'closed' or 'open'
          CooldownUntilUtc   [string]  ISO-8601 when 'open', '' otherwise

        Rule 6 classification (matches Xdr-PollStream wiring):
          live          -> success path (counter resets)
          live-empty    -> success path (counter resets)
          rate-limited  -> success path (apiproxy throttle is transient; the
                           Send-ToLogAnalytics 429 retry handled it)
          error         -> real failure (counter increments; trip at threshold)

        Pure function: no Storage IO, no telemetry, no clock side-effects.
        Caller passes -CurrentUtc when determinism matters (tests).

    .PARAMETER PriorConsecutiveErrors
        The ConsecutiveErrors value read from the prior XdrTierState row, or
        0 if there's no prior row (first poll for this stream).

    .PARAMETER SuccessKind
        One of: 'live' | 'live-empty' | 'rate-limited' | 'error'.

    .PARAMETER CurrentUtc
        UTC clock to use for CooldownUntilUtc. Defaults to [DateTime]::UtcNow.

    .PARAMETER CooldownMinutes
        How long the breaker stays open once tripped. Default: 30 (Decision 18).

    .PARAMETER TripThreshold
        Consecutive errors required to open the breaker. Default: 3 (Decision 18).

    .OUTPUTS
        [hashtable] with keys: ConsecutiveErrors, CircuitState, CooldownUntilUtc.

    .EXAMPLE
        $next = Get-XdrCircuitBreakerNextState -PriorConsecutiveErrors 2 -SuccessKind 'error'
        # -> @{ ConsecutiveErrors = 3; CircuitState = 'open'; CooldownUntilUtc = '2026-05-13T11:30:00.0000000Z' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [int] $PriorConsecutiveErrors,
        [Parameter(Mandatory)]
        [ValidateSet('live','live-empty','rate-limited','error')]
        [string] $SuccessKind,
        [datetime] $CurrentUtc = ([DateTime]::UtcNow),
        [int] $CooldownMinutes = 30,
        [int] $TripThreshold   = 3
    )

    if ($SuccessKind -eq 'error') {
        $newCount = $PriorConsecutiveErrors + 1
        if ($newCount -ge $TripThreshold) {
            return @{
                ConsecutiveErrors = $newCount
                CircuitState      = 'open'
                CooldownUntilUtc  = $CurrentUtc.AddMinutes($CooldownMinutes).ToString('o')
            }
        }
        return @{
            ConsecutiveErrors = $newCount
            CircuitState      = 'closed'
            CooldownUntilUtc  = ''
        }
    }

    return @{
        ConsecutiveErrors = 0
        CircuitState      = 'closed'
        CooldownUntilUtc  = ''
    }
}
