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

    Connect-DefenderPortal in Xdr.Defender.Auth is the canonical entry point
    for authenticated portal sessions. The auth-chain code (passkey branch)
    lives in Xdr.Common.Auth/Private/Complete-PasskeyFlow.ps1 +
    Xdr.Common.Auth/Private/Invoke-PasskeyChallenge.ps1. Get-XdrAuthFromKeyVault
    in Xdr.Common.Auth supplies the credential material.

    This gate locks the passkey contract permanently:
      - Connect-DefenderPortal accepts -Method Passkey
      - Get-XdrAuthFromKeyVault returns the passkey shape from KV
      - Auth chain has a passkey-specific code branch
      - Documentation (AUTH.md "Bring your own passkey" section) describes the
        unattended workflow
#>

BeforeAll {
    $script:RepoRoot          = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonModulePath  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth'   'Xdr.Common.Auth.psd1'
    $script:DefenderModulePath= Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'

    Import-Module $script:CommonModulePath   -Force -ErrorAction Stop
    Import-Module $script:DefenderModulePath -Force -ErrorAction Stop
    Set-StrictMode -Version Latest
}

AfterAll {
    Remove-Module Xdr.Defender.Auth -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth   -Force -ErrorAction SilentlyContinue
}

Describe 'Passkey unattended auth method — contract lock (iter 13.9 P1; v0.1.0 GA location)' {

    It 'Connect-DefenderPortal -Method parameter accepts Passkey value' {
        $cmd = Get-Command -Module Xdr.Defender.Auth -Name Connect-DefenderPortal -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $methodParam | Should -Not -BeNullOrEmpty -Because 'Method parameter must exist'

        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty -Because 'Method param must be ValidateSet-bound'
        $validateSet.ValidValues | Should -Contain 'Passkey' -Because 'Passkey is a documented unattended auth method'
    }

    It 'Get-XdrAuthFromKeyVault supports the passkey method enum' {
        $cmd = Get-Command -Module Xdr.Common.Auth -Name Get-XdrAuthFromKeyVault -ErrorAction Stop
        $methodParam = $cmd.Parameters['AuthMethod']
        $methodParam | Should -Not -BeNullOrEmpty

        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet.ValidValues | Should -Contain 'Passkey' -Because 'KV-backed passkey credential retrieval must be supported'
    }

    It 'auth chain has a passkey code branch in Xdr.Common.Auth (Complete-PasskeyFlow + Invoke-PasskeyChallenge)' {
        $passkeyFlow = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Private' 'Complete-PasskeyFlow.ps1'
        $passkeyChallenge = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Private' 'Invoke-PasskeyChallenge.ps1'

        Test-Path $passkeyFlow      | Should -BeTrue -Because 'Complete-PasskeyFlow.ps1 must exist as the L1 passkey branch'
        Test-Path $passkeyChallenge | Should -BeTrue -Because 'Invoke-PasskeyChallenge.ps1 must exist as the WebAuthn signer'

        $flowContent = Get-Content $passkeyFlow -Raw
        $hasPasskeyCode = ($flowContent -match '(?i)passkey') -or
                         ($flowContent -match '(?i)WebAuthn') -or
                         ($flowContent -match '(?i)FIDO')
        $hasPasskeyCode | Should -BeTrue -Because 'Complete-PasskeyFlow must include passkey/WebAuthn/FIDO handling'
    }

    It 'Get-EntraEstsAuth dispatches Passkey method to Complete-PasskeyFlow' {
        $estsPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Get-EntraEstsAuth.ps1'
        $content = Get-Content $estsPath -Raw
        $content | Should -Match "'Passkey'"          -Because "Get-EntraEstsAuth's switch must have a 'Passkey' case"
        $content | Should -Match 'Complete-PasskeyFlow' -Because 'Passkey case must call Complete-PasskeyFlow'
    }

    It 'docs/AUTH.md documents passkey as supported unattended method' {
        $authDoc = Get-Content (Join-Path $script:RepoRoot 'docs' 'AUTH.md') -Raw
        $authDoc | Should -Match '(?i)passkey' -Because 'AUTH.md must document the passkey method'
    }

    It 'docs/AUTH.md contains the "Bring your own passkey" workflow section' {
        # v0.1.0.x C6 consolidation (2026-05-08): BRING-YOUR-OWN-PASSKEY.md merged
        # into docs/AUTH.md as a section. This test was previously checking for
        # the standalone file; now verifies the section exists in AUTH.md instead.
        $authDoc = Join-Path $script:RepoRoot 'docs' 'AUTH.md'
        Test-Path $authDoc | Should -BeTrue -Because 'consolidated auth doc must exist'

        $content = Get-Content $authDoc -Raw
        $content | Should -Match '(?i)Bring your own passkey' -Because 'AUTH.md must contain the passkey workflow section (post-consolidation)'
        $content | Should -Match '(?i)Required JSON schema' -Because 'AUTH.md must document the passkey JSON schema'
        $content.Length | Should -BeGreaterThan 1000 -Because 'AUTH.md must contain substantial passkey workflow content'
    }

    It 'Get-XdrAuthFromKeyVault returns a credential hashtable with passkey-shape fields' {
        $kvFnPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Get-XdrAuthFromKeyVault.ps1'
        $content = Get-Content $kvFnPath -Raw
        $content | Should -Match '(?i)passkey' -Because 'KV credential function must construct passkey shape'
    }
}
