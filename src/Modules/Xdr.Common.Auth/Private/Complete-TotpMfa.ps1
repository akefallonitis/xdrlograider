function Complete-TotpMfa {
    <#
    .SYNOPSIS
        L1 portal-generic TOTP MFA: BeginAuth → EndAuth(TOTP, retry on dup) → ProcessAuth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.PowerShell.Commands.WebRequestSession] $Session,
        [Parameter(Mandatory)] [pscustomobject] $AuthState,
        [Parameter(Mandatory)] [string] $TotpBase32,
        [Parameter(Mandatory)] [guid] $CorrelationId
    )

    Write-Verbose "Complete-TotpMfa: MFA challenge detected"

    $proofs = @()
    if (Test-EntraField -Object $AuthState -Name 'arrUserProofs') {
        $proofs = @($AuthState.arrUserProofs)
    }
    $totpProof = $proofs | Where-Object { $_.authMethodId -eq 'PhoneAppOTP' } | Select-Object -First 1
    if (-not $totpProof) {
        $methods = ($proofs | ForEach-Object authMethodId) -join ', '
        throw "No PhoneAppOTP method. Available: $methods. Enrol TOTP via mysignins.microsoft.com."
    }

    # BeginAuth
    $beginBody = @{
        AuthMethodId = 'PhoneAppOTP'
        Method       = 'BeginAuth'
        ctx          = Get-EntraField -Object $AuthState -Name 'sCtx'
        flowToken    = Get-EntraField -Object $AuthState -Name 'sFT'
    } | ConvertTo-Json -Compress

    $beginAuth = $null
    try {
        $beginAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/BeginAuth' `
            -WebSession $Session -Method Post -Body $beginBody -ContentType 'application/json' -ErrorAction Stop
    } catch { throw "SAS/BeginAuth failed: $($_.Exception.Message)" }

    if (-not (Get-EntraField -Object $beginAuth -Name 'Success' -Default $false)) {
        throw "BeginAuth Success=false: $(Get-EntraField -Object $beginAuth -Name 'Message' -Default 'unknown')"
    }
    Write-Verbose "Complete-TotpMfa: BeginAuth OK (SessionId=$(Get-EntraField -Object $beginAuth -Name 'SessionId'))"

    # EndAuth with retry on duplicate-code
    $endAuth = $null
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        if ($attempt -gt 1) {
            $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $waitTo = [math]::Floor($now / 30) * 30 + 31
            $wait   = [math]::Max(1, $waitTo - $now)
            Write-Verbose "Complete-TotpMfa: waiting ${wait}s for next TOTP window"
            Start-Sleep -Seconds $wait
        }

        $code = Get-TotpCode -Base32Secret $TotpBase32

        $endBody = @{
            AuthMethodId       = 'PhoneAppOTP'
            Method             = 'EndAuth'
            SessionId          = Get-EntraField -Object $beginAuth -Name 'SessionId'
            FlowToken          = Get-EntraField -Object $beginAuth -Name 'FlowToken'
            Ctx                = Get-EntraField -Object $beginAuth -Name 'Ctx'
            AdditionalAuthData = $code
            PollCount          = $attempt
        } | ConvertTo-Json -Compress

        try {
            $endAuth = Invoke-RestMethod -Uri 'https://login.microsoftonline.com/common/SAS/EndAuth' `
                -WebSession $Session -Method Post -Body $endBody -ContentType 'application/json' -ErrorAction Stop
        } catch { throw "SAS/EndAuth failed: $($_.Exception.Message)" }

        if (Test-MfaEndAuthSuccess -EndAuth $endAuth) {
            Write-Verbose "Complete-TotpMfa: EndAuth OK (attempt $attempt)"
            break
        }

        $detail = (Get-EntraField -Object $endAuth -Name 'Message') ?? (Get-EntraField -Object $endAuth -Name 'ResultValue')
        if ($detail -match 'DuplicateCodeEntered' -and $attempt -lt 3) {
            Write-Verbose "Complete-TotpMfa: attempt $attempt got '$detail' — retry in next window"
            continue
        }
        throw "TOTP rejected on attempt ${attempt}: $detail. Check TOTP seed + system clock."
    }

    # ProcessAuth — form-urlencoded. If ContentType isn't explicitly set the
    # endpoint returns AADSTS9000410 "Malformed JSON".
    $processBody = @{
        type      = 22
        FlowToken = Get-EntraField -Object $endAuth -Name 'FlowToken'
        request   = Get-EntraField -Object $endAuth -Name 'Ctx'
        ctx       = Get-EntraField -Object $endAuth -Name 'Ctx'
    }
    $processResp = Invoke-WebRequest -Uri 'https://login.microsoftonline.com/common/SAS/ProcessAuth' `
        -WebSession $Session -Method Post -Body $processBody `
        -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -MaximumRedirection 0 -SkipHttpErrorCheck

    if ($processResp.StatusCode -ge 400) {
        $errBody = $processResp.Content
        if ($errBody -match 'AADSTS(\d+)[:\s]*([^"\\]+)') {
            $code = $Matches[1]; $msg = $Matches[2].Trim()
            throw "ProcessAuth failed: AADSTS$code - $msg"
        }
        throw "ProcessAuth failed with HTTP $($processResp.StatusCode). Body: $($errBody.Substring(0, [math]::Min(200, $errBody.Length)))"
    }

    $newState = Get-EntraConfigBlob -Html $processResp.Content
    if (-not $newState) {
        Write-Verbose "Complete-TotpMfa: ProcessAuth returned no parseable state — treating response as final redirect"
        return @{ State = $AuthState; LastResponse = $processResp }
    }
    $newPgid = Get-EntraField -Object $newState -Name 'pgid' -Default '<none>'
    Write-Verbose "Complete-TotpMfa: ProcessAuth OK (pgid=$newPgid)"
    return @{ State = $newState; LastResponse = $processResp }
}
