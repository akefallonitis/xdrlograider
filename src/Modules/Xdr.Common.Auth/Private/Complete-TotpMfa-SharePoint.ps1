function Complete-TotpMfa-SharePoint {
    <#
    .SYNOPSIS
        SharePoint variant of Complete-TotpMfa with MaximumRedirection=30 on ProcessAuth.
        SharePoint's MFA dance triggers additional redirects past the Entra-standard MaximumRedirection=0,
        so the SharePoint flow requires this override. The three Entra form_post sites
        (Credentials, Passkey, TOTP) correctly retain MaximumRedirection=0 (per Rule 7).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $AuthState,
        [Parameter(Mandatory)] [string] $TotpBase32,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    $proofs = @()
    if (Test-EntraField -Object $AuthState -Name 'arrUserProofs') { $proofs = @($AuthState.arrUserProofs) }
    $totpProof = $proofs | Where-Object { $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
    if (-not $totpProof) {
        $methods = ($proofs | ForEach-Object authMethodId) -join ', '
        throw "No PhoneAppOTP method. Available: $methods."
    }

    $beginBody = @{
        AuthMethodId = 'PhoneAppOTP'
        Method       = 'BeginAuth'
        ctx          = Get-EntraField -Object $AuthState -Name 'sCtx'
        flowToken    = Get-EntraField -Object $AuthState -Name 'sFT'
    } | ConvertTo-Json -Compress

    $beginAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/BeginAuth' `
        -WebSession $Session -Method Post -Body $beginBody -ContentType 'application/json'
    if (-not (Get-EntraField -Object $beginAuth -Name 'Success' -Default $false)) {
        throw "BeginAuth Success=false: $(Get-EntraField -Object $beginAuth -Name 'Message' -Default 'unknown')"
    }

    $endAuth = $null; $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        if ($attempt -gt 1) {
            $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $waitTo = [math]::Floor($now / 30) * 30 + 31
            $wait   = [math]::Max(1, $waitTo - $now)
            Start-Sleep -Seconds $wait
        }
        $code = Get-TotpCode -Base32Secret $TotpBase32
        $endBody = @{
            AuthMethodId       = 'PhoneAppOTP'; Method = 'EndAuth'
            SessionId          = Get-EntraField -Object $beginAuth -Name 'SessionId'
            FlowToken          = Get-EntraField -Object $beginAuth -Name 'FlowToken'
            Ctx                = Get-EntraField -Object $beginAuth -Name 'Ctx'
            AdditionalAuthData = $code; PollCount = $attempt
        } | ConvertTo-Json -Compress
        $endAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/EndAuth' `
            -WebSession $Session -Method Post -Body $endBody -ContentType 'application/json'
        if (Test-MfaEndAuthSuccess -EndAuth $endAuth) { break }
        $detail = (Get-EntraField -Object $endAuth -Name 'Message') ?? (Get-EntraField -Object $endAuth -Name 'ResultValue')
        if ($detail -match 'DuplicateCodeEntered' -and $attempt -lt 3) { continue }
        throw "TOTP rejected on attempt ${attempt}: $detail."
    }

    $processBody = @{
        type      = 22
        FlowToken = Get-EntraField -Object $endAuth -Name 'FlowToken'
        request   = Get-EntraField -Object $endAuth -Name 'Ctx'
        ctx       = Get-EntraField -Object $endAuth -Name 'Ctx'
    }
    $processResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
        -WebSession $Session -Method Post -Body $processBody `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -MaximumRedirection 30 -SkipHttpErrorCheck

    if ($processResp.StatusCode -ge 400) {
        $errBody = $processResp.Content
        if ($errBody -match 'AADSTS(\d+)[:\s]*([^"\\]+)') {
            throw "ProcessAuth failed: AADSTS$($Matches[1]) - $($Matches[2].Trim())"
        }
        throw "ProcessAuth failed HTTP $($processResp.StatusCode)."
    }

    $newState = Get-EntraConfigBlob -Html $processResp.Content
    if (-not $newState) { return @{ State = $AuthState; LastResponse = $processResp } }
    return @{ State = $newState; LastResponse = $processResp }
}
