#Requires -Modules Pester
<#
.SYNOPSIS
    Live auth chain tests against a real Entra/Defender XDR tenant.

.DESCRIPTION
    Gated by XDRLR_ONLINE=true. Reads test credentials from env vars
    (or tests/.env.local). Exercises the full Xdr.Portal.Auth chain:
      - TOTP / passkey assertion
      - login.microsoftonline.com ESTSAUTH cookie acquisition
      - security.microsoft.com sccauth + XSRF exchange
      - Sample /apiproxy API call

    Run locally:
      pwsh ./tests/Run-Tests.ps1 -Category local-online

    Required env vars (loaded from tests/.env.local if present):
      XDRLR_TEST_UPN
      XDRLR_TEST_AUTH_METHOD       ('CredentialsTotp' or 'Passkey')

    For CredentialsTotp:
      XDRLR_TEST_PASSWORD
      XDRLR_TEST_TOTP_SECRET

    For Passkey:
      XDRLR_TEST_PASSKEY_PATH      (path to passkey JSON)

    Never commit creds. tests/.env.local is gitignored.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Gate on online flag
    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN
    if (-not $script:RunLive) {
        Write-Warning "Auth-Chain-Live tests require XDRLR_ONLINE=true + XDRLR_TEST_UPN. Skipping."
    }

    # Build credential hashtable from env
    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) {
        $env:XDRLR_TEST_AUTH_METHOD
    } else {
        'CredentialsTotp'
    }

    $script:Credential = switch ($script:AuthMethod) {
        'CredentialsTotp' {
            if (-not $env:XDRLR_TEST_PASSWORD -or -not $env:XDRLR_TEST_TOTP_SECRET) {
                Write-Warning "CredentialsTotp method requires XDRLR_TEST_PASSWORD + XDRLR_TEST_TOTP_SECRET"
                $script:RunLive = $false
                return
            }
            @{
                upn        = $env:XDRLR_TEST_UPN
                password   = $env:XDRLR_TEST_PASSWORD
                totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
            }
        }
        'Passkey' {
            if (-not $env:XDRLR_TEST_PASSKEY_PATH -or -not (Test-Path $env:XDRLR_TEST_PASSKEY_PATH)) {
                Write-Warning "Passkey method requires XDRLR_TEST_PASSKEY_PATH pointing at a valid file"
                $script:RunLive = $false
                return
            }
            $passkey = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
            @{
                upn     = $env:XDRLR_TEST_UPN
                passkey = $passkey
            }
        }
        'DirectCookies' {
            if (-not $env:XDRLR_TEST_SCCAUTH -or -not $env:XDRLR_TEST_XSRF_TOKEN) {
                Write-Warning "DirectCookies method requires XDRLR_TEST_SCCAUTH + XDRLR_TEST_XSRF_TOKEN"
                $script:RunLive = $false
                return
            }
            @{
                upn       = $env:XDRLR_TEST_UPN
                sccauth   = $env:XDRLR_TEST_SCCAUTH
                xsrfToken = $env:XDRLR_TEST_XSRF_TOKEN
            }
        }
        default {
            throw "Invalid XDRLR_TEST_AUTH_METHOD: $script:AuthMethod (expected CredentialsTotp, Passkey, or DirectCookies)"
        }
    }

    $script:PortalHost = if ($env:XDRLR_TEST_PORTAL_HOST) {
        $env:XDRLR_TEST_PORTAL_HOST
    } else {
        'security.microsoft.com'
    }
}

AfterAll {
    Remove-Module Xdr.Portal.Auth -Force -ErrorAction SilentlyContinue
}

function New-LiveSession {
    param($AuthMethod, $Credential, $PortalHost, [switch]$Force)
    if ($AuthMethod -eq 'DirectCookies') {
        return Connect-MDEPortalWithCookies `
            -Sccauth $Credential.sccauth `
            -XsrfToken $Credential.xsrfToken `
            -Upn $Credential.upn `
            -PortalHost $PortalHost
    }
    return Connect-MDEPortal -Method $AuthMethod -Credential $Credential -PortalHost $PortalHost -Force:$Force.IsPresent
}

Describe 'Live auth chain against real tenant' -Tag 'online', 'live' {
    It 'Session has non-empty sccauth cookie' -Skip:(-not $script:RunLive) {
        $session = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session.Session | Should -Not -BeNullOrEmpty
        $session.AcquiredUtc | Should -BeOfType [datetime]
        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $sccauth = $cookies | Where-Object Name -eq 'sccauth' | Select-Object -First 1
        $sccauth.Value | Should -Not -BeNullOrEmpty
    }

    It 'XSRF-TOKEN present in session' -Skip:(-not $script:RunLive) {
        $session = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $xsrf = $cookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
        $xsrf.Value | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-MDEPortalRequest returns advanced features config' -Skip:(-not $script:RunLive) {
        $session = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $config = Invoke-MDEPortalRequest -Session $session -Path '/api/settings/GetAdvancedFeaturesSetting' -Method GET
        $config | Should -Not -BeNullOrEmpty
    }

    It 'Get-MDE_AdvancedFeatures returns non-empty rows' -Skip:(-not $script:RunLive) {
        $authModule   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
        $clientModule = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Client' 'XdrLogRaider.Client.psd1'
        Import-Module $authModule -Force
        Import-Module $clientModule -Force

        $session = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $rows = Get-MDE_AdvancedFeatures -Session $session
        ($rows | Measure-Object).Count | Should -BeGreaterThan 0
        $rows[0].SourceStream | Should -Be 'MDE_AdvancedFeatures_CL'
        $rows[0].TimeGenerated | Should -Not -BeNullOrEmpty
        $rows[0].RawJson | Should -Not -BeNullOrEmpty
    }

    It 'Caches the session: second Connect call returns same AcquiredUtc' -Skip:(-not $script:RunLive -or $script:AuthMethod -eq 'DirectCookies') {
        # Cache semantics only meaningful for CredentialsTotp/Passkey — DirectCookies creates fresh session each call
        $session1 = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session2 = New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $session2.AcquiredUtc | Should -Be $session1.AcquiredUtc
    }
}
