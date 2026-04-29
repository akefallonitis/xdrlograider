function Resolve-EntraInterruptPage {
    <#
    .SYNOPSIS
        L1 portal-generic Entra interrupt-page resolver. Walks KmsiInterrupt /
        CmsiInterrupt / ConvergedProofUpRedirect pages.

    .DESCRIPTION
        Accepts and returns an @{State; LastResponse} hashtable so the final
        form_post response is preserved for the caller (typically a Get-EntraEstsAuth
        wrapper that submits the form to the portal's OIDC callback).

        Public so that L2 portal modules can chain interrupt resolution after
        custom auth steps if needed (e.g., a portal that introduces an extra
        consent page after MFA).

    .PARAMETER Session
        WebRequestSession with the auth chain in progress.

    .PARAMETER AuthResult
        @{State; LastResponse} from the previous step.

    .OUTPUTS
        @{State; LastResponse} — possibly the same as input if no interrupt detected,
        or with State updated after walking interrupt pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [hashtable] $AuthResult
    )
    $state = $AuthResult.State
    $lastResponse = $AuthResult.LastResponse
    if (-not $state) { return $AuthResult }

    $lastPgid = $null
    $loops    = 0
    while ($state -and $loops -lt 10) {
        $pgid = Get-EntraField -Object $state -Name 'pgid' -Default ''
        if (-not $pgid -or $pgid -eq $lastPgid) { break }
        $lastPgid = $pgid
        $loops++

        $ctx    = Get-EntraField -Object $state -Name 'sCtx'
        $flowTk = Get-EntraField -Object $state -Name 'sFT'
        $canary = Get-EntraField -Object $state -Name 'canary'
        $corrId = Get-EntraField -Object $state -Name 'correlationId' -Default ([Guid]::NewGuid())
        $resp = $null; $handled = $false

        switch ($pgid) {
            'KmsiInterrupt' {
                Write-Verbose "Resolve-EntraInterruptPage: KmsiInterrupt"
                $body = @{ LoginOptions = 1; type = 28; ctx = $ctx; hpgrequestid = $corrId; flowToken = $flowTk; canary = $canary; i19 = 4130 }
                $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/kmsi' `
                    -WebSession $Session -Method Post -Body $body `
                    -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                $handled = $true
            }
            'CmsiInterrupt' {
                Write-Verbose "Resolve-EntraInterruptPage: CmsiInterrupt"
                $body = @{ ContinueAuth = 'true'; i19 = (Get-Random -Minimum 1000 -Maximum 9999); canary = $canary; iscsrfspeedbump = 'false'; flowToken = $flowTk; hpgrequestid = $corrId; ctx = $ctx }
                $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/appverify' `
                    -WebSession $Session -Method Post -Body $body `
                    -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                $handled = $true
            }
            'ConvergedProofUpRedirect' {
                $remaining = Get-EntraField -Object $state -Name 'iRemainingDaysToSkipMfaRegistration' -Default 0
                if ($remaining -gt 0) {
                    $proofState = Get-EntraField -Object $state -Name 'sProofUpAuthState' -Default $ctx
                    $body = @{ type = 22; FlowToken = $flowTk; request = $proofState; ctx = $proofState }
                    $resp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
                        -WebSession $Session -Method Post -Body $body `
                        -UseBasicParsing -MaximumRedirection 10 -SkipHttpErrorCheck
                    $handled = $true
                } else {
                    throw "MFA registration required; cannot skip. Enrol via mysignins.microsoft.com."
                }
            }
            default {
                # iter-13.9 (O1): unknown pgid is a diagnostic event — Entra introduced
                # a new interrupt page we don't handle yet. Capture diagnostic context
                # at Warning level so operators can root-cause from App Insights.
                $sErrorCode = Get-EntraField -Object $state -Name 'sErrorCode' -Default ''
                $sErrTxt    = Get-EntraField -Object $state -Name 'sErrTxt'    -Default ''
                $contentLen = if ($lastResponse -and $lastResponse.Content) { $lastResponse.Content.Length } else { 0 }
                Write-Warning ("Resolve-EntraInterruptPage: UNKNOWN pgid '$pgid' (sErrorCode='$sErrorCode' sErrTxt='$sErrTxt' contentLen=$contentLen). " +
                               "Auth chain cannot proceed. If this recurs, capture the HTML response and add a handler in Resolve-EntraInterruptPage.ps1.")
                Write-Verbose "Resolve-EntraInterruptPage: unknown pgid '$pgid' — exiting"
                break
            }
        }
        if (-not $handled) { break }
        Start-Sleep -Milliseconds 200
        $lastResponse = $resp
        $state = Get-EntraConfigBlob -Html $resp.Content
        if (-not $state) { break }
    }
    return @{ State = $state; LastResponse = $lastResponse }
}
