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

    $row = [ordered]@{
        TimeGenerated       = [datetime]::UtcNow.ToString('o')
        Method              = $TestResult.Method
        PortalHost          = $TestResult.PortalHost
        Upn                 = $TestResult.Upn
        Success             = $TestResult.Success
        Stage               = $TestResult.Stage
        FailureReason       = $TestResult.FailureReason
        EstsMs              = if ($TestResult.StageTimings.estsMs) { $TestResult.StageTimings.estsMs } else { 0 }
        SccauthMs           = if ($TestResult.StageTimings.sccauthMs) { $TestResult.StageTimings.sccauthMs } else { 0 }
        SampleCallHttpCode  = $TestResult.SampleCallHttpCode
        SampleCallLatencyMs = $TestResult.SampleCallLatencyMs
        SccauthAcquiredUtc  = if ($TestResult.SccauthAcquiredUtc) { $TestResult.SccauthAcquiredUtc.ToString('o') } else { $null }
    }

    Send-ToLogAnalytics `
        -DceEndpoint $DceEndpoint `
        -DcrImmutableId $DcrImmutableId `
        -StreamName 'Custom-MDE_AuthTestResult_CL' `
        -Rows @([pscustomobject]$row)
}
