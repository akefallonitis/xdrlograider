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
        PortalSession from Connect-MDEPortal.

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

    # --- Call ---
    $r = Invoke-MDEPortalEndpoint -Session $Session -Path $path -Method GET
    if (-not $r.Success) {
        Write-Warning "Invoke-MDEEndpoint Stream='$Stream' failed: $($r.Error)"
        return ,@()
    }

    # --- Expand + normalise ---
    $expandArgs = @{ Response = $r.Data }
    if ($entry.ContainsKey('IdProperty') -and $entry.IdProperty) {
        $expandArgs['IdProperty'] = [string[]]$entry.IdProperty
    }

    # Per-call Extras: carry any PathParams so ingested rows are self-describing
    # (useful for per-machineId / per-investigationId correlation).
    $extras = @{}
    foreach ($k in $PathParams.Keys) { $extras[$k] = $PathParams[$k] }

    # Force array semantics so .Count is always defined even when the response is empty.
    $rows = @(
        foreach ($pair in (Expand-MDEResponse @expandArgs)) {
            $entityId = if ($PathParams.Count -gt 0) {
                # Prefix with path-param values to keep IDs unique across devices/investigations
                (($PathParams.Values | ForEach-Object { [string]$_ }) + $pair.Id) -join '-'
            } else {
                $pair.Id
            }
            ConvertTo-MDEIngestRow -Stream $Stream -EntityId $entityId -Raw $pair.Entity -Extras $extras
        }
    )
    Write-Verbose "Invoke-MDEEndpoint Stream='$Stream' -> $($rows.Count) rows"
    return ,$rows
}
