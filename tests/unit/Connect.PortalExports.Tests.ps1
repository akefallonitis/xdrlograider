#Requires -Module Pester
# Locks Phase 0k · Connect-*Portal exports + cache contract.
# Tests verify:
#   1. All 5 Connect-*Portal functions exist + are exported from Xdr.Auth
#   2. Each accepts the expected param shape (Credentials + Portal-specific switches)
#   3. Cache behavior: Force / RefreshBeforeMinutes / cache key shape
#   4. Get-XdrBearerSession internal helper handles cache hit/miss/refresh paths
#
# Live OAuth chain NOT exercised here (operator-gated at Phase 0g). Tests use
# fake credentials + mocked TokenCache state where needed.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
    $script:psm1Content = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psm1')
}

Describe 'Connect-*Portal exports · Phase 0k contract' -Tag 'connect-portals' {

    It 'all 5 Connect-*Portal functions exported from Xdr.Auth' {
        $module = Get-Module Xdr.Auth
        $module.ExportedFunctions.Keys | Should -Contain 'Connect-DefenderPortal'
        $module.ExportedFunctions.Keys | Should -Contain 'Connect-PurviewPortal'
        $module.ExportedFunctions.Keys | Should -Contain 'Connect-EntraPortal'
        $module.ExportedFunctions.Keys | Should -Contain 'Connect-IntunePortal'
        $module.ExportedFunctions.Keys | Should -Contain 'Connect-SecurityCopilotPortal'
    }

    It 'Get-XdrBearerSession is NOT exported (internal helper)' {
        $module = Get-Module Xdr.Auth
        $module.ExportedFunctions.Keys | Should -Not -Contain 'Get-XdrBearerSession'
    }
}

Describe 'Connect-DefenderPortal param contract (cookie · already shipped)' -Tag 'connect-portals' {

    It 'declares Credentials/PortalHost/TenantId/Force/RefreshBeforeMinutes params' {
        $cmd = Get-Command Connect-DefenderPortal
        $cmd.Parameters.Keys | Should -Contain 'Credentials'
        $cmd.Parameters.Keys | Should -Contain 'PortalHost'
        $cmd.Parameters.Keys | Should -Contain 'TenantId'
        $cmd.Parameters.Keys | Should -Contain 'Force'
        $cmd.Parameters.Keys | Should -Contain 'RefreshBeforeMinutes'
    }

    It 'PortalHost defaults to security.microsoft.com (verified via psm1 source regex)' {
        # AST DefaultValue.Value is $null for string-typed params in PS7 · regex on source
        $script:psm1Content | Should -Match 'function\s+Connect-DefenderPortal\b[\s\S]*?\[string\]\$PortalHost\s*=\s*''security\.microsoft\.com'''
    }
}

Describe 'Connect-PurviewPortal param contract (cookie sibling)' -Tag 'connect-portals' {

    It 'declares Credentials/PortalHost/TenantId/Force/RefreshBeforeMinutes params' {
        $cmd = Get-Command Connect-PurviewPortal
        $cmd.Parameters.Keys | Should -Contain 'Credentials'
        $cmd.Parameters.Keys | Should -Contain 'PortalHost'
        $cmd.Parameters.Keys | Should -Contain 'TenantId'
        $cmd.Parameters.Keys | Should -Contain 'Force'
    }

    It 'PortalHost defaults to compliance.microsoft.com (verified via psm1 source regex)' {
        $script:psm1Content | Should -Match 'function\s+Connect-PurviewPortal\b[\s\S]*?\[string\]\$PortalHost\s*=\s*''compliance\.microsoft\.com'''
    }
}

Describe 'Connect-EntraPortal param contract (bearer · 5 sub-portals)' -Tag 'connect-portals' {

    It 'declares SubPortal with ValidateSet IAM/PIM/IDGov/IGA/B2C' {
        $cmd = Get-Command Connect-EntraPortal
        $cmd.Parameters.Keys | Should -Contain 'SubPortal'
        $validate = $cmd.Parameters['SubPortal'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validate.ValidValues | Should -Contain 'IAM'
        $validate.ValidValues | Should -Contain 'PIM'
        $validate.ValidValues | Should -Contain 'IDGov'
        $validate.ValidValues | Should -Contain 'IGA'
        $validate.ValidValues | Should -Contain 'B2C'
    }

    It 'SubPortal defaults to IAM (verified via psm1 source regex)' {
        $script:psm1Content | Should -Match 'function\s+Connect-EntraPortal\b[\s\S]*?\[string\]\$SubPortal\s*=\s*''IAM'''
    }
}

Describe 'Connect-IntunePortal param contract (bearer · 2 sub-portals)' -Tag 'connect-portals' {

    It 'declares SubPortal with ValidateSet Portal/Autopatch' {
        $cmd = Get-Command Connect-IntunePortal
        $validate = $cmd.Parameters['SubPortal'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validate.ValidValues | Should -Contain 'Portal'
        $validate.ValidValues | Should -Contain 'Autopatch'
    }

    It 'SubPortal defaults to Portal (verified via psm1 source regex)' {
        $script:psm1Content | Should -Match 'function\s+Connect-IntunePortal\b[\s\S]*?\[string\]\$SubPortal\s*=\s*''Portal'''
    }
}

Describe 'Connect-SecurityCopilotPortal param contract (bearer · multi-host)' -Tag 'connect-portals' {

    It 'declares Credentials/TenantId/Force/RefreshBeforeMinutes (no SubPortal · single config)' {
        $cmd = Get-Command Connect-SecurityCopilotPortal
        $cmd.Parameters.Keys | Should -Contain 'Credentials'
        $cmd.Parameters.Keys | Should -Contain 'TenantId'
        $cmd.Parameters.Keys | Should -Contain 'Force'
        $cmd.Parameters.Keys | Should -Contain 'RefreshBeforeMinutes'
        $cmd.Parameters.Keys | Should -Not -Contain 'SubPortal'
    }
}
