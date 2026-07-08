# XdrLogRaider · Xdr.Common.Exceptions module
#
# Typed exception classes — each maps to a distinct caller recovery action:
#   AuthChainBrokenException     → retry whole auth cycle OR fail the operation
#   XdrPortalTerminalException   → DLQ the operation (4xx permanent · no retry)
#   XdrPortalTransientException  → retry with backoff (5xx / 429 / network)
#   XdrIngestException           → DLQ the batch (DCE/DCR push failed)
#   XdrParserException           → skip the row (schema violation)
#   XdrCacheException            → fall through to next layer
#
# Invariant: silent catch swallowing is the #1 latent production bug · typed exceptions
# force the caller to decide recovery rather than ignoring the error. Catches that
# DO NOT re-throw MUST carry an INTENTIONAL-FAIL-SAFE comment naming the reason.

Set-StrictMode -Version Latest

# ===========================
# Exception class definitions (PS 7.4 typed classes)
# ===========================

class XdrException : System.Exception {
    [string] $ErrorClass
    [hashtable] $Context

    XdrException([string]$message) : base($message) {
        $this.ErrorClass = $this.GetType().Name
        $this.Context = @{}
    }

    XdrException([string]$message, [System.Exception]$inner) : base($message, $inner) {
        $this.ErrorClass = $this.GetType().Name
        $this.Context = @{}
    }
}

# Auth chain failures (cookie expired · sub-portal proxy 401 · KMSI lost · etc.)
class AuthChainBrokenException : XdrException {
    [string] $Portal
    [string] $SubPortal
    [string] $FailureStage  # one of: Login · MFA · Cookie · KMSI · SubPortalProxy · Refresh

    AuthChainBrokenException([string]$portal, [string]$stage, [string]$message) : base($message) {
        $this.Portal = $portal
        $this.FailureStage = $stage
    }
}

# Portal returned 4xx (terminal · permanent failure for this Operation · DLQ candidate)
class XdrPortalTerminalException : XdrException {
    [int] $StatusCode
    [string] $Portal
    [string] $OperationKey
    [string] $ResponseBody

    XdrPortalTerminalException([int]$statusCode, [string]$opKey, [string]$body) : base("Portal returned $statusCode for $opKey") {
        $this.StatusCode = $statusCode
        $this.OperationKey = $opKey
        $this.ResponseBody = $body
    }
}

# Portal returned 5xx or transient error (retryable · circuit-breaker increments)
class XdrPortalTransientException : XdrException {
    [int] $StatusCode
    [string] $OperationKey
    [int] $RetryAfterSeconds

    XdrPortalTransientException([int]$statusCode, [string]$opKey, [int]$retryAfter) : base("Portal transient $statusCode for $opKey · retry-after $retryAfter") {
        $this.StatusCode = $statusCode
        $this.OperationKey = $opKey
        $this.RetryAfterSeconds = $retryAfter
    }
}

# DCE/DCR push failure
class XdrIngestException : XdrException {
    [string] $DcrId
    [string] $StreamName
    [int] $RowCount
    [int] $StatusCode

    XdrIngestException([string]$dcrId, [string]$stream, [int]$rowCount, [int]$statusCode, [string]$message) : base($message) {
        $this.DcrId = $dcrId
        $this.StreamName = $stream
        $this.RowCount = $rowCount
        $this.StatusCode = $statusCode
    }
}

# Parser violation (B1 fan-out · B1b empty gate · B3 RawJson clamp · row schema mismatch)
class XdrParserException : XdrException {
    [string] $OperationKey
    [string] $ViolationType  # B1.FanOut · B1b.EmptyElement · B3.RawJsonSize · Schema.Mismatch

    XdrParserException([string]$opKey, [string]$violation, [string]$message) : base($message) {
        $this.OperationKey = $opKey
        $this.ViolationType = $violation
    }
}

# Cache layer failure (KV · in-memory · Storage Table · lease)
class XdrCacheException : XdrException {
    [string] $CacheLayer  # L0.KV · L1.Memory · L2.Table · L3.Lease
    [string] $CacheKey

    XdrCacheException([string]$layer, [string]$key, [string]$message) : base($message) {
        $this.CacheLayer = $layer
        $this.CacheKey = $key
    }
}

# ===========================
# Factory + classification helpers
# ===========================

