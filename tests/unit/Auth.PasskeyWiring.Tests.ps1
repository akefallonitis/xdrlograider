#Requires -Module Pester
# φ.AUTH.6b · Passkey wiring · -Method dispatch + 2 KV secrets + UI radio + ARM secrets
# Locks: Get-EntraEstsAuth -Method Passkey dispatches to Complete-XdrPasskeyFlow ·
# Get-XdrAuthFromKeyVault reads xdrlr-sa-auth-method + xdrlr-sa-passkey-pem · ARM
# parameters exposed · createUiDefinition.json authMethod radio + PEM password box.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
    $script:AuthSrc = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psm1')
    $script:ArmSrc  = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'deploy/mainTemplate.json')
    $script:UiSrc   = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'deploy/createUiDefinition.json')
}

Describe 'φ.AUTH.6b · Get-EntraEstsAuth · -Method dispatch' -Tag 'passkey-wiring' {

    It 'Get-EntraEstsAuth has -Method param with CredentialsTotp + Passkey ValidateSet (default CredentialsTotp)' {
        $cmd = Get-Command Get-EntraEstsAuth -Module Xdr.Auth
        $cmd.Parameters.Keys | Should -Contain 'Method'
        $methodParam = $cmd.Parameters['Method']
        $vSet = $methodParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -First 1
        @($vSet.ValidValues) | Should -Contain 'CredentialsTotp'
        @($vSet.ValidValues) | Should -Contain 'Passkey'
        # Default = CredentialsTotp (operators opt-in to Passkey)
        $script:AuthSrc.Contains("[string]`$Method = 'CredentialsTotp'") | Should -BeTrue
    }

    It 'Method=Passkey dispatches to Complete-XdrPasskeyFlow (not Complete-CredentialsFlow)' {
        $script:AuthSrc.Contains('if ($Method -eq ''Passkey'')') | Should -BeTrue
        $script:AuthSrc.Contains('Complete-XdrPasskeyFlow') | Should -BeTrue
        $script:AuthSrc.Contains('Auth.PasskeyFlow.Dispatched') | Should -BeTrue
    }

    It 'Method=Passkey requires Credential.passkey field (early throw before flow)' {
        $script:AuthSrc | Should -Match "Method -eq 'Passkey' -and -not"
        $script:AuthSrc | Should -Match "Credential\.passkey"
    }
}

Describe 'φ.AUTH.6b · Get-XdrAuthFromKeyVault · 2 new KV secrets' -Tag 'passkey-wiring' {

    It 'reads optional xdrlr-sa-auth-method secret (KV override for AuthMethod)' {
        $script:AuthSrc.Contains('$SecretPrefix-auth-method') | Should -BeTrue
    }

    It 'reads optional xdrlr-sa-passkey-pem secret (ECDSA-P256 PEM private key)' {
        $script:AuthSrc.Contains('$SecretPrefix-passkey-pem') | Should -BeTrue
    }

    It 'throws when AuthMethod=Passkey but PEM secret missing (no silent fallback)' {
        $script:AuthSrc.Contains("resolvedAuthMethod -eq 'Passkey' -and -not `$passkeyPem") | Should -BeTrue
        $script:AuthSrc.Contains("but `$SecretPrefix-passkey-pem is missing") | Should -BeTrue
    }

    It 'returns Passkey PSCustomObject matching Invoke-XdrPasskeyChallenge contract (credentialId + privateKeyPem + rpId)' {
        $script:AuthSrc.Contains('credentialId') | Should -BeTrue
        $script:AuthSrc.Contains('privateKeyPem = $passkeyPem') | Should -BeTrue
        $script:AuthSrc.Contains("rpId          = 'login.microsoft.com'") | Should -BeTrue
    }
}

Describe 'φ.AUTH.6b · ARM mainTemplate.json · 2 new params + 2 new KV secrets' -Tag 'passkey-wiring' {

    It 'ARM exposes serviceAccountAuthMethod param with CredentialsTotp + Passkey allowed values' {
        $arm = $script:ArmSrc | ConvertFrom-Json
        $param = $arm.parameters.serviceAccountAuthMethod
        $param | Should -Not -BeNullOrEmpty
        $param.defaultValue | Should -Be 'CredentialsTotp'
        @($param.allowedValues) | Should -Contain 'CredentialsTotp'
        @($param.allowedValues) | Should -Contain 'Passkey'
    }

    It 'ARM exposes serviceAccountPasskeyPem secure-input param (defaultValue empty)' {
        $arm = $script:ArmSrc | ConvertFrom-Json
        $param = $arm.parameters.serviceAccountPasskeyPem
        $param | Should -Not -BeNullOrEmpty
        $param.type | Should -Be 'securestring'
        $param.defaultValue | Should -Be ''
    }

    It 'ARM provisions defender-auth-method KV secret' {
        $arm = $script:ArmSrc | ConvertFrom-Json
        $secrets = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults/secrets' } | ForEach-Object { ($_.name -split '/')[-1] -replace "'\)\]?$","" })
        $secrets -join ',' | Should -Match 'defender-auth-method'
    }

    It 'ARM provisions defender-passkey-pem KV secret (secure-input)' {
        $arm = $script:ArmSrc | ConvertFrom-Json
        $secrets = @($arm.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults/secrets' } | ForEach-Object { ($_.name -split '/')[-1] -replace "'\)\]?$","" })
        $secrets -join ',' | Should -Match 'defender-passkey-pem'
    }
}

Describe 'φ.AUTH.6b · createUiDefinition.json · authMethod radio + conditional PEM input' -Tag 'passkey-wiring' {

    It 'UI has authMethod OptionsGroup with both CredentialsTotp + Passkey values' {
        $ui = $script:UiSrc | ConvertFrom-Json
        $auth = $ui.parameters.steps | Where-Object name -eq 'authStep'
        $methodEl = $auth.elements | Where-Object name -eq 'authMethod'
        $methodEl | Should -Not -BeNullOrEmpty
        $methodEl.type | Should -Be 'Microsoft.Common.OptionsGroup'
        $vals = @($methodEl.constraints.allowedValues.value)
        $vals | Should -Contain 'CredentialsTotp'
        $vals | Should -Contain 'Passkey'
    }

    It 'UI has passkeyPem PasswordBox conditionally visible when authMethod=Passkey' {
        $ui = $script:UiSrc | ConvertFrom-Json
        $auth = $ui.parameters.steps | Where-Object name -eq 'authStep'
        $pemEl = $auth.elements | Where-Object name -eq 'passkeyPem'
        $pemEl | Should -Not -BeNullOrEmpty
        $pemEl.type | Should -Be 'Microsoft.Common.PasswordBox'
        # Visible expression references authMethod
        ([string]$pemEl.visible) | Should -Match "steps\('authStep'\)\.authMethod"
        ([string]$pemEl.visible) | Should -Match "'Passkey'"
    }

    It 'UI outputs include serviceAccountAuthMethod + serviceAccountPasskeyPem (bound to authStep)' {
        $ui = $script:UiSrc | ConvertFrom-Json
        $outputs = $ui.parameters.outputs
        $outputs.serviceAccountAuthMethod | Should -Match "steps\('authStep'\)\.authMethod"
        # Use coalesce so blank PEM (TOTP mode) doesn't fail required-string validation
        ([string]$outputs.serviceAccountPasskeyPem) | Should -Match "coalesce\(steps\('authStep'\)\.passkeyPem, ''\)"
    }
}
