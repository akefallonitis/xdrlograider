function Invoke-TierPollWithHeartbeat {
    <#
    .SYNOPSIS
        Shared timer-function body. Wraps the full per-tier polling lifecycle —
        auth-gate check, credential fetch, portal sign-in, tier poll, heartbeat,
        fatal-error handling — behind a single call so each poll-*/run.ps1
        collapses to two lines.

    .DESCRIPTION
        Replaces ~45 lines of duplicated boilerplate previously copy-pasted
        across the per-cadence poll-*/run.ps1 files. Each timer body now becomes:

            param($Timer)
            Invoke-TierPollWithHeartbeat -Tier 'fast' -FunctionName 'poll-fast-10m'

        The helper enforces the canonical execution shape end-to-end:

          1. Strict mode + $ErrorActionPreference = 'Stop'.
          2. Config built directly from $env:* (process-scoped, always
             present per profile.ps1 required-env-vars validation). Eliminates
             runspace-local global state dependency to fix the multi-runspace
             propagation bug.
          3. Auth-self-test gate: skip with an informational heartbeat row if
             no successful sign-in has happened yet (the auth-selftest flag
             is set the first time any poll-* sign-in succeeds). Never
             silently no-ops — operators see a gated row, not zero rows.
          4. Main polling lifecycle, wrapped in top-level try/catch:
                Get-XdrAuthFromKeyVault
                Connect-DefenderPortal
                Invoke-MDETierPoll
                Write-Heartbeat (success row with Rate429Count + GzipBytes)
          5. Fatal-error catch:
                emit a heartbeat row with Notes.fatalError = exception message,
                guarded by a nested try/catch so a failed heartbeat emit doesn't
                mask the original fatal, then re-throw for App Insights to log.

        Forward-scalable: the optional -Portal parameter (defaults to
        'security.microsoft.com' — the only portal shipped in v0.1.0-beta) is
        passed through to Invoke-MDETierPoll which filters the manifest by both
        Tier AND Portal. Adding a second portal in v0.2.0+ requires zero change
        to this helper or the timer wrappers — just extra manifest entries with
        a non-default Portal value + extra poll-<portal>-<tier> timer files.

    .PARAMETER Tier
        One of fast | exposure | config | inventory | maintenance.
        Must match a Tier value declared in endpoints.manifest.psd1.

    .PARAMETER FunctionName
        The timer-function folder name (e.g. 'poll-fast-10m'). Used as
        the FunctionName label in MDE_Heartbeat_CL so operators can correlate
        heartbeat rows to App Insights invocations.

    .PARAMETER Portal
        Portal host to target. Defaults to 'security.microsoft.com'. In
        v0.1.0-beta every manifest entry is security-portal so the filter is
        a no-op; reserved for v0.2.0+ multi-portal expansion.

    .OUTPUTS
        None. Writes a row to MDE_Heartbeat_CL on every invocation (success or
        fatal). Re-throws on fatal so the Azure Functions runtime marks the
        invocation failed.

    .EXAMPLE
        # Canonical timer body (collapses a ~45-line boilerplate to 2 lines)
        param($Timer)
        Invoke-TierPollWithHeartbeat -Tier 'fast' -FunctionName 'poll-fast-10m'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('fast', 'exposure', 'config', 'inventory', 'maintenance')]
        [string] $Tier,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FunctionName,

        [ValidateNotNullOrEmpty()]
        [string] $Portal = 'security.microsoft.com'
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Information "$FunctionName starting (Tier=$Tier Portal=$Portal)"

    # Iter 13.3: read config directly from $env:* (process-scoped, always
    # present). Eliminates multi-runspace $global propagation bug that caused
    # "$global:XdrLogRaiderConfig not set" crashes in iter 13.x. Each timer
    # tick is now self-sufficient — does not depend on profile.ps1 having
    # populated runspace-local $global state.
    $config = [pscustomobject]@{
        KeyVaultUri          = $env:KEY_VAULT_URI
        AuthSecretName       = $env:AUTH_SECRET_NAME
        AuthMethod           = $env:AUTH_METHOD
        ServiceAccountUpn    = $env:SERVICE_ACCOUNT_UPN
        DceEndpoint          = $env:DCE_ENDPOINT
        DcrImmutableIdsJson  = $env:DCR_IMMUTABLE_IDS_JSON
        StorageAccountName   = $env:STORAGE_ACCOUNT_NAME
        CheckpointTable      = $env:CHECKPOINT_TABLE_NAME
        ExpectedTenantId     = $env:TENANT_ID
    }
    # Defensive: ensure required env vars actually populated (deploy-time
    # appSettings should guarantee, but fail fast if missing).
    # Iter 13.9 (C7): include current value (may be empty/whitespace) in error
    # so operator can distinguish "env var not set at all" vs "set but blank"
    # — both surface as IsNullOrWhiteSpace, but the troubleshooting steps differ.
    foreach ($req in 'KeyVaultUri', 'AuthSecretName', 'AuthMethod', 'DceEndpoint', 'DcrImmutableIdsJson', 'StorageAccountName', 'CheckpointTable') {
        if ([string]::IsNullOrWhiteSpace($config.$req)) {
            $rawValue = $config.$req
            $valueRepr = if ($null -eq $rawValue) { '<null>' } elseif ($rawValue -eq '') { '<empty string>' } else { "<whitespace: '" + ($rawValue -replace '[\s\r\n\t]', ' ') + "'>" }
            throw "Required config '$req' (env var) is blank or not set (currently=$valueRepr). ARM appSettings deploy may be broken. FunctionName=$FunctionName"
        }
    }

    # Resolve the Heartbeat DCR immutableId once — every Write-Heartbeat call
    # in this function targets MDE_Heartbeat_CL, so we look it up upfront and
    # reuse. Per-stream DCR resolution for data streams happens inside
    # Invoke-MDETierPoll using the same helper.
    $heartbeatDcrId = Get-DcrImmutableIdForStream -StreamName 'MDE_Heartbeat_CL'

    # Top-level try/catch: on any fatal (KV down, auth rejected, DCE unreachable)
    # emit a heartbeat row with Notes.fatalError so operators see the failure
    # in MDE_Heartbeat_CL rather than silence, then re-throw for App Insights.
    #
    # The auth-selftest cooldown gate is INSIDE this try (not a separate
    # top-level try) so the catch path covers selftest-read failures + writes
    # the failure flag uniformly. This keeps the helper's structural contract
    # to one top-level try (gated by TimerFunctions.Execution.Tests.ps1).
    try {
        # ---- Auth-self-test gate (v0.1.0-beta post-deploy hardening) ----
        # State machine:
        #   ABSENT                       → proceed (first-deploy bootstrap)
        #   {Success=true}               → proceed (steady state)
        #   {Success=false, age<TTL}     → SKIP   (cooldown — don't spam portal)
        #   {Success=false, age>=TTL}    → proceed (cooldown elapsed; auto-retry)
        # Cooldown TTL = AUTH_SELFTEST_COOLDOWN_MINUTES env var (default 30).
        # Provides automatic retry after operator rotates creds via
        # Initialize-XdrLogRaiderAuth.ps1, without requiring manual flag-clear.
        # The implicit selftest below WRITES the flag on every
        # Connect-DefenderPortal outcome (success → true; throw → false). The
        # CHANGELOG line "auth-selftest flag is set by the first successful
        # poll-* sign-in" describes this; the Set-XdrAuthSelfTestFlag writer
        # was absent in the v0.1.0-beta initial publish — every poll-*
        # deadlocked with reason='auth not validated'. Fixed here.
        $selfTestRow = Get-XdrAuthSelfTestFlag `
            -StorageAccountName $config.StorageAccountName `
            -CheckpointTable $config.CheckpointTable -ReturnRow

        if ($null -ne $selfTestRow -and
            $selfTestRow.PSObject.Properties['Success'] -and
            $selfTestRow.Success -eq $false) {

            $cooldownMinutes = 30
            if (-not [string]::IsNullOrWhiteSpace($env:AUTH_SELFTEST_COOLDOWN_MINUTES)) {
                $envVal = 0
                if ([int]::TryParse($env:AUTH_SELFTEST_COOLDOWN_MINUTES, [ref]$envVal) -and $envVal -gt 0) {
                    $cooldownMinutes = $envVal
                }
            }
            $flagAge = $null
            if ($selfTestRow.PSObject.Properties['TimeUtc']) {
                $flagTime = [datetime]::MinValue
                if ([datetime]::TryParse([string]$selfTestRow.TimeUtc, [ref]$flagTime)) {
                    $flagAge = [datetime]::UtcNow - $flagTime.ToUniversalTime()
                }
            }
            $inCooldown = ($null -ne $flagAge -and $flagAge.TotalMinutes -lt $cooldownMinutes)

            if ($inCooldown) {
                $reason = if ($selfTestRow.PSObject.Properties['Reason']) { [string]$selfTestRow.Reason } else { 'auth-selftest=failed' }
                $remainingMin = [int]($cooldownMinutes - $flagAge.TotalMinutes)
                Write-Warning "$FunctionName skipped — auth-selftest is FAILED ($reason); cooldown ${remainingMin}m remaining. Auto-retry after expiry; operator can clear the cooldown by uploading fresh credentials via Initialize-XdrLogRaiderAuth.ps1."
                Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $heartbeatDcrId `
                    -FunctionName $FunctionName -Tier $Tier `
                    -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
                    -LatencyMs ([int]$sw.ElapsedMilliseconds) `
                    -Notes ([pscustomobject]@{ skipped = $true; reason = "auth-selftest=failed (cooldown ${remainingMin}m remaining): $reason" }) | Out-Null
                return
            }
            # else cooldown elapsed → fall through to retry attempt below
        }

        # ---- Main poll lifecycle ----
        $credential = Get-XdrAuthFromKeyVault -VaultUri $config.KeyVaultUri -SecretPrefix $config.AuthSecretName -AuthMethod $config.AuthMethod
        $session    = Connect-DefenderPortal -Method $config.AuthMethod -Credential $credential -PortalHost $Portal

        # Implicit auth-selftest: connection succeeded → write/refresh the
        # gate flag so subsequent poll-* runs short-circuit the read above.
        # Idempotent (Upsert); cheap (~1 storage-table call per cycle).
        Set-XdrAuthSelfTestFlag `
            -StorageAccountName $config.StorageAccountName `
            -CheckpointTable $config.CheckpointTable `
            -Success $true -Stage 'complete'

        $result = Invoke-MDETierPoll -Session $session -Tier $Tier -Config $config

        $notes = [ordered]@{ errors = $result.Errors }
        # Pass through Rate429Count + GzipBytes when available (v0.1.0-beta
        # Phase 2 additions — surface rate-limit pressure + compression
        # effectiveness to MDE_Heartbeat_CL).
        if ($result.PSObject.Properties['Rate429Count']) { $notes['rate429Count'] = $result.Rate429Count }
        if ($result.PSObject.Properties['GzipBytes'])    { $notes['gzipBytes']    = $result.GzipBytes }

        Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $heartbeatDcrId `
            -FunctionName $FunctionName -Tier $Tier `
            -StreamsAttempted $result.StreamsAttempted -StreamsSucceeded $result.StreamsSucceeded `
            -RowsIngested $result.RowsIngested -LatencyMs ([int]$sw.ElapsedMilliseconds) `
            -Notes ([pscustomobject]$notes) | Out-Null

        Write-Information "$FunctionName complete — $($result.StreamsSucceeded)/$($result.StreamsAttempted) streams, $($result.RowsIngested) rows, $([int]$sw.ElapsedMilliseconds)ms"
    } catch {
        $errMsg = $_.Exception.Message
        Write-Error "$FunctionName FATAL: $errMsg"

        # Implicit auth-selftest FAILURE path: write flag so the gate above
        # cooldown-skips on next run instead of retrying every cadence cycle.
        # Failures BEFORE Connect-DefenderPortal succeeds (KV unreachable,
        # bad credentials, AADSTS, etc.) all flow through here. Failures
        # AFTER successful auth (DCE 5xx, table-missing) also flow here — the
        # next run's cooldown gives the upstream service time to recover.
        try {
            Set-XdrAuthSelfTestFlag `
                -StorageAccountName $config.StorageAccountName `
                -CheckpointTable $config.CheckpointTable `
                -Success $false -Stage 'fatal' -Reason $errMsg
        } catch {
            Write-Warning ("{0}: failed to write auth-selftest=failed flag: {1}" -f $FunctionName, $_.Exception.Message)
        }

        try {
            Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $heartbeatDcrId `
                -FunctionName $FunctionName -Tier $Tier `
                -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
                -LatencyMs ([int]$sw.ElapsedMilliseconds) `
                -Notes ([pscustomobject]@{ fatalError = $errMsg }) | Out-Null
        } catch {
            Write-Warning ("{0}: failed to emit fatal-error heartbeat: {1}" -f $FunctionName, $_.Exception.Message)
        }
        throw
    }
}
