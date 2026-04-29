#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5 unit tests for the L1 portal-generic Entra-layer module
    Xdr.Common.Auth (iter-14.0 Phase 1).

.DESCRIPTION
    Migrated out of tests/unit/Xdr.Portal.Auth.Tests.ps1 when the monolithic
    Xdr.Portal.Auth was split into:
        - L1 Xdr.Common.Auth   (Entra primitives — TOTP, passkey, ESTS auth, KV)
        - L2 Xdr.Defender.Auth (Defender-portal-specific cookie exchange)
        - Xdr.Portal.Auth      (backward-compat shim re-exporting MDE-prefixed wrappers)

    Tests for crypto primitives (Get-TotpCode, Invoke-PasskeyChallenge) and the
    public Entra entry points (Get-EntraEstsAuth, Resolve-EntraInterruptPage,
    Get-XdrAuthFromKeyVault) that previously lived inside Xdr.Portal.Auth's
    InModuleScope now live here scoped to Xdr.Common.Auth.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Common.Auth -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Xdr.Common.Auth module surface
# ============================================================================
Describe 'Xdr.Common.Auth module surface' {
    It 'exports Get-EntraEstsAuth, Get-XdrAuthFromKeyVault, Resolve-EntraInterruptPage' {
        $exported = (Get-Module Xdr.Common.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-EntraEstsAuth'
        $exported | Should -Contain 'Get-XdrAuthFromKeyVault'
        $exported | Should -Contain 'Resolve-EntraInterruptPage'
    }

    It 'does not leak private helpers (Get-TotpCode, Invoke-PasskeyChallenge, Submit-EntraFormPost, Get-EntraConfigBlob)' {
        $exported = (Get-Module Xdr.Common.Auth).ExportedFunctions.Keys
        $exported | Should -Not -Contain 'Get-TotpCode'
        $exported | Should -Not -Contain 'Invoke-PasskeyChallenge'
        $exported | Should -Not -Contain 'Submit-EntraFormPost'
        $exported | Should -Not -Contain 'Get-EntraConfigBlob'
        $exported | Should -Not -Contain 'Complete-CredentialsFlow'
        $exported | Should -Not -Contain 'Complete-TotpMfa'
        $exported | Should -Not -Contain 'Complete-PasskeyFlow'
    }

    It 'has PowerShell 7.4+ requirement' {
        $manifest = Import-PowerShellDataFile -Path $script:ModulePath
        $manifest.PowerShellVersion | Should -Be '7.4'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }
}

# ============================================================================
#  Get-TotpCode (RFC 6238 test vectors) — private helper, scoped via InModuleScope
# ============================================================================
Describe 'Get-TotpCode (RFC 6238 test vectors)' {
    # RFC 6238 uses ASCII "12345678901234567890" = Base32 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    # RFC publishes 8-digit OTPs; our impl returns the standard 6-digit TOTP
    # (what Microsoft Authenticator and Entra use). So we take the RFC value mod 1000000.

    It 'generates 287082 at time 59 (RFC vector 1, T=0x0000000000000001)' {
        InModuleScope Xdr.Common.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 59, [System.DateTimeKind]::Utc)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '287082'
        }
    }

    It 'generates 081804 at time 1111111109 (RFC vector 2)' {
        InModuleScope Xdr.Common.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds(1111111109)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '081804'
        }
    }

    It 'generates 050471 at time 1111111111 (RFC vector 3)' {
        InModuleScope Xdr.Common.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds(1111111111)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '050471'
        }
    }

    It 'returns exactly 6 digits (with leading zeros preserved)' {
        InModuleScope Xdr.Common.Auth {
            $code = Get-TotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'
            $code | Should -Match '^\d{6}$'
        }
    }

    It 'handles Base32 input with spaces and lowercase' {
        InModuleScope Xdr.Common.Auth {
            $code = Get-TotpCode -Base32Secret 'jbsw y3dp ehpk 3pxp'
            $code | Should -Match '^\d{6}$'
        }
    }

    It 'throws on invalid Base32 characters' {
        InModuleScope Xdr.Common.Auth {
            { Get-TotpCode -Base32Secret 'INVALID#CHARS!' } | Should -Throw "*Invalid Base32*"
        }
    }
}

