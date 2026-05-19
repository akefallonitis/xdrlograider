#Requires -Module Pester
# φ.AUTH.0 · Cross-runspace file-based session cache (v2 B-19 fix · TOTP cascade preempt)
# Locks: Save/Read-XdrSessionToCache round-trip · age cap · mismatch detection ·
# atomic-write pattern · cookie metadata preservation · corruption handling.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Use a test-specific cache path · isolated from any real session cache
    $script:OriginalCachePath = $env:XDR_SESSION_CACHE_PATH
    $script:TestCacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
    $env:XDR_SESSION_CACHE_PATH = Join-Path $script:TestCacheDir 'xdrlr-session.json'

    # Helper: build a fake session with cookies
    function New-FakeSession {
        param(
            [string]$EstsPersistentValue = 'fake-esau-persistent-value',
            [string]$SccauthValue = 'fake-sccauth-value',
            [int]$EstsPersistentDays = 90
        )
        $s = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $s.UserAgent = 'TestAgent/1.0'
        $c1 = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', $EstsPersistentValue)
        $c1.Domain = '.login.microsoftonline.com'
        $c1.Path = '/'
        $c1.Expires = [datetime]::UtcNow.AddDays($EstsPersistentDays)
        $c1.Secure = $true; $c1.HttpOnly = $true
        $s.Cookies.Add($c1)
        $c2 = [System.Net.Cookie]::new('sccauth', $SccauthValue)
        $c2.Domain = 'security.microsoft.com'
        $c2.Path = '/'
        # sccauth is a session cookie · Expires = MinValue
        $c2.Secure = $true; $c2.HttpOnly = $true
        $s.Cookies.Add($c2)
        return $s
    }
}

AfterAll {
    # Restore original cache path · clean up test dir
    if ($script:OriginalCachePath) {
        $env:XDR_SESSION_CACHE_PATH = $script:OriginalCachePath
    } else {
        Remove-Item env:XDR_SESSION_CACHE_PATH -ErrorAction SilentlyContinue
    }
    if (Test-Path $script:TestCacheDir) {
        Remove-Item -LiteralPath $script:TestCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'φ.AUTH.0 · Cross-runspace session cache · Save/Read round-trip' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'Save then Read returns equivalent session (round-trip)' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'test@example.com' -PortalHost 'security.microsoft.com' -TenantId 'tenant-guid' -RefreshType 'unit-test'
        $restored = Read-XdrSessionFromCache -Upn 'test@example.com' -PortalHost 'security.microsoft.com'
        $restored | Should -Not -BeNullOrEmpty
        $restored.Upn | Should -Be 'test@example.com'
        $restored.PortalHost | Should -Be 'security.microsoft.com'
        $restored.TenantId | Should -Be 'tenant-guid'
        $restored.RefreshType | Should -Be 'unit-test'
        $restored.Session | Should -Not -BeNullOrEmpty
    }

    It 'preserves all cookie metadata (Name/Value/Domain/Path/Expires/Secure/HttpOnly)' {
        $orig = New-FakeSession -EstsPersistentValue 'preserved-value-12345'
        Save-XdrSessionToCache -Session $orig -Upn 'p@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'p@x.com' -PortalHost 'security.microsoft.com'
        $cookies = @($restored.Session.Cookies.GetAllCookies())
        $cookies.Count | Should -Be 2
        $kmsi = $cookies | Where-Object Name -eq 'ESTSAUTHPERSISTENT' | Select-Object -First 1
        $kmsi.Value | Should -Be 'preserved-value-12345'
        $kmsi.Domain | Should -Be '.login.microsoftonline.com'
        $kmsi.Secure | Should -BeTrue
        $kmsi.HttpOnly | Should -BeTrue
        $kmsi.Expires | Should -BeGreaterThan ([datetime]::UtcNow.AddDays(80))
    }

    It 'preserves session cookies (Expires=MinValue · sccauth-style)' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'sess@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'sess@x.com' -PortalHost 'security.microsoft.com'
        $sccauth = $restored.Session.Cookies.GetAllCookies() | Where-Object Name -eq 'sccauth' | Select-Object -First 1
        $sccauth | Should -Not -BeNullOrEmpty
        $sccauth.Value | Should -Be 'fake-sccauth-value'
    }

    It 'preserves UserAgent' {
        $orig = New-FakeSession
        $orig.UserAgent = 'CustomUA/2.0'
        Save-XdrSessionToCache -Session $orig -Upn 'ua@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'ua@x.com' -PortalHost 'security.microsoft.com'
        $restored.Session.UserAgent | Should -Be 'CustomUA/2.0'
    }
}

