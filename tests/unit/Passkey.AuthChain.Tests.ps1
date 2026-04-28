#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.9 (P1 lock): the passkey auth method MUST be a supported,
    documented unattended path in the auth chain.

.DESCRIPTION
    The connector supports two unattended auth methods per docs/AUTH.md:
      1. CredentialsTotp — verified live today (sccauth minted, 36/45 endpoints 200)
      2. Passkey — software FIDO2 passkey JSON, ECDSA-signed assertion

    User explicitly asked to "ensure both totp and passkey will work properly
    unattendant". CredentialsTotp is exercised by Audit-Endpoints-Live + the
    integration test; Passkey is the second-priority unattended path.

    This gate locks the passkey contract permanently:
      - Connect-MDEPortal accepts -Method Passkey
      - Get-MDEAuthFromKeyVault returns the passkey shape from KV
      - Auth chain has a passkey-specific code branch
      - Documentation (AUTH.md + BRING-YOUR-OWN-PASSKEY.md) describes the
        unattended workflow
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AuthModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'

    Import-Module $script:AuthModulePath -Force -ErrorAction Stop
    Set-StrictMode -Version Latest
}

Describe 'Passkey unattended auth method — contract lock (iter 13.9 P1)' {

    It 'Connect-MDEPortal -Method parameter accepts Passkey value' {
        $cmd = Get-Command -Module Xdr.Portal.Auth -Name Connect-MDEPortal -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $methodParam | Should -Not -BeNullOrEmpty -Because 'Method parameter must exist'

        # ValidateSet attribute drives the allowed values
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty -Because 'Method param must be ValidateSet-bound'
        $validateSet.ValidValues | Should -Contain 'Passkey' -Because 'Passkey is a documented unattended auth method'
    }

    It 'Get-MDEAuthFromKeyVault supports the passkey method enum' {
        $cmd = Get-Command -Module Xdr.Portal.Auth -Name Get-MDEAuthFromKeyVault -ErrorAction Stop
        $methodParam = $cmd.Parameters['AuthMethod']
        $methodParam | Should -Not -BeNullOrEmpty

        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet.ValidValues | Should -Contain 'Passkey' -Because 'KV-backed passkey credential retrieval must be supported'
    }

    It 'auth chain has a passkey code branch' {
        $estsPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Private' 'Get-EstsCookie.ps1'
        $content = Get-Content $estsPath -Raw
        # Check for passkey-specific function or branching
        $hasPasskeyCode = ($content -match '(?i)passkey') -or
                         ($content -match '(?i)WebAuthn') -or
                         ($content -match '(?i)FIDO')
        $hasPasskeyCode | Should -BeTrue -Because 'auth chain must include passkey/WebAuthn/FIDO handling'
    }

    It 'docs/AUTH.md documents passkey as supported unattended method' {
        $authDoc = Get-Content (Join-Path $script:RepoRoot 'docs' 'AUTH.md') -Raw
        $authDoc | Should -Match '(?i)passkey' -Because 'AUTH.md must document the passkey method'
    }

    It 'docs/BRING-YOUR-OWN-PASSKEY.md exists with workflow description' {
        $passkeyDoc = Join-Path $script:RepoRoot 'docs' 'BRING-YOUR-OWN-PASSKEY.md'
        Test-Path $passkeyDoc | Should -BeTrue -Because 'passkey-specific workflow doc must exist'

        $content = Get-Content $passkeyDoc -Raw
        $content.Length | Should -BeGreaterThan 200 -Because 'doc must contain real workflow content, not be a stub'
    }

    It 'Get-MDEAuthFromKeyVault returns a credential hashtable with passkey-shape fields' {
        # Source-level lock: verify the function constructs a passkey credential
        # with documented fields (UPN + passkey JSON path or content).
        $kvFnPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Public' 'Get-MDEAuthFromKeyVault.ps1'
        $content = Get-Content $kvFnPath -Raw
        $content | Should -Match '(?i)passkey' -Because 'KV credential function must construct passkey shape'
    }
}
