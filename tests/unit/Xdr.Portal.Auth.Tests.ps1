#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 unit tests for the backward-compat shim Xdr.Portal.Auth (iter-14.0).

.DESCRIPTION
    iter-14.0 Phase 1 split the monolithic Xdr.Portal.Auth into:
        - Xdr.Common.Auth   (L1 Entra layer)
        - Xdr.Defender.Auth (L2 Defender-specific cookie exchange)

    Xdr.Portal.Auth is now a SHIM that imports both new modules and re-exports
    the legacy MDE-prefixed function names (Connect-MDEPortal,
    Invoke-MDEPortalRequest, Test-MDEPortalAuth, Get-MDEAuthFromKeyVault,
    Connect-MDEPortalWithCookies, Get-XdrPortalRate429Count,
    Reset-XdrPortalRate429Count) as wrappers around the new names.

    Tests for crypto primitives + the L1 Entra chain moved to:
        tests/unit/Xdr.Common.Auth.Tests.ps1
        tests/unit/Xdr.Common.Auth.AuthChain.Tests.ps1
    Tests for L2 Defender-specific behavior moved to:
        tests/unit/Xdr.Defender.Auth.Tests.ps1
        tests/unit/Xdr.Defender.Auth.AuthChain.Tests.ps1

    What stays here:
        - Surface-export assertions (the shim must export exactly the legacy names).
        - Smoke-tests proving the shim wrappers delegate to the new functions.
        - Connect-MDEPortalWithCookies wrapper still works (no Entra round-trip needed).
        - Rate-counter accessors still work via the shim.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Portal.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth   -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Module surface — KEEP (still valid for the shim)
