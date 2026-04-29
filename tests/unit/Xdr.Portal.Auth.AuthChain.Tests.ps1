#Requires -Modules Pester

<#
.SYNOPSIS
    Migration stub. iter-14.0 Phase 1 split the monolithic Xdr.Portal.Auth into
    Xdr.Common.Auth (L1 Entra) + Xdr.Defender.Auth (L2 Defender). The auth-chain
    tests that lived here moved to scoped sibling files:

      tests/unit/Xdr.Common.Auth.AuthChain.Tests.ps1
        - Get-EntraConfigBlob, Test-EntraField, Get-EntraField, Get-EntraFieldNames
        - Test-MfaEndAuthSuccess, Get-EntraErrorMessage
        - Submit-EntraFormPost (was Complete-PortalRedirectChain)
        - Resolve-EntraInterruptPage (was Resolve-InterruptPage)
        - Complete-CredentialsFlow / Complete-TotpMfa / Complete-PasskeyFlow
        - Get-EntraEstsAuth integration-level (was Get-EstsCookie)

      tests/unit/Xdr.Defender.Auth.AuthChain.Tests.ps1
        - Update-XsrfToken (Defender private)
        - Get-DefenderSccauth (Defender public; verifies sccauth + XSRF + tenant)

    What stays here: a sanity check that the shim REALLY DID stop exposing the
    old InModuleScope-accessible private helpers. Anyone who tries to revive the
    old InModuleScope Xdr.Portal.Auth { Get-EstsCookie ... } pattern will get a
    clear failure here pointing them to the new files.

.DESCRIPTION
    No HTTP fixtures. No Entra mocks. Just topology assertions about the shim.
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

Describe 'Xdr.Portal.Auth.AuthChain — migration topology' {
    It 'Get-EstsCookie is no longer findable in Xdr.Portal.Auth (moved to Xdr.Common.Auth as Get-EntraEstsAuth)' {
        # Use the InModuleScope pattern that was previously used to call
        # Get-EstsCookie. After migration the function no longer exists in the
        # shim's scope. The InModuleScope block must NOT find it.
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Get-EstsCookie -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse -Because (
            'iter-14.0: Get-EstsCookie was renamed to Get-EntraEstsAuth and moved ' +
            'to Xdr.Common.Auth (Public). Tests previously using ' +
            '`InModuleScope Xdr.Portal.Auth { Get-EstsCookie ... }` must migrate to ' +
            '`InModuleScope Xdr.Common.Auth { Get-EntraEstsAuth -ClientId ... -PortalHost ... }` ' +
            'or call Get-EntraEstsAuth directly (it is Public on Xdr.Common.Auth).'
        )
    }

    It 'Resolve-InterruptPage is no longer findable in Xdr.Portal.Auth (moved to Xdr.Common.Auth as Resolve-EntraInterruptPage)' {
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Resolve-InterruptPage -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse -Because (
            'iter-14.0: Resolve-InterruptPage was renamed to Resolve-EntraInterruptPage ' +
            '(Xdr.Common.Auth Public).'
        )
    }

    It 'Complete-PortalRedirectChain is no longer findable in Xdr.Portal.Auth (moved to Xdr.Common.Auth as Submit-EntraFormPost private)' {
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Complete-PortalRedirectChain -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse -Because (
            'iter-14.0: Complete-PortalRedirectChain was renamed to Submit-EntraFormPost ' +
            '(Xdr.Common.Auth Private). Tests must migrate to ' +
            '`InModuleScope Xdr.Common.Auth { Submit-EntraFormPost ... }`.'
        )
    }

    It 'Update-XsrfToken is no longer findable in Xdr.Portal.Auth scope (moved to Xdr.Defender.Auth Private)' {
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Update-XsrfToken -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse -Because (
            'iter-14.0: Update-XsrfToken moved to Xdr.Defender.Auth (Private). Tests must ' +
            'migrate to `InModuleScope Xdr.Defender.Auth { Update-XsrfToken ... }`.'
        )
    }

    It 'Get-TotpCode is no longer findable in Xdr.Portal.Auth (moved to Xdr.Common.Auth Private)' {
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Get-TotpCode -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse
    }

    It 'Invoke-PasskeyChallenge is no longer findable in Xdr.Portal.Auth (moved to Xdr.Common.Auth Private)' {
        $found = $true
        try {
            InModuleScope Xdr.Portal.Auth {
                Get-Command -Name Invoke-PasskeyChallenge -ErrorAction Stop
            } | Out-Null
        } catch {
            $found = $false
        }
        $found | Should -BeFalse
    }

    It 'pointer file mentions the new test file locations (one-stop migration breadcrumb)' {
        $thisFile = Get-Content -LiteralPath $PSCommandPath -Raw
        $thisFile | Should -Match 'Xdr\.Common\.Auth\.AuthChain\.Tests\.ps1'
        $thisFile | Should -Match 'Xdr\.Defender\.Auth\.AuthChain\.Tests\.ps1'
    }
}
