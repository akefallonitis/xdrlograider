# iter-14.0 Phase 14B — Microsoft-best-practices structured logging to App Insights.
#
# This file implements 4 public entry points that wrap the
# Microsoft.ApplicationInsights.Channel.TelemetryClient instance the Azure
# Functions PowerShell host already loads (via the
# APPLICATIONINSIGHTS_CONNECTION_STRING app setting) so callers can emit:
#   - traces           (Send-XdrAppInsightsTrace)
#   - custom events    (Send-XdrAppInsightsCustomEvent)
#   - custom metrics   (Send-XdrAppInsightsCustomMetric)
#   - exceptions       (Send-XdrAppInsightsException)
#
# Auto-stamps shared context on every emission:
#   * OperationId        — pass through $CorrelationId from the auth chain so
#                          AI's end-to-end transaction view stitches across
#                          Connect-DefenderPortal -> Invoke-DefenderPortalRequest
#                          -> Invoke-MDETierPoll. Generates a fresh GUID if not
#                          supplied so logs always carry an op id (single-call
#                          correlation still works in dev/test).
#   * Cloud_RoleName     — $env:WEBSITE_SITE_NAME (Function App name)
#   * Cloud_RoleInstance — $env:WEBSITE_INSTANCE_ID (worker GUID)
#   * XdrLogRaiderVersion — read once at first call from the Ingest module
#                          manifest's ModuleVersion or from
#                          $env:XDRLR_VERSION (override).
#
# Secret redaction (SAFE-NULL): keys named password / totpBase32 / sccauth /
# xsrfToken / passkey / privateKey (case-insensitive) have their values
# replaced with '<redacted>' BEFORE the property bag is handed to the
# TelemetryClient. Operators must NEVER accidentally leak secrets via a
# Properties splat.
#
# Backward-compat: if the TelemetryClient type is not loadable (unit-test /
# dev-time / when the AI worker hasn't initialized yet), every function
# falls back to Write-Information so callers never crash. The AI emission
# is ADDITIVE — auth chain still works without it.

# Module-scope cache of the TelemetryClient. Resolved lazily on first call so
# unit tests that import the module without the FA host running don't fail.
$script:XdrAiTelemetryClient    = $null
$script:XdrAiTelemetryClientTried = $false
$script:XdrAiVersion             = $null
$script:XdrAiSecretKeyPattern    = '^(password|totpBase32|sccauth|xsrfToken|passkey|privateKey)$'


function Get-XdrAiTelemetryClient {
    <#
    .SYNOPSIS
        Returns the cached TelemetryClient instance, or $null if it can't be
        resolved (unit-test / dev-time).

    .DESCRIPTION
        The Azure Functions PowerShell host loads
        Microsoft.ApplicationInsights.Channel.TelemetryClient automatically
        when APPLICATIONINSIGHTS_CONNECTION_STRING is set. We try to construct
        one with the default channel; if the type isn't loaded, we cache $null
        so subsequent calls don't pay the load cost.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()

    if ($script:XdrAiTelemetryClientTried) {
        return $script:XdrAiTelemetryClient
    }
    $script:XdrAiTelemetryClientTried = $true

    try {
        $clientType = [System.Type]::GetType('Microsoft.ApplicationInsights.TelemetryClient, Microsoft.ApplicationInsights', $false)
        if (-not $clientType) {
            return $null
        }
        $cs = [Environment]::GetEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING')
        if ([string]::IsNullOrWhiteSpace($cs)) {
            # The FA host normally pre-builds a default TelemetryClient that
            # picks up the connection string from environment, but if the env
            # var is missing we can't resolve a client either.
            return $null
        }
        $configType = [System.Type]::GetType('Microsoft.ApplicationInsights.Extensibility.TelemetryConfiguration, Microsoft.ApplicationInsights', $false)
        if (-not $configType) {
            return $null
        }
        $config = $configType::CreateDefault()
        $config.ConnectionString = $cs
        $client = [Activator]::CreateInstance($clientType, @($config))
        $script:XdrAiTelemetryClient = $client
        return $client
    } catch {
        # Strict-mode safe: an exception loading types collapses to null —
        # callers fall through to Write-Information.
        return $null
    }
}


