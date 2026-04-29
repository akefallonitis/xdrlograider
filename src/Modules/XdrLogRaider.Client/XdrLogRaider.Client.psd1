@{
    RootModule            = 'XdrLogRaider.Client.psm1'
    ModuleVersion         = '1.0.0'
    CompatiblePSEditions  = @('Core')
    PowerShellVersion     = '7.4'
    GUID                  = 'd2f4a5b7-1c83-44e9-9a25-3e8d7a1b6f04'
    Author                = 'Alex Kefallonitis'
    CompanyName           = 'Community'
    Copyright             = '(c) 2026 Alex Kefallonitis and contributors. MIT License.'
    Description           = 'Backward-compat shim. Imports Xdr.Defender.Client (L3 Defender-portal manifest dispatcher) and re-exports the legacy MDE-prefixed function names (Invoke-MDEEndpoint, Invoke-MDETierPoll, Invoke-TierPollWithHeartbeat, Get-MDEEndpointManifest, Invoke-MDEPortalEndpoint, ConvertTo-MDEIngestRow, Expand-MDEResponse). New code SHOULD reference Xdr.Defender.Client directly or use the L4 Xdr.Connector.Orchestrator surface; this shim stays through the v0.1.0 GA window for operator-script + test-mock backward-compat.'
    FunctionsToExport     = @(
        'Invoke-MDEEndpoint',
        'Invoke-MDETierPoll',
        'Invoke-TierPollWithHeartbeat',
        'Get-MDEEndpointManifest',
        'Invoke-MDEPortalEndpoint',
        'ConvertTo-MDEIngestRow',
        'Expand-MDEResponse'
    )
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()
    PrivateData           = @{
        PSData = @{
            Tags         = @('Defender', 'MDE', 'XDR', 'Portal', 'Endpoints', 'Compat')
            LicenseUri   = 'https://github.com/akefallonitis/xdrlograider/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/akefallonitis/xdrlograider'
            ReleaseNotes = 'Backward-compat shim. Re-exports the renamed Xdr.Defender.Client surface under the legacy XdrLogRaider.Client name.'
        }
    }
}
