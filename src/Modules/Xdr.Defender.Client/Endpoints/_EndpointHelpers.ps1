# Shared helpers for endpoint wrappers.
# Each MDE_*_CL wrapper follows the same pattern:
#   1. Call the portal endpoint via Invoke-DefenderPortalRequest
#   2. Enumerate the response into one row per entity
#   3. Each row has TimeGenerated, SourceStream, EntityId, RawJson (+ optional projected columns)

function ConvertTo-MDEIngestRow {
    <#
    .SYNOPSIS
        Builds a standard ingestion row from an endpoint response element.

    .DESCRIPTION
        Applies the manifest's per-stream `ProjectionMap` (when supplied) to
        extract typed columns alongside the existing RawJson dynamic blob.
        Operators query typed columns directly — no more
        `parse_json(RawJson) | extend …` everywhere.

        Backward-compat: ProjectionMap is OPTIONAL. Streams without one still
        produce TimeGenerated + SourceStream + EntityId + RawJson + any -Extras.
        RawJson is preserved on every row regardless of projection for
        forensic / future-proofing.

        Skips boundary-marker rows (Entity.__boundary_marker = $true): those
        emit only the standard 4 columns + a marker reason — no projection
        applied (they don't represent real entities).

    .PARAMETER Stream
        Stream/table name (e.g., 'MDE_PUAConfig_CL').

    .PARAMETER EntityId
        Stable identifier for the entity. Used as drift-comparison key.

    .PARAMETER Raw
        The raw object from the portal response (will be JSON-serialized for RawJson).

    .PARAMETER Extras
        Optional hashtable of additional projected columns. Merged AFTER the
        ProjectionMap so caller-supplied values override projected ones.

    .PARAMETER ProjectionMap
        Optional hashtable @{ TargetColumn = JSONPath-or-typed-hint }. When
        supplied, each TargetColumn becomes a typed column on the row with
        the value extracted + cast per Project-EntityField. See
        _ProjectionHelpers.ps1 for hint syntax.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Stream,
        [Parameter(Mandatory)] [string] $EntityId,
        [Parameter(Mandatory)] $Raw,
        [hashtable] $Extras = @{},
        [hashtable] $ProjectionMap = $null
    )

    $base = [ordered]@{
        TimeGenerated = [datetime]::UtcNow.ToString('o')
        SourceStream  = $Stream
        EntityId      = $EntityId
        RawJson       = ($Raw | ConvertTo-Json -Depth 10 -Compress)
    }

    # Apply ProjectionMap: each TargetColumn -> Project-EntityField($Hint, $Raw).
    # Skip boundary-marker rows — they don't represent real entities.
    $isBoundary = $false
    if ($Raw -is [pscustomobject] -and $Raw.PSObject.Properties['__boundary_marker']) {
        $isBoundary = [bool]$Raw.__boundary_marker
    } elseif ($Raw -is [hashtable] -and $Raw.ContainsKey('__boundary_marker')) {
        $isBoundary = [bool]$Raw['__boundary_marker']
    }

    if (-not $isBoundary -and $ProjectionMap -and $ProjectionMap.Count -gt 0) {
        # iter-14.0 — for property-bag streams (Shape 3 in Expand-MDEResponse),
        # the entity is the property VALUE (often a scalar like $true/$false).
        # The manifest convention `FeatureName = '$tostring:EntityId'` lets the
        # operator project the property NAME as a typed col. Synthesise a
        # projection-context object that wraps the entity + exposes EntityId
        # so JSONPath hints like `$tostring:EntityId` resolve. The original
        # $Raw is still used for RawJson serialization above.
        # iter-13.4 defense: edge-case entities (empty pscustomobject, hashtable
        # with one null-valued property, etc) must NOT crash the cloner under
        # Set-StrictMode -Version Latest. Wrap each access in try/catch +
        # explicit null guards.
        $projContext = $null
        try {
            if ($Raw -is [hashtable]) {
                $hasEntityIdKey = $Raw.ContainsKey('EntityId')
                if ($hasEntityIdKey) {
                    $projContext = $Raw
                } else {
                    $clone = [ordered]@{ EntityId = $EntityId }
                    foreach ($k in @($Raw.Keys)) { $clone[$k] = $Raw[$k] }
                    $projContext = [pscustomobject]$clone
                }
            } elseif ($Raw -is [pscustomobject]) {
                # PSObject access requires defensive null check on Properties.
                $propsObj = $Raw.PSObject.Properties
                $names = if ($null -ne $propsObj) { @($propsObj | ForEach-Object { $_.Name }) } else { @() }
                if ('EntityId' -in $names) {
                    $projContext = $Raw
                } else {
                    $clone = [ordered]@{ EntityId = $EntityId }
                    if ($null -ne $propsObj) {
                        foreach ($p in $propsObj) { $clone[$p.Name] = $p.Value }
                    }
                    $projContext = [pscustomobject]$clone
                }
            } else {
                # Scalar entity (Shape 4 in Expand-MDEResponse). Wrap so EntityId
                # + value are both accessible via JSONPath.
                $projContext = [pscustomobject]@{ EntityId = $EntityId; value = $Raw }
            }
        } catch {
            Write-Verbose "ConvertTo-MDEIngestRow: projection-context build failed for $Stream — falling back to bare entity: $($_.Exception.Message)"
            $projContext = $Raw
        }
        foreach ($targetCol in $ProjectionMap.Keys) {
            $hint = $ProjectionMap[$targetCol]
            if ([string]::IsNullOrWhiteSpace($hint)) { continue }
            try {
                $base[$targetCol] = Project-EntityField -Hint $hint -Entity $projContext
            } catch {
                Write-Verbose "ConvertTo-MDEIngestRow: projection failed for $Stream column '$targetCol' (hint='$hint'): $($_.Exception.Message)"
                $base[$targetCol] = $null
            }
        }
    }

    foreach ($key in $Extras.Keys) {
        $base[$key] = $Extras[$key]
    }
    return [pscustomobject]$base
}

