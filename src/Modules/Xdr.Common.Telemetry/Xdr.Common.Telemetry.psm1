# XdrLogRaider · Xdr.Common.Telemetry module
#
# AppInsights direct REST POST (no SDK · no Application Insights NuGet dependency).
# Architectural decision: AppInsights is provisioned in workspace-mode against the same
# Sentinel-enabled Log Analytics workspace · so AppEvents/AppDependencies/AppExceptions
# are queryable in KQL natively. Each TrackKind goes to the appropriate AppInsights
# surface (NOT JSON-buried in TrackTrace · the 5 surfaces are independently queryable).
#
# REST endpoint: <IngestionEndpoint>/v2/track
# Schema: Microsoft.ApplicationInsights.<iKey>.{Event,Dependency,Exception,Metric,Message}

Set-StrictMode -Version Latest

# ===========================
# AppInsights connection string parsing (cached at module-load)
# ===========================
$script:AiInstrumentationKey = $null
$script:AiIngestionEndpoint = $null
$script:AiConnectionInitialized = $false

function script:Initialize-XdrTelemetryConnection {
    if ($script:AiConnectionInitialized) { return }

    $cs = $env:APPLICATIONINSIGHTS_CONNECTION_STRING
    if (-not $cs) {
        Write-Warning '[Telemetry] APPLICATIONINSIGHTS_CONNECTION_STRING not set · telemetry will be no-op'
        $script:AiConnectionInitialized = $true
        return
    }

    foreach ($pair in ($cs -split ';')) {
        if ($pair -match '^InstrumentationKey=(.+)$') { $script:AiInstrumentationKey = $Matches[1] }
        elseif ($pair -match '^IngestionEndpoint=(.+)$') { $script:AiIngestionEndpoint = $Matches[1].TrimEnd('/') }
    }

    if (-not $script:AiInstrumentationKey) { Write-Warning '[Telemetry] InstrumentationKey not found in connection string' }
    if (-not $script:AiIngestionEndpoint) {
        # Fall back to global endpoint
        $script:AiIngestionEndpoint = 'https://dc.services.visualstudio.com'
    }

    $script:AiConnectionInitialized = $true
}

# ===========================
# Low-level POST envelope sender
# ===========================
function script:Send-XdrTelemetryEnvelope {
    param(
        [Parameter(Mandatory)] [string] $BaseType,
        [Parameter(Mandatory)] [hashtable] $BaseData
    )

    Initialize-XdrTelemetryConnection
    if (-not $script:AiInstrumentationKey) { return $false }

    $envelope = @{
        name = "Microsoft.ApplicationInsights.$($script:AiInstrumentationKey -replace '-','').$($BaseType -replace 'Data$','')"
        time = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        iKey = $script:AiInstrumentationKey
        tags = @{
            'ai.cloud.role' = 'XdrLogRaider'
            'ai.cloud.roleInstance' = $env:WEBSITE_INSTANCE_ID ?? $env:COMPUTERNAME ?? 'unknown'
            'ai.application.ver' = $env:XDRLR_CONNECTOR_VERSION ?? '0.1.0'
        }
        data = @{
            baseType = $BaseType
            baseData = $BaseData
        }
    }

    $url = "$($script:AiIngestionEndpoint)/v2/track"
    $body = $envelope | ConvertTo-Json -Depth 15 -Compress

    try {
        # TLS-1.2+ pinned code-side (§3) · AppInsights track endpoint
        $null = Invoke-RestMethod -Method Post -Uri $url -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 10 -ErrorAction Stop -SslProtocol 'Tls12, Tls13'
        return $true
    } catch {
        # INTENTIONAL-FAIL-SAFE: AppInsights unreachable MUST NOT break the FA cycle.
        # Telemetry is best-effort · honest-fail via Write-Warning (not silent swallow).
        Write-Warning "[Telemetry] Send failed for $BaseType : $($_.Exception.Message)"
        return $false
    }
}

