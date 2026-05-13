function Get-XdrCustomCollectionRuleById {
    <#
    .SYNOPSIS
        Fetches a single Defender Endpoint Custom Collection rule by RuleId via
        /mtp/mdeCustomCollection/rules/{RuleId}.

    .DESCRIPTION
        Companion to Get-XdrCustomCollectionRule for per-rule drill-down. Used
        when an operator wants the full rule body + version key (the list call
        may project a summary view depending on tenant configuration).

    .PARAMETER Session
        WebRequestSession from Connect-DefenderPortal.

    .PARAMETER RuleId
        The rule's unique identifier (GUID-shaped string).

    .OUTPUTS
        Single rule object with full body, Version, and UpdateKey for
        optimistic-concurrency PUT chains.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [string] $RuleId
    )

    $path = "/mtp/mdeCustomCollection/rules/$([System.Uri]::EscapeDataString($RuleId))"
    $r = Invoke-MDEPortalEndpoint -Session $Session -Path $path -Method GET
    if (-not $r.Success) {
        throw "Get-XdrCustomCollectionRuleById failed for RuleId='$RuleId': $($r.Error)"
    }
    return $r.Data
}
