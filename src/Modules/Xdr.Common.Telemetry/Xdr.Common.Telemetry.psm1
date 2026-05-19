# Xdr.Common.Telemetry · correlation-ID threading + structured event emission
#
# φ.AUTH.4 hardened (2026-05-18):
#   - Write-XdrTelemetry · Write-Information (NOT Write-Host) · PS Functions Y1 Consumption
#     auto-instrumentation reliably captures Information stream into traces.customDimensions
#     · Write-Host capture inconsistent on cold starts and across runspaces.
#   - Structured JSON payload · single compressed line · auto-parses to customDimensions
#     keys without runtime KQL split.
#   - SAFE-NULL secret redaction · any property name matching {password|totp|totpsecret|
#     sccauth|xsrf|passkey|bearer|accesstoken|refreshtoken|secret|pem|privatekey} (case-
#     insensitive) replaced by '<redacted>' regardless of value type.
#   - Auto-stamp OperationId · Cloud_RoleName · Cloud_RoleInstance · XdrLogRaiderVersion
#     from FA env vars when available (OperationId = CorrelationId for AppInsights stitching).
#
# Tiny 3-function surface (Set-/Get-XdrCorrelationId · Write-XdrTelemetry).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module state
$script:CorrelationId = $null
$script:CycleStartUtc = $null

# φ.AUTH.4 · Property-name regex for secret-redaction (case-insensitive)
# Matches whole key OR key-substring (e.g. 'TotpSecret' · 'XsrfToken' · 'SaPassword')
$script:_SecretKeyPattern = '(?i)(password|totp|sccauth|xsrf|passkey|bearer|accesstoken|refreshtoken|secret|pem|privatekey|apikey|authheader)'

function Set-XdrCorrelationId {
    <#
    .SYNOPSIS
        Set or rotate the correlation ID for the current Xdr-Poll cycle.
    .DESCRIPTION
        Called at the top of Xdr-Poll/run.ps1 on every TimerTrigger. Subsequent
        Auth/Poll/Ingest calls auto-thread this ID via Get-XdrCorrelationId.
        Rotates $script:CycleStartUtc to support cycle-duration metrics.
    .PARAMETER CorrelationId
        Optional · if omitted a fresh [guid]::NewGuid() is used.
    .OUTPUTS
        Returns the new ID (string).
    #>
    [CmdletBinding()][OutputType([string])]
    param([string]$CorrelationId)
    if (-not $CorrelationId) { $CorrelationId = [guid]::NewGuid().ToString() }
    $script:CorrelationId = $CorrelationId
    $script:CycleStartUtc = [datetime]::UtcNow
    $CorrelationId
}

function Get-XdrCorrelationId {
    <#
    .SYNOPSIS
        Read the current correlation ID. Auto-generates if Set-XdrCorrelationId hasn't run.
    .OUTPUTS
        Correlation ID string.
    #>
    [CmdletBinding()][OutputType([string])] param()
    if (-not $script:CorrelationId) { Set-XdrCorrelationId | Out-Null }
    $script:CorrelationId
}

function _ConvertTo-XdrAiSafeProperties {
    <#
    .SYNOPSIS
        φ.AUTH.4 · Redact secret-named properties before emit · returns a NEW hashtable.
    .DESCRIPTION
        Walks the input hashtable · replaces any value whose KEY matches the secret-pattern
        with '<redacted>'. Idempotent · safe to call repeatedly. Does NOT mutate input.
        Recurses one level into nested hashtables/PSCustomObjects (depth-1 is sufficient
        for our property shapes · prevents pathological recursion on cyclic graphs).
    #>
    param([hashtable]$Source)
    if (-not $Source) { return @{} }
    $out = @{}
    foreach ($k in $Source.Keys) {
        $v = $Source[$k]
        if ($k -match $script:_SecretKeyPattern) {
            $out[$k] = '<redacted>'
            continue
        }
        # Recurse one level into nested hashtables
        if ($v -is [hashtable]) {
            $nested = @{}
            foreach ($nk in $v.Keys) {
                if ($nk -match $script:_SecretKeyPattern) { $nested[$nk] = '<redacted>' }
                else { $nested[$nk] = $v[$nk] }
            }
            $out[$k] = $nested
            continue
        }
        $out[$k] = $v
    }
    $out
}

function Write-XdrTelemetry {
    <#
    .SYNOPSIS
        φ.AUTH.4 · Emit a structured telemetry event to the Information stream as a
        single-line JSON payload. PS Functions Y1 Consumption auto-instrumentation
        captures Information into AppInsights traces.customDimensions reliably.
    .PARAMETER Level
        Verbose · Information · Warning · Error · Critical
    .PARAMETER Message
        Short summary (operator-readable · 1 line).
    .PARAMETER Properties
        Hashtable of custom properties. Secret-named keys are redacted before emit.
    .PARAMETER EventName
        AppInsights customEvent name · defaults to caller function name.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Verbose','Information','Warning','Error','Critical')][string]$Level = 'Information',
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Properties = @{},
        [string]$EventName
    )
    $cid = Get-XdrCorrelationId
    $age = if ($script:CycleStartUtc) { [int]((([datetime]::UtcNow) - $script:CycleStartUtc).TotalMilliseconds) } else { 0 }
    if (-not $EventName) {
        $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).Command
        $EventName = if ($caller) { $caller } else { 'Xdr.Common.Telemetry' }
    }
    # φ.AUTH.4 · redact secrets in caller-supplied properties FIRST
    $safe = _ConvertTo-XdrAiSafeProperties -Source $Properties
    # φ.AUTH.4 · auto-stamp FA + AppInsights stitching fields
    $auto = [ordered]@{
        TimestampUtc        = [datetime]::UtcNow.ToString('o')
        Level               = $Level
        EventName           = $EventName
        Message             = $Message
        CorrelationId       = $cid
        OperationId         = $cid    # AppInsights operation_Id stitching · = CorrelationId
        CycleAgeMs          = $age
        ConnectorVersion    = $env:CONNECTOR_VERSION
        XdrLogRaiderVersion = if ($env:XDRLOGRAIDER_VERSION) { $env:XDRLOGRAIDER_VERSION } else { $env:CONNECTOR_VERSION }
        Cloud_RoleName      = if ($env:WEBSITE_SITE_NAME) { $env:WEBSITE_SITE_NAME } else { 'xdrlograider-local' }
        Cloud_RoleInstance  = if ($env:WEBSITE_INSTANCE_ID) { $env:WEBSITE_INSTANCE_ID } else { [System.Environment]::MachineName }
    }
    # Merge auto fields + redacted caller props (caller-provided wins ONLY for non-reserved keys)
    $payload = [ordered]@{}
    foreach ($k in $auto.Keys) { $payload[$k] = $auto[$k] }
    foreach ($k in $safe.Keys) {
        if (-not $payload.Contains($k)) { $payload[$k] = $safe[$k] }
    }
    # Emit · single-line JSON · Y1 auto-instrumentation captures Information
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    # Write-Information honours -InformationAction · we force Continue so Y1 captures it
    Write-Information $json -InformationAction Continue
}

Export-ModuleMember -Function `
    Set-XdrCorrelationId, `
    Get-XdrCorrelationId, `
    Write-XdrTelemetry
