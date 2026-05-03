function Invoke-MDEEndpoint {
    <#
    .SYNOPSIS
        Single dispatcher for every Defender XDR portal-only telemetry endpoint.

    .DESCRIPTION
        Looks up the requested Stream in endpoints.manifest.psd1 (loaded once at
        module import) and issues the HTTP GET against https://security.microsoft.com
        via Invoke-MDEPortalEndpoint. Response is flattened via Expand-MDEResponse
        and each entity normalised into a standard DCE-ready row by
        ConvertTo-MDEIngestRow.

        Responsibilities:
          - Stream-name validation (against manifest).
          - Path-placeholder substitution ({machineId} etc) from -PathParams.
          - Server-side filter construction (?fromDate=...) from -FromUtc when the
            manifest entry declares a Filter.
          - Fail-safe return: always returns an array; ,@() on any failure.

        Does NOT do: retry logic (Send-ToLogAnalytics does), checkpoint I/O
        (Invoke-MDETierPoll does), session reuse (caller owns the session).

    .PARAMETER Session
        PortalSession from Connect-DefenderPortal.

    .PARAMETER Stream
        Custom Log Analytics table name (e.g. 'MDE_PUAConfig_CL'). Must exist in
        the endpoint manifest. Validated at runtime.

    .PARAMETER FromUtc
        Optional lower-bound timestamp for endpoints that support server-side
        time filtering. Ignored for endpoints whose manifest entry has no
        `Filter` field.

    .PARAMETER PathParams
        Optional hashtable for substituting path placeholders. Keys match the
        manifest entry's PathParams array. Throws if a required placeholder is
        missing.

    .EXAMPLE
        # Simple full-snapshot pull
        Invoke-MDEEndpoint -Session $s -Stream 'MDE_PUAConfig_CL'

    .EXAMPLE
        # Incremental pull with server-side date filter
        Invoke-MDEEndpoint -Session $s -Stream 'MDE_ActionCenter_CL' `
                          -FromUtc ([datetime]::UtcNow.AddHours(-1))

    .OUTPUTS
        [object[]] — DCE-ready rows (may be empty).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [ValidateScript({
            $manifest = Get-MDEEndpointManifest
            if ($_ -notin $manifest.Keys) {
                throw "Unknown Stream '$_'. Known streams: $($manifest.Keys -join ', ')"
            }
            $true
        })]
        [string] $Stream,

        [datetime] $FromUtc,
        [hashtable] $PathParams = @{}
    )

    $entry = (Get-MDEEndpointManifest)[$Stream]

    # --- Path substitution ---
    $path = $entry.Path
    if ($entry.ContainsKey('PathParams') -and $entry.PathParams) {
        foreach ($key in $entry.PathParams) {
            if (-not $PathParams.ContainsKey($key)) {
                throw "Invoke-MDEEndpoint Stream='$Stream' requires -PathParams @{ $key = '...' }"
            }
            $escaped = [uri]::EscapeDataString([string]$PathParams[$key])
            $path = $path -replace "\{$key\}", $escaped
        }
    }

    # --- Server-side filter (opt-in via manifest) ---
    if ($entry.ContainsKey('Filter') -and $entry.Filter -and $PSBoundParameters.ContainsKey('FromUtc')) {
        $fromEncoded = [uri]::EscapeDataString($FromUtc.ToUniversalTime().ToString('o'))
        $sep = if ($path.Contains('?')) { '&' } else { '?' }
        $path = "${path}${sep}$($entry.Filter)=$fromEncoded"
    }

    # --- Method + optional request body (manifest may specify Method='POST' for
    # endpoints like XSPM attack paths that are POST-only) ---
    $httpMethod = if ($entry.ContainsKey('Method') -and $entry.Method) { $entry.Method } else { 'GET' }
    $postBody   = if ($httpMethod -eq 'POST') {
        if ($entry.ContainsKey('Body') -and $entry.Body) { $entry.Body } else { @{} }
    } else { $null }

    # --- Optional custom headers (e.g. XSPM requires x-tid + x-ms-scenario-name) ---
    # Supports template token {TenantId} → resolved from session's TenantId.
    $extraHeaders = @{}
    if ($entry.ContainsKey('Headers') -and $entry.Headers) {
        foreach ($key in $entry.Headers.Keys) {
            $val = $entry.Headers[$key]
            if ($val -is [string] -and $val -match '^\{TenantId\}$') {
                $val = [string]$Session.TenantId
            }
            $extraHeaders[$key] = $val
        }
    }

    # --- Call ---
    $r = Invoke-MDEPortalEndpoint -Session $Session -Path $path -Method $httpMethod -Body $postBody -AdditionalHeaders $extraHeaders

    # Iter 13.9 (C5): consolidate the early-exit gates. Three failure modes
    # all map to "return empty array, no error":
    #   1. $r itself is null (helper returned nothing — pathological)
    #   2. $r.Success is false (HTTP error caught by Invoke-MDEPortalEndpoint)
    #   3. $r.Data is null (200 with empty body — common on POST-only surfaces)
    # All three previously had separate guards; consolidating reduces the
    # surface area for strict-mode crashes if a future helper returns a
    # different shape.
    if ($null -eq $r) {
        Write-Warning "Invoke-MDEEndpoint Stream='$Stream' failed: Invoke-MDEPortalEndpoint returned null (helper-side bug)"
        return ,@()
    }
    if (-not $r.Success) {
        Write-Warning "Invoke-MDEEndpoint Stream='$Stream' failed: $($r.Error)"
        return ,@()
    }
    if ($null -eq $r.Data) {
        # 200 with empty body — observed on POST-only / scalar-response surfaces
        Write-Verbose "Invoke-MDEEndpoint Stream='$Stream' returned 200 with empty body — 0 rows"
        return ,@()
    }

    # --- Expand + normalise ---
    # Pass -Stream so Expand-MDEResponse can:
    #  (a) attach -Stream context to Ingest.BoundaryMarker AppInsights events
    #  (b) fire the XDR_DEBUG_RESPONSE_CAPTURE one-shot per stream when env=true
    $expandArgs = @{ Response = $r.Data; Stream = $Stream }
    if ($entry.ContainsKey('IdProperty') -and $entry.IdProperty) {
        $expandArgs['IdProperty'] = [string[]]$entry.IdProperty
    }
    # UnwrapProperty for responses wrapped in an object (e.g. {ServiceAccounts:[...]}).
    if ($entry.ContainsKey('UnwrapProperty') -and $entry.UnwrapProperty) {
        $expandArgs['UnwrapProperty'] = [string]$entry.UnwrapProperty
    }
    # iter-14.0 Phase 1: SingleObjectAsRow forces single-object responses to
    # emit ONE per-entity row (Shape 1) instead of N per-property rows (Shape 3).
    # Used for endpoints returning a single configuration object that's
    # operator-friendly as one row (TenantContext, ConnectedApps, UserPreferences).
    if ($entry.ContainsKey('SingleObjectAsRow') -and $entry.SingleObjectAsRow) {
        $expandArgs['SingleObjectAsRow'] = $true
    }

    # Per-call Extras: carry any PathParams so ingested rows are self-describing
    # (useful for per-machineId / per-investigationId correlation).
    $extras = @{}
    foreach ($k in $PathParams.Keys) { $extras[$k] = $PathParams[$k] }

    # Force array semantics so .Count is always defined even when the response is empty.
    $rows = @(
        foreach ($pair in (Expand-MDEResponse @expandArgs)) {
            # Expand-MDEResponse may emit pairs with $null Entity for edge-case
            # responses (primitives, empty scalars). Synthesise an empty object so
            # ConvertTo-MDEIngestRow's mandatory -Raw is always bindable.
            # Iter 13.4: triple-defense — $pair itself may be empty array under
            # certain edge-cases (live evidence from MDE_ActionCenter_CL real
            # portal response: "Cannot bind argument to parameter 'Raw' because
            # it is null"). Final null-coalesce makes -Raw NEVER null no matter
            # what shape $pair has.
            $rawEntity = $null
            if ($null -ne $pair) {
                if ($pair -is [hashtable] -and $pair.ContainsKey('Entity')) {
                    $rawEntity = $pair['Entity']
                } elseif ($pair.PSObject.Properties['Entity']) {
                    $rawEntity = $pair.Entity
                }
            }
            # Mandatory parameter binding rejects $null AND empty pipeline (which
            # an empty array @() effectively is when splatted to a single param).
            # Both must be replaced with a non-empty defensive sentinel.
            $entity = $rawEntity
            if ($null -eq $entity -or ($entity -is [array] -and @($entity).Count -eq 0)) {
                $entity = [pscustomobject]@{}
            }

            $rawId = $null
            if ($null -ne $pair) {
                if ($pair -is [hashtable] -and $pair.ContainsKey('Id')) {
                    $rawId = $pair['Id']
                } elseif ($pair.PSObject.Properties['Id']) {
                    $rawId = $pair.Id
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$rawId)) { $rawId = 'unknown' }

            $entityId = if ($PathParams.Count -gt 0) {
                # Prefix with path-param values to keep IDs unique across devices/investigations
                (($PathParams.Values | ForEach-Object { [string]$_ }) + $rawId) -join '-'
            } else {
                [string]$rawId
            }
            # iter-14.0 BUGFIX (CRITICAL — was silent in v0.1.0-beta): pass the
            # manifest's ProjectionMap so ConvertTo-MDEIngestRow extracts typed
            # columns. Without -ProjectionMap, the dispatcher silently emits
            # rows with only the 4 base columns + RawJson — every typed column
            # in every MDE_*_CL table came out NULL. Live verification on
            # MDE_AdvancedFeatures_CL / MDE_TenantContext_CL / MDE_PUAConfig_CL
            # confirmed NULL across the board pre-fix. ProjectionMap is always
            # at least @{} (Get-MDEEndpointManifest's Defaults block guarantees
            # the field exists), so a $null guard is unnecessary but harmless.
            $projMap = if ($entry.ContainsKey('ProjectionMap') -and $entry.ProjectionMap) { $entry.ProjectionMap } else { $null }
            ConvertTo-MDEIngestRow -Stream $Stream -EntityId $entityId -Raw $entity -Extras $extras -ProjectionMap $projMap
        }
    )
    Write-Verbose "Invoke-MDEEndpoint Stream='$Stream' -> $($rows.Count) rows"
    return ,$rows
}
