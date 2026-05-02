# iter-14.0 Phase 14B — Microsoft-best-practices structured logging to App Insights.
# v0.1.0-beta production-readiness polish — TrackDependency wrapper added so
# portal HTTP calls land in App Insights' end-to-end transaction view.
#
# This file implements 5 public entry points that wrap the
# Microsoft.ApplicationInsights.Channel.TelemetryClient instance the Azure
# Functions PowerShell host already loads (via the
# APPLICATIONINSIGHTS_CONNECTION_STRING app setting) so callers can emit:
#   - traces           (Send-XdrAppInsightsTrace)
#   - custom events    (Send-XdrAppInsightsCustomEvent)
#   - custom metrics   (Send-XdrAppInsightsCustomMetric)
#   - exceptions       (Send-XdrAppInsightsException)
#   - dependencies     (Send-XdrAppInsightsDependency) — TrackDependency for
#                      portal HTTP calls (security.microsoft.com / DCE / Tables)
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


function Send-XdrAppInsightsDependency {
    <#
    .SYNOPSIS
        Emit a dependency telemetry record (TrackDependency) to App Insights for
        an outgoing HTTP / storage / KV call. Surfaces in the end-to-end
        transaction view alongside the auth-chain customEvents on the same
        OperationId.

    .DESCRIPTION
        Wraps Microsoft.ApplicationInsights.DataContracts.DependencyTelemetry.
        Same secret-redaction pattern as the other Send-XdrAppInsights* helpers
        (keys matching password|totpBase32|sccauth|xsrfToken|passkey|privateKey
        have their values replaced with '<redacted>' before the property bag is
        handed to the TelemetryClient).

        Falls back to Write-Information when the TelemetryClient type is not
        loadable (unit-test / dev-time / when AI hasn't initialized yet) so
        callers never crash.

    .PARAMETER Target
        Target host or service identifier (e.g., 'security.microsoft.com',
        '<dce>.eastus.ingest.monitor.azure.com', '<sa>.table.core.windows.net').
        Low-cardinality dimension operators group by in KQL.

    .PARAMETER Name
        Dependency-call name. Conventionally the URL path (e.g.,
        '/api/settings/GetAdvancedFeaturesSetting') or a logical operation
        name. Passed to TrackDependency as the .Name property.

    .PARAMETER Success
        Whether the call succeeded. Maps to .Success on the dependency record.

    .PARAMETER DurationMs
        Wall-clock duration in milliseconds. Maps to .Duration as a TimeSpan.

    .PARAMETER ResultCode
        HTTP status code (or 0 for non-HTTP / pre-flight failure). Maps to
        .ResultCode (string-typed by the SDK).

    .PARAMETER Type
        Dependency type ('HTTP', 'Azure Table', 'Azure Key Vault', etc.). Maps
        to .Type. Default 'HTTP' since the primary use case is portal calls.

    .PARAMETER OperationId
        Pass-through correlation GUID (typically $CorrelationId from
        Connect-DefenderPortal). When omitted, a fresh GUID is generated.

    .PARAMETER Properties
        Hashtable of structured key/value pairs that surface as
        customDimensions.* in KQL. Secret-key values are redacted.

    .EXAMPLE
        # Inside a wrapper around Invoke-RestMethod / Invoke-WebRequest:
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-RestMethod -Uri $uri ...
            $success = $true; $resultCode = 200
            return $r
        } catch {
            $resultCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            throw
        } finally {
            $sw.Stop()
            Send-XdrAppInsightsDependency -Target 'security.microsoft.com' `
                -Name $Path -Success $success -DurationMs $sw.ElapsedMilliseconds `
                -ResultCode $resultCode -OperationId $env:CORRELATION_ID
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [bool]   $Success,
        [Parameter(Mandatory)] [int]    $DurationMs,
        [Parameter()]          [int]    $ResultCode = 0,
        [Parameter()]          [string] $Type = 'HTTP',
        [Parameter()]          [string] $OperationId,
        [Parameter()]          [hashtable] $Properties = @{}
    )

    $props   = ConvertTo-XdrAiSafeProperties -Properties $Properties
    $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $OperationId

    $client = Get-XdrAiTelemetryClient
    if ($null -eq $client) {
        # Fallback path — Write-Information so the line still lands in
        # FunctionAppLogs / live tail when AI isn't loaded.
        Write-Information ("XdrAI DEPENDENCY [{0}] op={1} target={2} name={3} success={4} duration={5}ms code={6}" -f `
            $Type, $ambient.OperationId, $Target, $Name, $Success, $DurationMs, $ResultCode)
        return
    }
    Set-XdrAiTelemetryContext -Client $client -Ambient $ambient

    try {
        # DependencyTelemetry is the canonical SDK type for outgoing-call
        # observability. Construct it via the loaded assembly so we don't
        # take a hard reference at module-import time.
        $depType = [System.Type]::GetType('Microsoft.ApplicationInsights.DataContracts.DependencyTelemetry, Microsoft.ApplicationInsights', $false)
        if ($null -eq $depType) {
            # SDK loaded the TelemetryClient but the DependencyTelemetry type
            # isn't reachable on this host. Fall through to TrackDependency()
            # method on the client (newer SDK exposes this directly).
            $startUtc = [DateTimeOffset]::UtcNow.AddMilliseconds(-1 * [int]$DurationMs)
            $duration = [TimeSpan]::FromMilliseconds([int]$DurationMs)
            # Method overload: TrackDependency(type, target, name, data, startTime, duration, resultCode, success)
            $client.TrackDependency($Type, $Target, $Name, '', $startUtc, $duration, [string]$ResultCode, [bool]$Success)
        } else {
            $dep = [Activator]::CreateInstance($depType)
            $dep.Type       = $Type
            $dep.Target     = $Target
            $dep.Name       = $Name
            $dep.Success    = [bool]$Success
            $dep.ResultCode = [string]$ResultCode
            $dep.Duration   = [TimeSpan]::FromMilliseconds([int]$DurationMs)
            $dep.Timestamp  = [DateTimeOffset]::UtcNow.AddMilliseconds(-1 * [int]$DurationMs)
            # Operation.Id stamping — keeps stitching consistent with
            # customEvents emitted by the same auth-chain correlation.
            try {
                if ($dep.Context -and $dep.Context.Operation -and $ambient.OperationId) {
                    $dep.Context.Operation.Id = [string]$ambient.OperationId
                }
            } catch {}
            # Properties bag (IDictionary<string,string>) — copy our redacted
            # dictionary onto the dependency's Properties field.
            try {
                if ($dep.Properties) {
                    foreach ($k in $props.Keys) {
                        $dep.Properties[$k] = [string]$props[$k]
                    }
                }
            } catch {}
            $client.TrackDependency($dep)
        }
    } catch {
        Write-Information ("XdrAI DEPENDENCY-FALLBACK op={0} err={1} target={2} name={3}" -f $ambient.OperationId, $_.Exception.Message, $Target, $Name)
    }
}
