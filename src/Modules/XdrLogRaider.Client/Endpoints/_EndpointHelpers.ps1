# Shared helpers for endpoint wrappers.
# Each MDE_*_CL wrapper follows the same pattern:
#   1. Call the portal endpoint via Invoke-MDEPortalRequest
#   2. Enumerate the response into one row per entity
#   3. Each row has TimeGenerated, SourceStream, EntityId, RawJson (+ optional projected columns)

function ConvertTo-MDEIngestRow {
    <#
    .SYNOPSIS
        Builds a standard ingestion row from an endpoint response element.

    .PARAMETER Stream
        Stream/table name (e.g., 'MDE_PUAConfig_CL').

    .PARAMETER EntityId
        Stable identifier for the entity. Used as drift-comparison key.

    .PARAMETER Raw
        The raw object from the portal response (will be JSON-serialized for RawJson).

    .PARAMETER Extras
        Optional hashtable of additional projected columns.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Stream,
        [Parameter(Mandatory)] [string] $EntityId,
        [Parameter(Mandatory)] $Raw,
        [hashtable] $Extras = @{}
    )

    $base = [ordered]@{
        TimeGenerated = [datetime]::UtcNow.ToString('o')
        SourceStream  = $Stream
        EntityId      = $EntityId
        RawJson       = ($Raw | ConvertTo-Json -Depth 10 -Compress)
    }
    foreach ($key in $Extras.Keys) {
        $base[$key] = $Extras[$key]
    }
    return [pscustomobject]$base
}

function Invoke-MDEPortalEndpoint {
    <#
    .SYNOPSIS
        Wraps Invoke-MDEPortalRequest with try/catch that converts failures into structured results.

    .DESCRIPTION
        Returns @{ Success=$true; Data=<response> } on success or @{ Success=$false; Error=$msg } on failure.
        Timer functions use this to track per-stream success without stopping the whole batch.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        $Body = $null,
        [int] $TimeoutSec = 60
    )

    try {
        $data = Invoke-MDEPortalRequest -Session $Session -Path $Path -Method $Method -Body $Body -TimeoutSec $TimeoutSec
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
        Handles the two common shapes:
          - array of objects (each with an 'id' or 'name' field)
          - object with named properties (each property becomes an entity)

        Returns an array of @{ Id = '...'; Entity = <obj> } pairs.

    .PARAMETER Response
        Parsed JSON response.

    .PARAMETER IdProperty
        Name of the field to use as entity ID. Default 'id', falls back to 'name' then 'Id' then 'Name'.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        $Response,
        [string[]] $IdProperty = @('id', 'name', 'Id', 'Name', 'ruleId', 'policyId')
    )

    if ($null -eq $Response) { return @() }

    $pairs = @()

    if ($Response -is [array]) {
        $i = 0
        foreach ($item in $Response) {
            $id = $null
            foreach ($prop in $IdProperty) {
                if ($item.PSObject.Properties[$prop]) {
                    $id = [string]$item.$prop
                    if ($id) { break }
                }
            }
            if (-not $id) { $id = "idx-$i" }
            $pairs += @{ Id = $id; Entity = $item }
            $i++
        }
    } elseif ($Response -is [pscustomobject] -or $Response -is [hashtable]) {
        foreach ($prop in $Response.PSObject.Properties) {
            $pairs += @{ Id = $prop.Name; Entity = $prop.Value }
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

    $indexed = @{}
    foreach ($entry in $raw.Endpoints) {
        if (-not $entry.Stream -or -not $entry.Path -or -not $entry.Tier) {
            Write-Warning "Skipping malformed manifest entry (missing Stream/Path/Tier): $($entry | ConvertTo-Json -Compress)"
            continue
        }
        if ($indexed.ContainsKey($entry.Stream)) {
            throw "Duplicate Stream '$($entry.Stream)' in manifest"
        }
        $indexed[$entry.Stream] = $entry
    }

    $script:MDEEndpointManifestCache = $indexed
    Write-Verbose "Get-MDEEndpointManifest: loaded $($indexed.Count) endpoint entries"
    return $indexed
}
