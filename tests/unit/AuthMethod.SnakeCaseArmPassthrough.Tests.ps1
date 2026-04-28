#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.12 lock: ARM template passes `authMethod = 'credentials_totp'` (snake_case)
    to the Function App. Profile.ps1 reads it as `$env:AUTH_METHOD` and timer
    functions pass it through to Test-MDEPortalAuth + Connect-MDEPortal.

    These functions' `-Method` ValidateSet MUST accept BOTH PascalCase
    (`CredentialsTotp`, `Passkey`) AND snake_case (`credentials_totp`,
    `passkey`) — and normalize internally.

.DESCRIPTION
    LIVE EVIDENCE (post iter-13.11 deploy, App Insights 2026-04-28):
        38 exceptions/h from validate-auth-selftest:
        "Cannot validate argument on parameter 'Method'.
         The argument 'credentials_totp' does not belong to the set
         'CredentialsTotp,Passkey' specified by the ValidateSet attribute."

    Root cause: ARM template's `authMethod` parameter is documented as
    `credentials_totp | passkey` (snake_case), and profile.ps1 surfaces this
    via `$env:AUTH_METHOD`. Timer functions pass `$config.AuthMethod` directly
    to portal-auth functions, but those functions' ValidateSet accepts only
    PascalCase. Result: every validate-auth-selftest invocation crashed before
    reaching the auth chain → MDE_AuthTestResult_CL never populated → all
    poll-* timers gated → zero rows ingested.

    Iter 13.12 fix:
      - Test-MDEPortalAuth accepts both cases + normalizes internally
      - Connect-MDEPortal accepts both cases + normalizes internally
      - This test locks the contract permanently
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:AuthModulePath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    Import-Module $script:AuthModulePath -Force -ErrorAction Stop
    Set-StrictMode -Version Latest
}

Describe 'AuthMethod ARM passthrough — snake_case ValidateSet acceptance (iter 13.12)' {

    It 'Test-MDEPortalAuth -Method ValidateSet accepts <Method>' -ForEach @(
        @{ Method = 'CredentialsTotp' }
        @{ Method = 'Passkey' }
        @{ Method = 'credentials_totp' }
        @{ Method = 'passkey' }
    ) {
        $cmd = Get-Command -Module Xdr.Portal.Auth -Name Test-MDEPortalAuth -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain $Method -Because (
            "iter-13.12: ARM template uses snake_case auth-method names. " +
            "Test-MDEPortalAuth must accept both cases."
        )
    }

    It 'Connect-MDEPortal -Method ValidateSet accepts <Method>' -ForEach @(
        @{ Method = 'CredentialsTotp' }
        @{ Method = 'Passkey' }
        @{ Method = 'credentials_totp' }
        @{ Method = 'passkey' }
    ) {
        $cmd = Get-Command -Module Xdr.Portal.Auth -Name Connect-MDEPortal -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain $Method -Because (
            "iter-13.12: Connect-MDEPortal must accept the same shape Test-MDEPortalAuth does."
        )
    }

    It 'Get-MDEAuthFromKeyVault -AuthMethod ValidateSet already accepts snake_case (regression guard for iter 13.x)' {
        $cmd = Get-Command -Module Xdr.Portal.Auth -Name Get-MDEAuthFromKeyVault -ErrorAction Stop
        $methodParam = $cmd.Parameters['AuthMethod']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet.ValidValues | Should -Contain 'credentials_totp' -Because 'KV credential function has supported snake_case since iter 13.x'
        $validateSet.ValidValues | Should -Contain 'passkey'
    }

    It 'main.bicep authMethod parameter uses snake_case allowed values (root cause documentation)' {
        $bicepPath = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
        $content = Get-Content $bicepPath -Raw
        # Confirm the root-cause: ARM template is the source of snake_case.
        # If a future contributor switches main.bicep to PascalCase, this test
        # would fail loud — at which point the snake_case aliases on the
        # ValidateSets become unnecessary and could be cleaned up.
        $content | Should -Match "credentials_totp" -Because 'main.bicep authMethod uses snake_case literals; if this changes, revisit the ValidateSet aliases'
    }
}