# ============================================================================
#  Invoke-PasskeyChallenge — private helper, scoped via InModuleScope
# ============================================================================
Describe 'Invoke-PasskeyChallenge' {
    BeforeAll {
        $curve = [System.Security.Cryptography.ECCurve]::CreateFromFriendlyName('nistP256')
        $ecdsa = [System.Security.Cryptography.ECDsa]::Create($curve)
        try {
            $script:TestPasskey = [pscustomobject]@{
                upn            = 'test@example.com'
                credentialId   = 'AAECAwQFBgcICQoLDA0ODw'
                privateKeyPem  = $ecdsa.ExportECPrivateKeyPem()
                rpId           = 'login.microsoft.com'
            }
        } finally {
            $ecdsa.Dispose()
        }
    }

    It 'produces an assertion with all four required fields' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Passkey = $script:TestPasskey } {
            param($Passkey)
            $assertion = Invoke-PasskeyChallenge -PasskeyJson $Passkey -Challenge 'dGVzdGNoYWxsZW5nZQ' -Origin 'https://login.microsoft.com'
            $assertion.credentialId      | Should -Not -BeNullOrEmpty
            $assertion.clientDataJSON    | Should -Not -BeNullOrEmpty
            $assertion.authenticatorData | Should -Not -BeNullOrEmpty
            $assertion.signature         | Should -Not -BeNullOrEmpty
        }
    }

    It 'clientDataJSON contains the challenge, origin, and type webauthn.get' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Passkey = $script:TestPasskey } {
            param($Passkey)
            $assertion = Invoke-PasskeyChallenge -PasskeyJson $Passkey -Challenge 'uniqueChallenge123' -Origin 'https://login.microsoft.com'

            $b64u = $assertion.clientDataJSON.Replace('-', '+').Replace('_', '/')
            $mod = $b64u.Length % 4
            if ($mod) { $b64u = $b64u + ('=' * (4 - $mod)) }
            $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64u)) | ConvertFrom-Json

            $json.type      | Should -Be 'webauthn.get'
            $json.challenge | Should -Be 'uniqueChallenge123'
            $json.origin    | Should -Be 'https://login.microsoft.com'
        }
    }

    It 'signature verifies against the same ECDSA key' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Passkey = $script:TestPasskey } {
            param($Passkey)
            $assertion = Invoke-PasskeyChallenge -PasskeyJson $Passkey -Challenge 'verifychallenge' -Origin 'https://login.microsoft.com'

            $fromB64u = {
                param([string] $t)
                $padded = $t.Replace('-', '+').Replace('_', '/')
                $mod = $padded.Length % 4
                if ($mod) { $padded = $padded + ('=' * (4 - $mod)) }
                return [Convert]::FromBase64String($padded)
            }

            $authData       = & $fromB64u $assertion.authenticatorData
            $clientDataJSON = & $fromB64u $assertion.clientDataJSON
            $signature      = & $fromB64u $assertion.signature
            $clientDataHash = [System.Security.Cryptography.SHA256]::HashData($clientDataJSON)

            $signedData = [byte[]]::new($authData.Length + $clientDataHash.Length)
            [array]::Copy($authData, 0, $signedData, 0, $authData.Length)
            [array]::Copy($clientDataHash, 0, $signedData, $authData.Length, $clientDataHash.Length)

            $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
            try {
                $ecdsa.ImportFromPem($Passkey.privateKeyPem)
                $verified = $ecdsa.VerifyData(
                    $signedData,
                    $signature,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence
                )
                $verified | Should -BeTrue
            } finally {
                $ecdsa.Dispose()
            }
        }
    }
}

