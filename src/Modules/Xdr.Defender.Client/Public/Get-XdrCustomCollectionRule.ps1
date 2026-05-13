function Get-XdrCustomCollectionRule {
    <#
    .SYNOPSIS
        Lists Defender Endpoint Custom Collection rules via the corrected
        apiproxy path /mtp/mdeCustomCollection/rules.

    .DESCRIPTION
        Mirrors the XDRInternals canonical source's Get-XdrEndpointConfigurationCustomCollectionRule
        cmdlet. Custom Collection rules govern endpoint event-data ingestion
        beyond default device telemetry (e.g. ETW providers, registry watchers,
        custom file collectors).

        Path correction history: nodoc YAML captured /mtp/customDataCollection/rules
        which returned 404. XDRInternals canonical was discovered to use
        /mtp/mdeCustomCollection/rules — same auth (sccauth+XSRF via apiproxy)
        as the rest of the 18 Defender sub-areas. Live-validated HTTP 200 on
        2026-05-13 with empty array (tenant has no rules configured).

    .PARAMETER Session
        WebRequestSession from Connect-DefenderPortal.

    .OUTPUTS
        Array of rule objects. Each rule carries Id, Name, IsEnabled, Table,
        Platform, ActionType, Scope, Filters, Tags, Version, UpdateKey, and
        creation/modification metadata. The Version+UpdateKey pair is needed
        for optimistic-concurrency PUT updates (write-shaped, excluded from
        Phase 1 read manifest).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    $r = Invoke-MDEPortalEndpoint -Session $Session -Path '/mtp/mdeCustomCollection/rules' -Method GET
    if (-not $r.Success) {
        throw "Get-XdrCustomCollectionRule failed: $($r.Error)"
    }
    return ,@($r.Data)
}
