function Get-XdrCustomCollectionModel {
    <#
    .SYNOPSIS
        Fetches the Defender Endpoint Custom Collection model (schema) via
        /mtp/mdeCustomCollection/model.

    .DESCRIPTION
        Returns the metadata schema (available tables, platforms, action types,
        scopes, filter operators) that operators use to construct valid Custom
        Collection rules. Required reading-side companion to the list+by-id
        cmdlets — without the model, operators cannot interpret rule body
        enums or build new rules.

        Same auth (sccauth+XSRF via apiproxy) as the rest of the 18 Defender
        sub-areas. Live-validated working schema endpoint.

    .PARAMETER Session
        WebRequestSession from Connect-DefenderPortal.

    .OUTPUTS
        Model object with table list, platform enum, action-type enum, scope
        enum, filter-operator enum, etc.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    $r = Invoke-MDEPortalEndpoint -Session $Session -Path '/mtp/mdeCustomCollection/model' -Method GET
    if (-not $r.Success) {
        throw "Get-XdrCustomCollectionModel failed: $($r.Error)"
    }
    return $r.Data
}