function Get-XdrAiVersion {
    <#
    .SYNOPSIS
        Resolves the XdrLogRaider connector version once, caches the result.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:XdrAiVersion) {
        return $script:XdrAiVersion
    }

    # Allow operators to override via env var (deployments may stamp it).
    $envVer = [Environment]::GetEnvironmentVariable('XDRLR_VERSION')
    if (-not [string]::IsNullOrWhiteSpace($envVer)) {
        $script:XdrAiVersion = $envVer
        return $envVer
    }

    # Read the Ingest module manifest's ModuleVersion. PSScriptRoot points at
    # Xdr.Sentinel.Ingest/Public — manifest is one level up.
    try {
        $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Xdr.Sentinel.Ingest.psd1'
        if (Test-Path -LiteralPath $manifestPath) {
            $data = Import-PowerShellDataFile -Path $manifestPath
            if ($data -and $data.ModuleVersion) {
                $script:XdrAiVersion = [string]$data.ModuleVersion
                return $script:XdrAiVersion
            }
        }
    } catch {
        # Diagnostic emission; never crash on read failure.
    }
    $script:XdrAiVersion = 'unknown'
    return $script:XdrAiVersion
}


function ConvertTo-XdrAiSafeProperties {
    <#
    .SYNOPSIS
        SAFE-NULL secret redaction. Returns a NEW string-string dictionary
        with values cast to string. Any key matching the secret-key regex
        has its value replaced with '<redacted>'.

    .DESCRIPTION
        Microsoft.ApplicationInsights expects properties as
        IDictionary<string,string>. We hand it a fresh dictionary every
        emission so caller hashtables are never mutated.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string,string]])]
    param(
        [hashtable] $Properties
    )

    $result = [System.Collections.Generic.Dictionary[string,string]]::new()
    if (-not $Properties -or $Properties.Count -eq 0) {
        return ,$result
    }
    foreach ($key in $Properties.Keys) {
        $sKey = [string]$key
        $rawVal = $Properties[$key]
        $sVal = if ($null -eq $rawVal) { '' } else { [string]$rawVal }
        if ($sKey -match $script:XdrAiSecretKeyPattern) {
            $sVal = '<redacted>'
        }
        $result[$sKey] = $sVal
    }
    return ,$result
}


function Add-XdrAiAmbientContext {
    <#
    .SYNOPSIS
        Stamps the ambient context (OperationId / Cloud_RoleName /
        Cloud_RoleInstance / XdrLogRaiderVersion) onto a properties dictionary
        + returns a [pscustomobject] containing the resolved OperationId so
        callers (and the TelemetryClient.Context.Operation.Id) can use it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [System.Collections.Generic.Dictionary[string,string]] $Properties,
        [string] $OperationId
    )

    $opId = if ([string]::IsNullOrWhiteSpace($OperationId)) {
        [Guid]::NewGuid().ToString()
    } else {
        $OperationId
    }

    $roleName     = [Environment]::GetEnvironmentVariable('WEBSITE_SITE_NAME')
    $roleInstance = [Environment]::GetEnvironmentVariable('WEBSITE_INSTANCE_ID')
    $version      = Get-XdrAiVersion

    if ($Properties) {
        # Stamp on properties so legacy AI consumers that ignore Operation.Id
        # still see the correlation field. Don't overwrite caller-supplied keys.
        if (-not $Properties.ContainsKey('OperationId'))         { $Properties['OperationId']         = $opId }
        if (-not $Properties.ContainsKey('Cloud_RoleName') -and $roleName)         { $Properties['Cloud_RoleName']     = [string]$roleName }
        if (-not $Properties.ContainsKey('Cloud_RoleInstance') -and $roleInstance) { $Properties['Cloud_RoleInstance'] = [string]$roleInstance }
        if (-not $Properties.ContainsKey('XdrLogRaiderVersion'))  { $Properties['XdrLogRaiderVersion'] = $version }
    }

    return [pscustomobject]@{
        OperationId        = $opId
        RoleName           = $roleName
        RoleInstance       = $roleInstance
        Version            = $version
    }
}


