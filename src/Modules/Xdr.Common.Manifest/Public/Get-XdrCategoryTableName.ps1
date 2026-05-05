function Get-XdrCategoryTableName {
    <#
    .SYNOPSIS
        Returns the canonical per-portal category-table name for a given
        NodocCategoryId + Portal (e.g. 'Defender_ConfigurationAndSettings_CL').

    .DESCRIPTION
        Phase J consolidation: 59 per-stream `MDE_*_CL` tables consolidate to
        10 per-category `Defender_<Category>_CL` tables. v0.2.0 multi-portal
        expansion adds parallel `Entra_<Category>_CL` / `Purview_<Category>_CL`
        / `Intune_<Category>_CL` tables under the SAME nodoc taxonomy.

        Naming convention: <Portal>_<PascalCategoryName>_CL
          Defender_EndpointDeviceManagement_CL    (NodocCategoryId=1)
          Defender_EndpointConfiguration_CL       (NodocCategoryId=2)
          Defender_VulnerabilityManagement_CL     (NodocCategoryId=3)
          Defender_IdentityProtection_CL          (NodocCategoryId=4)
          Defender_ConfigurationAndSettings_CL    (NodocCategoryId=5)
          Defender_ExposureManagement_CL          (NodocCategoryId=6)
          Defender_ThreatAnalytics_CL             (NodocCategoryId=7)
          Defender_ActionCenter_CL                (NodocCategoryId=8)
          Defender_MultiTenantOperations_CL       (NodocCategoryId=9)
          Defender_StreamingApi_CL                (NodocCategoryId=10)

        XdrConnectorHealth_CL is the operational table (transcends portals,
        Xdr* prefix indicates "produced by xdrlograider connector"); not
        returned by this function — it's a standalone ops table not tied
        to any nodoc category.

    .PARAMETER NodocCategoryId
        Integer 1-10. The nodoc taxonomy category.

    .PARAMETER Portal
        Portal name (Defender|Entra|Purview|Intune). v0.1.0 GA: only Defender
        is functional. v0.2.0 fills in Entra/Purview/Intune.

    .EXAMPLE
        Get-XdrCategoryTableName -NodocCategoryId 5 -Portal Defender
        # Returns 'Defender_ConfigurationAndSettings_CL'

    .EXAMPLE
        # v0.2.0 usage (when Entra portal is filled in):
        Get-XdrCategoryTableName -NodocCategoryId 4 -Portal Entra
        # Returns 'Entra_IdentityProtection_CL'

    .OUTPUTS
        [string] table name in `<Portal>_<PascalCategory>_CL` form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [int] $NodocCategoryId,
        [Parameter(Mandatory)]
        [ValidateSet('Defender', 'Entra', 'Purview', 'Intune')]
        [string] $Portal
    )

    $map = Get-XdrNodocCategoryMap
    if (-not $map.ContainsKey($NodocCategoryId)) {
        throw "Unknown NodocCategoryId: $NodocCategoryId. Must be 1-10 per nodoc 10-category taxonomy."
    }

    $pascalName = $map[$NodocCategoryId].PascalName
    return "${Portal}_${pascalName}_CL"
}
