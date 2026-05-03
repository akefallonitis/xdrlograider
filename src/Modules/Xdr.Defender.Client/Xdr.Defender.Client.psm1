# Xdr.Defender.Client — L3 Defender XDR portal-only telemetry client
#
# Architecture (v1.0):
#   endpoints.manifest.psd1         single catalogue of 52 streams (Tier, Path, Filter, IdProperty)
#   Endpoints/_EndpointHelpers.ps1  shared helpers:
#                                     Get-MDEEndpointManifest  (cached manifest loader)
#                                     Invoke-MDEPortalEndpoint (structured HTTP wrapper)
#                                     ConvertTo-MDEIngestRow   (row normaliser)
#                                     Expand-MDEResponse       (response flattener)
#   Public/Invoke-MDEEndpoint.ps1   single per-stream dispatcher
#   Public/Invoke-MDETierPoll.ps1   per-tier loop used by the 7 scheduled timer functions
#
# Callers use exactly one entry point:
#   - Scheduled tier polling:     Invoke-MDETierPoll  -Session $s -Tier 'P0' -Config $c
#   - Direct single-stream call:  Invoke-MDEEndpoint  -Session $s -Stream 'MDE_PUAConfig_CL' [-FromUtc $since]
#
# Scope: READ-ONLY. No action-triggering endpoints. All entries are HTTP GETs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 1) Helpers first (required by everything else).
. (Join-Path $PSScriptRoot 'Endpoints' '_ProjectionHelpers.ps1')
. (Join-Path $PSScriptRoot 'Endpoints' '_EndpointHelpers.ps1')

# v0.1.0-beta post-deploy: strict-mode-safe init for the debug-capture
# tracking var used by Expand-MDEResponse when XDR_DEBUG_RESPONSE_CAPTURE=true.
# Without this init, every poll-* invocation crashed with
#   "The variable '$script:DebugResponseSeen' cannot be retrieved because
#    it has not been set"
# under Set-StrictMode -Version Latest. Same pattern as $script:DcrIdMap
# init in Xdr.Sentinel.Ingest.psm1.
$script:DebugResponseSeen = @{}

# 2) Public entry points (dispatcher + tier poller).
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter *.ps1 -ErrorAction SilentlyContinue)
foreach ($file in $publicFiles) {
    try {
        . $file.FullName
    } catch {
        Write-Error "Failed to load $($file.FullName): $_"
        throw
    }
}

# 3) Warm the manifest cache at import time so any first-call latency stays in
#    cold-start rather than first real poll.
$null = Get-MDEEndpointManifest

Export-ModuleMember -Function @(
    'Invoke-MDEEndpoint',
    'Invoke-MDETierPoll',
    'Invoke-TierPollWithHeartbeat',
    'Get-MDEEndpointManifest',
    'Invoke-MDEPortalEndpoint',
    'ConvertTo-MDEIngestRow',
    'Expand-MDEResponse'
)
