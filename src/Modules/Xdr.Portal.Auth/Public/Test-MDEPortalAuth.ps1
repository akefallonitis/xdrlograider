function Test-MDEPortalAuth {
    <#
    .SYNOPSIS
        Runs the full auth chain and a benign probe call; returns structured diagnostic.

    .DESCRIPTION
        Used by the Function App's validate-auth-selftest timer and by operator
        diagnostics. Returns a structured object covering each stage of the auth
        chain (ESTSAUTH+sccauth via Get-EstsCookie, then a benign portal API probe)
        with timing and success/failure per stage.

        As of v1.0 the auth flow is a single hop: Get-EstsCookie returns a session
        that already carries sccauth + XSRF for the target portal, so there is no
        separate `sccauth-exchange` stage. Probe call uses TenantContext which is
        the most stable portal endpoint (unauthenticated 401 if creds bad,
        200 + AuthInfo if good).

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
        SccauthAcquiredUtc  = $null
        TenantId            = $null
        SampleCallHttpCode  = $null
        SampleCallLatencyMs = $null
    }

    $stageStopwatch = [System.Diagnostics.Stopwatch]::new()

    try {
        # --- Stage 1: authenticate (Get-EstsCookie returns session with sccauth+XSRF) ---
        $result.Stage = 'ests-cookie'
        $stageStopwatch.Restart()
        $auth = Get-EstsCookie -Method $Method -Credential $Credential -PortalHost $PortalHost
        $result.StageTimings.estsMs      = [int]$stageStopwatch.ElapsedMilliseconds
        $result.SccauthAcquiredUtc       = $auth.AcquiredUtc
        $result.TenantId                 = $auth.TenantId

        # --- Stage 2: benign portal probe (TenantContext — proven-working endpoint) ---
        $result.Stage = 'sample-call'
        $stageStopwatch.Restart()
        $connected = [pscustomobject]@{
            Session     = $auth.Session
            Upn         = $Credential.upn
            PortalHost  = $PortalHost
            AcquiredUtc = $auth.AcquiredUtc
            TenantId    = $auth.TenantId
        }
        try {
            $sample = Invoke-MDEPortalRequest `
                -Session $connected `
                -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' `
                -Method GET `
                -TimeoutSec 30
            $result.SampleCallHttpCode  = 200
            $result.SampleCallLatencyMs = [int]$stageStopwatch.ElapsedMilliseconds
            # Iter 13.2 fix: strict mode evaluates LHS to bool BEFORE short-circuit;
            # plain `$sample.AuthInfo` access throws PropertyNotFoundException
            # if AuthInfo property is absent. Defensive PSObject.Properties check.
            $hasAuthInfo = ($null -ne $sample) -and
                           ($sample.PSObject.Properties['AuthInfo']) -and
                           ($null -ne $sample.AuthInfo)
            if (-not $hasAuthInfo) {
                throw "Probe returned 200 but body lacks AuthInfo — response shape unexpected"
            }
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            # Iter 13.2 fix: $_.Exception.Response may be $null on some HTTP
            # error paths (DNS failure, TLS handshake fail, etc.). Strict-mode
            # access throws on null. Wrap defensively.
            $statusCode = 0
            try {
                if ($null -ne $_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
            } catch {}
            $result.SampleCallHttpCode  = $statusCode
            $result.SampleCallLatencyMs = [int]$stageStopwatch.ElapsedMilliseconds
            throw "Sample call failed: HTTP $statusCode — $($_.Exception.Message)"
        }

        $result.Success = $true
        $result.Stage   = 'complete'
    } catch {
        $result.FailureReason = $_.Exception.Message
        Write-Warning "Test-MDEPortalAuth stage=$($result.Stage) failed: $($result.FailureReason)"
    }

    return [pscustomobject]$result
}
