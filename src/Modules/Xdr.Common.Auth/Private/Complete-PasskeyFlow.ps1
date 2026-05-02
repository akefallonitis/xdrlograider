function Complete-PasskeyFlow {
    <#
    .SYNOPSIS
        L1 portal-generic passkey flow: FIDO pre-verify at /common/fido/get → assertion
        POST at /common/login → SSO reload → interrupt-loop. No browser.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $SessionInfo,
        [Parameter(Mandatory)] [hashtable] $Credential,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    $passkey = $Credential.passkey
    if (-not $passkey) { throw "Passkey method requires 'passkey' JSON object" }

    # Extract FIDO challenge from initial $Config. Modern authorize with sso_reload=true
    # pre-populates oGetCredTypeResult.Credentials.FidoParams.Challenge.
    $challenge = $null
    $hasFido   = $false
    $allowList = $null

    $cred = Get-EntraField -Object (Get-EntraField -Object $SessionInfo -Name 'oGetCredTypeResult') -Name 'Credentials'
    if ($cred) {
        $hasFido = [bool](Get-EntraField -Object $cred -Name 'HasFido' -Default $false)
        $fidoParams = Get-EntraField -Object $cred -Name 'FidoParams'
        if ($fidoParams) {
            $challenge = Get-EntraField -Object $fidoParams -Name 'Challenge'
            $allowList = Get-EntraField -Object $fidoParams -Name 'AllowList'
        }
    }
    if (-not $challenge) {
        $challenge = Get-EntraField -Object $SessionInfo -Name 'sFidoChallenge'
        if ($challenge) { $hasFido = $true }
    }
    if (-not $hasFido -or -not $challenge) {
        throw "Passkey not available. HasFido=$hasFido ChallengePresent=$([bool]$challenge). Account likely has no passkey registered."
    }

    $origin    = 'https://login.microsoft.com'
    $assertion = Invoke-PasskeyChallenge -PasskeyJson $passkey -Challenge $challenge -Origin $origin

    # XDRInternals pattern: pre-verify at /common/fido/get?uiflavor=Web
    $credentialsJson = if ($allowList) { ($allowList -join ',') } else { '' }
    $verifyBody = @{
        allowedIdentities = 2
        canary            = Get-EntraField -Object $SessionInfo -Name 'sFT'
        ServerChallenge   = Get-EntraField -Object $SessionInfo -Name 'sFT'
        postBackUrl       = Get-EntraField -Object $SessionInfo -Name 'urlPost'
        postBackUrlAad    = Get-EntraField -Object $SessionInfo -Name 'urlPostAad'
        postBackUrlMsa    = Get-EntraField -Object $SessionInfo -Name 'urlPostMsa'
        cancelUrl         = Get-EntraField -Object $SessionInfo -Name 'urlRefresh'
        resumeUrl         = Get-EntraField -Object $SessionInfo -Name 'urlResume'
        correlationId     = Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId
        credentialsJson   = $credentialsJson
        ctx               = Get-EntraField -Object $SessionInfo -Name 'sCtx'
        username          = $Credential.upn
        loginCanary       = Get-EntraField -Object $SessionInfo -Name 'canary'
    }
    Write-Verbose "Complete-PasskeyFlow: pre-verify at /common/fido/get"
    $verifyResp = Invoke-WebRequest -Uri 'https://login.microsoft.com/common/fido/get?uiflavor=Web' `
        -WebSession $Session -Method Post -Body $verifyBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    $responseInfo = Get-EntraConfigBlob -Html $verifyResp.Content
    if (-not $responseInfo) {
        throw "Passkey pre-verify returned no parseable `$Config at /common/fido/get. HTTP $($verifyResp.StatusCode)."
    }

    # Submit signed assertion to /common/login
    $fidoPayload = [ordered]@{
        id                = $passkey.credentialId
        clientDataJSON    = $assertion.clientDataJSON
        authenticatorData = $assertion.authenticatorData
        signature         = $assertion.signature
        userHandle        = Get-EntraField -Object $passkey -Name 'userHandle' -Default ''
    }
    $loginBody = @{
        type         = 23
        ps           = 23
        assertion    = ($fidoPayload | ConvertTo-Json -Compress -Depth 10)
        lmcCanary    = Get-EntraField -Object $responseInfo -Name 'sCrossDomainCanary'
        hpgrequestid = Get-EntraField -Object $responseInfo -Name 'sessionId' -Default $CorrelationId
        ctx          = Get-EntraField -Object $responseInfo -Name 'sCtx'
        canary       = Get-EntraField -Object $responseInfo -Name 'canary'
        flowToken    = Get-EntraField -Object $responseInfo -Name 'sFT'
    }
    Write-Verbose "Complete-PasskeyFlow: POST assertion to /common/login"
    $loginResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login' `
        -WebSession $Session -Method Post -Body $loginBody `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    # SSO reload — re-POST with the flowToken from oGetCredTypeResult.FlowToken
    $reloadFlowToken = Get-EntraField -Object (Get-EntraField -Object $SessionInfo -Name 'oGetCredTypeResult') -Name 'FlowToken'
    if ($reloadFlowToken) {
        $loginBody.flowToken = $reloadFlowToken
        Write-Verbose "Complete-PasskeyFlow: SSO reload POST"
        $reloadResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/login?sso_reload=true' `
            -WebSession $Session -Method Post -Body $loginBody `
            -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

        $newState = Get-EntraConfigBlob -Html $reloadResp.Content
        if ($newState) { return @{ State = $newState; LastResponse = $reloadResp } }
        return @{ State = $null; LastResponse = $reloadResp }
    }

    $fallback = [pscustomobject]@{
        pgid          = ''
        sCtx          = (Get-EntraField -Object $SessionInfo -Name 'sCtx')
        sFT           = (Get-EntraField -Object $SessionInfo -Name 'sFT')
        canary        = (Get-EntraField -Object $SessionInfo -Name 'canary')
        correlationId = (Get-EntraField -Object $SessionInfo -Name 'correlationId' -Default $CorrelationId)
    }
    return @{ State = $fallback; LastResponse = $loginResp }
}
