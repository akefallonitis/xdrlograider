function Test-MDEPortalAuth {
    <#
    .SYNOPSIS
        Runs the full auth chain and a benign probe call; returns structured diagnostic.

    .DESCRIPTION
        Used by the Function App's validate-auth-selftest timer and by operator
        diagnostics. Returns a structured object covering each stage of the auth
        chain (login → ESTSAUTH → sccauth+XSRF → sample API call) with timing and
        success/failure per stage.

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'.

    .PARAMETER Credential
        Hashtable matching the method (see Connect-MDEPortal).

    .PARAMETER PortalHost
        Target portal. Default: security.microsoft.com.

    .OUTPUTS
        [pscustomobject] with stage-level timings and overall success flag.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,

        [string] $PortalHost = 'security.microsoft.com'
    )

    $result = [ordered]@{
        TimeGenerated = [datetime]::UtcNow
        Method        = $Method
        PortalHost    = $PortalHost
        Upn           = $Credential.upn
        Success       = $false
        Stage         = 'start'
        StageTimings  = [ordered]@{}
        FailureReason = $null
        SccauthAcquiredUtc = $null
        SampleCallHttpCode = $null
        SampleCallLatencyMs = $null
    }

    $stageStopwatch = [System.Diagnostics.Stopwatch]::new()

    try {
        # --- Stage 1: ESTSAUTHPERSISTENT ---
        $result.Stage = 'ests-cookie'
        $stageStopwatch.Restart()
        $session = Get-EstsCookie -Method $Method -Credential $Credential -PortalHost $PortalHost
        $result.StageTimings.estsMs = [int]$stageStopwatch.ElapsedMilliseconds

        # --- Stage 2: sccauth + XSRF ---
        $result.Stage = 'sccauth-exchange'
        $stageStopwatch.Restart()
        $exchange = Exchange-SccauthCookie -Session $session -PortalHost $PortalHost
        $result.StageTimings.sccauthMs = [int]$stageStopwatch.ElapsedMilliseconds
        $result.SccauthAcquiredUtc = $exchange.AcquiredUtc

        # --- Stage 3: sample API call (benign, low-rate-limit impact) ---
        $result.Stage = 'sample-call'
        $stageStopwatch.Restart()
        $connected = [pscustomobject]@{
            Session     = $exchange.Session
            Upn         = $Credential.upn
            PortalHost  = $PortalHost
            AcquiredUtc = $exchange.AcquiredUtc
        }
        try {
            $sample = Invoke-MDEPortalRequest -Session $connected -Path '/api/settings/GetAdvancedFeaturesSetting' -Method GET -TimeoutSec 30
            $result.SampleCallHttpCode  = 200
            $result.SampleCallLatencyMs = [int]$stageStopwatch.ElapsedMilliseconds
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $result.SampleCallHttpCode  = [int]$_.Exception.Response.StatusCode
            $result.SampleCallLatencyMs = [int]$stageStopwatch.ElapsedMilliseconds
            throw "Sample call failed: HTTP $($result.SampleCallHttpCode) — $($_.Exception.Message)"
        }

        $result.Success = $true
        $result.Stage   = 'complete'
    } catch {
        $result.FailureReason = $_.Exception.Message
        Write-Warning "Test-MDEPortalAuth stage=$($result.Stage) failed: $($result.FailureReason)"
    }

    return [pscustomobject]$result
}
