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
            $manifest = Get-XdrEndpointManifest -Portal Defender
            if ($_ -notin $manifest.Keys) {
                throw "Unknown Stream '$_'. Known streams: $($manifest.Keys -join ', ')"
            }
            $true
        })]
        [string] $Stream,

        [datetime] $FromUtc,
        [hashtable] $PathParams = @{},

        # Section R++++++ Architecture C (2026-05-07): per-call body override.
        # Used by PerPlatformFanout activity loop to pass body['platform']='Linux',
        # 'Windows', 'macOS', 'iOS' across iterations of the same stream. Merged
        # into the manifest-declared Body (keys in BodyOverride win on collision).
        # Also usable for pagination loops (BodyOverride={pageIndex=2}, etc).
        [hashtable] $BodyOverride = $null
    )

    $entry = (Get-XdrEndpointManifest -Portal Defender)[$Stream]

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

    # Section R++++++ Architecture C (2026-05-07): merge per-call BodyOverride into
    # the manifest body (caller wins on collision). Used by PerPlatformFanout activity
    # loop and pagination loops.
    if ($null -ne $BodyOverride -and $BodyOverride.Count -gt 0) {
        if ($null -eq $postBody) { $postBody = @{} }
        # Clone the manifest body so we don't mutate the manifest hashtable across calls.
        $merged = @{}
        foreach ($k in $postBody.Keys) { $merged[$k] = $postBody[$k] }
        foreach ($k in $BodyOverride.Keys) { $merged[$k] = $BodyOverride[$k] }
        $postBody = $merged
    }

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

    # --- Call (with optional pagination loop per Section R++++++ Architecture F) ---
    # Pagination semantics: when manifest declares Pagination = @{ Style='pageIndex';
    # PageSize=200; MaxPages=50 }, fetch additional pages until: (a) page < pageSize
    # (last page), (b) MaxPages reached, or (c) page returns 0 items / error. Aggregate
    # all pages into a single $r.Data array compatible with the existing Expand flow.
    # 429s within the loop are handled by Invoke-MDEPortalEndpoint's existing retry
    # logic; per-page checkpoint is handled by the activity layer.
    $pagination = if ($entry.ContainsKey('Pagination') -and $entry.Pagination) { $entry.Pagination } else { $null }

    $r = Invoke-MDEPortalEndpoint -Session $Session -Path $path -Method $httpMethod -Body $postBody -AdditionalHeaders $extraHeaders

    if ($null -ne $pagination -and $null -ne $r -and $r.Success -and $null -ne $r.Data) {
        $maxPages   = if ($pagination.ContainsKey('MaxPages'))  { [int]$pagination.MaxPages }  else { 50 }
        $pageSize   = if ($pagination.ContainsKey('PageSize'))  { [int]$pagination.PageSize }  else { 200 }
        $unwrapKey  = if ($entry.ContainsKey('UnwrapProperty')) { [string]$entry.UnwrapProperty } else { $null }

        # Extract first-page items via the same UnwrapProperty rule the activity uses.
        $firstPageItems = @()
        if ($unwrapKey -and $r.Data.PSObject.Properties[$unwrapKey]) {
            $firstPageItems = @($r.Data.$unwrapKey)
        } elseif ($r.Data -is [array]) {
            $firstPageItems = @($r.Data)
        } else {
            $firstPageItems = @($r.Data)
        }
        $aggregatedItems = @($firstPageItems)

        # Continue paginating only if first page filled (likely more pages exist).
        if ($firstPageItems.Count -ge $pageSize) {
            for ($pageIndex = 2; $pageIndex -le $maxPages; $pageIndex++) {
                $sep = if ($path.Contains('?')) { '&' } else { '?' }
                $pagedPath = "${path}${sep}pageIndex=${pageIndex}&pageSize=${pageSize}"
                $rPage = Invoke-MDEPortalEndpoint -Session $Session -Path $pagedPath -Method $httpMethod -Body $postBody -AdditionalHeaders $extraHeaders
                if (-not $rPage -or -not $rPage.Success -or $null -eq $rPage.Data) { break }
                $pageItems = @()
                if ($unwrapKey -and $rPage.Data.PSObject.Properties[$unwrapKey]) {
                    $pageItems = @($rPage.Data.$unwrapKey)
                } elseif ($rPage.Data -is [array]) {
                    $pageItems = @($rPage.Data)
                } else {
                    $pageItems = @($rPage.Data)
                }
                $aggregatedItems += $pageItems
                if ($pageItems.Count -lt $pageSize) { break }  # last page
            }
        }

        # Reconstruct $r.Data with aggregated items so the existing Expand flow sees
        # the full result set under the same UnwrapProperty key.
        if ($unwrapKey) {
            $r = [pscustomobject]@{
                Success    = $true
                Data       = [pscustomobject]@{ $unwrapKey = $aggregatedItems }
                HttpStatus = 200
            }
        } else {
            $r = [pscustomobject]@{
                Success    = $true
                Data       = $aggregatedItems
                HttpStatus = 200
            }
        }
        Write-Verbose "Invoke-MDEEndpoint Stream='$Stream' aggregated $($aggregatedItems.Count) items across pagination loop"
    }

    # Iter 13.9 (C5): consolidate the early-exit gates. Three failure modes
    # all map to "return empty array, no error":
    #   1. $r itself is null (helper returned nothing — pathological)
    #   2. $r.Success is false (HTTP error caught by Invoke-MDEPortalEndpoint)
    #   3. $r.Data is null (200 with empty body — common on POST-only surfaces)
    # All three previously had separate guards; consolidating reduces the
    # surface area for strict-mode crashes if a future helper returns a
    # different shape.
    # ----------------------------------------------------------------------
    # Section R++.A — TRUTH-SIGNAL via module-scope side-channel.
    # The legacy contract (return ,@() on any failure) is preserved so existing
    # callers + tests don't break. Activity callers can now read the latest
    # call's outcome via Get-MDEEndpointLastResult to distinguish:
    #   live           — 200 with non-empty Data (rows returned)
    #   live-empty     — 200 with null/empty Data (legitimate "no data this poll")
    #   tenant-gated   — 401/403/404 (license-gated; expected on unlicensed tenant)
    #   error          — 5xx, network failure, helper-side bug (REAL failure)
    # Activity uses this to drive Set-XdrTierStateRow -Reason + connector-card UX.
    # See R++.A in plan immutable-splashing-waffle.md.
    # ----------------------------------------------------------------------
    if ($null -eq $r) {
        Set-MDEEndpointLastResult -Stream $Stream -SuccessKind 'error' -HttpStatus 0 `
            -ErrorText 'Invoke-MDEPortalEndpoint returned null (helper-side bug)'
        Write-Warning "Invoke-MDEEndpoint Stream='$Stream' failed: Invoke-MDEPortalEndpoint returned null (helper-side bug)"
        return ,@()
    }
    if (-not $r.Success) {
        # Classify by HTTP status when available. 401/403/404 = tenant-gated
        # (license/scope absent). 5xx + network errors = real failure.
        $status = 0
        if ($null -ne $r.PSObject.Properties['HttpStatus']) { $status = [int]$r.HttpStatus }
        elseif ($r.Error -match '\b(40[134])\b') { $status = [int]$matches[1] }
        elseif ($r.Error -match '\b(5\d\d)\b')   { $status = [int]$matches[1] }
        $kind = if ($status -in 401, 403, 404) { 'tenant-gated' } else { 'error' }
        Set-MDEEndpointLastResult -Stream $Stream -SuccessKind $kind -HttpStatus $status -ErrorText $r.Error
        Write-Warning "Invoke-MDEEndpoint Stream='$Stream' [$kind/$status]: $($r.Error)"
        return ,@()
    }
    if ($null -eq $r.Data) {
        # 200 with empty body — legitimate "no data" (e.g. tenant has no
        # configured exclusions; not a failure, not gated).
        Set-MDEEndpointLastResult -Stream $Stream -SuccessKind 'live-empty' -HttpStatus 200 -ErrorText ''
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
    # v0.1.0 GA: SingleObjectAsRow forces single-object responses to
    # emit ONE per-entity row (Shape 1) instead of N per-property rows (Shape 3).
    # Used for endpoints returning a single configuration object that's
    # operator-friendly as one row (TenantContext, ConnectedApps, UserPreferences).
    if ($entry.ContainsKey('SingleObjectAsRow') -and $entry.SingleObjectAsRow) {
        $expandArgs['SingleObjectAsRow'] = $true
    }
    # Section R++++++ Phase 1 fix (2026-05-07T17:25Z): wire manifest's
    # SyntheticEntityId through to Expand-MDEResponse so SingleObjectAsRow
    # streams with no natural id-col emit a stable synthetic EntityId
    # (e.g. 'topthreats-singleton') instead of the idx-N fallback.
    if ($entry.ContainsKey('SyntheticEntityId') -and $entry.SyntheticEntityId) {
        $expandArgs['SyntheticEntityId'] = [string]$entry.SyntheticEntityId
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
            # v0.1.0 GA BUGFIX (CRITICAL — was silent in v0.1.0-beta): pass the
            # manifest's ProjectionMap so ConvertTo-MDEIngestRow extracts typed
            # columns. Without -ProjectionMap, the dispatcher silently emits
            # rows with only the 4 base columns + RawJson — every typed column
            # in every MDE_*_CL table came out NULL. Live verification on
            # MDE_AdvancedFeatures_CL / MDE_TenantContext_CL / MDE_PUAConfig_CL
            # confirmed NULL across the board pre-fix. ProjectionMap is always
            # at least @{} (Get-XdrEndpointManifest -Portal Defender's Defaults block guarantees
            # the field exists), so a $null guard is unnecessary but harmless.
            $projMap = if ($entry.ContainsKey('ProjectionMap') -and $entry.ProjectionMap) { $entry.ProjectionMap } else { $null }
            # Phase I REVERTED per user feedback (2026-05-04): nodoc taxonomy
            # remains MANIFEST-INTERNAL reference only. Per-row stamping was
            # over-engineering; operators query typed cols + RawJson, not nodoc
            # metadata. Reverted to original ConvertTo-MDEIngestRow signature.
            ConvertTo-MDEIngestRow -Stream $Stream -EntityId $entityId -Raw $entity -Extras $extras -ProjectionMap $projMap
        }
    )
    # Section R++.A: success path — distinguish live (rows) from live-empty (no rows).
    $kind = if ($rows.Count -gt 0) { 'live' } else { 'live-empty' }
    Set-MDEEndpointLastResult -Stream $Stream -SuccessKind $kind -HttpStatus 200 -ErrorText ''
    Write-Verbose "Invoke-MDEEndpoint Stream='$Stream' -> $($rows.Count) rows [$kind]"
    return ,$rows
}
