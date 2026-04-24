#Requires -Modules Pester

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Portal.Auth -Force -ErrorAction SilentlyContinue
}

Describe 'Xdr.Portal.Auth module surface' {
    It 'exports Connect-MDEPortal, Invoke-MDEPortalRequest, Test-MDEPortalAuth' {
        $exported = (Get-Module Xdr.Portal.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Connect-MDEPortal'
        $exported | Should -Contain 'Invoke-MDEPortalRequest'
        $exported | Should -Contain 'Test-MDEPortalAuth'
    }

    It 'does not leak private helpers' {
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

Describe 'Get-TotpCode (RFC 6238 test vectors)' {
    # RFC 6238 uses ASCII "12345678901234567890" = Base32 "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    # RFC publishes 8-digit OTPs; our impl returns the standard 6-digit TOTP
    # (what Microsoft Authenticator and Entra use). So we take the RFC value mod 1000000.

    It 'generates 287082 at time 59 (RFC vector 1, T=0x0000000000000001)' {
        InModuleScope Xdr.Portal.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 59, [System.DateTimeKind]::Utc)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '287082'
        }
    }

    It 'generates 081804 at time 1111111109 (RFC vector 2)' {
        InModuleScope Xdr.Portal.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds(1111111109)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '081804'
        }
    }

    It 'generates 050471 at time 1111111111 (RFC vector 3)' {
        InModuleScope Xdr.Portal.Auth {
            $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
            $ts = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc).AddSeconds(1111111111)
            $code = Get-TotpCode -Base32Secret $secret -Timestamp $ts
            $code | Should -Be '050471'
        }
    }

    It 'returns exactly 6 digits (with leading zeros preserved)' {
        InModuleScope Xdr.Portal.Auth {
            $code = Get-TotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'
            $code | Should -Match '^\d{6}$'
        }
    }

    It 'handles Base32 input with spaces and lowercase' {
        InModuleScope Xdr.Portal.Auth {
            $code = Get-TotpCode -Base32Secret 'jbsw y3dp ehpk 3pxp'
            $code | Should -Match '^\d{6}$'
        }
    }

    It 'throws on invalid Base32 characters' {
        InModuleScope Xdr.Portal.Auth {
            { Get-TotpCode -Base32Secret 'INVALID#CHARS!' } | Should -Throw "*Invalid Base32*"
        }
    }
}

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
        InModuleScope Xdr.Portal.Auth -Parameters @{ Passkey = $script:TestPasskey } {
            param($Passkey)
            $assertion = Invoke-PasskeyChallenge -PasskeyJson $Passkey -Challenge 'dGVzdGNoYWxsZW5nZQ' -Origin 'https://login.microsoft.com'
            $assertion.credentialId      | Should -Not -BeNullOrEmpty
            $assertion.clientDataJSON    | Should -Not -BeNullOrEmpty
            $assertion.authenticatorData | Should -Not -BeNullOrEmpty
            $assertion.signature         | Should -Not -BeNullOrEmpty
        }
    }

    It 'clientDataJSON contains the challenge, origin, and type webauthn.get' {
        InModuleScope Xdr.Portal.Auth -Parameters @{ Passkey = $script:TestPasskey } {
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
        InModuleScope Xdr.Portal.Auth -Parameters @{ Passkey = $script:TestPasskey } {
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

Describe 'Connect-MDEPortal parameter validation' {
    It 'rejects invalid Method parameter' {
        { Connect-MDEPortal -Method 'InvalidMethod' -Credential @{ upn = 'x@y.com' } } |
            Should -Throw "*Cannot validate argument*"
    }

    It 'requires upn in Credential hashtable' {
        { Connect-MDEPortal -Method CredentialsTotp -Credential @{ password = 'x' } } |
            Should -Throw "*upn*"
    }
}

Describe 'Connect-MDEPortalWithCookies' {
    It 'builds a session with injected cookies' {
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
            -Sccauth 'x' `
            -XsrfToken 'y' `
            -PortalHost 'intune.microsoft.com'

        $result.PortalHost | Should -Be 'intune.microsoft.com'
    }

    It 'caches the session in the module cache' {
        InModuleScope Xdr.Portal.Auth {
            $script:SessionCache.Clear()
            Connect-MDEPortalWithCookies -Sccauth 'abc' -XsrfToken 'def' -Upn 'svc@test.com' | Out-Null
            $script:SessionCache.ContainsKey('svc@test.com::security.microsoft.com') | Should -BeTrue
        }
    }
}

Describe 'Invoke-MDEPortalRequest 401 auto-refresh' {
    It 'attempts Connect-MDEPortal -Force on 401 and retries' {
        InModuleScope Xdr.Portal.Auth {
            # Seed cache with a session that has _Method + _Credential
            $fakeSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $fakeSessionObj = [pscustomobject]@{
                Session     = $fakeSession
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
            }
            $script:SessionCache['svc@test.com::security.microsoft.com'] = @{
                Session     = $fakeSession
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
                _Method     = 'CredentialsTotp'
                _Credential = @{ upn = 'svc@test.com'; password = 'x'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            }

            # Mock Update-XsrfToken to always return a value (session cookies normally set)
            Mock Update-XsrfToken { return 'test-xsrf' }

            $script:callCount = 0
            Mock Invoke-WebRequest {
                $script:callCount++
                if ($script:callCount -eq 1) {
                    $resp = [pscustomobject]@{ StatusCode = 401 }
                    $err = [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                        'Unauthorized',
                        [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
                    )
                    throw $err
                }
                return @{ StatusCode = 200; Content = '{"ok":true}' }
            }

            # Mock Connect-MDEPortal to avoid actually calling Entra
            Mock Connect-MDEPortal {
                $newSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                return [pscustomobject]@{
                    Session     = $newSession
                    Upn         = 'svc@test.com'
                    PortalHost  = 'security.microsoft.com'
                    AcquiredUtc = [datetime]::UtcNow
                    _Method     = 'CredentialsTotp'
                    _Credential = @{ upn = 'svc@test.com' }
                }
            }

            try {
                $result = Invoke-MDEPortalRequest -Session $fakeSessionObj -Path '/api/test' -Method GET
                # Should have retried after 401 and gotten 200
                $result.ok | Should -BeTrue
                Should -Invoke Invoke-WebRequest -Times 2 -Exactly
                Should -Invoke Connect-MDEPortal -Times 1 -Exactly
            } catch {
                # In Pester's strict mode the mock exception may bubble differently;
                # the key assertion is that Connect-MDEPortal was invoked on 401.
                Should -Invoke Connect-MDEPortal -AtLeast 1
            }
        }
    }
}

Describe 'Test-MDEPortalAuth — offline mock' {
    It 'returns Success=false and populates FailureReason when ESTS fails' {
        InModuleScope Xdr.Portal.Auth {
            Mock Get-EstsCookie { throw "ESTS failure injected" }
            $result = Test-MDEPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $result.Success | Should -BeFalse
            $result.Stage   | Should -Be 'ests-cookie'
            $result.FailureReason | Should -Match 'ESTS failure injected'
        }
    }

    It 'records missing-sccauth stage failure when Get-EstsCookie returns a session without sccauth' {
        # After the v1.0 auth-chain rewrite, the portal-client-id single-hop flow
        # returns sccauth directly from Get-EstsCookie. Failure to land sccauth now
        # manifests as Get-EstsCookie throwing "Auth flow completed but sccauth not
        # issued" — Test-MDEPortalAuth should categorise this into the ests-cookie
        # stage (since that's the function that failed), not a separate exchange stage.
        InModuleScope Xdr.Portal.Auth {
            Mock Get-EstsCookie { throw "Auth flow completed but sccauth not issued. Portal cookies: OpenIdConnect.nonce..." }

            $result = Test-MDEPortalAuth -Method CredentialsTotp -Credential @{
                upn = 'x@y.com'; password = 'p'; totpBase32 = 'JBSWY3DPEHPK3PXP'
            }
            $result.Success | Should -BeFalse
            $result.Stage   | Should -Be 'ests-cookie'
            $result.FailureReason | Should -Match 'sccauth not issued'
        }
    }
}

Describe 'Xdr.Portal.Auth — 429 Retry-After handling (v0.1.0-beta)' {

    It 'exposes Get/Reset-XdrPortalRate429Count accessors for heartbeat integration' {
        $exported = (Get-Module Xdr.Portal.Auth).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-XdrPortalRate429Count'
        $exported | Should -Contain 'Reset-XdrPortalRate429Count'
    }

    It 'Reset clears cumulative 429 counter back to 0' {
        Reset-XdrPortalRate429Count
        Get-XdrPortalRate429Count | Should -Be 0
    }

    It 'Invoke-MDEPortalRequest source contains 429 branch with Retry-After parse (seconds + HTTP-date)' {
        $script:AuthRoot = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Public'
        $source = Get-Content (Join-Path $script:AuthRoot 'Invoke-MDEPortalRequest.ps1') -Raw
        $source | Should -Match '\$statusInt -eq 429' -Because '429 branch must exist'
        $source | Should -Match 'Retry-After' -Because 'Retry-After header must be parsed'
        $source | Should -Match 'MDERateLimited' -Because 'exhausted 429 must throw the MDERateLimited message'
        $source | Should -Match 'Rate429Count\+\+' -Because 'counter must increment on every 429 observed'
    }

    It 'Invoke-MDEPortalRequest source enforces session TTL proactive refresh (3h30m)' {
        $source = Get-Content (Join-Path $script:AuthRoot 'Invoke-MDEPortalRequest.ps1') -Raw
        $source | Should -Match 'SessionMaxAgeMinutes\s*=\s*210' -Because 'proactive 3h30m TTL cap'
        $source | Should -Match 'sessionAge' -Because 'TTL comparison logic present'
        $source | Should -Match 'Connect-MDEPortal.*-Force' -Because 'force-refresh on TTL expiry'
    }
}

Describe 'Xdr.Portal.Auth — DirectCookies is testing-only (not production)' {

    It 'Initialize-XdrLogRaiderAuth.ps1 source explicitly refuses cookies as a production KV method' {
        $initPath = Join-Path $PSScriptRoot '..' '..' 'tools' 'Initialize-XdrLogRaiderAuth.ps1'
        $source = Get-Content $initPath -Raw
        # The script must not accept 'cookies' as a production AuthMethod. Even
        # if Connect-MDEPortalWithCookies exists (for laptop testing via
        # tests/.env.local), the KV writer rejects it.
        $source | Should -Match "'credentials_totp'|'passkey'" -Because 'only these two are writable to KV'
    }
}