# ===========================
# Secret-scrubber · caller $Properties are forwarded VERBATIM to AppInsights (AppEvents) + the AppTraces host-mirror,
# and an auth/poll call site can pass secret-bearing values (sccauth/cookie/XSRF/token/seed/FlowToken/auth-error bodies).
# Redact by KEY substring (case-insensitive) BEFORE either sink sees them. Returns a scrubbed COPY (never mutates caller).
$script:XdrTelemetryDenyKeys = @('sccauth','cookie','xsrf','token','secret','password','pwd','seed','assertion',
    'bearer','authorization','credential','pem','privatekey','clientsecret','flowtoken','bodypreview','finalhtml','kmsi')
function script:Protect-XdrTelemetryProperties {
    param([hashtable] $Properties)
    if (-not $Properties -or $Properties.Count -eq 0) { return $Properties }
    $out = @{}
    foreach ($k in @($Properties.Keys)) {
        $kl = ([string]$k).ToLowerInvariant()
        $deny = $false
        foreach ($d in $script:XdrTelemetryDenyKeys) { if ($kl.Contains($d)) { $deny = $true; break } }
        $out[$k] = if ($deny) { '***REDACTED***' } else { $Properties[$k] }
    }
    return $out
}

# Redact secret VALUES embedded in a free-text message (exception messages mirror auth-stage error bodies that can
# carry FlowToken / code / id_token / sccauth / JWTs · the audit's BodyPreview/FlowToken-to-AppExceptions leak).
function script:Protect-XdrTelemetryMessage {
    param([string] $Message)
    if ([string]::IsNullOrEmpty($Message)) { return $Message }
    $m = [regex]::Replace($Message, '(?i)(flowtoken|id_token|access_token|refresh_token|sccauth|assertion|client_secret|password|x-xsrf-token|authorization|\bcode)\s*[=:]\s*"?[^"&\s,}]{6,}', '${1}=***REDACTED***')
    $m = [regex]::Replace($m, '\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}', '***JWT-REDACTED***')
    return $m
}

# Public surface · 5 native AppInsights TrackKinds
# ===========================

function Track-XdrEvent {
    <#
    .SYNOPSIS
    Emit AppEvents entry (custom named event with properties).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [hashtable] $Properties = @{},
        [hashtable] $Measurements = @{}
    )
    $Properties = Protect-XdrTelemetryProperties -Properties $Properties   # redact secret-bearing values before BOTH sinks
    # A-OBSERVABILITY (plan §30): mirror the event to the HOST (Information) stream so it lands in AppTraces.
    # Workspace-mode AppInsights does NOT reliably surface /v2/track custom events (AppEvents) — but Write-Host
    # DOES land (verified live: boot/dispatch/lease lines). This makes the auth/poll/ingest chain observable
    # without editing every call site. On by default; set XDRLR_TRACE_TO_HOST=0 to silence in steady state.
    if ($env:XDRLR_TRACE_TO_HOST -ne '0') {
        try {
            $kv = if ($Properties -and $Properties.Count -gt 0) {
                ($Properties.GetEnumerator() | Select-Object -First 8 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            } else { '' }
            Write-Host "[evt] $Name $kv"
        } catch {
            # INTENTIONAL-FAIL-SAFE: the trace mirror is best-effort observability; it must never break a cycle.
        }
    }
    # iter#16: do NOT return the envelope-send bool — an unassigned Track-* call would otherwise leak
    # $true/$false into the CALLER's pipeline, turning e.g. Invoke-XdrEntryPoll's return into an array
    # and breaking `$result.Success` access under StrictMode. Telemetry is fire-and-forget (void).
    $null = Send-XdrTelemetryEnvelope -BaseType 'EventData' -BaseData @{
        ver = 2
        name = $Name
        properties = $Properties
        measurements = $Measurements
    }
}

