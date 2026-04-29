#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 unit tests for the L2 Defender-portal-specific module
    Xdr.Defender.Auth (iter-14.0 Phase 1).

.DESCRIPTION
    Migrated out of tests/unit/Xdr.Portal.Auth.Tests.ps1 when the monolithic
    Xdr.Portal.Auth was split. Covers Connect-DefenderPortal,
    Connect-DefenderPortalWithCookies, Test-DefenderPortalAuth,
    Invoke-DefenderPortalRequest 401 auto-refresh, and the rate-counter helpers.

    Test-DefenderPortalAuth tests now mock Connect-DefenderPortal (the new
    authoritative path) since Get-EstsCookie no longer exists.
#>

BeforeAll {
    $script:CommonPath   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Common.Auth'   'Xdr.Common.Auth.psd1'
    $script:DefenderPath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
    Import-Module $script:CommonPath   -Force -ErrorAction Stop
    Import-Module $script:DefenderPath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Auth -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth   -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Module surface
# ============================================================================
Describe 'Xdr.Defender.Auth module surface' {
    It 'exports Connect-DefenderPortal, Invoke-DefenderPortalRequest, Test-DefenderPortalAuth' {
        $exported = (Get-Module Xdr.Defender.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Connect-DefenderPortal'
        $exported | Should -Contain 'Invoke-DefenderPortalRequest'
        $exported | Should -Contain 'Test-DefenderPortalAuth'
        $exported | Should -Contain 'Connect-DefenderPortalWithCookies'
        $exported | Should -Contain 'Get-DefenderSccauth'
        $exported | Should -Contain 'Get-XdrPortalRate429Count'
        $exported | Should -Contain 'Reset-XdrPortalRate429Count'
    }

    It 'does not leak the L1 Entra primitives (Get-EntraEstsAuth lives in Xdr.Common.Auth)' {
        $exported = (Get-Module Xdr.Defender.Auth).ExportedFunctions.Keys
        $exported | Should -Not -Contain 'Get-EntraEstsAuth'
        $exported | Should -Not -Contain 'Get-XdrAuthFromKeyVault'
        $exported | Should -Not -Contain 'Resolve-EntraInterruptPage'
    }

    It 'has PowerShell 7.4+ requirement' {
        $manifest = Import-PowerShellDataFile -Path $script:DefenderPath
        $manifest.PowerShellVersion | Should -Be '7.4'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }
}

# ============================================================================
#  Connect-DefenderPortal parameter validation
# ============================================================================
Describe 'Connect-DefenderPortal parameter validation' {
    It 'rejects invalid Method parameter' {
        { Connect-DefenderPortal -Method 'InvalidMethod' -Credential @{ upn = 'x@y.com' } } |
            Should -Throw "*Cannot validate argument*"
    }

    It 'requires upn in Credential hashtable' {
        { Connect-DefenderPortal -Method CredentialsTotp -Credential @{ password = 'x' } } |
            Should -Throw "*upn*"
    }
}

# ============================================================================
#  Connect-DefenderPortalWithCookies
# ============================================================================
Describe 'Connect-DefenderPortalWithCookies' {
    It 'builds a session with injected cookies' {
        $result = Connect-DefenderPortalWithCookies `
            -Sccauth 'fake-sccauth-value-very-long-base64url-tokenish-string-12345' `
            -XsrfToken 'fake-xsrf-token-value-16chars+' `
            -Upn 'svc@test.com'

        $result.Session | Should -Not -BeNullOrEmpty
        $result.Upn | Should -Be 'svc@test.com'
        $result.PortalHost | Should -Be 'security.microsoft.com'
        $result.AcquiredUtc | Should -BeOfType [datetime]

        $cookies = $result.Session.Cookies.GetCookies('https://security.microsoft.com')
        ($cookies | Where-Object Name -eq 'sccauth').Value | Should -Be 'fake-sccauth-value-very-long-base64url-tokenish-string-12345'
        ($cookies | Where-Object Name -eq 'XSRF-TOKEN').Value | Should -Be 'fake-xsrf-token-value-16chars+'
    }

    It 'accepts custom PortalHost' {
        $result = Connect-DefenderPortalWithCookies `
            -Sccauth 'x' `
            -XsrfToken 'y' `
            -PortalHost 'intune.microsoft.com'

        $result.PortalHost | Should -Be 'intune.microsoft.com'
    }

    It 'caches the session in the module cache' {
        InModuleScope Xdr.Defender.Auth {
            $script:SessionCache.Clear()
            Connect-DefenderPortalWithCookies -Sccauth 'abc' -XsrfToken 'def' -Upn 'svc@test.com' | Out-Null
            $script:SessionCache.ContainsKey('svc@test.com::security.microsoft.com') | Should -BeTrue
        }
    }
}

# ============================================================================
#  Invoke-DefenderPortalRequest 401 auto-refresh
# ============================================================================
Describe 'Invoke-DefenderPortalRequest 401 auto-refresh' {
    It 'attempts Connect-DefenderPortal -Force on 401 and retries' {
        InModuleScope Xdr.Defender.Auth {
            $fakeSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $fakeSessionObj = [pscustomobject]@{
                Session     = $fakeSession
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
            }
            $script:SessionCache['svc@test.com::security.microsoft.com'] = @{
                Session     = $fakeSession
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
                _Method     = 'CredentialsTotp'
                _Credential = @{ upn = 'svc@test.com'; password = 'x'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            }

            Mock Update-XsrfToken { return 'test-xsrf' }

            $script:callCount = 0
            Mock Invoke-WebRequest {
                $script:callCount++
                if ($script:callCount -eq 1) {
                    $err = [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                        'Unauthorized',
                        [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
                    )
                    throw $err
                }
                return @{ StatusCode = 200; Content = '{"ok":true}' }
            }

            Mock Connect-DefenderPortal {
                $newSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                return [pscustomobject]@{
                    Session     = $newSession
                    Upn         = 'svc@test.com'
                    PortalHost  = 'security.microsoft.com'
                    AcquiredUtc = [datetime]::UtcNow
                    _Method     = 'CredentialsTotp'
                    _Credential = @{ upn = 'svc@test.com' }
                }
            }

            try {
                $result = Invoke-DefenderPortalRequest -Session $fakeSessionObj -Path '/api/test' -Method GET
                $result.ok | Should -BeTrue
                Should -Invoke Invoke-WebRequest -Times 2 -Exactly
                Should -Invoke Connect-DefenderPortal -Times 1 -Exactly
            } catch {
                Should -Invoke Connect-DefenderPortal -AtLeast 1
            }
        }
    }
}

# ============================================================================
#  Test-DefenderPortalAuth — offline mock (uses Connect-DefenderPortal mock)
# ============================================================================
Describe 'Test-DefenderPortalAuth — offline mock' {
    It 'returns Success=false and populates FailureReason when auth-chain fails' {
        InModuleScope Xdr.Defender.Auth {
            Mock Connect-DefenderPortal { throw "Auth-chain failure injected" }
            $result = Test-DefenderPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $result.Success | Should -BeFalse
            $result.Stage   | Should -Be 'auth-chain'
            $result.FailureReason | Should -Match 'Auth-chain failure injected'
        }
    }

    It 'records auth-chain stage failure when Connect-DefenderPortal throws "sccauth not issued"' {
        # After the v1.0 auth-chain rewrite, the L2 Get-DefenderSccauth verifies
        # sccauth presence and throws "Auth flow completed but sccauth not issued"
        # if the cookie didn't drop. Test-DefenderPortalAuth wraps this in the
        # auth-chain stage (since Connect-DefenderPortal is what actually fails).
        InModuleScope Xdr.Defender.Auth {
            Mock Connect-DefenderPortal { throw "Auth flow completed but sccauth not issued. Portal cookies: OpenIdConnect.nonce..." }

            $result = Test-DefenderPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $result.Success | Should -BeFalse
            $result.Stage   | Should -Be 'auth-chain'
            $result.FailureReason | Should -Match 'sccauth not issued'
        }
    }

    It 'reports Success=true + TenantId when every step green' {
        InModuleScope Xdr.Defender.Auth {
            $s = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc = [System.Net.Cookie]::new('sccauth', 'real-sccauth-value', '/', 'security.microsoft.com')
            $xs = [System.Net.Cookie]::new('XSRF-TOKEN', 'real-xsrf', '/', 'security.microsoft.com')
            $s.Cookies.Add($uri, $sc); $s.Cookies.Add($uri, $xs)

            Mock Connect-DefenderPortal {
                [pscustomobject]@{
                    Session     = $s
                    Upn         = 'x@y.com'
                    PortalHost  = 'security.microsoft.com'
                    TenantId    = '45f52f35-73d5-4066-8378-fe506ee90fb1'
                    AcquiredUtc = [datetime]::UtcNow
                }
            }
            Mock Invoke-DefenderPortalRequest {
                [pscustomobject]@{ AuthInfo = [pscustomobject]@{ TenantId = '45f52f35-73d5-4066-8378-fe506ee90fb1' } }
            }

            $r = Test-DefenderPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $r.Success            | Should -BeTrue
            $r.Stage              | Should -Be 'complete'
            $r.TenantId           | Should -Be '45f52f35-73d5-4066-8378-fe506ee90fb1'
            $r.SampleCallHttpCode | Should -Be 200
        }
    }
}

# ============================================================================
#  429 Retry-After handling (v0.1.0-beta carry-forward)
# ============================================================================
Describe 'Xdr.Defender.Auth — 429 Retry-After handling' {
    It 'exposes Get/Reset-XdrPortalRate429Count accessors for heartbeat integration' {
        $exported = (Get-Module Xdr.Defender.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-XdrPortalRate429Count'
        $exported | Should -Contain 'Reset-XdrPortalRate429Count'
    }

    It 'Reset clears cumulative 429 counter back to 0' {
        Reset-XdrPortalRate429Count
        Get-XdrPortalRate429Count | Should -Be 0
    }

    It 'Invoke-DefenderPortalRequest source contains 429 branch with Retry-After parse (seconds + HTTP-date)' {
        $script:AuthRoot = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Auth' 'Public'
        $source = Get-Content (Join-Path $script:AuthRoot 'Invoke-DefenderPortalRequest.ps1') -Raw
        $source | Should -Match '\$statusInt -eq 429' -Because '429 branch must exist'
        $source | Should -Match 'Retry-After' -Because 'Retry-After header must be parsed'
        $source | Should -Match 'MDERateLimited' -Because 'exhausted 429 must throw the MDERateLimited message'
        $source | Should -Match 'Rate429Count\+\+' -Because 'counter must increment on every 429 observed'
    }

    It 'Invoke-DefenderPortalRequest source enforces session TTL proactive refresh (3h30m)' {
        $source = Get-Content (Join-Path $script:AuthRoot 'Invoke-DefenderPortalRequest.ps1') -Raw
        $source | Should -Match 'SessionMaxAgeMinutes' -Because 'proactive 3h30m TTL cap reference'
        $source | Should -Match 'sessionAge' -Because 'TTL comparison logic present'
        $source | Should -Match 'Connect-DefenderPortal.*-Force' -Because 'force-refresh on TTL expiry'
    }
}