function New-XdrException {
    <#
    .SYNOPSIS
    Factory for typed XdrException subclasses.
    #>
    [CmdletBinding()]
    [OutputType([XdrException])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('XdrException','AuthChainBroken','PortalTerminal','PortalTransient','Ingest','Parser','Cache')]
        [string] $Type,

        [Parameter(Mandatory)]
        [string] $Message,

        [hashtable] $Properties = @{}
    )

    # $Properties is a [hashtable]; callers pass only the keys relevant to their failure (e.g. a 4xx omits
    # ResponseBody, a token-fetch omits StatusCode). Under StrictMode -Version Latest, DOT-access of a MISSING
    # hashtable key THROWS PropertyNotFoundException BEFORE `??` can coalesce — which silently replaced the
    # intended typed exception with a generic one and corrupted DLQ/breaker classification on every 4xx/5xx.
    # The INDEXER `$Properties['k']` returns $null for an absent key, so `?? default` works. Indexer-only here.
    switch ($Type) {
        'AuthChainBroken' {
            $portal = $Properties['Portal'] ?? 'unknown'
            $stage = $Properties['FailureStage'] ?? 'unknown'
            return [AuthChainBrokenException]::new($portal, $stage, $Message)
        }
        'PortalTerminal' {
            return [XdrPortalTerminalException]::new(
                ($Properties['StatusCode'] ?? 0),
                ($Properties['OperationKey'] ?? 'unknown'),
                ($Properties['ResponseBody'] ?? '')
            )
        }
        'PortalTransient' {
            return [XdrPortalTransientException]::new(
                ($Properties['StatusCode'] ?? 503),
                ($Properties['OperationKey'] ?? 'unknown'),
                ($Properties['RetryAfterSeconds'] ?? 30)
            )
        }
        'Ingest' {
            return [XdrIngestException]::new(
                ($Properties['DcrId'] ?? 'unknown'),
                ($Properties['StreamName'] ?? 'unknown'),
                ($Properties['RowCount'] ?? 0),
                ($Properties['StatusCode'] ?? 0),
                $Message
            )
        }
        'Parser' {
            return [XdrParserException]::new(
                ($Properties['OperationKey'] ?? 'unknown'),
                ($Properties['ViolationType'] ?? 'unknown'),
                $Message
            )
        }
        'Cache' {
            return [XdrCacheException]::new(
                ($Properties['CacheLayer'] ?? 'unknown'),
                ($Properties['CacheKey'] ?? 'unknown'),
                $Message
            )
        }
        default {
            return [XdrException]::new($Message)
        }
    }
}

function Get-XdrErrorClass {
    <#
    .SYNOPSIS
    Classify an exception for Result reporting + telemetry tagging.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Exception] $Exception
    )

    # PowerShell 7.4 has a type-check foot-gun: `[string] -is [PSCustomObject]` returns TRUE
    # in some pipeline contexts. Always use GetType().Name on exceptions · NEVER -is [PSCustomObject].
    return $Exception.GetType().Name
}

function ConvertTo-XdrUtc {
    <#
    .SYNOPSIS
    AU1 (audit 2026-06-12) · CULTURE-SAFE conversion of a cursor/expiry value to a UTC [DateTime]. THE shared,
    generic parser for every time value in the connector — no module re-implements [DateTime]::Parse.
    Why this exists: `ConvertFrom-Json -AsHashtable` (the runtime's table-read shape) auto-converts ISO strings
    into [DateTime] objects. The old `[DateTime]::Parse([string]$v)` then stringified that [DateTime] with the
    INVARIANT 'MM/dd/yyyy' format and re-parsed it with the CURRENT culture — on a dd/MM host (e.g. el-GR/de-DE,
    the operator's dev machine) that SWAPS month and day (proven), corrupting TTLs and cursors. Fix: short-circuit
    values that are ALREADY [DateTime]/[DateTimeOffset] (no stringify-reparse); parse strings with InvariantCulture
    + RoundtripKind. Returns $null on null/blank/unparseable (fail-safe · callers treat null as cold/expired).
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[datetime]])]
    param([Parameter()] [AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        # WS-A (audit 2026-06-12) · a NAIVE [DateTime] (Kind=Unspecified — e.g. a parse without tz, or
        # ConvertFrom-Json of a no-Z string) must be treated as UTC, NOT host-local: .ToUniversalTime() on an
        # Unspecified value ASSUMES Local and SHIFTS it by the host offset (the el-GR/de-DE regression · the FA is
        # UTC so the pilot never exposed it, but "generic across all hosts/cases" requires the assume-UTC contract).
        # SpecifyKind(Utc) pins a naive value as-is; Utc/Local kinds convert normally (lossless · no stringify).
        $dt = [datetime]$Value
        if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) { return [System.DateTime]::SpecifyKind($dt, [System.DateTimeKind]::Utc) }
        return $dt.ToUniversalTime()
    }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).UtcDateTime }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    # AssumeUniversal: a string with NO tz info (naive) is read as UTC (not host-local · same anti-shift contract as
    # the [DateTime] branch). AdjustToUniversal: a Z/offset string is honoured and normalised to UTC. Both invariant.
    try { return [DateTime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)) }
    catch { return $null }
}

function ConvertTo-XdrUtcString {
    <#
    .SYNOPSIS
    WS-A (audit 2026-06-12) · CANONICALISE any time value to a full-fidelity, round-trippable UTC ISO-8601 string
    ('o' · invariant). THE read/write-boundary canonicaliser for every datetime-typed checkpoint field. Why this
    exists: Get-XdrTableEntity reads the StateStore via `ConvertFrom-Json -AsHashtable`, which PROMOTES a stored ISO
    string to a [DateTime]; a bare `[string]` cast of that [DateTime] is LOSSY (truncates to whole seconds + culture-
    formats — '06/05/2026 01:51:53'), so the high-water regressed on every no-ingest cycle → the boundary row
    re-ingested = the live DUPLICATE. Routing through ConvertTo-XdrUtc (which short-circuits a [DateTime] losslessly
    + assume-UTC for naive) then emitting 'o' preserves the sub-second high-water EXACTLY and consistently.
    Contract: null → $null and blank → '' (cold-start semantics preserved); an unparseable NON-empty value is returned
    UNCHANGED (never destroy data — only genuine datetime values are canonicalised; opaque tokens pass through).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()] [AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    if (($Value -is [string]) -and [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $utc = ConvertTo-XdrUtc $Value
    if ($null -eq $utc) { return $Value }
    return $utc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

Export-ModuleMember -Function New-XdrException, Get-XdrErrorClass, ConvertTo-XdrUtc, ConvertTo-XdrUtcString
