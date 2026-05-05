# Module manifest for Xdr.Common.Manifest
# Generic endpoint-manifest loader serving any portal (Defender today; Entra,
# Purview, Intune in v0.2.0). Per Phase J D'.1: extracted from
# Xdr.Defender.Client to provide the right abstraction NOW so v0.2.0 portal
# modules plug in cleanly without depending on Xdr.Defender.Client.
@{
    RootModule        = 'Xdr.Common.Manifest.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '8a4c9b2d-7f31-4e6a-9c5d-1f8b3a7e2d6c'
    Author            = 'XdrLogRaider Project'
    Description       = 'Generic per-portal endpoint manifest loader (Defender, Entra, Purview, Intune)'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Get-XdrEndpointManifest',
        'Get-XdrCategoryTableName',
        'Get-XdrNodocCategorySlug'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('XdrLogRaider', 'Sentinel', 'Manifest', 'MultiPortal')
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'v0.1.0 GA Phase J D''.1 — extracted from Xdr.Defender.Client for v0.2.0 multi-portal forward-compat.'
        }
    }
}
