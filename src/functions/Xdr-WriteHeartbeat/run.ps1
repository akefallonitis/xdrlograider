# Xdr-WriteHeartbeat — Durable Functions activity (Phase H per directive 16).
#
# Receives the orchestrator's aggregate per-tier metrics and persists a row to
# XdrConnectorHealth_CL via Write-Heartbeat → DCE → DCR. Without this activity,
# the Sentinel data-connector card stays 'Disconnected' because the
# connectivityCriteria gates on StreamsSucceeded > 0 — which only the standalone
# Connector-Heartbeat function would write (always with 0 streams since it
# doesn't poll). Cadence-tier success rows MUST come from this activity.
#
# Activities CAN be non-deterministic — DCE writes, current time, exception
# handling are all OK here. Only the orchestrator must be deterministic.
#
# CRITICAL: The activity parameter MUST NOT be named '$Input' — that name
# shadows PowerShell's automatic $Input variable, causing the Durable input
# binding to silently resolve to an empty pipeline enumerator. Live forensic
# 2026-05-06 (fb2c6f4): the same bug took down Xdr-PollStream activity
# ingestion entirely. Binding name in function.json is 'ActivityInput'.

param($ActivityInput)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Cast the JObject properties to expected types defensively.
$portal           = [string]$ActivityInput.Portal
$tier             = [string]$ActivityInput.Tier
$functionName     = [string]$ActivityInput.FunctionName
$streamsAttempted = [int]$ActivityInput.StreamsAttempted
$streamsSucceeded = [int]$ActivityInput.StreamsSucceeded
$rowsIngested     = [int]$ActivityInput.RowsIngested
$latencyMs        = [int]$ActivityInput.LatencyMs
$instanceId       = [string]$ActivityInput.OrchestrationInstanceId

# Convert errors hashtable (may arrive as JObject) to a Notes property bag.
$errorsCount = 0
$errorsSnippet = ''
if ($ActivityInput.Errors) {
    try {
        $errorsHashtable = @{}
        foreach ($prop in $ActivityInput.Errors.PSObject.Properties) {
            $errorsHashtable[$prop.Name] = [string]$prop.Value
            $errorsCount++
        }
        if ($errorsCount -gt 0) {
            $errorsSnippet = ($errorsHashtable.GetEnumerator() | Select-Object -First 3 | ForEach-Object { "$($_.Key): $($_.Value)" }) -join '; '
        }
    } catch {
        $errorsSnippet = "errors-deserialization-failed: $($_.Exception.Message)"
    }
}

# Resolve heartbeat DCR id from per-stream map (XdrConnectorHealth_CL is in
# the JSON map alongside the data streams).
$heartbeatDcrId = $null
try {
    $heartbeatDcrId = Get-DcrImmutableIdForStream -StreamName 'XdrConnectorHealth_CL'
} catch {
    Write-Warning ("Xdr-WriteHeartbeat: failed to resolve heartbeat DCR id: {0}" -f $_.Exception.Message)
}

if (-not $heartbeatDcrId) {
    $sw.Stop()
    return @{
        Success = $false
        Error   = 'Heartbeat DCR id not resolvable'
        LatencyMs = [int]$sw.ElapsedMilliseconds
    }
}

# Notes structured payload — operators query JSON in workbook.
$notes = @{
    OrchestrationInstanceId = $instanceId
    ErrorsCount             = $errorsCount
    ErrorsSnippet           = $errorsSnippet
}

try {
    Write-Heartbeat `
        -DceEndpoint     $env:DCE_ENDPOINT `
        -DcrImmutableId  $heartbeatDcrId `
        -FunctionName    $functionName `
        -Tier            $tier `
        -StreamsAttempted $streamsAttempted `
        -StreamsSucceeded $streamsSucceeded `
        -RowsIngested    $rowsIngested `
        -LatencyMs       $latencyMs `
        -Portal          $portal `
        -FunctionType    'Durable' `
        -OrchestrationInstanceId $instanceId `
        -Notes           ([pscustomobject]$notes) | Out-Null

    $sw.Stop()
    return @{
        Success    = $true
        Error      = $null
        LatencyMs  = [int]$sw.ElapsedMilliseconds
    }
} catch {
    $sw.Stop()
    if (Get-Command -Name Send-XdrAppInsightsException -ErrorAction SilentlyContinue) {
        Send-XdrAppInsightsException -Exception $_.Exception `
            -SeverityLevel 'Warning' `
            -Properties @{
                Phase    = 'durable-activity-write-heartbeat'
                Tier     = $tier
                Portal   = $portal
                FunctionName = $functionName
            }
    }
    return @{
        Success    = $false
        Error      = $_.Exception.Message
        LatencyMs  = [int]$sw.ElapsedMilliseconds
    }
}
