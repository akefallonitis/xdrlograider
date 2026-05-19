#Requires -Module Pester
# Π11 ITER2-R2 · Connect-DefenderPortal + Connect-PurviewPortal must accept and pass-through
# AuthMethod=Passkey to Get-EntraEstsAuth (which dispatches to Complete-XdrPasskeyFlow). Prior
# state: Connect-DefenderPortal hard-threw "Only AuthMethod='CredentialsTotp' is wired" while
# ARM exposed Passkey selector + KV stored defender-passkey-pem · operator-facing footgun.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Capture what Get-EntraEstsAuth was called with · we never actually exercise the chain
    $script:LastEstsCall = $null
    Mock -ModuleName Xdr.Auth Get-EntraEstsAuth {
        param($Credential, $ClientId, $PortalHost, $RedirectUri, $AuthProfile, $AuthVersion, $Resource, $CodeChallenge, $TenantId, $CorrelationId, $Method)
        $script:LastEstsCall = @{
            Method     = $Method
            HasPasskey = $Credential.ContainsKey('passkey') -and $Credential.passkey
            CredKeys   = @($Credential.Keys)
            ClientId   = $ClientId
            PortalHost = $PortalHost
        }
        # Return a minimal viable session shape so caller doesn't crash
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $sess.Cookies.Add([System.Net.Cookie]::new('sccauth', 'mock-sccauth', '/', '.security.microsoft.com'))
        return @{
            Session     = $sess
            AcquiredUtc = [datetime]::UtcNow
        }
    }
    Mock -ModuleName Xdr.Auth Invoke-XdrKmsiSsoRefresh { return $null }   # force fresh-chain path
    Mock -ModuleName Xdr.Auth Read-XdrSessionFromCache { return $null }   # force fresh-chain path
    Mock -ModuleName Xdr.Auth Save-XdrSessionToCache { }                  # silence cache writes
    Mock -ModuleName Xdr.Auth Reset-XdrAuthCircuit { }                    # silence telemetry
    Mock -ModuleName Xdr.Auth Test-XdrAuthCircuitOpen { return $false }
}

Describe 'Π11 ITER2-R2 · Connect-DefenderPortal Passkey dispatch' -Tag 'tier1','unit' {

    BeforeEach {
        Clear-XdrCookieCache
        Clear-XdrAuthCircuit
        $script:LastEstsCall = $null
    }

    It 'CredentialsTotp method passes through (no regression for default path)' {
        $creds = [pscustomobject]@{
            Upn        = 'sa@tenant.test'
            Password   = 'p'
            TotpSecret = 'JBSWY3DPEHPK3PXP'
            AuthMethod = 'CredentialsTotp'
        }
        { Connect-DefenderPortal -Credentials $creds } | Should -Not -Throw
        $script:LastEstsCall.Method | Should -Be 'CredentialsTotp'
        $script:LastEstsCall.HasPasskey | Should -BeFalse
    }

    It 'Passkey method WITH PEM payload passes through to Get-EntraEstsAuth -Method Passkey' {
        $creds = [pscustomobject]@{
            Upn        = 'sa@tenant.test'
            Password   = 'p'
            TotpSecret = 'JBSWY3DPEHPK3PXP'
            AuthMethod = 'Passkey'
            Passkey    = [pscustomobject]@{
                credentialId  = 'sa@tenant.test'
                privateKeyPem = "-----BEGIN PRIVATE KEY-----`nfake`n-----END PRIVATE KEY-----"
                rpId          = 'login.microsoft.com'
            }
        }
        { Connect-DefenderPortal -Credentials $creds } | Should -Not -Throw
        $script:LastEstsCall.Method | Should -Be 'Passkey'
        $script:LastEstsCall.HasPasskey | Should -BeTrue
        $script:LastEstsCall.CredKeys | Should -Contain 'passkey'
    }

    It 'Passkey method WITHOUT PEM payload throws a clear actionable error (operator-grade)' {
        $creds = [pscustomobject]@{
            Upn        = 'sa@tenant.test'
            Password   = 'p'
            TotpSecret = 'JBSWY3DPEHPK3PXP'
            AuthMethod = 'Passkey'
            # Passkey field absent · simulates KV defender-passkey-pem missing/empty
        }
        { Connect-DefenderPortal -Credentials $creds } | Should -Throw '*requires Credentials.Passkey*'
        # Get-EntraEstsAuth must NOT have been reached
        $script:LastEstsCall | Should -BeNullOrEmpty
    }
}

Describe 'Π11 ITER2-R2 · Connect-PurviewPortal Passkey dispatch (parity with Defender)' -Tag 'tier1','unit' {

    BeforeEach {
        Clear-XdrCookieCache
        Clear-XdrAuthCircuit
        $script:LastEstsCall = $null
    }

    It 'CredentialsTotp passes through (no regression)' {
        $creds = [pscustomobject]@{
            Upn        = 'sa@tenant.test'
            Password   = 'p'
            TotpSecret = 'JBSWY3DPEHPK3PXP'
            AuthMethod = 'CredentialsTotp'
        }
        { Connect-PurviewPortal -Credentials $creds } | Should -Not -Throw
        $script:LastEstsCall.Method | Should -Be 'CredentialsTotp'
    }

    It 'Passkey reaches Get-EntraEstsAuth with -Method Passkey + passkey in credential hash' {
        $creds = [pscustomobject]@{
            Upn        = 'sa@tenant.test'
            Password   = 'p'
            TotpSecret = 'JBSWY3DPEHPK3PXP'
            AuthMethod = 'Passkey'
            Passkey    = [pscustomobject]@{
                credentialId  = 'sa@tenant.test'
                privateKeyPem = "-----BEGIN PRIVATE KEY-----`nfake`n-----END PRIVATE KEY-----"
                rpId          = 'login.microsoft.com'
            }
        }
        { Connect-PurviewPortal -Credentials $creds } | Should -Not -Throw
        $script:LastEstsCall.Method | Should -Be 'Passkey'
        $script:LastEstsCall.HasPasskey | Should -BeTrue
    }
}
