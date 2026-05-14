#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# TOTP + Passkey auth path coverage. Both methods must work end-to-end per Rule 19.
# We mock Get-EntraEstsAuth (L1 — Entra layer) + Get-DefenderSccauth (L2 — portal
# cookie verification) so Connect-DefenderPortal's orchestration is testable
# without hitting login.microsoftonline.com.

Describe 'Connect-DefenderPortal — TOTP + Passkey paths (Rule 19)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
    }

    Context 'CredentialsTotp method' {
        It 'passes TOTP credential hashtable through to Get-EntraEstsAuth + returns session' {
            $script:CapturedMethod = $null
            $script:CapturedCred   = $null
            Mock Get-EntraEstsAuth -ModuleName Xdr.Defender.Auth {
                param($Method, $Credential, $ClientId, $PortalHost, $TenantId, $CorrelationId)
                $script:CapturedMethod = $Method
                $script:CapturedCred = $Credential
                @{ Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
            }
            Mock Get-DefenderSccauth -ModuleName Xdr.Defender.Auth {
                @{ TenantId = '00000000-0000-0000-0000-000000000000'; AcquiredUtc = [DateTime]::UtcNow }
            }
            $cred = @{ upn = 'svc-totp@contoso.com'; password = 'p@ss'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            $r = Connect-DefenderPortal -Method 'CredentialsTotp' -Credential $cred -PortalHost 'security.microsoft.com' -Force
            $r.Upn | Should -Be 'svc-totp@contoso.com'
            $script:CapturedMethod | Should -Be 'CredentialsTotp'
            $script:CapturedCred.upn | Should -Be 'svc-totp@contoso.com'
            $script:CapturedCred.totpBase32 | Should -Be 'JBSWY3DPEHPK3PXP'
        }

        It 'normalises snake_case credentials_totp to PascalCase CredentialsTotp' {
            Mock Get-EntraEstsAuth -ModuleName Xdr.Defender.Auth {
                param($Method)
                $script:CapturedMethod = $Method
                @{ Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
            }
            Mock Get-DefenderSccauth -ModuleName Xdr.Defender.Auth {
                @{ TenantId = 'x'; AcquiredUtc = [DateTime]::UtcNow }
            }
            $cred = @{ upn = 'svc@x'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            Connect-DefenderPortal -Method 'credentials_totp' -Credential $cred -Force | Out-Null
            $script:CapturedMethod | Should -Be 'CredentialsTotp'
        }
    }

    Context 'Passkey method' {
        It 'passes passkey JSON credential through to Get-EntraEstsAuth + returns session' {
            $script:CapturedMethod = $null
            $script:CapturedCred   = $null
            Mock Get-EntraEstsAuth -ModuleName Xdr.Defender.Auth {
                param($Method, $Credential, $ClientId, $PortalHost, $TenantId, $CorrelationId)
                $script:CapturedMethod = $Method
                $script:CapturedCred = $Credential
                @{ Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
            }
            Mock Get-DefenderSccauth -ModuleName Xdr.Defender.Auth {
                @{ TenantId = '00000000-0000-0000-0000-000000000000'; AcquiredUtc = [DateTime]::UtcNow }
            }
            $cred = @{
                upn = 'svc-passkey@contoso.com'
                passkey = @{
                    rpId = 'login.microsoft.com'
                    credentialId = 'cred-abc123'
                    privateKey = '<pem>'
                }
            }
            $r = Connect-DefenderPortal -Method 'Passkey' -Credential $cred -PortalHost 'security.microsoft.com' -Force
            $r.Upn | Should -Be 'svc-passkey@contoso.com'
            $script:CapturedMethod | Should -Be 'Passkey'
            $script:CapturedCred.passkey | Should -Not -BeNullOrEmpty
            $script:CapturedCred.passkey.rpId | Should -Be 'login.microsoft.com'
        }

        It 'normalises snake_case passkey method consistently' {
            Mock Get-EntraEstsAuth -ModuleName Xdr.Defender.Auth {
                param($Method)
                $script:CapturedMethod = $Method
                @{ Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
            }
            Mock Get-DefenderSccauth -ModuleName Xdr.Defender.Auth {
                @{ TenantId = 'x'; AcquiredUtc = [DateTime]::UtcNow }
            }
            $cred = @{ upn = 'svc@x'; passkey = @{ credentialId = 'c' } }
            Connect-DefenderPortal -Method 'passkey' -Credential $cred -Force | Out-Null
            $script:CapturedMethod | Should -Be 'Passkey'
        }
    }

    Context 'Method ValidateSet rejects unsupported methods' {
        It 'rejects unsupported auth method' {
            $cred = @{ upn = 'svc@x' }
            { Connect-DefenderPortal -Method 'FakeMethod' -Credential $cred } | Should -Throw '*ValidateSet*'
        }
    }
}

Describe 'Get-XdrAuthFromKeyVault — TOTP + Passkey secret loading (mocked KV)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1') -Force
    }

    It 'CredentialsTotp method: loads upn + password + totpBase32 secrets from KV' {
        # Mock Get-AzKeyVaultSecret (the actual cmdlet used by the function)
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'mde-portal-upn'      { 'svc-totp@contoso.com' }
                'mde-portal-password' { 'P@ssw0rd!' }
                'mde-portal-totp'     { 'JBSWY3DPEHPK3PXP' }
                default               { '' }
            }
        }
        $cred = Get-XdrAuthFromKeyVault `
            -VaultUri 'https://xdrlr-kv-abc.vault.azure.net' `
            -SecretPrefix 'mde-portal' `
            -AuthMethod 'CredentialsTotp' `
            -Force
        $cred | Should -Not -BeNullOrEmpty
        $cred.upn        | Should -Be 'svc-totp@contoso.com'
        $cred.password   | Should -Be 'P@ssw0rd!'
        $cred.totpBase32 | Should -Be 'JBSWY3DPEHPK3PXP'
    }

    It 'Passkey method: loads upn + passkey JSON blob' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'mde-portal-upn'     { 'svc-pk@contoso.com' }
                'mde-portal-passkey' { '{"upn":"svc-pk@contoso.com","rpId":"login.microsoft.com","credentialId":"cred-1","privateKey":"<pem>"}' }
                default              { '' }
            }
        }
        $cred = Get-XdrAuthFromKeyVault `
            -VaultUri 'https://xdrlr-kv-abc.vault.azure.net' `
            -SecretPrefix 'mde-portal' `
            -AuthMethod 'Passkey' `
            -Force
        $cred.upn     | Should -Be 'svc-pk@contoso.com'
        $cred.passkey | Should -Not -BeNullOrEmpty
        $cred.passkey.credentialId | Should -Be 'cred-1'
    }

    It 'snake_case ARM passthrough is normalised (credentials_totp + passkey)' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            if ($Name -match 'passkey$') {
                '{"upn":"svc@x","credentialId":"c"}'
            } else {
                'placeholder'
            }
        }
        { Get-XdrAuthFromKeyVault -VaultUri 'https://x.vault.azure.net' -SecretPrefix 'p' -AuthMethod 'credentials_totp' -Force } | Should -Not -Throw
        { Get-XdrAuthFromKeyVault -VaultUri 'https://x.vault.azure.net' -SecretPrefix 'p' -AuthMethod 'passkey' -Force } | Should -Not -Throw
    }
}

