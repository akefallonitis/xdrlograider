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
    [CmdletBinding(DefaultParameterSetName = 'ByEntryKey')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,

        # ByEntryKey (Phase 1 preferred): unique per-endpoint key '<SubArea>::<Slug>'.
        [Parameter(Mandatory, ParameterSetName = 'ByEntryKey')]
        [string] $EntryKey,

        # ByStream (legacy compatibility): only resolves uniquely when one entry
        # exists for the stream. Phase 1 has 18 sub-area-level Streams shared by
        # many endpoints; prefer -EntryKey.
        [Parameter(Mandatory, ParameterSetName = 'ByStream')]
        [string] $Stream,

        [datetime] $FromUtc,
        [hashtable] $PathParams = @{},
        [hashtable] $BodyOverride = $null,

        # Phase A0.3 multi-cycle pagination resume. Activity layer reads
        # connectorCheckpoints, passes StartFromPage = LastCompletedPage + 1
        # so an interrupted vuln_management 1000-page first poll resumes
        # from where the previous activity left off. MaxPagesPerCycle caps
        # pages consumed per activity invocation so each call stays under
        # the Y1 10-min activity timeout (default: respect manifest MaxPages;
        # override to a smaller number to spread work across cycles).
        [int] $StartFromPage = 1,
        [Nullable[int]] $MaxPagesPerCycle = $null
    )

    $manifest = Get-XdrEndpointManifest -Portal Defender
    $entry = $null
    if ($PSCmdlet.ParameterSetName -eq 'ByEntryKey') {
        if (-not $manifest.ContainsKey($EntryKey)) {
            throw "Unknown EntryKey '$EntryKey'. Format is '<sub-area>::<slug>' (e.g. 'action_center::GetHistory')."
        }
        $entry = $manifest[$EntryKey]
    } else {
        $matches = @($manifest.Values | Where-Object { $_.Stream -eq $Stream })
        if ($matches.Count -eq 0) {
            throw "No manifest entry with Stream='$Stream'."
        }
        if ($matches.Count -gt 1) {
            throw "Stream '$Stream' resolves to $($matches.Count) entries. Use -EntryKey '<sub-area>::<slug>' to disambiguate."
        }
        $entry = $matches[0]
    }

    # Stable per-row identifier used for log messages + Set-MDEEndpointLastResult.
    # EntryKey when available; Stream as fallback for pilot-shaped manifests.
    $entryKey = if ($entry.ContainsKey('EntryKey') -and $entry.EntryKey) { $entry.EntryKey } else { $entry.Stream }
    $streamForLA = $entry.Stream

    # --- Path substitution ---
    $path = $entry.Path
    if ($entry.ContainsKey('PathParams') -and $entry.PathParams) {
        foreach ($key in $entry.PathParams) {
            if (-not $PathParams.ContainsKey($key)) {
                throw "Invoke-MDEEndpoint EntryKey='$entryKey' requires -PathParams @{ $key = '...' }"
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

    # Phase A0.3 multi-cycle resume: when StartFromPage > 1, skip directly to
    # the requested page (no page-1 fetch). This avoids re-ingesting earlier
    # pages on activity-cycle restart for endpoints with multi-cycle pagination.
    # Single-cycle path (StartFromPage=1, the default) is unchanged.
    $lastPageFetched = 0
    $paginationExhausted = $true

    if ($null -ne $pagination -and $StartFromPage -gt 1) {
        $pageSize   = if ($pagination.ContainsKey('PageSize'))  { [int]$pagination.PageSize }  else { 200 }
        $sep        = if ($path.Contains('?')) { '&' } else { '?' }
        $pagedPath  = "${path}${sep}pageIndex=${StartFromPage}&pageSize=${pageSize}"
        $r = Invoke-MDEPortalEndpoint -Session $Session -Path $pagedPath -Method $httpMethod -Body $postBody -AdditionalHeaders $extraHeaders
        $lastPageFetched = $StartFromPage
    } else {
        $r = Invoke-MDEPortalEndpoint -Session $Session -Path $path -Method $httpMethod -Body $postBody -AdditionalHeaders $extraHeaders
        $lastPageFetched = 1
    }

    if ($null -ne $pagination -and $null -ne $r -and $r.Success -and $null -ne $r.Data) {
        $manifestMaxPages = if ($pagination.ContainsKey('MaxPages'))  { [int]$pagination.MaxPages }  else { 50 }
        # Per-cycle cap: caller may override to spread vuln_management 1000-page
        # first poll across many cycles. Default = manifest MaxPages (no spread).
        $cycleMaxPages = if ($null -ne $MaxPagesPerCycle) { [int]$MaxPagesPerCycle } else { $manifestMaxPages }
        $pageSize      = if ($pagination.ContainsKey('PageSize'))  { [int]$pagination.PageSize }  else { 200 }
        $unwrapKey     = if ($entry.ContainsKey('UnwrapProperty')) { [string]$entry.UnwrapProperty } else { $null }

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
            $cyclePagesConsumed = 1
            $absoluteCap = [Math]::Min($manifestMaxPages, ($lastPageFetched + $cycleMaxPages - 1))
            for ($pageIndex = ($lastPageFetched + 1); $pageIndex -le $absoluteCap; $pageIndex++) {
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
                $lastPageFetched = $pageIndex
                $cyclePagesConsumed++
                if ($pageItems.Count -lt $pageSize) {
                    # Last page (partial fill) — pagination exhausted.
                    $paginationExhausted = $true
                    break
                }
            }
            # Decide whether pagination is exhausted vs interrupted by cycle cap.
            # If we stopped because of the per-cycle cap AND haven't seen a partial
            # page, more pages likely remain → next cycle resumes at lastPageFetched+1.
            if ($lastPageFetched -ge $manifestMaxPages) {
                $paginationExhausted = $true  # hit manifest hard cap
            } elseif ($firstPageItems.Count -ge $pageSize -and $lastPageFetched -lt $manifestMaxPages -and $cyclePagesConsumed -ge $cycleMaxPages) {
                $paginationExhausted = $false  # cycle-cap interruption; resume next cycle
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
        Write-Verbose "Invoke-MDEEndpoint EntryKey='$entryKey' aggregated $($aggregatedItems.Count) items (pages $StartFromPage..$lastPageFetched, exhausted=$paginationExhausted)"
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
    # 4-value truth-signal (Rule 6, tenant-gated retired per Rule 23).
    # The legacy contract (return ,@() on any failure) is preserved so existing
    # callers + tests don't break. Activity callers read Get-MDEEndpointLastResult
    # after each call to distinguish:
    #   live           — 200 with non-empty Data (rows returned)
    #   live-empty     — 200 with null/empty Data (legitimate "no data this poll")
    #   rate-limited   — 429 (apiproxy throttling; back off and retry next cycle)
    #   error          — 5xx, network failure, helper bug, OR 401/403/404 with
    #                    LicenseHint populated when the endpoint requires a SKU
    #                    the tenant doesn't have. Operators see LicenseHint in
    #                    XdrConnectorHealth_CL Notes; it's a configuration
    #                    signal, not a connector defect (Rule 23).
    # ----------------------------------------------------------------------
    if ($null -eq $r) {
        Set-MDEEndpointLastResult -Stream $entryKey -SuccessKind 'error' -HttpStatus 0 `
            -ErrorText 'Invoke-MDEPortalEndpoint returned null (helper-side bug)'
        Write-Warning "Invoke-MDEEndpoint EntryKey='$entryKey' failed: Invoke-MDEPortalEndpoint returned null (helper-side bug)"
        return ,@()
    }
    if (-not $r.Success) {
        $status = 0
        if ($null -ne $r.PSObject.Properties['HttpStatus']) { $status = [int]$r.HttpStatus }
        elseif ($r.Error -match '\b(429)\b')     { $status = 429 }
        elseif ($r.Error -match '\b(40[134])\b') { $status = [int]$matches[1] }
        elseif ($r.Error -match '\b(5\d\d)\b')   { $status = [int]$matches[1] }
        if ($status -eq 429) {
            Set-MDEEndpointLastResult -Stream $entryKey -SuccessKind 'rate-limited' -HttpStatus 429 -ErrorText $r.Error
            Write-Warning "Invoke-MDEEndpoint EntryKey='$entryKey' [rate-limited/429]: $($r.Error)"
            return ,@()
        }
        $licenseHint = ''
        if ($status -in 401, 403, 404) {
            $licenseHint = [string]($entry['LicenseHint'])
        }
        Set-MDEEndpointLastResult -Stream $entryKey -SuccessKind 'error' -HttpStatus $status `
            -ErrorText $r.Error -LicenseHint $licenseHint
        if ($licenseHint) {
            Write-Warning "Invoke-MDEEndpoint EntryKey='$entryKey' [error/$status, license-blocked: $licenseHint]: $($r.Error)"
        } else {
            Write-Warning "Invoke-MDEEndpoint EntryKey='$entryKey' [error/$status]: $($r.Error)"
        }
        return ,@()
    }
    if ($null -eq $r.Data) {
        # 200 with empty body — legitimate "no data" (e.g. tenant has no
        # configured exclusions; not a failure, not gated).
        Set-MDEEndpointLastResult -Stream $entryKey -SuccessKind 'live-empty' -HttpStatus 200 -ErrorText ''
        Write-Verbose "Invoke-MDEEndpoint EntryKey='$entryKey' returned 200 with empty body — 0 rows"
        return ,@()
    }

    # --- Expand + normalise ---
    # Pass -Stream so Expand-MDEResponse can:
    #  (a) attach -Stream context to Ingest.BoundaryMarker AppInsights events
    #  (b) fire the XDR_DEBUG_RESPONSE_CAPTURE one-shot per stream when env=true
    $expandArgs = @{ Response = $r.Data; Stream = $streamForLA }
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
            ConvertTo-MDEIngestRow -Stream $streamForLA -EntityId $entityId -Raw $entity -Extras $extras -ProjectionMap $projMap
        }
    )
    # Section R++.A: success path — distinguish live (rows) from live-empty (no rows).
    $kind = if ($rows.Count -gt 0) { 'live' } else { 'live-empty' }
    Set-MDEEndpointLastResult -Stream $entryKey -SuccessKind $kind -HttpStatus 200 -ErrorText '' `
        -LastCompletedPage $lastPageFetched -PaginationExhausted $paginationExhausted
    Write-Verbose "Invoke-MDEEndpoint EntryKey='$entryKey' -> $($rows.Count) rows [$kind] lastPage=$lastPageFetched exhausted=$paginationExhausted"
    return ,$rows
}