# ============================================================================
Describe 'Xdr.Portal.Auth shim module surface' {
    It 'exports Connect-MDEPortal, Invoke-MDEPortalRequest, Test-MDEPortalAuth' {
        $exported = (Get-Module Xdr.Portal.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Connect-MDEPortal'
        $exported | Should -Contain 'Invoke-MDEPortalRequest'
        $exported | Should -Contain 'Test-MDEPortalAuth'
    }

    It 'does not leak L1 private helpers (Get-TotpCode, Invoke-PasskeyChallenge, Get-EstsCookie)' {
        $exported = (Get-Module Xdr.Portal.Auth).ExportedFunctions.Keys
        $exported | Should -Not -Contain 'Get-TotpCode'
        $exported | Should -Not -Contain 'Invoke-PasskeyChallenge'
        $exported | Should -Not -Contain 'Get-EstsCookie'
    }

    It 'has PowerShell 7.4+ requirement' {
        $manifest = Import-PowerShellDataFile -Path $script:ModulePath
        $manifest.PowerShellVersion | Should -Be '7.4'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }
}

# ============================================================================
#  Connect-MDEPortal parameter validation (KEEP — still hits the shim wrapper)
# ============================================================================
Describe 'Connect-MDEPortal (shim) parameter validation' {
    It 'rejects invalid Method parameter' {
        { Connect-MDEPortal -Method 'InvalidMethod' -Credential @{ upn = 'x@y.com' } } |
            Should -Throw "*Cannot validate argument*"
    }

    It 'requires upn in Credential hashtable' {
        { Connect-MDEPortal -Method CredentialsTotp -Credential @{ password = 'x' } } |
            Should -Throw "*upn*"
    }
}

# ============================================================================
#  Connect-MDEPortalWithCookies (KEEP — pure-PS wrapper, no network)
# ============================================================================
Describe 'Connect-MDEPortalWithCookies (shim wrapper)' {
    It 'builds a session with injected cookies (delegates to Connect-DefenderPortalWithCookies)' {
        $result = Connect-MDEPortalWithCookies `
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
        $result = Connect-MDEPortalWithCookies `
            -Sccauth 'x' -XsrfToken 'y' -PortalHost 'intune.microsoft.com'
        $result.PortalHost | Should -Be 'intune.microsoft.com'
    }
}

# ============================================================================
#  Shim delegation sanity — proves the MDE-prefixed wrapper functions actually
#  call into the new Defender / Common module functions.
#  Note: Pester 5 InModuleScope-defined mocks expire when the InModuleScope
#  block exits. To install a mock that persists for an entire 'It' block (so
#  the shim wrapper sees it), we use Mock -ModuleName from the test scope.
# ============================================================================
Describe 'Xdr.Portal.Auth shim delegation' {
    It 'Connect-MDEPortal wrapper delegates to Connect-DefenderPortal' {
        # The shim's wrapper invokes Connect-DefenderPortal from inside the
        # Xdr.Portal.Auth module scope. Mocking against the shim's scope is
        # what intercepts the call in Pester 5.
        Mock -ModuleName 'Xdr.Portal.Auth' Connect-DefenderPortal {
            return [pscustomobject]@{
                Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Upn         = $Credential.upn
                PortalHost  = $PortalHost
                AcquiredUtc = [datetime]::UtcNow
            }
        }

        $result = Connect-MDEPortal -Method CredentialsTotp -Credential @{
            upn = 'svc@test.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
        } -PortalHost 'security.microsoft.com'

        $result.Upn        | Should -Be 'svc@test.com'
        $result.PortalHost | Should -Be 'security.microsoft.com'

        Should -Invoke -ModuleName 'Xdr.Portal.Auth' Connect-DefenderPortal -Times 1 -Exactly
    }

    It 'Invoke-MDEPortalRequest wrapper delegates to Invoke-DefenderPortalRequest' {
        Mock -ModuleName 'Xdr.Portal.Auth' Invoke-DefenderPortalRequest { return @{ delegated = $true } }

        $fakeSession = [pscustomobject]@{
            Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Upn         = 'svc@test.com'
            PortalHost  = 'security.microsoft.com'
            AcquiredUtc = [datetime]::UtcNow
        }
        $result = Invoke-MDEPortalRequest -Session $fakeSession -Path '/api/test'
        $result.delegated | Should -BeTrue

        Should -Invoke -ModuleName 'Xdr.Portal.Auth' Invoke-DefenderPortalRequest -Times 1 -Exactly
    }

    It 'Test-MDEPortalAuth wrapper delegates to Test-DefenderPortalAuth' {
        Mock -ModuleName 'Xdr.Portal.Auth' Test-DefenderPortalAuth {
            return [pscustomobject]@{
                Success = $true
                Stage   = 'complete'
                Method  = $Method
            }
        }

        $r = Test-MDEPortalAuth -Method CredentialsTotp -Credential @{
            upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
        }
        $r.Success | Should -BeTrue
        $r.Method  | Should -Be 'CredentialsTotp'

        Should -Invoke -ModuleName 'Xdr.Portal.Auth' Test-DefenderPortalAuth -Times 1 -Exactly
    }

    It 'Get-MDEAuthFromKeyVault wrapper maps -SecretName onto -SecretPrefix and delegates to Get-XdrAuthFromKeyVault' {
        Mock -ModuleName 'Xdr.Portal.Auth' Get-XdrAuthFromKeyVault {
            return @{
                upn           = 'svc@test.com'
                password      = 'pw'
                totpBase32    = 'x'
                _delegated    = $true
                _SecretPrefix = $SecretPrefix
            }
        }

        $r = Get-MDEAuthFromKeyVault -VaultUri 'https://my.vault.azure.net' -AuthMethod CredentialsTotp
        $r._delegated    | Should -BeTrue
        # Default -SecretName is 'mde-portal-auth' → prefix should strip '-auth' → 'mde-portal'.
        $r._SecretPrefix | Should -Be 'mde-portal'

        Should -Invoke -ModuleName 'Xdr.Portal.Auth' Get-XdrAuthFromKeyVault -Times 1 -Exactly
    }
}

# ============================================================================
#  Rate-counter accessors via the shim (still need to work)
# ============================================================================
Describe 'Xdr.Portal.Auth shim — 429 rate-counter accessors' {
    It 'exposes Get/Reset-XdrPortalRate429Count via the shim wrapper' {
        $exported = (Get-Module Xdr.Portal.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-XdrPortalRate429Count'
        $exported | Should -Contain 'Reset-XdrPortalRate429Count'
    }

    It 'Reset clears cumulative 429 counter back to 0 (via the shim)' {
        Reset-XdrPortalRate429Count
        Get-XdrPortalRate429Count | Should -Be 0
    }
}

# ============================================================================
#  DirectCookies is testing-only (not production) — KEEP from legacy file
# ============================================================================
Describe 'Xdr.Portal.Auth — DirectCookies is testing-only (not production)' {
    It 'Initialize-XdrLogRaiderAuth.ps1 source explicitly refuses cookies as a production KV method' {
        $initPath = Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-XdrLogRaiderAuth.ps1'
        $source = Get-Content $initPath -Raw
        $source | Should -Match "'credentials_totp'|'passkey'" -Because 'only these two are writable to KV'
    }
}
