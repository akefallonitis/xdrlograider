function Get-XdrEndpointManifest {
    <#
    .SYNOPSIS
        Generic per-portal endpoint manifest loader. Returns a Stream-keyed
        hashtable for the requested portal (cached per portal).

    .DESCRIPTION
        Phase J D'.1 (2026-05-04): extracted from
        Xdr.Defender.Client/_EndpointHelpers.ps1 Get-MDEEndpointManifest.
        v0.2.0 multi-portal expansion uses the same loader semantics for
        Entra/Purview/Intune.

        Loads `endpoints.manifest.psd1` from the portal-specific client
        module directory:
          Defender -> src/Modules/Xdr.Defender.Client/endpoints.manifest.psd1
          Entra    -> src/Modules/Xdr.Entra.Client/endpoints.manifest.psd1     (v0.2.0)
          Purview  -> src/Modules/Xdr.Purview.Client/endpoints.manifest.psd1   (v0.2.0)
          Intune   -> src/Modules/Xdr.Intune.Client/endpoints.manifest.psd1    (v0.2.0)

        v0.1.0 GA: only Portal='Defender' is functional. Other portals throw
        "v0.2.0 roadmap" until their manifests are populated.

        Per-entry processing:
          1. Apply Defaults block (Portal/MFAMethodsSupported/AuditScope/IdProperty/
             ProjectionMap/SchemaSource/StreamSubtype/SnapshotDedupRationale)
          2. Validate mandatory fields (Stream/Path/Tier/Category/Purpose/Availability)
          3. Derive CategorySlug from CategoryId via authoritative taxonomy
          4. Derive SourceName from Stream + StreamSubtype (TitleCase)
          5. Derive CategoryTable from CategoryId + Portal (Phase J)
          6. Reject AuditScope='public-api-covered' (operators should use
             official Microsoft Sentinel data connector for those)

    .PARAMETER Portal
        Portal name (Defender|Entra|Purview|Intune). Default: Defender.

    .PARAMETER Force
        Re-read the manifest from disk, discarding the per-portal cache.
        Useful in tests.

    .OUTPUTS
        [hashtable] keyed by Stream name (e.g. 'MDE_AdvancedFeatures_CL');
        values are per-entry hashtables with Defaults applied + derived
        fields populated.

    .EXAMPLE
        $mf = Get-XdrEndpointManifest -Portal Defender
        $puaConfig = $mf['MDE_PUAConfig_CL']
        # $puaConfig.CategoryTable -> 'Defender_EndpointConfiguration_CL'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateSet('Defender', 'Entra', 'Purview', 'Intune')]
        [string] $Portal = 'Defender',

        [switch] $Force
    )

    if (-not $Force -and $script:ManifestCache.ContainsKey($Portal)) {
        return $script:ManifestCache[$Portal]
    }

    # Resolve client module + manifest path.
    $portalMap = Get-XdrPortalClientModuleMap
    $clientModule = $portalMap[$Portal]
    if (-not $clientModule) {
        throw "Unknown Portal '$Portal'. Supported: $(($portalMap.Keys | Sort-Object) -join ', ')"
    }

    # Walk up from this module's location to find <repoRoot>/src/Modules/<ClientModule>/
    # This module lives at: src/Modules/Xdr.Common.Manifest/Public/<this>.ps1
    # We need: src/Modules/<ClientModule>/endpoints.manifest.psd1
    $modulesDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $clientModuleDir = Join-Path $modulesDir $clientModule
    $manifestPath = Join-Path $clientModuleDir 'endpoints.manifest.psd1'

    if (-not (Test-Path $manifestPath)) {
        if ($Portal -ne 'Defender') {
            throw "Portal '$Portal' is v0.2.0 roadmap — manifest not yet populated at $manifestPath. Use Portal='Defender' for v0.1.0 GA."
        }
        throw "Endpoint manifest not found: $manifestPath"
    }

    $raw = Import-PowerShellDataFile -Path $manifestPath
    if (-not $raw.Endpoints) {
        throw "Manifest at $manifestPath missing required 'Endpoints' array"
    }

    # Apply manifest-level Defaults (entry overrides take precedence).
    $defaults = Get-XdrManifestDefaults
    if ($raw.PSObject.Properties['Defaults'] -and $raw.Defaults) {
        foreach ($key in @($defaults.Keys)) {
            if ($raw.Defaults.PSObject.Properties[$key]) {
                $defaults[$key] = $raw.Defaults.$key
            }
        }
    }

    $mandatoryFields = Get-XdrManifestMandatoryFields
    $nodocMap = Get-XdrNodocCategoryMap

    $indexed = @{}
    foreach ($entry in $raw.Endpoints) {
        $missingField = $mandatoryFields | Where-Object {
            -not $entry.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$entry[$_])
        } | Select-Object -First 1
        if ($missingField) {
            Write-Warning "Skipping malformed manifest entry (missing $missingField): $($entry | ConvertTo-Json -Compress -Depth 3)"
            continue
        }
        if ($indexed.ContainsKey($entry.Stream)) {
            throw "Duplicate Stream '$($entry.Stream)' in manifest"
        }

        # Apply each Default field if not overridden.
        foreach ($key in $defaults.Keys) {
            if (-not $entry.ContainsKey($key)) {
                $entry[$key] = $defaults[$key]
            }
        }

        # Derive CategorySlug from CategoryId (if not explicit).
        if (-not $entry.ContainsKey('CategorySlug')) {
            if ($entry.ContainsKey('CategoryId') -and $nodocMap.ContainsKey([int]$entry.CategoryId)) {
                $entry['CategorySlug'] = $nodocMap[[int]$entry.CategoryId].Slug
            } else {
                $entry['CategorySlug'] = 'unknown'
            }
        }

        # Derive SourceName from Stream + StreamSubtype (TitleCase).
        # Convention: <Stream-without-_CL>_<TitleCaseSubtype>
        # e.g. MDE_AdvancedFeatures_CL + portal-api -> MDE_AdvancedFeatures_PortalApi
        if (-not $entry.ContainsKey('SourceName')) {
            $streamBase = $entry.Stream -replace '_CL$', ''
            $parts = $entry.StreamSubtype -split '-'
            $titleCased = New-Object System.Collections.Generic.List[string]
            foreach ($p in $parts) {
                if ([string]::IsNullOrEmpty($p)) { continue }
                $titleCased.Add($p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1))
            }
            $subtypeTitle = $titleCased -join ''
            $entry['SourceName'] = "${streamBase}_${subtypeTitle}"
        }

        # Phase J D'.1: derive CategoryTable from CategoryId + Portal.
        # This is the operator-facing target table after Phase J consolidation.
        if (-not $entry.ContainsKey('CategoryTable')) {
            if ($entry.ContainsKey('CategoryId') -and $nodocMap.ContainsKey([int]$entry.CategoryId)) {
                $pascalName = $nodocMap[[int]$entry.CategoryId].PascalName
                $entry['CategoryTable'] = "${Portal}_${pascalName}_CL"
            } else {
                $entry['CategoryTable'] = 'unknown'
            }
        }

        # AuditScope='public-api-covered' is forbidden (operators should use
        # official Sentinel connectors for those data sources).
        if ($entry.AuditScope -eq 'public-api-covered') {
            throw "Manifest entry '$($entry.Stream)' has AuditScope='public-api-covered'. The connector ingests portal-only telemetry; publicly-API-covered streams must be removed (use the official Microsoft Sentinel data connector instead)."
        }

        $indexed[$entry.Stream] = $entry
    }

    $script:ManifestCache[$Portal] = $indexed
    Write-Verbose "Get-XdrEndpointManifest: loaded $($indexed.Count) endpoint entries for portal '$Portal'"
    return $indexed
}
