function Test-DefenderPortalAuth {
    <#
    .SYNOPSIS
        L2 Defender — runs the full auth chain + benign portal probe; returns
        structured diagnostic.

    .DESCRIPTION
        Used by the Function App's validate-auth-selftest timer and by operator
        diagnostics. Returns a structured object covering each stage of the auth
        chain (Get-EntraEstsAuth + Get-DefenderSccauth + benign portal API probe)
        with timing and success/failure per stage.

        Probe call uses TenantContext which is the most stable portal endpoint
        (unauthenticated 401 if creds bad, 200 + AuthInfo if good).

    .PARAMETER Method
        'CredentialsTotp' or 'Passkey'.

    .PARAMETER Credential
        Hashtable matching the method (see Connect-DefenderPortal).

    .PARAMETER PortalHost
        Target portal. Default: security.microsoft.com.

    .OUTPUTS
        [pscustomobject] with stage-level timings and overall success flag.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        # iter-13.12: accept BOTH PascalCase + snake_case so the ARM template's
        # `authMethod` parameter ('credentials_totp' / 'passkey') flows through
        # profile.ps1 → $env:AUTH_METHOD → here without intermediate normalization.
        [ValidateSet('CredentialsTotp', 'Passkey', 'credentials_totp', 'passkey')]
        [string] $Method,

        [Parameter(Mandatory)] [hashtable] $Credential,

        [string] $PortalHost = 'security.microsoft.com'
    )

    # Normalize snake_case -> PascalCase
    $Method = switch ($Method) {
        'credentials_totp' { 'CredentialsTotp' }
        'passkey'          { 'Passkey' }
        default            { $Method }
    }

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
        # --- Stage 1: full auth chain (L1 Get-EntraEstsAuth + L2 Get-DefenderSccauth) ---
        $result.Stage = 'auth-chain'
        $stageStopwatch.Restart()
        $connected = Connect-DefenderPortal -Method $Method -Credential $Credential -PortalHost $PortalHost
        $result.StageTimings.authMs      = [int]$stageStopwatch.ElapsedMilliseconds
        $result.SccauthAcquiredUtc       = $connected.AcquiredUtc
        $result.TenantId                 = $connected.TenantId

        # --- Stage 2: benign portal probe (TenantContext — proven-working endpoint) ---
        $result.Stage = 'sample-call'
        $stageStopwatch.Restart()
        try {
            $sample = Invoke-DefenderPortalRequest `
                -Session $connected `
                -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' `
                -Method GET `
                -TimeoutSec 30
            $result.SampleCallHttpCode  = 200
            $result.SampleCallLatencyMs = [int]$stageStopwatch.ElapsedMilliseconds
            # iter-13.2: strict-mode-safe AuthInfo presence check
            $hasAuthInfo = ($null -ne $sample) -and
                           ($sample.PSObject.Properties['AuthInfo']) -and
                           ($null -ne $sample.AuthInfo)
            if (-not $hasAuthInfo) {
                throw "Probe returned 200 but body lacks AuthInfo — response shape unexpected"
            }
        } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
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
        Write-Warning "Test-DefenderPortalAuth stage=$($result.Stage) failed: $($result.FailureReason)"
    }

    return [pscustomobject]$result
}
