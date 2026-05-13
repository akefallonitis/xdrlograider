function Get-XdrNodocCategorySlug {
    <#
    .SYNOPSIS
        Returns the kebab-case nodoc category slug for a given NodocCategoryId
        (1-10) per the authoritative taxonomy.

    .DESCRIPTION
        Maps NodocCategoryId (integer 1-10) to a kebab-case slug used as an
        ARM-stable identifier and the basis for `Defender_<PascalName>_CL`
        category-table naming (Phase J consolidation).

        Categories per the nodoc 10-category authoritative taxonomy
        (yellow-only per user screenshot 2026-05-04):
          1  endpoint-device-management
          2  endpoint-configuration
          3  vulnerability-management
          4  identity-protection
          5  configuration-and-settings
          6  exposure-management
          7  threat-analytics
          8  action-center
          9  multi-tenant-operations
          10 streaming-api

    .PARAMETER NodocCategoryId
        Integer 1-10 from the manifest's NodocCategoryId field.

    .EXAMPLE
        Get-XdrNodocCategorySlug -NodocCategoryId 5
        # Returns 'configuration-and-settings'

    .OUTPUTS
        [string] kebab-case slug, or 'unknown' for unmapped IDs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $NodocCategoryId
    )

    $map = Get-XdrNodocCategoryMap
    if ($map.ContainsKey($NodocCategoryId)) {
        return $map[$NodocCategoryId].Slug
    }
    return 'unknown'
}
