# Xdr.Sentinel.Ingest — L1 portal-generic Sentinel ingest layer
# (DCE/DCR + Storage Table + Send-XdrAppInsightsEvent). Dot-source
# public functions and re-export per the manifest.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$publicPath = Join-Path $PSScriptRoot 'Public'
$public = @(Get-ChildItem -Path $publicPath -Filter *.ps1 -ErrorAction SilentlyContinue)

foreach ($file in $public) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

# Module-scope token cache for monitor.azure.com scope.
# Tokens are refreshed ~5 min before expiry.
$script:MonitorTokenCache = $null
$script:MonitorTokenExpiry = [datetime]::MinValue

# Iter 13.15: cached HttpClient for Invoke-XdrStorageTableEntity (socket-pool
# efficiency). Initialized to $null so strict-mode reads succeed.
$script:XdrTableHttpClient = $null

# v0.1.0-beta post-deploy bug fix: cached DCR-immutable-id map for
# Get-DcrImmutableIdForStream. Initialized to $null so the
# `if ($null -eq $script:DcrIdMap)` first-call check succeeds under
# `Set-StrictMode -Version Latest` (every poll-* + heartbeat-5m enables it).
# Without this init, heartbeat-5m crashed on every cold-start invocation:
# "The variable '$script:DcrIdMap' cannot be retrieved because it has not
# been set."
$script:DcrIdMap = $null

# Export all public functions. Most files contain a single function whose
# name matches BaseName, but iter-14.0 Phase 14B's Send-XdrAppInsightsEvent.ps1
# bundles four Send-XdrAppInsights* entry points + helpers in one file. We
# enumerate the explicit FunctionsToExport list from the manifest so the
# bundle's individual functions are picked up correctly.
$manifestPath = Join-Path $PSScriptRoot 'Xdr.Sentinel.Ingest.psd1'
$manifest = Import-PowerShellDataFile -Path $manifestPath
Export-ModuleMember -Function $manifest.FunctionsToExport