# ============================================================================
#  Get-EntraEstsAuth parameter validation (public)
# ============================================================================
Describe 'Get-EntraEstsAuth parameter validation' {
    It 'rejects invalid Method parameter' {
        { Get-EntraEstsAuth -Method 'InvalidMethod' -Credential @{ upn='x@y.com' } `
            -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'security.microsoft.com' } |
            Should -Throw "*Cannot validate argument*"
    }

    It 'requires ClientId (mandatory parameter)' {
        # Mandatory params trigger a missing-parameter exception when omitted —
        # PowerShell's invocation engine raises ParameterBindingException.
        $err = $null
        try {
            Get-EntraEstsAuth -Method CredentialsTotp -Credential @{ upn='x@y.com' } `
                -PortalHost 'security.microsoft.com' -ErrorAction Stop
        } catch { $err = $_ }
        # Either the parameter binding fails or the function throws after binding —
        # either way we expect an error. Use -BeNullOrEmpty inverse to assert.
        $err | Should -Not -BeNullOrEmpty
    }

    It "throws when Credential lacks 'upn'" {
        {
            Get-EntraEstsAuth -Method CredentialsTotp -Credential @{ password='pw'; totpBase32='x' } `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'security.microsoft.com'
        } | Should -Throw "*upn*"
    }
}

# ============================================================================
#  Get-XdrAuthFromKeyVault — surface and snake_case alias coverage
# ============================================================================
Describe 'Get-XdrAuthFromKeyVault parameter validation' {
    It 'rejects invalid AuthMethod parameter' {
        { Get-XdrAuthFromKeyVault -VaultUri 'https://x.vault.azure.net' -AuthMethod 'NotAMethod' } |
            Should -Throw "*Cannot validate argument*"
    }

    It 'accepts CredentialsTotp + Passkey + DirectCookies plus snake_case aliases' {
        $cmd = Get-Command -Module Xdr.Common.Auth -Name Get-XdrAuthFromKeyVault
        $methodParam = $cmd.Parameters['AuthMethod']
        $vs = $methodParam.Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $vs.ValidValues | Should -Contain 'CredentialsTotp'
        $vs.ValidValues | Should -Contain 'Passkey'
        $vs.ValidValues | Should -Contain 'DirectCookies'
        $vs.ValidValues | Should -Contain 'credentials_totp'
        $vs.ValidValues | Should -Contain 'passkey'
        $vs.ValidValues | Should -Contain 'direct_cookies'
    }

    It 'returns shape {upn, password, totpBase32} for CredentialsTotp' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-AzKeyVaultSecret {
                param($VaultName, $Name, [switch]$AsPlainText)
                switch -Regex ($Name) {
                    '-upn$'      { return 'svc@test.com' }
                    '-password$' { return 'P@ssw0rd' }
                    '-totp$'     { return 'JBSWY3DPEHPK3PXP' }
                }
            }
            $r = Get-XdrAuthFromKeyVault -VaultUri 'https://my.vault.azure.net' -AuthMethod CredentialsTotp
            $r.upn        | Should -Be 'svc@test.com'
            $r.password   | Should -Be 'P@ssw0rd'
            $r.totpBase32 | Should -Be 'JBSWY3DPEHPK3PXP'
        }
    }

    It 'returns shape {upn, passkey} for Passkey method (snake_case alias)' {
        InModuleScope Xdr.Common.Auth {
            $passkeyJson = '{ "upn": "pk@test.com", "credentialId": "cid", "privateKeyPem": "-----BEGIN-----", "rpId": "login.microsoft.com" }'
            Mock Get-AzKeyVaultSecret {
                param($VaultName, $Name, [switch]$AsPlainText)
                if ($Name -like '*-passkey') { return $passkeyJson }
            }
            $r = Get-XdrAuthFromKeyVault -VaultUri 'https://my.vault.azure.net' -AuthMethod 'passkey'
            $r.upn         | Should -Be 'pk@test.com'
            $r.passkey.upn | Should -Be 'pk@test.com'
            $r.passkey.credentialId | Should -Be 'cid'
        }
    }

    It 'returns shape {upn, sccauth, xsrfToken} for DirectCookies (cookies-mode is testing-only)' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-AzKeyVaultSecret {
                param($VaultName, $Name, [switch]$AsPlainText)
                switch -Regex ($Name) {
                    '-upn$'     { return 'svc@test.com' }
                    '-sccauth$' { return 'fake-sccauth' }
                    '-xsrf$'    { return 'fake-xsrf' }
                }
            }
            $r = Get-XdrAuthFromKeyVault -VaultUri 'https://my.vault.azure.net' -AuthMethod DirectCookies
            $r.upn       | Should -Be 'svc@test.com'
            $r.sccauth   | Should -Be 'fake-sccauth'
            $r.xsrfToken | Should -Be 'fake-xsrf'
        }
    }
}

# ============================================================================
#  Resolve-EntraInterruptPage — PUBLIC L2-callable interrupt walker
# ============================================================================
Describe 'Resolve-EntraInterruptPage (public)' {
    It 'POSTs to /kmsi with LoginOptions=1 + type=28 when pgid=KmsiInterrupt' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    Content      = '<html>done</html>'
                    StatusCode   = 200
                    InputFields  = @()
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'KmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/kmsi' -and
                $Method -eq 'Post' -and
                $Body.LoginOptions -eq 1 -and
                $Body.type -eq 28
            }
            $result | Should -Not -BeNullOrEmpty
        }
    }

    It 'POSTs to /appverify with ContinueAuth=true when pgid=CmsiInterrupt' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    Content      = '<html>done</html>'
                    StatusCode   = 200
                    InputFields  = @()
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'CmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/appverify' -and
                $Method -eq 'Post' -and
                $Body.ContinueAuth -eq 'true'
            }
        }
    }

    It 'throws when ConvergedProofUpRedirect has iRemainingDaysToSkipMfaRegistration = 0' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest { }

            $state = [pscustomobject]@{
                pgid = 'ConvergedProofUpRedirect'
                iRemainingDaysToSkipMfaRegistration = 0
                sCtx = 'c'; sFT = 'f'; canary = 'cn'
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }
            } | Should -Throw "*MFA registration required*"
        }
    }
}
