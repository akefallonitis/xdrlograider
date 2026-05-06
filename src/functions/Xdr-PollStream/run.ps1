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
#
# CRITICAL: The activity parameter MUST NOT be named '$Input' — that name
# shadows PowerShell's automatic $Input variable (the pipeline enumerator).
# Azure Functions PowerShell host binds the activity input to the parameter,
# but the parameter-vs-automatic ambiguity causes the parameter binding to
# silently resolve to the EMPTY automatic $Input (pipeline enumerator) instead
# of the JObject from Durable. Property access then returns null on every
# field, [string]$null = '', and downstream calls fail with "Unknown Stream ''".
#
# Live forensic 2026-05-06: this caused 100% of activity invocations to throw
# inside their try/catch (Pop-XdrIngestDlq + Invoke-MDEEndpoint both received
# empty Stream values) despite the orchestrator correctly fanning out 2
# matched streams per ActionCenter cadence. Renaming to $ActivityInput fixes it.
param($ActivityInput)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Activity input from Durable orchestrator is a JObject; .Property returns
# JValue. Explicit [string] cast prevents the same JValue->String cast crash
# the orchestrator hit before we fixed it. Safe even if input is already a string.
$portal     = [string]$ActivityInput.Portal
$tier       = [string]$ActivityInput.Tier
$streamName = [string]$ActivityInput.StreamName

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
    DlqTable             = $env:XDR_INGEST_DLQ_TABLE_NAME
    ExpectedTenantId     = $env:TENANT_ID
}

try {
    # Auth — Connect-DefenderPortal caches session per FA instance for ~50 min.
    # First activity in fan-out triggers actual auth; subsequent activities hit cache.
    #
    # Get-XdrAuthFromKeyVault signature:
    #   -VaultUri      (mandatory)  KV URI from env: KEY_VAULT_URI
    #   -SecretPrefix  (default 'mde-portal') from env: AUTH_SECRET_NAME
    #   -AuthMethod    (mandatory)  from env: AUTH_METHOD
    # Returns a hashtable: @{ upn; password; totpBase32 } for CredentialsTotp,
    # @{ upn; passkey } for Passkey, etc. The WHOLE hashtable IS the credential.
    #
    # Connect-DefenderPortal signature:
    #   -Method        (mandatory) AuthMethod string
    #   -Credential    (mandatory) the whole hashtable returned by Get-XdrAuthFromKeyVault
    #   -PortalHost    (optional)  default 'security.microsoft.com'
    #   -TenantId      (optional)  for tenant-scoped sign-in
    # Returns a session object cached for ~50 min keyed by "<upn>::<host>".
    $authBundle = Get-XdrAuthFromKeyVault `
        -VaultUri     $config.KeyVaultUri `
        -SecretPrefix $config.AuthSecretName `
        -AuthMethod   $config.AuthMethod
    $session = Connect-DefenderPortal `
        -Method     $config.AuthMethod `
        -Credential $authBundle `
        -TenantId   $config.ExpectedTenantId

    # Pop any DLQ entries for this stream first (drain before fresh ingest).
    # Pop-XdrIngestDlq signature requires:
    #   -StorageAccountName, -TableName, -StreamName, -MaxBatches  (all mandatory)
    $dlqRows = @()
    try {
        $dlqEntries = Pop-XdrIngestDlq `
            -StorageAccountName $config.StorageAccountName `
            -TableName          $config.DlqTable `
            -StreamName         "Custom-$streamName" `
            -MaxBatches         5
        foreach ($entry in $dlqEntries) { $dlqRows += $entry.Rows }
    } catch {
        Write-Warning ("Xdr-PollStream: DLQ pop failed for {0}: {1}" -f $streamName, $_.Exception.Message)
    }

    # Poll fresh data via the single-endpoint dispatcher. Invoke-MDEEndpoint
    # returns an object[] of DCE-ready rows (NOT a wrapper with .RowsIngested).
    # Signature: -Session (pscustomobject), -Stream (string), -FromUtc (optional),
    # -PathParams (optional). It does NOT take a -Config parameter.
    $freshRows = @(Invoke-MDEEndpoint -Session $session -Stream $streamName)

    # Resolve the per-stream DCR immutableId from the deploy-time map.
    $dcrImmutableIds = $config.DcrImmutableIdsJson | ConvertFrom-Json -AsHashtable
    if (-not $dcrImmutableIds.ContainsKey($streamName)) {
        throw "Stream '$streamName' missing from DCR_IMMUTABLE_IDS_JSON env var"
    }
    $dcrId = [string]$dcrImmutableIds[$streamName]

    # Ingest fresh rows + any DLQ replay rows in a single batch via the DCE.
    $allRows = @($freshRows) + @($dlqRows)
    $rowsIngested = 0
    if ($allRows.Count -gt 0) {
        Send-ToLogAnalytics `
            -DceEndpoint     $config.DceEndpoint `
            -DcrImmutableId  $dcrId `
            -StreamName      "Custom-$streamName" `
            -Rows            $allRows `
            -DlqStorageAccount $config.StorageAccountName | Out-Null
        $rowsIngested = $allRows.Count
    }

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
