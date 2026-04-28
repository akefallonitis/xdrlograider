# XdrLogRaider.Ingest — Log Analytics DCE/DCR ingestion + heartbeat + checkpoints
# Dot-source public functions, export.

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

Export-ModuleMember -Function $public.BaseName
