#Requires -Version 7.4
# P1.2 D5 · Test-XdrSessionAlive's credential-presence guard MUST match Connect-XdrPortal's session-shape contract
# ($hasCookie = Sccauth OR Cookie · $hasBearer = AccessToken). Pre-fix it required 'Cookie' specifically, so a
# Sccauth-only cookie session AND every bearer (AccessToken) session failed liveness → reauth-every-cycle for any
# portal/path that doesn't also set 'Cookie' (latent for the 4 bearer portals). RED pre-fix.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
    $script:future = ([datetime]::UtcNow.AddHours(1)).ToString('o')
}

Describe 'P1.2 D5 · Test-XdrSessionAlive accepts Sccauth-only + bearer sessions (shape symmetry with Connect)' {
    It 'a Sccauth-only cookie session (no Cookie key) with a future ExpiresUtc is ALIVE' {
        Test-XdrSessionAlive -Portal 'Defender' -Session @{ Sccauth = 'abc'; ExpiresUtc = $script:future } | Should -BeTrue
    }
    It 'a bearer (AccessToken) session with a future ExpiresUtc is ALIVE' {
        Test-XdrSessionAlive -Portal 'Entra' -Session @{ AccessToken = 'jwt'; ExpiresUtc = $script:future } | Should -BeTrue
    }
    It 'a session with NO credential is DEAD (guard still rejects credential-less rows)' {
        Test-XdrSessionAlive -Portal 'Defender' -Session @{ ExpiresUtc = $script:future } | Should -BeFalse
    }
}
