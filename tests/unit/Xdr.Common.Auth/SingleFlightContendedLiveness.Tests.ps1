#Requires -Version 7.4
# AU2 RED pin (audit 2026-06-12) · the single-flight CONTENDED re-read must be liveness-checked, exactly like the
# primary cache path. Returning $cached unconditionally could hand back the SAME dead session that triggered the
# peer worker's reauth (the peer may still be mid-T2/T3, longer than the 5s wait) → repeated 440s + a re-populated
# dead L1. A dead contended re-read must FAIL LOUD (AuthChainBroken) so this cycle retries cleanly.

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@xdrtest.local'
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'AU2 · single-flight contended re-read is liveness-checked' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Auth Get-XdrCredentials { @{ UPN = 'svc@xdrtest.local'; Password = 'p'; TenantId = '00000000-0000-0000-0000-000000000001' } }
        Mock -ModuleName Xdr.Common.Auth Lock-XdrSingleFlight { $null }   # CONTENTION · a peer holds the lease
        Mock -ModuleName Xdr.Common.Auth Start-Sleep { }
        Mock -ModuleName Xdr.Common.Auth Track-XdrEvent { }
        Mock -ModuleName Xdr.Common.Auth Track-XdrException { }
    }
    It 'a DEAD contended re-read throws AuthChainBroken (NOT the dead session)' {
        # The cached session exists but is NOT alive on either the primary check or the contended re-read.
        Mock -ModuleName Xdr.Common.Auth Get-XdrCachedSession { @{ Portal = 'Defender'; Sccauth = 'dead'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Auth Test-XdrSessionAlive { $false }
        $err = { Connect-XdrPortal -Portal 'Defender' } | Should -Throw -PassThru
        $err.Exception.GetType().Name | Should -Be 'AuthChainBrokenException'
    }
}
