#Requires -Module Pester
# Locks B-26: Get-XdrCookieExpiry actually wired into the cache decision.
# Cache key is "<upn>::<host>". Cache hit when cookie expiry > now+RefreshBeforeMinutes.
# Cache miss (or -Force) calls Get-EntraEstsAuth ONE TIME and stores the result.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $ModulePath -Force

    # φ.AUTH.0 · Test isolation · use dedicated cache path so file-cache from prior tests
    # doesn't pollute Connect-DefenderPortal cache-wiring tests below.
    $env:XDR_SESSION_CACHE_PATH = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-cookie-expiry-test-" + [guid]::NewGuid().ToString('N') + ".json")

    function New-MockSessionWithCookie {
        param([datetime]$ExpiresUtc, [string]$Name = 'ESTSAUTHPERSISTENT')
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $cookie = [System.Net.Cookie]::new($Name, 'fake-value', '/', 'login.microsoftonline.com')
        $cookie.Expires = $ExpiresUtc.ToLocalTime()
        $session.Cookies.Add($cookie)
        $session
    }
}

Describe 'Get-XdrCookieExpiry — primitive correctness' {
    BeforeEach { Clear-XdrCookieCache }

    It 'returns the cookie expiry as UTC datetime' {
        $expected = [datetime]::UtcNow.AddDays(90)
        $session = New-MockSessionWithCookie -ExpiresUtc $expected
        $actual = Get-XdrCookieExpiry -Session $session
        $actual | Should -Not -BeNullOrEmpty
        $actual.Kind | Should -Be 'Utc'
        ($actual - $expected).TotalSeconds | Should -BeLessThan 2
    }

    It 'returns null when session has no priority cookies' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Get-XdrCookieExpiry -Session $session | Should -BeNullOrEmpty
    }

    It 'returns null when session is null' {
        Get-XdrCookieExpiry -Session $null | Should -BeNullOrEmpty
    }

    It 'returns earliest expiry across priority cookies (ESTSAUTHPERSISTENT > sccauth > ESTSAUTH)' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $earlier = [datetime]::UtcNow.AddHours(2)
        $later   = [datetime]::UtcNow.AddDays(90)
        $c1 = [System.Net.Cookie]::new('sccauth','v','/','security.microsoft.com')
        $c1.Expires = $earlier.ToLocalTime()
        $c2 = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','v','/','login.microsoftonline.com')
        $c2.Expires = $later.ToLocalTime()
        $session.Cookies.Add($c1); $session.Cookies.Add($c2)
        $actual = Get-XdrCookieExpiry -Session $session
        ($actual - $earlier).TotalSeconds | Should -BeLessThan 2
    }
}

Describe 'Connect-DefenderPortal — cache wiring (B-26 fix)' {
    BeforeEach {
        Clear-XdrCookieCache
        # φ.AUTH.0 · Also clear file cache · isolated from cross-runspace cache test pollution
        Remove-XdrSessionFromCache
        Mock -ModuleName Xdr.Auth Get-EntraEstsAuth {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $cookie = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','fresh','/','login.microsoftonline.com')
            $cookie.Expires = ([datetime]::UtcNow.AddDays(90)).ToLocalTime()
            $session.Cookies.Add($cookie)
            @{ Session=$session; State=$null; LastResponse=$null; AcquiredUtc=[datetime]::UtcNow; ClientId=$ClientId; PortalHost=$PortalHost }
        }
    }

    It 'cold start: calls Get-EntraEstsAuth exactly once and caches the result' {
        $creds = [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $r1 = Connect-DefenderPortal -Credentials $creds
        $r1.Session | Should -Not -BeNullOrEmpty
        $r1.Upn | Should -Be 'x@y'
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 1
    }

    It 'second call within cookie lifetime: cache hit, NO new Get-EntraEstsAuth call (locks B-26 wiring)' {
        $creds = [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $null = Connect-DefenderPortal -Credentials $creds
        $null = Connect-DefenderPortal -Credentials $creds
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 1
    }

    It 'evicts cache when cookie within 5 min of expiry (NOT 50-min hardcode)' {
        # Seed cache with a near-expiry cookie
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $cookie = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','near','/','login.microsoftonline.com')
        $cookie.Expires = ([datetime]::UtcNow.AddMinutes(2)).ToLocalTime()
        $session.Cookies.Add($cookie)
        InModuleScope Xdr.Auth -ScriptBlock {
            param($Cached) $script:SessionCache['x@y::security.microsoft.com'] = $Cached
        } -Parameters @{ Cached = @{ Session=$session; Upn='x@y'; PortalHost='security.microsoft.com'; TenantId=$null; AcquiredUtc=[datetime]::UtcNow } }

        $creds = [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $null = Connect-DefenderPortal -Credentials $creds
        # Should evict and call Get-EntraEstsAuth (new chain)
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 1
    }

    It '-Force always evicts cache, even with fresh cookie' {
        $creds = [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $null = Connect-DefenderPortal -Credentials $creds
        $null = Connect-DefenderPortal -Credentials $creds -Force
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 2
    }

    It 'throws on Passkey auth method (deferred to P2 per scope)' {
        $creds = [pscustomobject]@{ Upn='x@y'; AuthMethod='Passkey' }
        { Connect-DefenderPortal -Credentials $creds } | Should -Throw -ExpectedMessage '*Passkey*'
    }

    It 'cache is keyed by upn::host (different UPN = separate chain)' {
        $c1 = [pscustomobject]@{ Upn='a@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $c2 = [pscustomobject]@{ Upn='b@y'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $null = Connect-DefenderPortal -Credentials $c1
        $null = Connect-DefenderPortal -Credentials $c2
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 2
    }
}
