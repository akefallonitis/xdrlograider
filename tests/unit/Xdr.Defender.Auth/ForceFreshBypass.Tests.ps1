#Requires -Version 7.4
# R-ENGINE(2) · Connect-XdrPortal -Force must reach the handler's INNER cache (the self-heal safety net). Without
# __ForceFresh, a forced reauth (after a 440) re-returns the SAME stale cached session via the handler's T1 cache-hit
# → re-loops the 440 (the empty-UPN self-heal path that can't drop the L2 row). With __ForceFresh, the T1 cache-hit is
# skipped and the T2 KMSI silent re-mint fires → a FRESH sccauth (no TOTP). RED pre-fix: __ForceFresh returns the stale
# 'old' session because the T1 gate doesn't exist.

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

Describe 'R-ENGINE(2) · __ForceFresh bypasses the handler T1 cache-hit (self-heal cannot re-serve the stale session)' {
    It 'WITHOUT __ForceFresh → T1 cache hit returns the alive cached session' {
        InModuleScope Xdr.Defender.Auth {
            Mock Get-XdrCachedSession { @{ Sccauth = 'old'; ExpiresUtc = ([datetime]::UtcNow.AddHours(1)).ToString('o'); KmsiCookie = 'kmsi'; UPN = 'svc@x' } }
            Mock Refresh-DefenderSccauth { @{ Success = $true; Session = @{ Sccauth = 'REFRESHED-T2' } } }
            $r = Connect-DefenderPortal -Credentials @{ UPN = 'svc@x'; AuthMethod = 'TOTP' }
            $r['Sccauth'] | Should -Be 'old'
        }
    }
    It 'WITH __ForceFresh → skips T1, T2 silent re-mint returns a FRESH sccauth (not the stale one)' {
        InModuleScope Xdr.Defender.Auth {
            Mock Get-XdrCachedSession { @{ Sccauth = 'old'; ExpiresUtc = ([datetime]::UtcNow.AddHours(1)).ToString('o'); KmsiCookie = 'kmsi'; UPN = 'svc@x' } }
            Mock Refresh-DefenderSccauth { @{ Success = $true; Session = @{ Sccauth = 'REFRESHED-T2' } } }
            $r = Connect-DefenderPortal -Credentials @{ UPN = 'svc@x'; AuthMethod = 'TOTP'; __ForceFresh = $true }
            $r['Sccauth'] | Should -Be 'REFRESHED-T2'
        }
    }
}