function Track-XdrDependency {
    <#
    .SYNOPSIS
    Emit AppDependencies entry (outgoing HTTP/REST/etc.).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Type,
        [string] $Data = '',
        [string] $Target = '',
        [int] $DurationMs = 0,
        [bool] $Success = $true,
        [string] $ResultCode = '0',
        [hashtable] $Properties = @{}
    )
    # iter#16: do NOT return the envelope-send bool — an unassigned Track-* call would otherwise leak
    # $true/$false into the CALLER's pipeline, turning e.g. Invoke-XdrEntryPoll's return into an array
    # and breaking `$result.Success` access under StrictMode. Telemetry is fire-and-forget (void).
    $null = Send-XdrTelemetryEnvelope -BaseType 'RemoteDependencyData' -BaseData @{
        ver = 2
        name = $Name
        id = [Guid]::NewGuid().ToString('N')
        type = $Type
        data = $Data
        target = $Target
        duration = ([TimeSpan]::FromMilliseconds($DurationMs)).ToString('c')
        success = $Success
        resultCode = $ResultCode
        properties = $Properties
    }
}

function Track-XdrException {
    <#
    .SYNOPSIS
    Emit AppExceptions entry (typed exception with stack).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception,
        [hashtable] $Properties = @{},
        [string] $SeverityLevel = 'Error'
    )
    $Properties = Protect-XdrTelemetryProperties -Properties $Properties   # redact secret-bearing props before BOTH sinks
    $exInfo = @{
        typeName = $Exception.GetType().FullName
        message = Protect-XdrTelemetryMessage -Message $Exception.Message
        hasFullStack = $true
        stack = $Exception.StackTrace ?? ''
        parsedStack = @()
    }
    # A-OBSERVABILITY (plan §20.D F-OBS-1): mirror the exception to the HOST (Information) stream so it lands in
    # AppTraces. Custom ExceptionData on /v2/track is NOT reliably surfaced in workspace-mode AppInsights — so a
    # caught-then-Track-XdrException'd error would otherwise be invisible (the class of gap that let the live
    # auth crash-loop hide). Track-XdrEvent already mirrors; this brings the exception path to parity.
    if ($env:XDRLR_TRACE_TO_HOST -ne '0') {
        try {
            $pk = if ($Properties -and $Properties.Count -gt 0) { ($Properties.GetEnumerator() | Select-Object -First 6 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ' } else { '' }
            $em = Protect-XdrTelemetryMessage -Message ([string]$Exception.Message); if ($em.Length -gt 300) { $em = $em.Substring(0, 300) }
            Write-Host "[exn] $($Exception.GetType().Name): $em $pk"
        } catch {
            # INTENTIONAL-FAIL-SAFE: the trace mirror is best-effort observability; it must never break a cycle.
        }
    }
    # iter#16: do NOT return the envelope-send bool — an unassigned Track-* call would otherwise leak
    # $true/$false into the CALLER's pipeline, turning e.g. Invoke-XdrEntryPoll's return into an array
    # and breaking `$result.Success` access under StrictMode. Telemetry is fire-and-forget (void).
    $null = Send-XdrTelemetryEnvelope -BaseType 'ExceptionData' -BaseData @{
        ver = 2
        exceptions = @($exInfo)
        severityLevel = $SeverityLevel
        properties = $Properties
    }
}

function Track-XdrMetric {
    <#
    .SYNOPSIS
    Emit AppMetrics entry (named numeric value).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [double] $Value,
        [hashtable] $Properties = @{},
        [int] $Count = 1
    )
    # iter#16: do NOT return the envelope-send bool — an unassigned Track-* call would otherwise leak
    # $true/$false into the CALLER's pipeline, turning e.g. Invoke-XdrEntryPoll's return into an array
    # and breaking `$result.Success` access under StrictMode. Telemetry is fire-and-forget (void).
    $null = Send-XdrTelemetryEnvelope -BaseType 'MetricData' -BaseData @{
        ver = 2
        metrics = @(@{
            name = $Name
            kind = 'Aggregation'
            value = $Value
            count = $Count
        })
        properties = $Properties
    }
}