Describe 'Get-XdrAuthFromKeyVault — empty-secret validation (silent-failure prevention)' {
    # Pre-deploy audit risk: when a KV secret EXISTS but its value is BLANK
    # (operator forgot to fill the wizard input, or rotation set empty), the
    # auth chain used to proceed with empty credentials and fail silently at
    # portal sign-in — the connector would loop forever with no clear signal.
    # These tests lock the fail-fast contract: empty secret values throw a
    # clear, actionable error naming the offending secret + remediation cmd.
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1') -Force
    }

    It 'CredentialsTotp: throws when password secret is empty' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'defender-upn'      { 'svc@contoso.com' }
                'defender-password' { '' }                 # the empty one
                'defender-totp'     { 'JBSWY3DPEHPK3PXP' }
                default             { 'x' }
            }
        }
        { Get-XdrAuthFromKeyVault `
            -VaultUri 'https://x.vault.azure.net' `
            -SecretPrefix 'defender' `
            -AuthMethod 'CredentialsTotp' `
            -Force } | Should -Throw '*defender-password*empty*'
    }

    It 'CredentialsTotp: throws when totp secret is empty (named with corrected -totp suffix)' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'defender-upn'      { 'svc@contoso.com' }
                'defender-password' { 'P@ssw0rd!' }
                'defender-totp'     { '   ' }              # whitespace-only counts as empty
                default             { 'x' }
            }
        }
        { Get-XdrAuthFromKeyVault `
            -VaultUri 'https://x.vault.azure.net' `
            -SecretPrefix 'defender' `
            -AuthMethod 'CredentialsTotp' `
            -Force } | Should -Throw '*defender-totp*empty*'
    }

    It 'CredentialsTotp: throws when upn secret is empty' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'defender-upn'      { '' }
                'defender-password' { 'P@ssw0rd!' }
                'defender-totp'     { 'JBSWY3DPEHPK3PXP' }
                default             { 'x' }
            }
        }
        { Get-XdrAuthFromKeyVault `
            -VaultUri 'https://x.vault.azure.net' `
            -SecretPrefix 'defender' `
            -AuthMethod 'CredentialsTotp' `
            -Force } | Should -Throw '*defender-upn*empty*'
    }

    It 'Passkey: throws when passkey JSON is empty/blank' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            if ($Name -match 'passkey$') { '' } else { 'x' }
        }
        { Get-XdrAuthFromKeyVault `
            -VaultUri 'https://x.vault.azure.net' `
            -SecretPrefix 'defender' `
            -AuthMethod 'Passkey' `
            -Force } | Should -Throw
    }

    It 'Passkey: throws when passkey JSON lacks upn field' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            if ($Name -match 'passkey$') { '{"rpId":"login.microsoft.com","credentialId":"c"}' }  # no upn
            else { 'x' }
        }
        { Get-XdrAuthFromKeyVault `
            -VaultUri 'https://x.vault.azure.net' `
            -SecretPrefix 'defender' `
            -AuthMethod 'Passkey' `
            -Force } | Should -Throw '*passkey*upn*'
    }

    It 'error message includes the az keyvault secret set remediation command' {
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            switch ($Name) {
                'defender-password' { '' }
                default             { 'x' }
            }
        }
        try {
            Get-XdrAuthFromKeyVault `
                -VaultUri 'https://x.vault.azure.net' `
                -SecretPrefix 'defender' `
                -AuthMethod 'CredentialsTotp' `
                -Force
            throw 'should have thrown'
        } catch {
            $_.Exception.Message | Should -Match 'az keyvault secret set'
            $_.Exception.Message | Should -Match 'defender-password'
        }
    }
}