function Set-XdrAiTelemetryContext {
    <#
    .SYNOPSIS
        Mirrors the ambient context onto the TelemetryClient.Context fields
        before each emission so AI's end-to-end transaction view stitches
        operations correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Client,
        [Parameter(Mandatory)] [pscustomobject] $Ambient
    )

    try {
        if ($Client.Context.Operation -and $Ambient.OperationId) {
            $Client.Context.Operation.Id = $Ambient.OperationId
        }
        if ($Client.Context.Cloud) {
            if ($Ambient.RoleName)     { $Client.Context.Cloud.RoleName     = $Ambient.RoleName }
            if ($Ambient.RoleInstance) { $Client.Context.Cloud.RoleInstance = $Ambient.RoleInstance }
        }
    } catch {
        # Context fields may be read-only on some SDK versions — emission
        # still proceeds with the property-bag fallback.
    }
}


function Resolve-XdrAiSeverityLevel {
    <#
    .SYNOPSIS
        Maps a string severity to the SDK's SeverityLevel enum. Returns the
        underlying int if the enum type isn't loadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SeverityLevel
    )
    $svMap = @{
        Verbose     = 0
        Information = 1
        Warning     = 2
        Error       = 3
        Critical    = 4
    }
    $intVal = if ($svMap.ContainsKey($SeverityLevel)) { $svMap[$SeverityLevel] } else { 1 }
    try {
        $enumType = [System.Type]::GetType('Microsoft.ApplicationInsights.DataContracts.SeverityLevel, Microsoft.ApplicationInsights', $false)
        if ($enumType) {
            return [Enum]::Parse($enumType, $SeverityLevel, $true)
        }
    } catch {}
    return $intVal
}


function Send-XdrAppInsightsTrace {
    <#
    .SYNOPSIS
        Emit a structured trace (TrackTrace) to App Insights with auto-stamped
        ambient context.

    .PARAMETER Message
        Free-text message body. Keep low-cardinality; per Microsoft best
        practice, structured property keys go in -Properties.

    .PARAMETER SeverityLevel
        Maps to Microsoft.ApplicationInsights.DataContracts.SeverityLevel.

    .PARAMETER Properties
        Hashtable of structured key/value pairs that surface as
        customDimensions.* in KQL. Secret-key values are redacted.

    .PARAMETER OperationId
        Pass-through correlation GUID (typically $CorrelationId from
        Connect-DefenderPortal). When omitted, a fresh GUID is generated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Verbose','Information','Warning','Error','Critical')]
        [string] $SeverityLevel = 'Information',
        [hashtable] $Properties,
        [string] $OperationId
    )

    $props   = ConvertTo-XdrAiSafeProperties -Properties $Properties
    $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $OperationId

    $client = Get-XdrAiTelemetryClient
    if ($null -eq $client) {
        # Fallback path: Write-Information so the line still lands in
        # FunctionAppLogs / live tail when AI isn't loaded.
        Write-Information ("XdrAI TRACE [{0}] op={1} {2}" -f $SeverityLevel, $ambient.OperationId, $Message)
        return
    }
    Set-XdrAiTelemetryContext -Client $client -Ambient $ambient
    try {
        $sev = Resolve-XdrAiSeverityLevel -SeverityLevel $SeverityLevel
        $client.TrackTrace($Message, $sev, $props)
    } catch {
        Write-Information ("XdrAI TRACE-FALLBACK op={0} err={1} msg={2}" -f $ambient.OperationId, $_.Exception.Message, $Message)
    }
}


