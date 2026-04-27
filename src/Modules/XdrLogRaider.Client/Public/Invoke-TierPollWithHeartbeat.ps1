function Invoke-TierPollWithHeartbeat {
    <#
    .SYNOPSIS
        Shared timer-function body. Wraps the full per-tier polling lifecycle —
        auth-gate check, credential fetch, portal sign-in, tier poll, heartbeat,
        fatal-error handling — behind a single call so each poll-*/run.ps1
        collapses to two lines.

    .DESCRIPTION
        Replaces ~45 lines of duplicated boilerplate previously copy-pasted
        across the 7 poll-p*/run.ps1 files. Each timer body now becomes:

            param($Timer)
            Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-compliance-1h'

        The helper enforces the canonical execution shape end-to-end:

          1. Strict mode + $ErrorActionPreference = 'Stop'.
          2. Config built directly from $env:* (process-scoped, always
             present per profile.ps1 required-env-vars validation). Iter 13.3
             eliminated runspace-local global state dependency to fix the
             multi-runspace propagation bug.
          3. Auth-self-test gate: skip with an informational heartbeat row if
             validate-auth-selftest hasn't turned green yet. Never silently
             no-ops — operators see a gated row, not zero rows.
          4. Main polling lifecycle, wrapped in top-level try/catch:
                Get-MDEAuthFromKeyVault
                Connect-MDEPortal
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
        One of P0..P7 (excluding P4 which was retired pre-v0.1.0-beta.1).
        Must match a Tier value declared in endpoints.manifest.psd1.

    .PARAMETER FunctionName
        The timer-function folder name (e.g. 'poll-p0-compliance-1h'). Used as
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
        Invoke-TierPollWithHeartbeat -Tier 'P0' -FunctionName 'poll-p0-compliance-1h'
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('P0', 'P1', 'P2', 'P3', 'P5', 'P6', 'P7')]
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
        KeyVaultUri        = $env:KEY_VAULT_URI
        AuthSecretName     = $env:AUTH_SECRET_NAME
        AuthMethod         = $env:AUTH_METHOD
        ServiceAccountUpn  = $env:SERVICE_ACCOUNT_UPN
        DceEndpoint        = $env:DCE_ENDPOINT
        DcrImmutableId     = $env:DCR_IMMUTABLE_ID
        StorageAccountName = $env:STORAGE_ACCOUNT_NAME
        CheckpointTable    = $env:CHECKPOINT_TABLE_NAME
        ExpectedTenantId   = $env:TENANT_ID
    }
    # Defensive: ensure required env vars actually populated (deploy-time
    # appSettings should guarantee, but fail fast if missing).
    foreach ($req in 'KeyVaultUri', 'AuthSecretName', 'AuthMethod', 'DceEndpoint', 'DcrImmutableId', 'StorageAccountName', 'CheckpointTable') {
        if ([string]::IsNullOrWhiteSpace($config.$req)) {
            throw "Required config '$req' (env var) is not set. ARM appSettings deploy may be broken. FunctionName=$FunctionName"
        }
    }

    # Auth-self-test gate: refuse to poll until validate-auth-selftest has
    # signed in at least once. Emits an informational heartbeat row so
    # operators can see "gated, not broken" in MDE_Heartbeat_CL.
    if (-not (Get-XdrAuthSelfTestFlag -StorageAccountName $config.StorageAccountName -CheckpointTable $config.CheckpointTable)) {
        Write-Warning "$FunctionName skipped — auth self-test not yet green"
        Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
            -FunctionName $FunctionName -Tier $Tier `
            -StreamsAttempted 0 -StreamsSucceeded 0 -RowsIngested 0 `
            -LatencyMs ([int]$sw.ElapsedMilliseconds) `
            -Notes ([pscustomobject]@{ skipped = $true; reason = 'auth not validated' }) | Out-Null
        return
    }

    # Top-level try/catch: on any fatal (KV down, auth rejected, DCE unreachable)
    # emit a heartbeat row with Notes.fatalError so operators see the failure
    # in MDE_Heartbeat_CL rather than silence, then re-throw for App Insights.
    try {
        $credential = Get-MDEAuthFromKeyVault -VaultUri $config.KeyVaultUri -SecretName $config.AuthSecretName -AuthMethod $config.AuthMethod
        $session    = Connect-MDEPortal -Method $config.AuthMethod -Credential $credential -PortalHost $Portal

        $result = Invoke-MDETierPoll -Session $session -Tier $Tier -Config $config

        $notes = [ordered]@{ errors = $result.Errors }
        # Pass through Rate429Count + GzipBytes when available (v0.1.0-beta
        # Phase 2 additions — surface rate-limit pressure + compression
        # effectiveness to MDE_Heartbeat_CL).
        if ($result.PSObject.Properties['Rate429Count']) { $notes['rate429Count'] = $result.Rate429Count }
        if ($result.PSObject.Properties['GzipBytes'])    { $notes['gzipBytes']    = $result.GzipBytes }

        Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
            -FunctionName $FunctionName -Tier $Tier `
            -StreamsAttempted $result.StreamsAttempted -StreamsSucceeded $result.StreamsSucceeded `
            -RowsIngested $result.RowsIngested -LatencyMs ([int]$sw.ElapsedMilliseconds) `
            -Notes ([pscustomobject]$notes) | Out-Null

        Write-Information "$FunctionName complete — $($result.StreamsSucceeded)/$($result.StreamsAttempted) streams, $($result.RowsIngested) rows, $([int]$sw.ElapsedMilliseconds)ms"
    } catch {
        $errMsg = $_.Exception.Message
        Write-Error "$FunctionName FATAL: $errMsg"
        try {
            Write-Heartbeat -DceEndpoint $config.DceEndpoint -DcrImmutableId $config.DcrImmutableId `
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