Describe 'Get-XdrAuthFromKeyVault — TTL cache + Force bypass (rule 23 401-rotation)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1') -Force
    }

    It 'caches the second call within TTL — KV is hit ONCE only' {
        $script:KvCalls = 0
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            $script:KvCalls++
            switch ($Name) {
                'cache-test-totp-upn'      { 'svc-cache@x.com' }
                'cache-test-totp-password' { 'pw' }
                'cache-test-totp-totp'     { 'JBSWY3DPEHPK3PXP' }
                default                    { '' }
            }
        }
        $cred1 = Get-XdrAuthFromKeyVault -VaultUri 'https://x-cache-test.vault.azure.net' -SecretPrefix 'cache-test-totp' -AuthMethod 'CredentialsTotp'
        $cred2 = Get-XdrAuthFromKeyVault -VaultUri 'https://x-cache-test.vault.azure.net' -SecretPrefix 'cache-test-totp' -AuthMethod 'CredentialsTotp'
        $cred1.upn | Should -Be $cred2.upn
        # Each call fetches 3 secrets (upn, password, totp). First call = 3 fetches.
        # Second call = cache hit; KV is NOT contacted again.
        $script:KvCalls | Should -Be 3
    }

    It '-Force bypasses the cache and re-fetches from KV (used on 401 rotation per Rule 23)' {
        $script:KvCalls = 0
        Mock Get-AzKeyVaultSecret -ModuleName Xdr.Common.Auth {
            param($VaultName, $Name, [switch]$AsPlainText)
            $script:KvCalls++
            switch ($Name) {
                'force-test-totp-upn'      { 'svc-force@x.com' }
                'force-test-totp-password' { 'pw' }
                'force-test-totp-totp'     { 'JBSWY3DPEHPK3PXP' }
                default                    { '' }
            }
        }
        $null = Get-XdrAuthFromKeyVault -VaultUri 'https://x-force-test.vault.azure.net' -SecretPrefix 'force-test-totp' -AuthMethod 'CredentialsTotp'
        $null = Get-XdrAuthFromKeyVault -VaultUri 'https://x-force-test.vault.azure.net' -SecretPrefix 'force-test-totp' -AuthMethod 'CredentialsTotp' -Force
        # First call = 3 fetches; second call with -Force bypasses cache = 3 more fetches.
        $script:KvCalls | Should -Be 6
    }
}

Describe 'Xdr.Common.Auth — Private fns: Complete-TotpMfa-SharePoint exists' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'Private/Complete-TotpMfa-SharePoint.ps1 exists with MaxRedirection=30 (SharePoint MFA dance)' {
        $path = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Private/Complete-TotpMfa-SharePoint.ps1'
        Test-Path $path | Should -BeTrue
        $content = Get-Content -Raw $path
        # The SharePoint variant uses MaximumRedirection=30
        $content | Should -Match 'MaximumRedirection\s+30'
        # The 3 Entra form_post sites in Complete-CredentialsFlow/Complete-PasskeyFlow/Complete-TotpMfa
        # remain at MaximumRedirection=0 (Rule 7 — correct, NOT a bug).
        $entraSites = @(
            'Private/Complete-CredentialsFlow.ps1'
            'Private/Complete-PasskeyFlow.ps1'
            'Private/Complete-TotpMfa.ps1'
        )
        foreach ($p in $entraSites) {
            $f = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth' $p
            $c = Get-Content -Raw $f
            $c | Should -Match 'MaximumRedirection\s+0' -Because "$p must retain MaxRedirection=0 (Rule 7)"
        }
    }
}
