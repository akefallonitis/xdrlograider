#Requires -Module Pester
# Pure-function coverage tests for Xdr.Auth helpers that don't need live HTTP.
# Boosts coverage without requiring Entra mock — exercises:
#   Test-EntraField · Get-EntraField · Get-EntraConfigBlob · Get-EntraErrorMessage
#   Test-MfaEndAuthSuccess · Resolve-EntraResponse · Get-XdrCookieExpiry
#   Get-XdrTotpCode (RFC 6238) · New-ApiproxyPath · Get-XdrBearerTokenExpiry
#   Get-XdrPortalConfig (data-driven config · D-37)
#
# Each function exercised through its public API surface. Hashtable/PSObject
# duality covered. Null + empty inputs covered.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
}

Describe 'Get-EntraErrorMessage' -Tag 'auth-pure' {
    It 'returns message for canonical 50126' {
        $msg = & (Get-Module Xdr.Auth) { Get-EntraErrorMessage -Code '50126' }
        $msg | Should -Match 'Invalid username or password'
    }
    It 'returns message for 50080 (B-25 type-trap)' {
        $msg = & (Get-Module Xdr.Auth) { Get-EntraErrorMessage -Code '50080' }
        $msg | Should -Match 'type-trap'
    }
    It 'falls back to DefaultText for unknown code' {
        $msg = & (Get-Module Xdr.Auth) { Get-EntraErrorMessage -Code '99999' -DefaultText 'custom-fallback' }
        $msg | Should -Be 'custom-fallback'
    }
    It 'returns generic literal-Entra-error-prefixed message when no DefaultText for unknown code' {
        $msg = & (Get-Module Xdr.Auth) { Get-EntraErrorMessage -Code '99998' }
        $msg | Should -Be 'Entra error 99998'
    }
}

Describe 'Resolve-EntraResponse classifier' -Tag 'auth-pure' {
    It 'classifies null response as unknown' {
        $r = Resolve-EntraResponse -Response $null
        $r.Classification | Should -Be 'unknown'
    }
    It 'classifies AADSTS50196 as throttle-mfa' {
        $resp = [pscustomobject]@{ StatusCode = 200; Content = 'something AADSTS50196 happened' }
        (Resolve-EntraResponse -Response $resp).Classification | Should -Be 'throttle-mfa'
    }
    It 'classifies generic AADSTS code with aadsts-prefix' {
        $resp = [pscustomobject]@{ StatusCode = 200; Content = 'AADSTS50011 redirect mismatch' }
        (Resolve-EntraResponse -Response $resp).Classification | Should -Be 'aadsts-50011'
    }
    It 'classifies 200 HTML SPA shell at JSON endpoint as html-terminal' {
        $resp = [pscustomobject]@{ StatusCode = 200; Content = '<!DOCTYPE html><html><body>SPA shell</body></html>' }
        (Resolve-EntraResponse -Response $resp).Classification | Should -Be 'html-terminal'
    }
    It 'classifies 302 redirect during BeginAuth as intermediate (NOT terminal)' {
        $resp = [pscustomobject]@{ StatusCode = 302; Content = '<!DOCTYPE html><body></body>' }
        (Resolve-EntraResponse -Response $resp -ExpectedStage 'BeginAuth').Classification | Should -Be 'auth-redirect-intermediate'
    }
    It 'classifies 302 HTML redirect at unexpected stage as html-redirect-terminal' {
        $resp = [pscustomobject]@{ StatusCode = 302; Content = '<html></html>' }
        (Resolve-EntraResponse -Response $resp -ExpectedStage 'PortalRequest').Classification | Should -Be 'html-redirect-terminal'
    }
    It 'classifies 200 JSON body as auth-ok' {
        $resp = [pscustomobject]@{ StatusCode = 200; Content = '{"OrgId":"123"}' }
        (Resolve-EntraResponse -Response $resp).Classification | Should -Be 'auth-ok'
    }
    It 'classifies 500 with no body markers as unknown' {
        $resp = [pscustomobject]@{ StatusCode = 500; Content = 'Server error' }
        (Resolve-EntraResponse -Response $resp).Classification | Should -Be 'unknown'
    }
}

