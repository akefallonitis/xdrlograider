# Capture-EndpointSchemas helpers · dot-sourceable from main script + Pester tests.
# Pure functions · no portal-state side effects.

function Redact-PII {
    param([string] $Text)
    if (-not $Text) { return $Text }
    # JWTs · eyJ<base64url>.<base64url>.<base64url>
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '<REDACTED-JWT>')
    # Email · simple RFC-5322-lite
    $Text = [regex]::Replace($Text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<REDACTED-EMAIL>')
    # Cookie-looking long opaque blobs
    $Text = [regex]::Replace($Text, '(ESTSAUTH[A-Z]*|sccauth|XSRF-TOKEN)=[A-Za-z0-9+/=%_.-]{40,}', '$1=<REDACTED-COOKIE>')
    # SHA-256 hex secrets-ish (long hex strings)
    $Text = [regex]::Replace($Text, '\b[0-9a-fA-F]{64}\b', '<REDACTED-HEX64>')
    return $Text
}

function Get-PaginationHints {
    param([string] $RawBody, $ParsedJson)
    $hints = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $ParsedJson) {
        foreach ($k in @('nextLink','@odata.nextLink','nextPageLink','continuationToken','nextPageToken','cursor','nextCursor','skipToken')) {
            if ($ParsedJson.PSObject.Properties[$k]) { $hints.Add($k) | Out-Null }
        }
    }
    foreach ($k in @('nextLink','@odata.nextLink','nextPageLink','continuationToken','nextPageToken','cursor','nextCursor','skipToken')) {
        if ($RawBody -match "`"$k`"\s*:\s*`"") { if (-not $hints.Contains($k)) { $hints.Add($k) | Out-Null } }
    }
    return @($hints)
}

function Get-TimeFilterHints {
    param([string] $Path)
    $hints = [System.Collections.Generic.List[string]]::new()
    foreach ($pat in @('since','from','startDate','endDate','startTime','endTime','afterDate','beforeDate','timestamp','lastModified','modifiedAfter','modifiedSince','fromTime','toTime')) {
        if ($Path -match "[?&]${pat}=") { $hints.Add($pat) | Out-Null }
    }
    return @($hints)
}

function ConvertTo-Slug {
    param([string] $Text)
    $s = ($Text -replace '[^A-Za-z0-9]+','-').Trim('-').ToLowerInvariant()
    if (-not $s) { $s = 'unknown' }
    return $s
}

# Classifier · maps HTTP status → output filename
function Resolve-CaptureArtifactName {
    param([int] $StatusCode)
    switch ($StatusCode) {
        { $_ -ge 200 -and $_ -lt 300 } { return 'live.json' }
        401  { return 'license-blocked.json' }
        403  { return 'license-blocked.json' }
        404  { return 'unreachable.json' }
        429  { return 'rate-limited.json' }
        { $_ -ge 500 } { return 'server-error.json' }
        default { return 'unclassified.json' }
    }
}
