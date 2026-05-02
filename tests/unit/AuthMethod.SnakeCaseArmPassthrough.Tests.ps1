#Requires -Modules Pester
<#
.SYNOPSIS
    Lock: ARM template passes `authMethod = 'credentials_totp'` (snake_case)
    to the Function App. profile.ps1 reads it as `$env:AUTH_METHOD` and timer
    functions pass it through to Test-DefenderPortalAuth + Connect-DefenderPortal.

    These functions' `-Method` ValidateSet MUST accept BOTH PascalCase
    (`CredentialsTotp`, `Passkey`) AND snake_case (`credentials_totp`,
    `passkey`) — and normalize internally.

.DESCRIPTION
    Historical root cause: when the ARM template's `authMethod` parameter is
    documented as `credentials_totp | passkey` (snake_case), profile.ps1
    surfaces this via `$env:AUTH_METHOD`. Timer functions pass
    `$config.AuthMethod` directly to portal-auth functions; if those
    functions' ValidateSet accepted only PascalCase the FA would crash
    before reaching the auth chain.

    Permanent fix preserved across the v0.1.0-beta first publish refactor:
      - Test-DefenderPortalAuth accepts both cases + normalizes internally
      - Connect-DefenderPortal accepts both cases + normalizes internally
      - Get-XdrAuthFromKeyVault accepts both cases
      - This test locks the contract permanently
#>

BeforeDiscovery {
    # BeforeDiscovery for inline -Skip clauses (Bicep is archived to
    # .internal/bicep-reference/ in v0.1.0-beta first publish).
    $script:DiscoveryRepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:DiscoveryMainBicep = Join-Path $script:DiscoveryRepoRoot 'deploy' 'main.bicep'
}

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'
    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Set-StrictMode -Version Latest
}

Describe 'AuthMethod ARM passthrough — snake_case ValidateSet acceptance' {

    It 'Test-DefenderPortalAuth -Method ValidateSet accepts <Method>' -ForEach @(
        @{ Method = 'CredentialsTotp' }
        @{ Method = 'Passkey' }
        @{ Method = 'credentials_totp' }
        @{ Method = 'passkey' }
    ) {
        $cmd = Get-Command -Module Xdr.Defender.Auth -Name Test-DefenderPortalAuth -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain $Method -Because (
            "ARM template uses snake_case auth-method names. " +
            "Test-DefenderPortalAuth must accept both cases."
        )
    }

    It 'Connect-DefenderPortal -Method ValidateSet accepts <Method>' -ForEach @(
        @{ Method = 'CredentialsTotp' }
        @{ Method = 'Passkey' }
        @{ Method = 'credentials_totp' }
        @{ Method = 'passkey' }
    ) {
        $cmd = Get-Command -Module Xdr.Defender.Auth -Name Connect-DefenderPortal -ErrorAction Stop
        $methodParam = $cmd.Parameters['Method']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain $Method -Because (
            "Connect-DefenderPortal must accept the same shape Test-DefenderPortalAuth does."
        )
    }

    It 'Get-XdrAuthFromKeyVault -AuthMethod ValidateSet accepts snake_case (regression guard)' {
        $cmd = Get-Command -Module Xdr.Common.Auth -Name Get-XdrAuthFromKeyVault -ErrorAction Stop
        $methodParam = $cmd.Parameters['AuthMethod']
        $validateSet = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $validateSet.ValidValues | Should -Contain 'credentials_totp' -Because 'KV credential function must accept the snake_case form ARM passes through'
        $validateSet.ValidValues | Should -Contain 'passkey'
    }

    It 'main.bicep authMethod parameter uses snake_case allowed values (root cause documentation)' -Skip:(-not (Test-Path -LiteralPath $script:DiscoveryMainBicep)) {
        # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
        # single source of truth). Skip cleanly when not present.
        $bicepPath = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
        $content = Get-Content $bicepPath -Raw
        $content | Should -Match "credentials_totp" -Because 'main.bicep authMethod uses snake_case literals; if this changes, revisit the ValidateSet aliases'
    }
}
