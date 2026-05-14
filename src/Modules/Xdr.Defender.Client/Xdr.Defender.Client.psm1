# Xdr.Defender.Client — L3 Defender XDR portal-only telemetry client
#
# Architecture (v0.1.0 GA):
#   endpoints.manifest.psd1         scriptblock-eval manifest of 492 endpoints across 18 sub-areas
#                                     (each entry carries Tier, Path, Filter, IdProperty, Pagination,
#                                     PerEntityFanout, PerPlatformFanout, ProjectionMap)
#   Endpoints/_EndpointHelpers.ps1  shared helpers:
#                                     Get-XdrEndpointManifest -Portal Defender  (cached manifest loader)
#                                     Invoke-MDEPortalEndpoint (structured HTTP wrapper)
#                                     ConvertTo-MDEIngestRow   (row normaliser)
#                                     Expand-MDEResponse       (response flattener)
#   Public/Invoke-MDEEndpoint.ps1   per-EntryKey dispatcher (used by the Xdr-PollStream activity)
#
# The 4 Durable functions own scheduling + tier fan-out + heartbeat — Xdr-PollStream
# calls Invoke-MDEEndpoint directly with the EntryKey supplied by Xdr-PollOrchestrator
# (which reads the manifest for the (Portal, Tier) burst). No per-tier loop here.
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

# 3) Manifest loads lazily on first Get-XdrEndpointManifest call.
#    Get-XdrEndpointManifest memoises its result in module scope, so the
#    second-and-subsequent calls are O(1). This shifts the first-call
#    parse cost into the first real poll rather than module import,
#    so functions that never reach a poll (e.g. cold-start aborts) don't
#    pay it.

Export-ModuleMember -Function @(
    'Invoke-MDEEndpoint',
    'Invoke-MDEPortalEndpoint',
    'ConvertTo-MDEIngestRow',
    'Expand-MDEResponse',
    'Get-MDEEndpointLastResult',
    'Get-XdrCustomCollectionRule',
    'Get-XdrCustomCollectionRuleById',
    'Get-XdrCustomCollectionModel',
    'Get-DefenderTenantContext'
)
