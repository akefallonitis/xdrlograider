function Write-AuthTestResult {
    <#
    .SYNOPSIS
        Appends an auth-self-test result row to MDE_AuthTestResult_CL.

    .DESCRIPTION
        Called by the validate-auth-selftest timer. The row includes per-stage timing,
        overall success, and failure reason if applicable. This is the single source
        of truth for "does auth work" — the Connector UI, runbook, and troubleshooting
        docs all point at this table.

    .PARAMETER DceEndpoint
        DCE URL.

    .PARAMETER DcrImmutableId
        DCR immutable ID.

    .PARAMETER TestResult
        Output from Test-MDEPortalAuth (pscustomobject with Success, Stage, FailureReason, etc.)

    .OUTPUTS
        Same shape as Send-ToLogAnalytics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DceEndpoint,
        [Parameter(Mandatory)] [string] $DcrImmutableId,
        [Parameter(Mandatory)] [pscustomobject] $TestResult
    )

    # Iter 13.2 fix: under Set-StrictMode -Version Latest, accessing a hash
    # key that doesn't exist throws PropertyNotFoundException. StageTimings
    # may be empty (validate-auth-selftest preflight failure) or missing
    # estsMs/sccauthMs entries (Test-MDEPortalAuth path-of-failure variations).
    # Use a defensive Contains() check that works for both [hashtable] and
    # [System.Collections.Specialized.OrderedDictionary].
    $stageTimings = $TestResult.StageTimings
    $estsMs = 0
    $sccauthMs = 0
    if ($null -ne $stageTimings) {
        # IDictionary covers both [hashtable] and [ordered]hashtable
        if ($stageTimings -is [System.Collections.IDictionary]) {
            if ($stageTimings.Contains('estsMs') -and $null -ne $stageTimings['estsMs']) {
                $estsMs = $stageTimings['estsMs']
            }
            if ($stageTimings.Contains('sccauthMs') -and $null -ne $stageTimings['sccauthMs']) {
                $sccauthMs = $stageTimings['sccauthMs']
            }
        }
    }
    # SccauthAcquiredUtc may be missing on some failure paths. Defensive null-check.
    $sccauthAcquiredUtc = $null
    if ($TestResult.PSObject.Properties['SccauthAcquiredUtc'] -and $null -ne $TestResult.SccauthAcquiredUtc) {
        $sccauthAcquiredUtc = $TestResult.SccauthAcquiredUtc.ToString('o')
    }

    $row = [ordered]@{
        TimeGenerated       = [datetime]::UtcNow.ToString('o')
        Method              = $TestResult.Method
        PortalHost          = $TestResult.PortalHost
        Upn                 = $TestResult.Upn
        Success             = $TestResult.Success
        Stage               = $TestResult.Stage
        FailureReason       = $TestResult.FailureReason
        EstsMs              = $estsMs
        SccauthMs           = $sccauthMs
        SampleCallHttpCode  = $TestResult.SampleCallHttpCode
        SampleCallLatencyMs = $TestResult.SampleCallLatencyMs
        SccauthAcquiredUtc  = $sccauthAcquiredUtc
    }

    Send-ToLogAnalytics `
        -DceEndpoint $DceEndpoint `
        -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-MDE_AuthTestResult_CL' `
        -Rows @([pscustomobject]$row)
}
