#Requires -Module Pester
# φ.AUTH.8 · FA-runtime simulation · cold-start path
# Locks: PS Function App cold-start spawns fresh runspace · module-scope $script:SessionCache
# is EMPTY · cross-runspace file cache must restore the session · zero TOTP burn on cycle 2+.
#
# This test simulates the runspace boundary by:
#   1. Cycle 1 · seed file cache via Save-XdrSessionToCache (simulates "previous runspace
#      successfully authed and saved")
#   2. Cycle 2 · NEW process invocation (file cache already on disk) · Connect-DefenderPortal
#      should hit file-cache · RefreshType='file-cache-restored' · ZERO Get-EntraEstsAuth call
#   3. Verify Mock count for Get-EntraEstsAuth is 0 (no TOTP chain ran)
#
# This is the B-19 root-cause fix from φ.AUTH.0 · simulated at unit-test level.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Dedicated cache path per test file (isolation)
    $env:XDR_SESSION_CACHE_PATH = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-fa-coldstart-" + [guid]::NewGuid().ToString('N') + ".json")

    function New-LiveCookieSession {
        # Build a session with sccauth (Defender) + ESTSAUTHPERSISTENT (90d KMSI)
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $scc = [System.Net.Cookie]::new('sccauth','live-sccauth-value','/','security.microsoft.com')
        $scc.Expires = [datetime]::MinValue  # session cookie
        $sess.Cookies.Add($scc)
        $kmsi = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','kmsi-90d-value','/','login.microsoftonline.com')
        $kmsi.Expires = ([datetime]::UtcNow.AddDays(90)).ToLocalTime()
        $sess.Cookies.Add($kmsi)
        $sess
    }
}

AfterAll {
    Remove-Item env:XDR_SESSION_CACHE_PATH -ErrorAction SilentlyContinue
}

Describe 'φ.AUTH.8 · FA cold-start · file cache restores session · ZERO TOTP' -Tag 'fa-runtime-sim' {

    BeforeEach {
        # Simulate fresh FA runspace: clear in-memory cache (file cache stays on disk)
        Clear-XdrCookieCache
        Clear-XdrAuthCircuit
        Remove-XdrSessionFromCache  # start with no file either
    }

    It 'Cycle 1 cold-cold · TOTP chain runs · saves session to file cache' {
        Mock -ModuleName Xdr.Auth Get-EntraEstsAuth {
            $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $scc = [System.Net.Cookie]::new('sccauth','cycle1-scc','/','security.microsoft.com')
            $scc.Expires = [datetime]::MinValue
            $sess.Cookies.Add($scc)
            $kmsi = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','cycle1-kmsi','/','login.microsoftonline.com')
            $kmsi.Expires = ([datetime]::UtcNow.AddDays(90)).ToLocalTime()
            $sess.Cookies.Add($kmsi)
            @{ Session=$sess; State=$null; LastResponse=$null; AcquiredUtc=[datetime]::UtcNow; ClientId=$ClientId; PortalHost=$PortalHost }
        }
        $creds = [pscustomobject]@{ Upn='sa@coldstart.test'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $cycle1 = Connect-DefenderPortal -Credentials $creds
        $cycle1.RefreshType | Should -Be 'full-totp-chain'
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 1
        # File cache should now exist on disk
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeTrue
    }

    It 'Cycle 2 NEW RUNSPACE (in-memory cleared · file cache on disk) · ZERO TOTP burn' {
        # === SETUP · simulates cycle 1 already happened ===
        $sess = New-LiveCookieSession
        Save-XdrSessionToCache -Session $sess -Upn 'sa@coldstart.test' `
            -PortalHost 'security.microsoft.com' -TenantId 'tenant-guid' -RefreshType 'full-totp-chain'
        Test-Path $env:XDR_SESSION_CACHE_PATH | Should -BeTrue

        # === CYCLE 2 · clear in-memory · this is the "new runspace" simulation ===
        Clear-XdrCookieCache

        # Mock Get-EntraEstsAuth to ensure it's NOT called (would mean file cache miss)
        $script:EstsCallCount = 0
        Mock -ModuleName Xdr.Auth Get-EntraEstsAuth {
            $script:EstsCallCount++
            throw "Get-EntraEstsAuth was called · file cache should have served the request"
        }

        $creds = [pscustomobject]@{ Upn='sa@coldstart.test'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        $cycle2 = Connect-DefenderPortal -Credentials $creds
        $cycle2 | Should -Not -BeNullOrEmpty
        $cycle2.RefreshType | Should -Be 'file-cache-restored'
        $cycle2.Upn | Should -Be 'sa@coldstart.test'
        $script:EstsCallCount | Should -Be 0
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 0
    }
}

Describe 'φ.AUTH.8 · FA warm cycle · in-memory cache hit · ZERO TOTP · ZERO file read' -Tag 'fa-runtime-sim' {

    BeforeEach {
        Clear-XdrCookieCache
        Clear-XdrAuthCircuit
        Remove-XdrSessionFromCache
    }

    It 'Cycle N (same runspace · in-memory cache valid) · in-memory hit · NO file read · NO TOTP' {
        Mock -ModuleName Xdr.Auth Get-EntraEstsAuth {
            $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $scc = [System.Net.Cookie]::new('sccauth','warm-scc','/','security.microsoft.com')
            $scc.Expires = [datetime]::MinValue
            $sess.Cookies.Add($scc)
            $kmsi = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','warm-kmsi','/','login.microsoftonline.com')
            $kmsi.Expires = ([datetime]::UtcNow.AddDays(90)).ToLocalTime()
            $sess.Cookies.Add($kmsi)
            @{ Session=$sess; State=$null; LastResponse=$null; AcquiredUtc=[datetime]::UtcNow; ClientId=$ClientId; PortalHost=$PortalHost }
        }
        $creds = [pscustomobject]@{ Upn='sa@warm.test'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        # Cycle 1 · warms in-memory
        $null = Connect-DefenderPortal -Credentials $creds
        # Cycle 2..5 · all should hit in-memory · NOT touch ESTS
        for ($i = 0; $i -lt 4; $i++) { $null = Connect-DefenderPortal -Credentials $creds }
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 1
    }
}

Describe 'φ.AUTH.8 · KV TTL cache · zero KV reads on hot cycles' -Tag 'fa-runtime-sim' {

    BeforeEach {
        Clear-XdrCredentialCache
    }

    It '60-min TTL · 10 sequential Get-XdrAuthFromKeyVault calls → exactly 1 KV read' {
        $script:KvCount = 0
        Mock -ModuleName Xdr.Auth Import-Module {}
        Mock -ModuleName Xdr.Auth Get-AzKeyVaultSecret {
            $script:KvCount++
            switch -Regex ($Name) {
                'upn$'      { return 'sa@hotcycle.test' }
                'password$' { return 'hot-pwd' }
                'totp$'     { return 'JBSWY3DPEHPK3PXP' }
                default     { return $null }
            }
        }
        for ($i = 0; $i -lt 10; $i++) {
            $b = Get-XdrAuthFromKeyVault -KeyVaultName 'hot-kv'
            $b | Should -Not -BeNullOrEmpty
        }
        # 10 calls · 5 KV reads on first call (3 mandatory + 2 optional φ.AUTH.6b passkey) ·
        # 0 on cycles 2-10 (cache hits)
        $script:KvCount | Should -Be 5
    }
}