Describe 'φ.AUTH.0 · Mismatch detection (security · prevents cross-tenant pollution)' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'returns null when Upn mismatch' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'tenantA@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'tenantB@x.com' -PortalHost 'security.microsoft.com'
        $restored | Should -BeNullOrEmpty
    }

    It 'returns null when PortalHost mismatch' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'same@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'same@x.com' -PortalHost 'compliance.microsoft.com'
        $restored | Should -BeNullOrEmpty
    }

    It 'returns null when cache file missing' {
        Remove-XdrSessionFromCache
        $restored = Read-XdrSessionFromCache -Upn 'nofile@x.com' -PortalHost 'security.microsoft.com'
        $restored | Should -BeNullOrEmpty
    }
}

Describe 'φ.AUTH.0 · Age cap (50-min D-25 safety)' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'returns null when cache age exceeds MaxAgeMinutes parameter' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'agetest@x.com' -PortalHost 'security.microsoft.com'
        # Read with MaxAgeMinutes=0 forces stale on any non-zero age
        Start-Sleep -Milliseconds 100
        $restored = Read-XdrSessionFromCache -Upn 'agetest@x.com' -PortalHost 'security.microsoft.com' -MaxAgeMinutes 0
        $restored | Should -BeNullOrEmpty
    }

    It 'returns session when age within default 50-min cap' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'fresh@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'fresh@x.com' -PortalHost 'security.microsoft.com'
        $restored | Should -Not -BeNullOrEmpty
    }
}

Describe 'φ.AUTH.0 · Corruption + recovery handling' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'returns null when cache file is corrupted JSON (logs warning · no throw)' {
        Set-Content -LiteralPath $env:XDR_SESSION_CACHE_PATH -Value '{ not valid json' -Encoding UTF8
        $restored = Read-XdrSessionFromCache -Upn 'corrupt@x.com' -PortalHost 'security.microsoft.com'
        $restored | Should -BeNullOrEmpty
    }

    It 'returns null when cache file is empty' {
        Set-Content -LiteralPath $env:XDR_SESSION_CACHE_PATH -Value '' -Encoding UTF8
        $restored = Read-XdrSessionFromCache -Upn 'empty@x.com' -PortalHost 'security.microsoft.com'
        $restored | Should -BeNullOrEmpty
    }

    It 'Remove-XdrSessionFromCache deletes the cache file (operator cleanup)' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'cleanup@x.com' -PortalHost 'security.microsoft.com'
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeTrue
        Remove-XdrSessionFromCache
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeFalse
    }
}

Describe 'φ.AUTH.0 · Atomic-write pattern (no partial-read race)' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'writes via .tmp + rename (no partial-state cache file)' {
        # Write a fake session · verify only final file exists (no leftover .tmp)
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'atomic@x.com' -PortalHost 'security.microsoft.com'
        $finalExists = Test-Path $env:XDR_SESSION_CACHE_PATH
        $tmpPath = "$($env:XDR_SESSION_CACHE_PATH).tmp"
        $tmpExists = Test-Path $tmpPath
        $finalExists | Should -BeTrue
        $tmpExists | Should -BeFalse  # tmp must be renamed away · no leftover
    }

    It 'overwriting an existing cache works (Save twice succeeds)' {
        $first = New-FakeSession -EstsPersistentValue 'first'
        Save-XdrSessionToCache -Session $first -Upn 'overwrite@x.com' -PortalHost 'security.microsoft.com'
        $second = New-FakeSession -EstsPersistentValue 'second'
        Save-XdrSessionToCache -Session $second -Upn 'overwrite@x.com' -PortalHost 'security.microsoft.com'
        $restored = Read-XdrSessionFromCache -Upn 'overwrite@x.com' -PortalHost 'security.microsoft.com'
        $kmsi = $restored.Session.Cookies.GetAllCookies() | Where-Object Name -eq 'ESTSAUTHPERSISTENT' | Select-Object -First 1
        $kmsi.Value | Should -Be 'second'
    }
}

Describe 'φ.AUTH.0 · Schema versioning (forward compat)' -Tag 'auth-cache' {
    BeforeEach { Remove-XdrSessionFromCache }

    It 'cache file declares SchemaVersion field for future migrations' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'schema@x.com' -PortalHost 'security.microsoft.com'
        $raw = Get-Content -Raw -LiteralPath $env:XDR_SESSION_CACHE_PATH | ConvertFrom-Json
        $raw.SchemaVersion | Should -Be '1.0'
    }

    It 'cache file includes cookie count (telemetry sanity check)' {
        $orig = New-FakeSession
        Save-XdrSessionToCache -Session $orig -Upn 'count@x.com' -PortalHost 'security.microsoft.com'
        $raw = Get-Content -Raw -LiteralPath $env:XDR_SESSION_CACHE_PATH | ConvertFrom-Json
        $raw.CookieCount | Should -Be 2
    }
}