function Invoke-MDEPortalEndpoint {
    <#
    .SYNOPSIS
        Wraps Invoke-DefenderPortalRequest with try/catch that converts failures into structured results.

    .DESCRIPTION
        Returns @{ Success=$true; Data=<response> } on success or @{ Success=$false; Error=$msg } on failure.
        Timer functions use this to track per-stream success without stopping the whole batch.

        Supports optional `-AdditionalHeaders` hashtable for endpoints requiring
        extra HTTP headers (e.g. XSPM requires `x-tid` + `x-ms-scenario-name`).
        Manifest-driven callers route their entry's `Headers` field here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        $Body = $null,
        [int] $TimeoutSec = 60,
        [hashtable] $AdditionalHeaders = @{}
    )

    try {
        $data = Invoke-DefenderPortalRequest -Session $Session -Path $Path -Method $Method `
            -Body $Body -TimeoutSec $TimeoutSec -AdditionalHeaders $AdditionalHeaders
        return @{ Success = $true; Data = $data; Path = $Path }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message; Path = $Path }
    }
}

function Expand-MDEResponse {
    <#
    .SYNOPSIS
        Flattens a portal response into an enumerable of entity objects with extracted IDs.

    .DESCRIPTION
        Handles five response shapes:
          1. Array of objects                      → one row per item; ID extracted via IdProperty heuristic
          2. Wrapper object with array property    → -UnwrapProperty unwraps then path 1 runs
          3. Object with named properties          → one row per top-level property (rare; flat property-bag responses)
          4. Scalar (bool/int/string/double)       → ONE row with Id='value' + Entity={value=<scalar>}
          5. NULL                                  → ONE boundary-marker row so heartbeat can distinguish
                                                     "API working but no data" from "API failed"

        Shapes 4 + 5 make the heartbeat tier-roll-up non-blind: a null/empty
        response would otherwise log at Verbose only and the heartbeat would
        see no data — operators couldn't tell whether the poll succeeded with
        no data or failed silently. The boundary-marker pattern emits one
        well-typed sentinel row that downstream consumers (parsers, KQL
        queries) can filter or count.

        Returns an array of @{ Id = '...'; Entity = <obj> } pairs.

    .PARAMETER Response
        Parsed JSON response (or $null on empty/204-no-content).

    .PARAMETER IdProperty
        Per-call override of the ID-extraction heuristic. Default list includes
        ActionId/InvestigationId/incidentId/alertId/attackPathId so streams whose
        primary key uses those names (Action Center, AIR investigations, XSPM,
        Incident/Alert details) get correct EntityIds without per-stream override.

    .PARAMETER UnwrapProperty
        Optional. When supplied and the response is a wrapper object with that
        property (e.g. {Results:[…], Count:N} with UnwrapProperty='Results'),
        the inner value replaces $Response before normal array/object handling.
        Without this, wrapper objects flatten to one pair per top-level property,
        which is semantically wrong for paged bulk endpoints (produces
        EntityId='Results' and EntityId='Count' wrapper-key rows instead of
        per-entity rows).

    .PARAMETER Stream
        Optional. Stream name (e.g. 'MDE_ActionCenter_CL'). Embedded in the
        boundary-marker row's Entity for forensic + included in EntityId so
        operators can filter heartbeat boundary rows by stream.

    .OUTPUTS
        [hashtable[]] — array of @{ Id; Entity } pairs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        $Response,
        [string[]] $IdProperty = @(
            'id', 'name', 'Id', 'Name',
            'ruleId', 'policyId',
            'ActionId', 'InvestigationId',
            'incidentId', 'alertId',
            'attackPathId', 'machineId', 'deviceId',
            'AlertId', 'IncidentId', 'MachineId', 'DeviceId'
        ),
        [string] $UnwrapProperty,
        [string] $Stream
    )

    # v0.1.0-beta post-deploy hardening: DEBUG-CAPTURE mode.
    # When XDR_DEBUG_RESPONSE_CAPTURE=true, log first 800 chars of the raw
    # response shape per stream to AppInsights customEvent so an audit can
    # see what the portal ACTUALLY returns (vs what the manifest assumes).
    # Default OFF — only enable for one cycle when investigating projection
    # mismatches. Capture ONCE per stream per worker process to keep volume
    # bounded.
    if ($Stream -and $env:XDR_DEBUG_RESPONSE_CAPTURE -eq 'true') {
        if ($null -eq $script:DebugResponseSeen) { $script:DebugResponseSeen = @{} }
        if (-not $script:DebugResponseSeen.ContainsKey($Stream)) {
            $script:DebugResponseSeen[$Stream] = $true
            $rawShape = if ($null -eq $Response) {
                'NULL'
            } else {
                try { ($Response | ConvertTo-Json -Depth 4 -Compress) } catch { "<unserializable: $($_.Exception.Message)>" }
            }
            if ($rawShape.Length -gt 800) { $rawShape = $rawShape.Substring(0, 800) + '...[truncated]' }
            if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                Send-XdrAppInsightsCustomEvent -EventName 'Ingest.RawResponseShape' -Properties @{
                    Stream      = [string]$Stream
                    UnwrapHint  = [string]$UnwrapProperty
                    RawSnippet  = $rawShape
                    ResponseType = if ($null -eq $Response) { 'null' } else { $Response.GetType().FullName }
                }
            }
        }
    }

    # --- Shape 5: NULL response — emit AppInsights event, return ZERO rows ---
    # Pre-v0.1.0-beta this returned a "boundary marker" row inserted into the
    # MDE_*_CL table. That polluted the customer's data tables with non-entity
    # rows that broke parser/workbook/rule queries (which assumed every row
    # represented a real entity). The correct contract:
    #   - Null/empty responses produce ZERO rows in MDE_*_CL
    #   - Operator visibility comes from the Ingest.BoundaryMarker
    #     AppInsights customEvent + the heartbeat's emptyStreams Notes counter
    if ($null -eq $Response) {
        if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
            Send-XdrAppInsightsCustomEvent -EventName 'Ingest.BoundaryMarker' -Properties @{
                Stream = [string]$Stream
                Reason = 'api-returned-null'
            }
        }
        return @()
    }

    # --- Shape 2: unwrap wrapper before generic flattening (CQ1 fix) ---------
    if ($UnwrapProperty -and ($Response -is [pscustomobject] -or $Response -is [hashtable])) {
        $hasProp = $false
        if ($Response -is [hashtable]) {
            $hasProp = $Response.ContainsKey($UnwrapProperty)
        } else {
            $hasProp = [bool]($Response.PSObject.Properties[$UnwrapProperty])
        }
        if ($hasProp) {
            $inner = if ($Response -is [hashtable]) { $Response[$UnwrapProperty] } else { $Response.$UnwrapProperty }
            if ($null -eq $inner) {
                # Unwrap-target was present but null — emit AppInsights event
                # for operator visibility, return ZERO rows. (No more boundary-
                # marker rows polluting the MDE_*_CL tables.)
                if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                    Send-XdrAppInsightsCustomEvent -EventName 'Ingest.BoundaryMarker' -Properties @{
                        Stream         = [string]$Stream
                        Reason         = 'unwrap-target-null'
                        UnwrapProperty = $UnwrapProperty
                    }
                }
                return @()
            }
            # PowerShell quirk defense: when a hashtable is constructed in PowerShell
            # source code with a single-item array value (e.g. @{Results=@(item)}),
            # the array can collapse to a scalar at lookup time. Production responses
            # from ConvertFrom-Json don't collapse, but test code that constructs
            # responses inline does. Detect "the unwrap-target was supposed to be an
            # array but came back as a single object" and re-wrap as 1-element array
            # so shape 1 (array iteration with IdProperty extraction) handles it.
            if ($inner -is [pscustomobject] -or $inner -is [hashtable]) {
                $Response = [Object[]]@($inner)
            } else {
                $Response = $inner
            }
        }
    }

    $pairs = @()

    # --- Shape 1: array of objects -------------------------------------------
    if ($Response -is [array]) {
        if ($Response.Count -eq 0) {
            # Empty array — operator visibility via AppInsights only; return
            # ZERO rows (no MDE_*_CL pollution).
            if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                Send-XdrAppInsightsCustomEvent -EventName 'Ingest.BoundaryMarker' -Properties @{
                    Stream = [string]$Stream
                    Reason = 'empty-array'
                }
            }
            return @()
        }
        $i = 0
        foreach ($item in $Response) {
            $id = $null
            if ($item -is [pscustomobject] -or $item -is [hashtable]) {
                foreach ($prop in $IdProperty) {
                    $hasProp = if ($item -is [hashtable]) { $item.ContainsKey($prop) } else { [bool]($item.PSObject.Properties[$prop]) }
                    if ($hasProp) {
                        $val = if ($item -is [hashtable]) { $item[$prop] } else { $item.$prop }
                        $id = [string]$val
                        if ($id) { break }
                    }
                }
            }
            if (-not $id) { $id = "idx-$i" }
            $pairs += @{ Id = $id; Entity = $item }
            $i++
        }
        return ,$pairs
    }

    # --- Shape 4: scalar (bool/int/string/double) ----------------------------
    # iter-14.0 Phase 3.4 — wrap so the row schema (TimeGenerated/EntityId/RawJson)
    # stays consistent across all streams. Without this, scalar responses
    # produced 0 rows and the heartbeat counted them as "no data".
    if ($Response -is [bool] -or $Response -is [int] -or $Response -is [long] -or
        $Response -is [double] -or $Response -is [decimal] -or
        $Response -is [string]) {
        $pairs += @{
            Id     = 'value'
            Entity = [pscustomobject]@{ value = $Response }
        }
        return ,$pairs
    }

    # --- Shape 3: object with named properties (each property → one row) ----
    # This is the "v0.1.0-beta legacy" case — a few endpoints return shaped
    # like {FeatureName: bool, OtherFeature: bool, …}. We flatten each top-level
    # property into a row with EntityId=propertyName.
    # iter-14.0 Phase 3 EntityId-wrapper-key fix lives in shape 2 above —
    # streams whose response is `{Results:[…], Count:N}` should declare
    # UnwrapProperty='Results'. Streams that legitimately return a flat
    # property-bag (e.g. AdvancedFeatures = {AntiTampering: true, …}) still
    # use shape 3.
    if ($Response -is [pscustomobject] -or $Response -is [hashtable]) {
        $properties = if ($Response -is [hashtable]) { $Response.GetEnumerator() } else { $Response.PSObject.Properties }
        foreach ($prop in $properties) {
            $pairs += @{ Id = $prop.Name; Entity = $prop.Value }
        }
        if ($pairs.Count -eq 0) {
            # Empty object — AppInsights event for visibility, return ZERO rows.
            if (Get-Command -Name Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue) {
                Send-XdrAppInsightsCustomEvent -EventName 'Ingest.BoundaryMarker' -Properties @{
                    Stream = [string]$Stream
                    Reason = 'empty-object'
                }
            }
            return @()
        }
    }

    return ,$pairs
}

$script:MDEEndpointManifestCache = $null

function Get-MDEEndpointManifest {
    <#
    .SYNOPSIS
        Returns the endpoint manifest as a Stream-keyed hashtable (cached for the
        module's lifetime).

    .DESCRIPTION
        Loads `endpoints.manifest.psd1` (sibling of the Endpoints/ folder) on first
        call via `Import-PowerShellDataFile`. Converts the flat `Endpoints = @(...)`
        array into a hashtable indexed by Stream name for O(1) lookup by the
        dispatcher (`Invoke-MDEEndpoint`) and tier-poller (`Invoke-MDETierPoll`).

        Subsequent calls return the cached table.

    .PARAMETER Force
        Re-read the manifest from disk, discarding the cache. Useful in tests.

    .OUTPUTS
        [hashtable] — keys are stream names (e.g. 'MDE_PUAConfig_CL');
                      values are the per-entry hashtables from the manifest.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [switch] $Force
    )

    if (-not $Force -and $script:MDEEndpointManifestCache) {
        return $script:MDEEndpointManifestCache
    }

    # _EndpointHelpers.ps1 lives at <moduleRoot>/Endpoints/_EndpointHelpers.ps1.
    $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'endpoints.manifest.psd1'
    if (-not (Test-Path $manifestPath)) {
        throw "Endpoint manifest not found: $manifestPath"
    }

    $raw = Import-PowerShellDataFile -Path $manifestPath
    if (-not $raw.Endpoints) {
        throw "Manifest at $manifestPath missing required 'Endpoints' array"
    }

    # iter-14.0 schema: apply manifest-level Defaults at load time so entries
    # don't need to repeat common values on every line. Defaults block carries:
    #   Portal              (default 'security.microsoft.com')
    #   MFAMethodsSupported (default @('CredentialsTotp', 'Passkey'))
    #   AuditScope          (default 'portal-only')
    #   IdProperty          (default $null — Expand-MDEResponse heuristic list)
    #   ProjectionMap       (default @{} — populated per-stream in Phase 4)
    # Per-entry values OVERRIDE Defaults. Loader sets the field on every entry
    # so consumers (Invoke-MDEEndpoint, ConvertTo-MDEIngestRow, parsers, etc.)
    # always see a populated field.
    $defaults = @{
        Portal              = 'security.microsoft.com'
        MFAMethodsSupported = @('CredentialsTotp', 'Passkey')
        AuditScope          = 'portal-only'
        IdProperty          = $null
        ProjectionMap       = @{}
    }
    if ($raw.PSObject.Properties['Defaults'] -and $raw.Defaults) {
        foreach ($key in $defaults.Keys.Clone()) {
            if ($raw.Defaults.PSObject.Properties[$key]) {
                $defaults[$key] = $raw.Defaults.$key
            }
        }
    }

    # iter-14.0 audit gate: every entry MUST have Category + Purpose declared
    # (no defaults — operators need explicit categorization). Test gates assert
    # this; loader surfaces a clear error so the source of malformed entries
    # is the violating manifest line, not a downstream NRE.
    $mandatoryFields = @('Stream', 'Path', 'Tier', 'Category', 'Purpose', 'Availability')

    $indexed = @{}
    foreach ($entry in $raw.Endpoints) {
        $missingField = $mandatoryFields | Where-Object { -not $entry.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$entry[$_]) } | Select-Object -First 1
        if ($missingField) {
            Write-Warning "Skipping malformed manifest entry (missing $missingField): $($entry | ConvertTo-Json -Compress -Depth 3)"
            continue
        }
        if ($indexed.ContainsKey($entry.Stream)) {
            throw "Duplicate Stream '$($entry.Stream)' in manifest"
        }
        # Apply each Default field if the entry doesn't override it.
        foreach ($key in $defaults.Keys) {
            if (-not $entry.ContainsKey($key)) {
                $entry[$key] = $defaults[$key]
            }
        }
        # iter-14.0 audit-scope gate: 'public-api-covered' MUST NOT appear in
        # this manifest (the connector's purpose is portal-only telemetry; if
        # something is publicly-API-covered, operators should use the official
        # connector instead). Test gate enforces this; loader surfaces a clean
        # error so the violating entry can be removed.
        if ($entry.AuditScope -eq 'public-api-covered') {
            throw "Manifest entry '$($entry.Stream)' has AuditScope='public-api-covered'. The connector ingests portal-only telemetry; publicly-API-covered streams must be removed (use the official Microsoft Sentinel data connector instead)."
        }
        $indexed[$entry.Stream] = $entry
    }

    $script:MDEEndpointManifestCache = $indexed
    Write-Verbose "Get-MDEEndpointManifest: loaded $($indexed.Count) endpoint entries"
    return $indexed
}