function Track-XdrTrace {
    <#
    .SYNOPSIS
    Emit AppTraces entry (free-form log message · use sparingly · prefer Track-XdrEvent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Verbose','Information','Warning','Error','Critical')]
        [string] $SeverityLevel = 'Information',
        [hashtable] $Properties = @{}
    )
    $severityNum = switch ($SeverityLevel) {
        'Verbose' { 0 } 'Information' { 1 } 'Warning' { 2 } 'Error' { 3 } 'Critical' { 4 }
    }
    # iter#16: do NOT return the envelope-send bool — an unassigned Track-* call would otherwise leak
    # $true/$false into the CALLER's pipeline, turning e.g. Invoke-XdrEntryPoll's return into an array
    # and breaking `$result.Success` access under StrictMode. Telemetry is fire-and-forget (void).
    $null = Send-XdrTelemetryEnvelope -BaseType 'MessageData' -BaseData @{
        ver = 2
        message = $Message
        severityLevel = $severityNum
        properties = $Properties
    }
}

function Send-XdrTelemetry {
    <#
    .SYNOPSIS
    Convenience dispatcher for any TrackKind. Used by legacy call sites.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Event','Dependency','Exception','Metric','Trace')]
        [string] $Kind,

        [hashtable] $Args = @{}
    )
    switch ($Kind) {
        'Event' { return Track-XdrEvent @Args }
        'Dependency' { return Track-XdrDependency @Args }
        'Exception' { return Track-XdrException @Args }
        'Metric' { return Track-XdrMetric @Args }
        'Trace' { return Track-XdrTrace @Args }
    }
}

function Send-XdrHeartbeat {
    <#
    .SYNOPSIS
    G-G · Per-cycle liveness signal (plan §3.3/§4.I). Emits a customEvent 'XdrLogRaider.Heartbeat' AND a
    customMetric 'XdrLogRaider.Heartbeat.OpsDispatched' carrying the cycle's CycleId, OpsDispatched,
    OpenCircuits, DurationMs — so an operator can confirm the dispatcher is alive each cycle (a cycle that
    dispatches 0 ops for a benign reason still beats, distinguishing "alive but idle" from "dead worker").

    .DESCRIPTION
    Built ENTIRELY on the existing telemetry primitives (Track-XdrEvent + Track-XdrMetric) — no new transport.
    INTERNALLY FAIL-SAFE: the whole body is wrapped in try/catch and NEVER throws, so a heartbeat emit failure
    (AppInsights unreachable · a primitive missing) cannot break the dispatch cycle that calls it. Fields are
    ALL real measured values supplied by the caller — no fabricated behavioral data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CycleId,
        [int] $OpsDispatched = 0,
        [int] $OpenCircuits = 0,
        [int] $DurationMs = 0
    )
    try {
        $props = @{
            CycleId       = $CycleId
            OpsDispatched = $OpsDispatched
            OpenCircuits  = $OpenCircuits
            DurationMs    = $DurationMs
        }
        Track-XdrEvent -Name 'XdrLogRaider.Heartbeat' -Properties $props -Measurements @{
            OpsDispatched = [double]$OpsDispatched
            OpenCircuits  = [double]$OpenCircuits
            DurationMs    = [double]$DurationMs
        }
        Track-XdrMetric -Name 'XdrLogRaider.Heartbeat.OpsDispatched' -Value ([double]$OpsDispatched) -Properties $props
    } catch {
        # INTENTIONAL-FAIL-SAFE: the heartbeat is best-effort liveness · a telemetry failure must NEVER break the
        # cycle. Honest-fail via Write-Warning (not silent swallow). The caller also guards with Get-Command.
        Write-Warning "[Telemetry] Send-XdrHeartbeat failed: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Send-XdrTelemetry, Track-XdrEvent, Track-XdrException, Track-XdrDependency, Track-XdrMetric, Track-XdrTrace, Send-XdrHeartbeat