function Send-XdrAppInsightsCustomEvent {
    <#
    .SYNOPSIS
        Emit a custom event (TrackEvent) to App Insights. Use for discrete
        well-typed business events (AuthChain.CacheHit, Stream.Polled, …)
        that operators query via `customEvents | where name == '...'`.

    .PARAMETER EventName
        Event name (low cardinality — operators filter by this in KQL).

    .PARAMETER Properties
        Structured property bag. Secret-key values are redacted.

    .PARAMETER OperationId
        Correlation GUID. See Send-XdrAppInsightsTrace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EventName,
        [hashtable] $Properties,
        [string] $OperationId
    )

    $props   = ConvertTo-XdrAiSafeProperties -Properties $Properties
    $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $OperationId

    $client = Get-XdrAiTelemetryClient
    if ($null -eq $client) {
        Write-Information ("XdrAI EVENT [{0}] op={1}" -f $EventName, $ambient.OperationId)
        return
    }
    Set-XdrAiTelemetryContext -Client $client -Ambient $ambient
    try {
        $client.TrackEvent($EventName, $props, $null)
    } catch {
        Write-Information ("XdrAI EVENT-FALLBACK op={0} err={1} name={2}" -f $ambient.OperationId, $_.Exception.Message, $EventName)
    }
}


function Send-XdrAppInsightsCustomMetric {
    <#
    .SYNOPSIS
        Emit a custom metric (TrackMetric) to App Insights.

    .PARAMETER MetricName
        Low-cardinality metric name (Stream.LatencyMs, Rate429Count, …).

    .PARAMETER Value
        Numeric value to record.

    .PARAMETER Properties
        Optional dimensions (Stream='MDE_PUAConfig_CL', Tier='P0', …).

    .PARAMETER OperationId
        Correlation GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MetricName,
        [Parameter(Mandatory)] [double] $Value,
        [hashtable] $Properties,
        [string] $OperationId
    )

    $props   = ConvertTo-XdrAiSafeProperties -Properties $Properties
    $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $OperationId

    $client = Get-XdrAiTelemetryClient
    if ($null -eq $client) {
        Write-Information ("XdrAI METRIC {0}={1} op={2}" -f $MetricName, $Value, $ambient.OperationId)
        return
    }
    Set-XdrAiTelemetryContext -Client $client -Ambient $ambient
    try {
        $client.GetMetric($MetricName).TrackValue($Value)
        # Also TrackMetric so dimensional properties land on the metric record
        # via the legacy API surface (newer GetMetric() drops custom dims).
        $client.TrackMetric($MetricName, $Value, $props)
    } catch {
        Write-Information ("XdrAI METRIC-FALLBACK op={0} err={1} name={2}" -f $ambient.OperationId, $_.Exception.Message, $MetricName)
    }
}


function Send-XdrAppInsightsException {
    <#
    .SYNOPSIS
        Emit an exception (TrackException) to App Insights.

    .PARAMETER Exception
        [Exception] instance. Caller is responsible for rethrowing if the
        original control flow expected a throw.

    .PARAMETER Properties
        Optional structured dimensions.

    .PARAMETER SeverityLevel
        Warning or Error (Critical maps via the SDK's enum).

    .PARAMETER OperationId
        Correlation GUID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception,
        [hashtable] $Properties,
        [ValidateSet('Warning','Error','Critical')]
        [string] $SeverityLevel = 'Error',
        [string] $OperationId
    )

    $props   = ConvertTo-XdrAiSafeProperties -Properties $Properties
    $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $OperationId

    $client = Get-XdrAiTelemetryClient
    if ($null -eq $client) {
        Write-Information ("XdrAI EXCEPTION [{0}] op={1} type={2} msg={3}" -f $SeverityLevel, $ambient.OperationId, $Exception.GetType().FullName, $Exception.Message)
        return
    }
    Set-XdrAiTelemetryContext -Client $client -Ambient $ambient
    try {
        $client.TrackException($Exception, $props)
    } catch {
        Write-Information ("XdrAI EXCEPTION-FALLBACK op={0} err={1} msg={2}" -f $ambient.OperationId, $_.Exception.Message, $Exception.Message)
    }
}
