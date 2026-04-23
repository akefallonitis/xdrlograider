#Requires -Modules Pester
<#
.SYNOPSIS
    Live auth chain tests against a real Entra / Defender XDR tenant.

.DESCRIPTION
    Gated by XDRLR_ONLINE=true. Reads test credentials from env vars
    (or tests/.env.local via Run-Tests.ps1). Exercises the full
    Xdr.Portal.Auth chain + one sample dispatcher call.

    Run locally:
      pwsh ./tests/Run-Tests.ps1 -Category local-online

    Required env vars (loaded by Run-Tests.ps1):
      XDRLR_TEST_UPN
      XDRLR_TEST_AUTH_METHOD       ('CredentialsTotp' | 'Passkey' | 'DirectCookies')

    For CredentialsTotp:  XDRLR_TEST_PASSWORD + XDRLR_TEST_TOTP_SECRET
    For Passkey:          XDRLR_TEST_PASSKEY_PATH
    For DirectCookies:    XDRLR_TEST_SCCAUTH + XDRLR_TEST_XSRF_TOKEN
#>

BeforeDiscovery {
    # Pester 5 evaluates `-Skip:(...)` at discovery time, so all gating flags
    # must be available BEFORE the run phase. Env vars are already loaded by
    # Run-Tests.ps1 from tests/.env.local.

    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN -and (
        ($script:AuthMethod -eq 'CredentialsTotp' -and $env:XDRLR_TEST_PASSWORD     -and $env:XDRLR_TEST_TOTP_SECRET) -or
        ($script:AuthMethod -eq 'Passkey'         -and $env:XDRLR_TEST_PASSKEY_PATH -and (Test-Path $env:XDRLR_TEST_PASSKEY_PATH)) -or
        ($script:AuthMethod -eq 'DirectCookies'   -and $env:XDRLR_TEST_SCCAUTH      -and $env:XDRLR_TEST_XSRF_TOKEN)
    )

    $script:SkipCacheTest = (-not $script:RunLive) -or ($script:AuthMethod -eq 'DirectCookies')
}

BeforeAll {
    # Modules needed for live auth + dispatcher calls
    $authPsd1   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth'     'Xdr.Portal.Auth.psd1'
    $ingestPsd1 = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'
    $clientPsd1 = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'XdrLogRaider.Client.psd1'

    Import-Module $authPsd1   -Force -ErrorAction Stop
    Import-Module $ingestPsd1 -Force -ErrorAction Stop
    Import-Module $clientPsd1 -Force -ErrorAction Stop

    # Mirror discovery-phase gating flag so it's valid during run too.
    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN
    if (-not $script:RunLive) {
        Write-Warning "Auth-Chain-Live tests require XDRLR_ONLINE=true + XDRLR_TEST_UPN. Skipping."
    }

    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

    $script:Credential = switch ($script:AuthMethod) {
        'CredentialsTotp' {
            @{
                upn        = $env:XDRLR_TEST_UPN
                password   = $env:XDRLR_TEST_PASSWORD
                totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
            }
        }
        'Passkey' {
            $passkey = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
            @{
                upn     = $env:XDRLR_TEST_UPN
                passkey = $passkey
            }
        }
        'DirectCookies' {
            @{
                upn       = $env:XDRLR_TEST_UPN
                sccauth   = $env:XDRLR_TEST_SCCAUTH
                xsrfToken = $env:XDRLR_TEST_XSRF_TOKEN
            }
        }
        default {
            throw "Invalid XDRLR_TEST_AUTH_METHOD: $script:AuthMethod (expected CredentialsTotp | Passkey | DirectCookies)"
        }
    }

    $script:PortalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }

    # Helper — defined in BeforeAll so it's visible inside It blocks (Pester 5
    # doesn't propagate top-level file functions into the run scope).
    function script:New-LiveSession {
        param($AuthMethod, $Credential, $PortalHost, [switch]$Force)
        if ($AuthMethod -eq 'DirectCookies') {
            return Connect-MDEPortalWithCookies `
                -Sccauth   $Credential.sccauth `
                -XsrfToken $Credential.xsrfToken `
                -Upn       $Credential.upn `
                -PortalHost $PortalHost
        }
        return Connect-MDEPortal -Method $AuthMethod -Credential $Credential -PortalHost $PortalHost -Force:$Force.IsPresent
    }
}

AfterAll {
    Remove-Module XdrLogRaider.Client -Force -ErrorAction SilentlyContinue
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Portal.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Live auth chain against real tenant' -Tag 'online', 'live' {

    It 'Session has non-empty sccauth cookie' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session             | Should -Not -BeNullOrEmpty
        $session.Session     | Should -Not -BeNullOrEmpty
        $session.AcquiredUtc | Should -BeOfType [datetime]

        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $sccauth = $cookies | Where-Object Name -eq 'sccauth' | Select-Object -First 1
        $sccauth        | Should -Not -BeNullOrEmpty
        $sccauth.Value  | Should -Not -BeNullOrEmpty
    }

    It 'XSRF-TOKEN present in session' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $xsrf = $cookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
        $xsrf       | Should -Not -BeNullOrEmpty
        $xsrf.Value | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-MDEPortalRequest returns advanced-features config' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $config  = Invoke-MDEPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting' -Method GET
        $config | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-MDEEndpoint -Stream MDE_AdvancedFeatures_CL returns non-empty rows' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $rows = Invoke-MDEEndpoint -Session $session -Stream 'MDE_AdvancedFeatures_CL'
        ($rows | Measure-Object).Count | Should -BeGreaterThan 0
        $rows[0].SourceStream   | Should -Be 'MDE_AdvancedFeatures_CL'
        $rows[0].TimeGenerated  | Should -Not -BeNullOrEmpty
        $rows[0].RawJson        | Should -Not -BeNullOrEmpty
    }

    It 'Session cache: second Connect call returns same AcquiredUtc (50-min cache)' -Skip:$script:SkipCacheTest {
        $session1 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session2 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $session2.AcquiredUtc | Should -Be $session1.AcquiredUtc
    }
}
