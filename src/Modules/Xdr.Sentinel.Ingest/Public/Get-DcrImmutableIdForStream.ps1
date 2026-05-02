function Get-DcrImmutableIdForStream {
    <#
    .SYNOPSIS
        Resolves the per-stream DCR immutableId from the deploy-time map.

    .DESCRIPTION
        47 streams are partitioned across 5 DCRs (one DCE shared) — see
        deploy/modules/dce-dcr.bicep for the partition rationale (Microsoft
        Learn data-collection-rule-structure: 1 dataFlow per stream with
        explicit outputStream + transformKql=source, capped at 10 dataFlows
        per DCR). Callers in the FA pipeline (Send-ToLogAnalytics,
        Write-Heartbeat) need the right DCR's immutableId for the stream they
        are writing — this helper does the lookup.

        The lookup table arrives via the FA app setting
        DCR_IMMUTABLE_IDS_JSON (set by mainTemplate.json from
        modules/dce-dcr.bicep:dcrImmutableIdsJson output). It is parsed
        once per worker process and cached in script scope; callers pay the
        JSON parse cost on first call only.

    .PARAMETER StreamName
        Stream name with or without the `Custom-` prefix. Both
        'MDE_AdvancedFeatures_CL' and 'Custom-MDE_AdvancedFeatures_CL'
        resolve to the same DCR — the helper strips the prefix so callers
        do not need to know which form their caller passed.

    .OUTPUTS
        [string] DCR immutableId (`dcr-<32 hex chars>`).

    .EXAMPLE
        $dcr = Get-DcrImmutableIdForStream -StreamName 'MDE_AdvancedFeatures_CL'
        Send-ToLogAnalytics -DceEndpoint $env:DCE_ENDPOINT `
            -DcrImmutableId $dcr `
            -StreamName 'Custom-MDE_AdvancedFeatures_CL' `
            -Rows $rows
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StreamName
    )

    # Strict-mode-safe variable existence check. The module's psm1 inits
    # $script:DcrIdMap = $null at load time (same pattern as MonitorTokenCache /
    # XdrTableHttpClient) so this read works under
    # `Set-StrictMode -Version Latest` (enabled in heartbeat-5m + every poll-*).
    # Without the module-init, this check threw "The variable '$script:DcrIdMap'
    # cannot be retrieved because it has not been set" on cold start.
    if ($null -eq $script:DcrIdMap) {
        $json = $env:DCR_IMMUTABLE_IDS_JSON
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'DCR_IMMUTABLE_IDS_JSON env var is empty. FA appSettings misconfigured.'
        }
        $script:DcrIdMap = $json | ConvertFrom-Json -AsHashtable
    }
    $key = $StreamName -replace '^Custom-', ''
    if (-not $script:DcrIdMap.ContainsKey($key)) {
        throw "Stream '$key' has no DCR mapping. DCR_IMMUTABLE_IDS_JSON keys: $($script:DcrIdMap.Keys -join ', ')"
    }
    return $script:DcrIdMap[$key]
}
