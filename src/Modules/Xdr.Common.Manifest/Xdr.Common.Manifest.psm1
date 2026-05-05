# Xdr.Common.Manifest — generic per-portal endpoint manifest loader
#
# Phase J D'.1 (2026-05-04): extracted from Xdr.Defender.Client/_EndpointHelpers.ps1
# Get-MDEEndpointManifest. v0.2.0 multi-portal expansion (Entra/Purview/Intune)
# uses the same loader semantics; extracting here NOW gives the right
# dependency graph (portal modules depend on Xdr.Common.Manifest, NOT on
# Xdr.Defender.Client).
#
# v0.1.0 GA scope: only Portal='Defender' is functional. v0.2.0 fills in
# Xdr.Entra.Client / Xdr.Purview.Client / Xdr.Intune.Client manifests.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Per-portal manifest cache (process-scoped). Keyed by portal name.
$script:ManifestCache = @{}

# Dot-source private helpers + public functions.
foreach ($folder in @('Private', 'Public')) {
    $dir = Join-Path $PSScriptRoot $folder
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Filter '*.ps1' -File | ForEach-Object {
            . $_.FullName
        }
    }
}

# Export public functions per the .psd1 FunctionsToExport list.
Export-ModuleMember -Function @(
    'Get-XdrEndpointManifest',
    'Get-XdrCategoryTableName',
    'Get-XdrNodocCategorySlug'
)
