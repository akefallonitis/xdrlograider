# Xdr-PollStream — Durable Functions activity (Phase H per directive 16).
#
# Receives input: @{ Portal, Tier, StreamName, StreamPath }
# Performs auth (cached per FA instance via Connect-DefenderPortal's session
# cache) + single-stream poll + Send-ToLogAnalytics ingest.
# Returns: @{ StreamName, RowsIngested, LatencyMs, Success, Error }
#
# Activities CAN be non-deterministic (KV reads, portal API calls, current
# time, exception handling) — only orchestrators must be deterministic.
#
# Per .claude/plans/immutable-splashing-waffle.md Section 2.A.

param($Input)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Activity input from Durable orchestrator is a JObject; .Property returns
# JValue. Explicit [string] cast prevents the same JValue->String cast crash
# the orchestrator hit before we fixed it. Safe even if input is already a string.
$portal     = [string]$Input.Portal
$tier       = [string]$Input.Tier
$streamName = [string]$Input.StreamName

# Read FA config from $env:* (process-scoped; always present per profile.ps1)
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

try {
    # Auth — Connect-DefenderPortal caches session per FA instance for ~50 min.
    # First activity in fan-out triggers actual auth; subsequent activities hit cache.
    # Param names match the actual Get-XdrAuthFromKeyVault signature:
    #   -VaultUri      (was wrongly named -KeyVaultUri)
    #   -SecretPrefix  (was wrongly named -SecretName)
    #   -AuthMethod    (correct)
    # ServiceAccountUpn / ExpectedTenantId are NOT params of Get-XdrAuthFromKeyVault;
    # they're passed to Connect-DefenderPortal further down.
    $authBundle = Get-XdrAuthFromKeyVault `
        -VaultUri     $config.KeyVaultUri `
        -SecretPrefix $config.AuthSecretName `
        -AuthMethod   $config.AuthMethod
    $session = Connect-DefenderPortal -Method $config.AuthMethod `
        -Credential $authBundle.Credential `
        -TotpBase32Secret $authBundle.TotpBase32Secret `
        -PasskeyJsonPath $authBundle.PasskeyJsonPath `
        -ServiceAccountUpn $config.ServiceAccountUpn `
        -ExpectedTenantId $config.ExpectedTenantId

    # Pop any DLQ entries for this stream first (drain before fresh ingest)
    $dlqRows = @()
    try {
        $dlqEntries = Pop-XdrIngestDlq -StorageAccountName $config.StorageAccountName -StreamName "Custom-$streamName" -MaxBatches 5
        foreach ($entry in $dlqEntries) {
            $dlqRows += $entry.Rows
        }
    } catch {
        Write-Warning ("Xdr-PollStream: DLQ pop failed for {0}: {1}" -f $streamName, $_.Exception.Message)
    }

    # Poll fresh data via single-endpoint dispatch
    $result = Invoke-MDEEndpoint -Session $session -Stream $streamName -Config $config
    $rowsIngested = if ($result -and $result.RowsIngested) { [int]$result.RowsIngested } else { 0 }

    $sw.Stop()
    return @{
        StreamName    = $streamName
        Tier          = $tier
        Portal        = $portal
        RowsIngested  = $rowsIngested
        LatencyMs     = [int]$sw.ElapsedMilliseconds
        Success       = $true
        Error         = $null
        DlqDrained    = $dlqRows.Count
    }
} catch {
    $sw.Stop()
    $errMsg = $_.Exception.Message
    # Emit AppInsights exception with stream context for forensic visibility
    if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsException -Exception $_.Exception `
            -SeverityLevel 'Warning' `
            -Properties @{
                Stream    = $streamName
                Tier      = $tier
                Portal    = $portal
                Phase     = 'durable-activity-poll'
            }
    }
    return @{
        StreamName    = $streamName
        Tier          = $tier
        Portal        = $portal
        RowsIngested  = 0
        LatencyMs     = [int]$sw.ElapsedMilliseconds
        Success       = $false
        Error         = $errMsg
        DlqDrained    = 0
    }
}
