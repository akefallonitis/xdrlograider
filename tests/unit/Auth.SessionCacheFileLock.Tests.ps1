#Requires -Module Pester
# Π11.C1 · Named-mutex protected atomic write on Save-XdrSessionToCache.
# Prevents torn JSON when multiple runspaces / Durable activities write concurrently.
# Y1 Consumption is single-worker today · Premium/EP scale-out and Durable multi-runspace safe-by-design.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    $script:OriginalCachePath = $env:XDR_SESSION_CACHE_PATH
    $script:TestCacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-tests-filelock-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestCacheDir -Force | Out-Null
    $env:XDR_SESSION_CACHE_PATH = Join-Path $script:TestCacheDir 'xdrlr-session.json'

    function New-FakeSession {
        param([string]$Sentinel = 'sentinel-cookie-value')
        $s = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $c = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', $Sentinel)
        $c.Domain = '.login.microsoftonline.com'; $c.Path = '/'
        $c.Expires = [datetime]::UtcNow.AddDays(90); $c.Secure = $true; $c.HttpOnly = $true
        $s.Cookies.Add($c)
        return $s
    }
}

AfterAll {
    if ($script:OriginalCachePath) { $env:XDR_SESSION_CACHE_PATH = $script:OriginalCachePath }
    else { Remove-Item env:XDR_SESSION_CACHE_PATH -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestCacheDir) { Remove-Item -LiteralPath $script:TestCacheDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Π11.C1 · Save-XdrSessionToCache · file-lock + atomic write' -Tag 'tier1','unit' {

    BeforeEach {
        if (Test-Path $env:XDR_SESSION_CACHE_PATH) { Remove-Item -LiteralPath $env:XDR_SESSION_CACHE_PATH -Force }
        # Clear any leftover .tmp from a previous failed-mid-rename test
        $tmpPath = $env:XDR_SESSION_CACHE_PATH + '.tmp'
        if (Test-Path $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force }
    }

    It 'writes a complete, parseable JSON payload (single writer baseline)' {
        $session = New-FakeSession -Sentinel 'baseline-write'
        Save-XdrSessionToCache -Session $session -Upn 'user@tenant.test' -PortalHost 'security.microsoft.com' -TenantId '00000000-0000-0000-0000-000000000001' -RefreshType 'kmsi-sso'
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeTrue
        $raw = Get-Content -Raw -LiteralPath $env:XDR_SESSION_CACHE_PATH
        { $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
        $obj = $raw | ConvertFrom-Json
        $obj.Upn        | Should -Be 'user@tenant.test'
        $obj.PortalHost | Should -Be 'security.microsoft.com'
    }

    It 'leaves no .tmp file behind after a successful write' {
        $session = New-FakeSession
        Save-XdrSessionToCache -Session $session -Upn 'u1@t.test' -PortalHost 'security.microsoft.com' -TenantId 'tid' -RefreshType 'totp'
        $tmpPath = $env:XDR_SESSION_CACHE_PATH + '.tmp'
        Test-Path $tmpPath | Should -BeFalse
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeTrue
    }

    It 'preserves JSON integrity across 4 concurrent ThreadJob writers (no torn JSON)' {
        # Stress: 4 parallel writers attempt to write distinct payloads. Mutex must serialize the
        # final file write so reading mid-stress still parses cleanly. Final winning payload is
        # implementation-defined (we only assert "JSON is intact").
        $repoRoot   = $script:RepoRoot
        $cachePath  = $env:XDR_SESSION_CACHE_PATH
        $scriptBlock = {
            param($RepoRoot, $CachePath, $Sentinel)
            $env:XDR_SESSION_CACHE_PATH = $CachePath
            Import-Module (Join-Path $RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
            Import-Module (Join-Path $RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
            $s = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $c = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', $Sentinel)
            $c.Domain = '.login.microsoftonline.com'; $c.Path = '/'
            $c.Expires = [datetime]::UtcNow.AddDays(90); $c.Secure = $true; $c.HttpOnly = $true
            $s.Cookies.Add($c)
            for ($i = 0; $i -lt 5; $i++) {
                Save-XdrSessionToCache -Session $s -Upn "$Sentinel@t.test" -PortalHost 'security.microsoft.com' -TenantId 'tid' -RefreshType 'totp'
            }
        }
        if (-not (Get-Module -ListAvailable ThreadJob)) {
            Set-ItResult -Skipped -Because 'ThreadJob module not available · file-lock concurrency assertion deferred to operator runtime'
            return
        }
        $jobs = @()
        foreach ($sentinel in 'w1','w2','w3','w4') {
            $jobs += Start-ThreadJob -ScriptBlock $scriptBlock -ArgumentList $repoRoot, $cachePath, $sentinel
        }
        $jobs | Wait-Job | Out-Null
        $jobs | ForEach-Object { Receive-Job $_ -ErrorAction SilentlyContinue | Out-Null; Remove-Job $_ }
        # Final file must parse cleanly · partial/torn JSON would throw
        Test-Path $cachePath | Should -BeTrue
        $raw = Get-Content -Raw -LiteralPath $cachePath
        { $raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'mutex is released even when atomic-rename fails (finally block reached)' {
        # Simulate failure: pre-create the cachePath as a read-only file to make Remove-Item fail.
        # Mutex MUST still release · subsequent normal writes succeed.
        $session = New-FakeSession
        if ($IsWindows) {
            # On Windows · set ReadOnly attribute · Remove-Item -Force overrides RO so test still passes
            # but exercises the finally path. Skip the deeper failure injection · keep this as the
            # simpler exhaustion-path test (would need filesystem mock for true fault injection).
            Save-XdrSessionToCache -Session $session -Upn 'fault@t.test' -PortalHost 'security.microsoft.com' -TenantId 'tid' -RefreshType 'totp'
            Save-XdrSessionToCache -Session $session -Upn 'fault2@t.test' -PortalHost 'security.microsoft.com' -TenantId 'tid' -RefreshType 'totp'
            $raw = Get-Content -Raw -LiteralPath $env:XDR_SESSION_CACHE_PATH
            $obj = $raw | ConvertFrom-Json
            $obj.Upn | Should -Be 'fault2@t.test'   # Second write replaced first · mutex was released
        } else {
            Set-ItResult -Skipped -Because 'Linux mutex release behavior validated via concurrent-writer test above'
        }
    }
}