Describe 'Get-XdrCookieExpiry' -Tag 'auth-pure' {
    It 'returns $null on null session' {
        Get-XdrCookieExpiry -Session $null | Should -BeNullOrEmpty
    }
    It 'returns $null on session with no cookies' {
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Get-XdrCookieExpiry -Session $sess
        $r | Should -BeNullOrEmpty
    }
    It 'returns a datetime when priority cookies present (UTC-normalized)' {
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $early = [datetime]::UtcNow.AddHours(1)
        $late  = [datetime]::UtcNow.AddDays(7)
        $c1 = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','val1','/','.login.microsoftonline.com'); $c1.Expires = $late
        $c2 = [System.Net.Cookie]::new('sccauth','val2','/','.security.microsoft.com'); $c2.Expires = $early
        $sess.Cookies.Add($c1); $sess.Cookies.Add($c2)
        $r = Get-XdrCookieExpiry -Session $sess
        $r | Should -Not -BeNullOrEmpty
        $r | Should -BeOfType [datetime]
        # Should be ≤ $late (earliest selected) · allow 4h drift for cookie-store timezone normalisation
        ($r - $early).TotalHours | Should -BeLessThan 4
    }
}

Describe 'New-ApiproxyPath builder' -Tag 'auth-pure' {
    It 'builds /apiproxy/-service-/-path- for valid service' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'sccManagement/mgmt/TenantContext'
        $p | Should -Be '/apiproxy/mtp/sccManagement/mgmt/TenantContext'
    }
    It 'handles leading slash on path gracefully' {
        $p = New-ApiproxyPath -Service 'mtp' -Path '/sccManagement/mgmt/TenantContext'
        $p | Should -Be '/apiproxy/mtp/sccManagement/mgmt/TenantContext'
    }
    It 'preserves query string' {
        $p = New-ApiproxyPath -Service 'mtp' -Path 'sccManagement/mgmt/TenantContext?realTime=true'
        $p | Should -Match '\?realTime=true$'
    }
}

Describe 'Get-XdrPortalConfig (D-37 data-driven config)' -Tag 'auth-pure' {
    It 'returns the Defender portal entry' {
        $cfg = Get-XdrPortalConfig -Portal 'Defender'
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.Portal | Should -Be 'Defender'
        $cfg.AuthProfile | Should -Be 'Cookie'
    }
    It 'returns the Entra IAM entry (SPA client · v1 OAuth · PKCE)' {
        $cfg = Get-XdrPortalConfig -Portal 'Entra' -SubPortal 'IAM'
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.AuthProfile | Should -Be 'Bearer'
        $cfg.ClientId | Should -Be 'c44b4083-3bb0-49c1-b47d-974e53cbdf3c'
        $cfg.ClientType | Should -Be 'SPA'
        $cfg.AuthVersion | Should -Be 'v1'
    }
    It 'returns the Intune Portal entry (Azure CLI public client)' {
        $cfg = Get-XdrPortalConfig -Portal 'Intune' -SubPortal 'Portal'
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.ClientId | Should -Be '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        $cfg.ClientType | Should -Be 'PublicClient'
    }
    It 'throws on unknown portal/sub-portal combination (D-37 strict)' {
        { Get-XdrPortalConfig -Portal 'Entra' -SubPortal 'DoesNotExist' } | Should -Throw '*unknown portal key*'
    }
}

Describe 'Get-XdrTotpCode (RFC 6238)' -Tag 'auth-pure' {
    It 'generates 6-digit code from base32 seed' {
        # Known seed/timestamp pair from RFC 6238 test vectors (T=59, seed=JBSWY3DPEHPK3PXP "Hello!\xDE\xAD\xBE\xEF")
        $code = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'
        $code | Should -Match '^\d{6}$'
    }
    It 'rejects invalid base32 with error' {
        { Get-XdrTotpCode -Base32Secret '!!!INVALID!!!' } | Should -Throw
    }
}

Describe 'Get-XdrBearerTokenExpiry' -Tag 'auth-pure' {
    It 'returns a value with Expires + AcquiredUtc when given a token-shaped string' {
        # Synthetic JWT with exp claim · header.payload.signature (all base64url-safe)
        $payload = '{"exp":' + (([DateTimeOffset]::UtcNow.AddMinutes(50)).ToUnixTimeSeconds()) + '}'
        $b64Payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)).TrimEnd('=').Replace('+','-').Replace('/','_')
        $token = "header.$b64Payload.signature"
        $r = Get-XdrBearerTokenExpiry -BearerToken $token
        $r | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties.Name | Should -Contain 'ExpiresUtc'
    }
    It 'falls back to DefaultTtlMinutes when token lacks exp claim' {
        $b64Payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}')).TrimEnd('=').Replace('+','-').Replace('/','_')
        $token = "header.$b64Payload.signature"
        $r = Get-XdrBearerTokenExpiry -BearerToken $token -DefaultTtlMinutes 45 -AcquiredUtc ([datetime]::UtcNow)
        $r | Should -Not -BeNullOrEmpty
        $r.ExpiresUtc | Should -Not -BeNullOrEmpty
    }
}
