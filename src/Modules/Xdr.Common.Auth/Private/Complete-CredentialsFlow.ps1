function Complete-CredentialsFlow {
    <#
    .SYNOPSIS
        L1 portal-generic credentials POST + MFA branching.

    .DESCRIPTION
        Sends username + password to Entra's urlPost with the portal's client_id.
        If MFA challenged (pgid=ConvergedTFA), delegates to Complete-TotpMfa.
        Returns @{State; LastResponse} for the orchestrator to pass through interrupts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $SessionInfo,
        [Parameter(Mandatory)] [string] $UrlPost,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    $upn        = $Credential.upn
    $password   = $Credential.password
    $totpBase32 = $Credential.totpBase32

    if (-not $password)   { throw "CredentialsTotp requires 'password'" }
    if (-not $totpBase32) { throw "CredentialsTotp requires 'totpBase32'" }

    # iter-13.15 (Phase C) discipline: wrap secret-bearing variables in try/finally so
    # the password (and downstream credBody) are removed from the local scope as soon
    # as control leaves this function — including on exception paths. PS strings are
    # GC-managed (immutable); we cannot zero memory but we do reduce lifetime to GC
    # discretion vs leaving the binding alive until parent-scope cleanup.
    try {
        # Credential POST. client_id is MANDATORY for web-client flows — omitting
        # triggers AADSTS900144.
        $credBody = @{
            login        = $upn
            passwd       = $password
            type         = 11
            ps           = 2
            client_id    = $ClientId
            flowToken    = Get-EntraField -Object $SessionInfo -Name 'sFT'
            ctx          = Get-EntraField -Object $SessionInfo -Name 'sCtx'
            canary       = Get-EntraField -Object $SessionInfo -Name 'canary'
            hpgrequestid = Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId
        }

        Write-Verbose "Complete-CredentialsFlow: POST credentials to $UrlPost"
        $credResponse = Invoke-WebRequest -Uri $UrlPost `
            -WebSession $Session -Method Post -Body $credBody `
            -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

        $authState = Get-EntraConfigBlob -Html $credResponse.Content
        if (-not $authState) {
            throw "Password POST returned no response `$Config. Tenant may use a federated IdP not supported by non-browser auth."
        }

        $errCode = Get-EntraField -Object $authState -Name 'sErrorCode'
        if ($errCode) {
            $errTxt = Get-EntraField -Object $authState -Name 'sErrTxt' -Default ''
            $msg = Get-EntraErrorMessage -Code $errCode -DefaultText $errTxt
            # iter-13.9 (C3): include UPN so operators can triage from
            # MDE_Heartbeat_CL.Notes alone without correlating App Insights.
            throw "Authentication failed for UPN='$upn' (AADSTS$errCode): $msg"
        }

        $pgid = Get-EntraField -Object $authState -Name 'pgid' -Default ''
        if ($pgid -eq 'ConvergedTFA') {
            $mfa = Complete-TotpMfa -Session $Session -AuthState $authState `
                -TotpBase32 $totpBase32 -CorrelationId $CorrelationId
            return $mfa
        }
        Write-Verbose "Complete-CredentialsFlow: no MFA (pgid=$pgid)"
        return @{ State = $authState; LastResponse = $credResponse }
    } finally {
        Remove-Variable -Name password -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name totpBase32 -Force -ErrorAction SilentlyContinue
        if (Get-Variable -Name credBody -Scope Local -ErrorAction SilentlyContinue) {
            Remove-Variable -Name credBody -Force -ErrorAction SilentlyContinue
        }
    }
}
