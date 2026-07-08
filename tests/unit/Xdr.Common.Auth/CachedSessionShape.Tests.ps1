#Requires -Version 7.4
# AU5 (audit 2026-06-12 · postdeploy-as-gate · LIVE-PROVEN 62903 lifetime occurrences): Connect-XdrPortal's
# fresh-auth path normalizes the per-portal handler's return through ConvertTo-XdrSessionHashtable (iter#18 — it
# "collapses pipeline-leak arrays"), but the L1/L2 CACHE-read path did NOT. When Get-XdrCachedSession returns a
# pipeline-leak [Object[]] (a cache layer emitting a stray object alongside the session), Connect returned that
# array → the caller's `Invoke-XdrPortalHttp -Session [hashtable]` binding threw
# ParameterBindingArgumentTransformationException ("Cannot convert System.Object[] to Hashtable") — the live
# intermittent poll failure (warm-cache cycles succeed; a leaky cache read fails). FIX: normalize $cached at the
# cache-read source (mirrors the fresh path), so Test-XdrSessionAlive AND the return both get a clean [hashtable].

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
    $script:future = ([datetime]::UtcNow.AddHours(1)).ToString('o')
}

Describe 'AU5 · Connect-XdrPortal normalizes a pipeline-leak [Object[]] cached session to a clean [hashtable]' {
    It 'a cache read that leaks an array @(stray, session) → Connect returns the SINGLE session hashtable (no Object[] binding fail)' {
        InModuleScope Xdr.Common.Auth {
            $sess = @{ Sccauth = 'live-cookie'; ExpiresUtc = ([datetime]::UtcNow.AddHours(1)).ToString('o'); Portal = 'Defender' }
            # the production leak shape: a stray pipeline object emitted alongside the session hashtable
            Mock Get-XdrCachedSession { ,@('stray-pipeline-leak', $sess) }
            Mock Test-XdrSessionAlive { $true }
            Mock Track-XdrEvent { }
            $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@contoso.com'
            $out = Connect-XdrPortal -Portal 'Defender'
            $out -is [hashtable] | Should -BeTrue -Because 'the cached return must be a clean hashtable, never an Object[]'
            $out.Sccauth        | Should -Be 'live-cookie'
            ($out -is [System.Array]) | Should -BeFalse
        }
    }
    It 'a clean single-hashtable cache hit still returns that hashtable (no regression)' {
        InModuleScope Xdr.Common.Auth {
            $sess = @{ Sccauth = 'c'; ExpiresUtc = ([datetime]::UtcNow.AddHours(1)).ToString('o'); Portal = 'Defender' }
            Mock Get-XdrCachedSession { $sess }
            Mock Test-XdrSessionAlive { $true }
            Mock Track-XdrEvent { }
            (Connect-XdrPortal -Portal 'Defender').Sccauth | Should -Be 'c'
        }
    }
}

# WS4.3 (audit 2026-06-14 · LIVE-PROVEN · GetEffectiveTenantGroup · the fresh-auth lease winner during reset+reauth
# cache churn): the FRESH-auth path leaked too — Save-XdrSession did `return Set-XdrCachedSession …`, and
# Set-XdrCachedSession returns the L2-write [bool] $resp.Success. Connect-XdrPortal calls Save-XdrSession UNCAPTURED
# then `return $session`, so the bool leaked → @($true, $session) = [Object[]] → the consumer's -Session [hashtable]
# bind threw ParameterBindingArgumentTransformationException. FIX: Save-XdrSession is VOID at the source (+ the
# fresh-path call is | Out-Null belt-and-suspenders). The AU5 test above covers the cache-read leak; this covers save.
Describe 'WS4.3 · Save-XdrSession is VOID (the L2-write bool can never leak into a caller pipeline)' {
    It 'returns NOTHING even though Set-XdrCachedSession returns a [bool] $true' {
        InModuleScope Xdr.Common.Auth {
            Mock Set-XdrCachedSession { $true }   # the L2-write success bool that used to leak through
            $out = Save-XdrSession -Portal 'Defender' -UPN 'svc@contoso.com' -Session @{ Sccauth = 'c' }
            $out | Should -BeNullOrEmpty -Because 'a save is a side-effect · propagating the bool is the pipeline leak'
        }
    }
    It 'the fresh-path tail pattern (uncaptured save THEN return $session) yields a SINGLE hashtable, not @($true,$session)' {
        InModuleScope Xdr.Common.Auth {
            Mock Set-XdrCachedSession { $true }
            $sess = @{ Sccauth = 'c'; Portal = 'Defender' }
            # mirror Connect-XdrPortal's fresh-auth tail exactly: an uncaptured Save-XdrSession, then return the session
            $captured = & { Save-XdrSession -Portal 'Defender' -UPN 'u' -Session $sess | Out-Null; $sess }
            $captured -is [hashtable]     | Should -BeTrue  -Because 'the consumer binds -Session [hashtable] · an Object[] throws'
            ($captured -is [System.Array]) | Should -BeFalse
        }
    }
}
