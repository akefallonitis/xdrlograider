#Requires -Version 7.4
# R-ENGINE(1) · Get-XdrCookieExpiry returns the REAL earliest cookie expiry — genuinely DYNAMIC per-cookie, NO static cap.
# Verified LIVE (2026-06-11): sccauth — the cookie sent to /apiproxy — is an opaque non-JWT SESSION cookie with NO
# server-declared Expires (Expires==MinValue → skipped), so its lifetime is unreadable anywhere; ESTSAUTHPERSISTENT's
# real ~90d KMSI expiry legitimately becomes ExpiresUtc. sccauth's shorter server-side death is handled REACTIVELY
# (401/440 → AuthChainBroken → Invoke-XdrAuthenticated self-heals via a T2 KMSI SILENT re-mint · NO TOTP · then retries),
# and the self-heal PRESERVES KMSI (Runtime · L1-only invalidation) so recovery stays TOTP-free until KMSI itself expires.
# This REPLACES the old static 110-min sccauth-ttl-cap (which only existed because the self-heal used to destroy KMSI →
# forcing a T3 TOTP burn on every reactive 440 · both root causes now fixed). Regression-lock for the dynamic contract.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@xdrtest.local'
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth',
                     'Xdr.Common.OAuthBearer','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Capabilities',
                     'Xdr.Common.Runtime','Xdr.Defender.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'R-ENGINE(1) · Get-XdrCookieExpiry is dynamic per-cookie (no static cap · real KMSI expiry)' {
    It 'returns the real ESTSAUTHPERSISTENT ~90d expiry when sccauth is a session cookie (NO cap · dynamic)' {
        InModuleScope 'Xdr.Defender.Auth' {
            $acq = [datetime]::UtcNow
            $ws  = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $persist = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT', 'kmsi-val', '/', 'login.microsoftonline.com')
            $persist.Expires = $acq.AddDays(90)
            $scc = [System.Net.Cookie]::new('sccauth', 'scc-val', '/', 'security.microsoft.com')   # session cookie · Expires=MinValue
            $ws.Cookies.Add($persist); $ws.Cookies.Add($scc)

            $r = Get-XdrCookieExpiry -WebSession $ws -PortalHost 'security.microsoft.com' -DefaultTtlMinutes 110 -AcquiredUtc $acq

            # NO cap → ExpiresUtc IS the real 90d KMSI expiry (dynamic per-cookie). sccauth's shorter death is handled
            # reactively (401/440 → T2 KMSI silent re-mint · no TOTP), NOT by a static-floor proactive re-mint.
            ($r.ExpiresUtc - $acq).TotalDays    | Should -BeGreaterThan 80
            ($r.KmsiExpiresUtc - $acq).TotalDays | Should -BeGreaterThan 80
            $r.EarliestExpirySource             | Should -Be 'ESTSAUTHPERSISTENT'
        }
    }
    It 'uses an already-short REAL sccauth expiry verbatim (dynamic · earliest real expiry wins)' {
        InModuleScope 'Xdr.Defender.Auth' {
            $acq = [datetime]::UtcNow
            $ws  = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $scc = [System.Net.Cookie]::new('sccauth', 'scc-val', '/', 'security.microsoft.com')
            $scc.Expires = $acq.AddMinutes(30)   # a real, short expiry → used verbatim (no cap, no lengthening)
            $ws.Cookies.Add($scc)
            $r = Get-XdrCookieExpiry -WebSession $ws -PortalHost 'security.microsoft.com' -DefaultTtlMinutes 110 -AcquiredUtc $acq
            ($r.ExpiresUtc - $acq).TotalMinutes | Should -BeLessOrEqual 31
            $r.EarliestExpirySource | Should -Be 'sccauth'
        }
    }
    It 'falls back to the configurable DefaultTtlMinutes ONLY when no priority cookie has any Expires' {
        InModuleScope 'Xdr.Defender.Auth' {
            $acq = [datetime]::UtcNow
            $ws  = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $scc = [System.Net.Cookie]::new('sccauth', 'scc-val', '/', 'security.microsoft.com')   # session-scope · no Expires
            $ws.Cookies.Add($scc)
            $r = Get-XdrCookieExpiry -WebSession $ws -PortalHost 'security.microsoft.com' -DefaultTtlMinutes 90 -AcquiredUtc $acq
            ($r.ExpiresUtc - $acq).TotalMinutes | Should -BeLessOrEqual 91
            ($r.ExpiresUtc - $acq).TotalMinutes | Should -BeGreaterThan 80
            $r.EarliestExpirySource | Should -Be 'default-ttl'
        }
    }
}
