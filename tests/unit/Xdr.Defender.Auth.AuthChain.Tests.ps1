#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 unit tests for Defender-portal-specific auth-chain helpers
    (iter-14.0 Phase 1).

.DESCRIPTION
    Migrated out of tests/unit/Xdr.Portal.Auth.AuthChain.Tests.ps1. Covers:
        - Update-XsrfToken (private; Defender-specific XSRF cookie reader)
        - Get-DefenderSccauth (public; verifies sccauth + XSRF + auto-resolves
          TenantId via /apiproxy/mtp/sccManagement/mgmt/TenantContext)
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
#  Update-XsrfToken (private)
# ============================================================================
Describe 'Update-XsrfToken (Xdr.Defender.Auth private)' {
    It 'throws when the portal cookie jar has no XSRF-TOKEN' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            { Update-XsrfToken -Session $session -PortalHost 'security.microsoft.com' } |
                Should -Throw -ExpectedMessage '*XSRF-TOKEN missing*'
        }
    }

    It 'URL-decodes the cookie value before returning (portal middleware rejects encoded form)' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $cookie = [System.Net.Cookie]::new('XSRF-TOKEN', 'abc%2Bdef%3D', '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $cookie)

            $decoded = Update-XsrfToken -Session $session -PortalHost 'security.microsoft.com'
            $decoded | Should -Be 'abc+def='
        }
    }

    It 'reads from the requested PortalHost when explicitly passed' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://intune.microsoft.com/')
            $cookie = [System.Net.Cookie]::new('XSRF-TOKEN', 'intune-xsrf', '/', 'intune.microsoft.com')
            $session.Cookies.Add($uri, $cookie)

            $val = Update-XsrfToken -Session $session -PortalHost 'intune.microsoft.com'
            $val | Should -Be 'intune-xsrf'
        }
    }
}

# ============================================================================
#  Get-DefenderSccauth (public)
# ============================================================================
Describe 'Get-DefenderSccauth (public)' {
    It 'throws when sccauth is not present on the session' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Get-DefenderSccauth -Session $session -PortalHost 'security.microsoft.com' } |
            Should -Throw "*sccauth not issued*"
    }

    It 'returns @{Sccauth, XsrfToken, TenantId, AcquiredUtc} when both cookies are present and TenantContext succeeds' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc  = [System.Net.Cookie]::new('sccauth',    'real-sccauth-fixture', '/', 'security.microsoft.com')
            $xs  = [System.Net.Cookie]::new('XSRF-TOKEN', 'real-xsrf-fixture',    '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $sc); $session.Cookies.Add($uri, $xs)

            Mock Invoke-RestMethod {
                [pscustomobject]@{
                    AuthInfo = [pscustomobject]@{ TenantId = 'tenant-fixture-aaaa-bbbb-cccc' }
                }
            }

            $r = Get-DefenderSccauth -Session $session -PortalHost 'security.microsoft.com'
            $r.Sccauth     | Should -Be 'real-sccauth-fixture'
            $r.XsrfToken   | Should -Be 'real-xsrf-fixture'
            $r.TenantId    | Should -Be 'tenant-fixture-aaaa-bbbb-cccc'
            $r.AcquiredUtc | Should -BeOfType [datetime]
        }
    }

    It 'honours an explicitly-supplied -TenantId without calling TenantContext' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc  = [System.Net.Cookie]::new('sccauth',    's', '/', 'security.microsoft.com')
            $xs  = [System.Net.Cookie]::new('XSRF-TOKEN', 'x', '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $sc); $session.Cookies.Add($uri, $xs)

            Mock Invoke-RestMethod { throw "TenantContext should NOT be called" }

            $r = Get-DefenderSccauth -Session $session -PortalHost 'security.microsoft.com' -TenantId 'preset-tenant-id'
            $r.TenantId | Should -Be 'preset-tenant-id'
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    It 'pings the portal root once when XSRF-TOKEN is missing on first probe (some tenants mint XSRF on first /apiproxy)' {
        InModuleScope Xdr.Defender.Auth {
            # Seed only sccauth — XSRF will be missing initially.
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc  = [System.Net.Cookie]::new('sccauth', 's', '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $sc)

            # When the function nudges the portal root, simulate the portal minting
            # XSRF-TOKEN on the same session.
            Mock Invoke-WebRequest {
                $u = [System.Uri]::new('https://security.microsoft.com/')
                $xs = [System.Net.Cookie]::new('XSRF-TOKEN', 'minted-after-ping', '/', 'security.microsoft.com')
                $session.Cookies.Add($u, $xs)
                return $null
            }
            Mock Invoke-RestMethod { return $null }

            $r = Get-DefenderSccauth -Session $session -PortalHost 'security.microsoft.com' -TenantId 'preset'
            $r.XsrfToken | Should -Be 'minted-after-ping'
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/'
            }
        }
    }

    It 'throws when XSRF-TOKEN is still missing after the portal-root ping' {
        InModuleScope Xdr.Defender.Auth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $uri = [System.Uri]::new('https://security.microsoft.com/')
            $sc  = [System.Net.Cookie]::new('sccauth', 's', '/', 'security.microsoft.com')
            $session.Cookies.Add($uri, $sc)

            # Ping does NOT mint XSRF — function should throw with clear message.
            Mock Invoke-WebRequest { return $null }

            { Get-DefenderSccauth -Session $session -PortalHost 'security.microsoft.com' -TenantId 'preset' } |
                Should -Throw "*XSRF-TOKEN not set*"
        }
    }
}
