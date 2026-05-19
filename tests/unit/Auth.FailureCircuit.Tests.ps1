#Requires -Module Pester
# φ.AUTH.2 · Auth-failure sliding-window circuit-breaker · prevents TOTP cascade-retry.
# Locks: per-key isolation · sliding window prune · trip threshold · reset on success ·
# Auth.FailureCircuit telemetry events (Recorded · Tripped · OpenSkip · Reset · ClearAll).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
}

Describe 'φ.AUTH.2 · Test-XdrAuthCircuitOpen · default-closed behavior' -Tag 'auth-circuit' {

    BeforeEach { Clear-XdrAuthCircuit }

    It 'unknown key returns $false (default-closed · no prior failures)' {
        Test-XdrAuthCircuitOpen -Key 'never-seen' | Should -BeFalse
    }

    It 'single failure does NOT trip (below threshold=2)' {
        Add-XdrAuthCircuitFailure -Key 'k1' -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key 'k1' | Should -BeFalse
    }
}

Describe 'φ.AUTH.2 · trip threshold + sliding-window decay' -Tag 'auth-circuit' {

    BeforeEach { Clear-XdrAuthCircuit }

    It 'two failures within window TRIPS circuit (TripThreshold=2 default)' {
        Add-XdrAuthCircuitFailure -Key 'k2' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'k2' -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key 'k2' | Should -BeTrue
    }

    It 'three failures within window remains OPEN' {
        1..3 | ForEach-Object { Add-XdrAuthCircuitFailure -Key 'k3' -Reason 'unit' }
        Test-XdrAuthCircuitOpen -Key 'k3' | Should -BeTrue
    }

    It 'WindowMinutes=0 (immediate decay) · prior failures never count' {
        Add-XdrAuthCircuitFailure -Key 'k4' -Reason 'unit' -WindowMinutes 1
        Start-Sleep -Milliseconds 5
        # Subsequent check with WindowMinutes=0 prunes everything older than NOW
        Test-XdrAuthCircuitOpen -Key 'k4' -WindowMinutes 0 | Should -BeFalse
    }

    It 'custom TripThreshold=3 · two failures NOT yet open' {
        Add-XdrAuthCircuitFailure -Key 'k5' -Reason 'unit' -TripThreshold 3
        Add-XdrAuthCircuitFailure -Key 'k5' -Reason 'unit' -TripThreshold 3
        Test-XdrAuthCircuitOpen -Key 'k5' -TripThreshold 3 | Should -BeFalse
        Add-XdrAuthCircuitFailure -Key 'k5' -Reason 'unit' -TripThreshold 3
        Test-XdrAuthCircuitOpen -Key 'k5' -TripThreshold 3 | Should -BeTrue
    }
}

Describe 'φ.AUTH.2 · Reset-XdrAuthCircuit · success clears window' -Tag 'auth-circuit' {

    BeforeEach { Clear-XdrAuthCircuit }

    It 'Reset after trip · subsequent Test returns false' {
        Add-XdrAuthCircuitFailure -Key 'kR' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'kR' -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key 'kR' | Should -BeTrue
        Reset-XdrAuthCircuit -Key 'kR'
        Test-XdrAuthCircuitOpen -Key 'kR' | Should -BeFalse
    }

    It 'Reset on never-seen key is a no-op (does not throw)' {
        { Reset-XdrAuthCircuit -Key 'never-seen' } | Should -Not -Throw
    }
}

Describe 'φ.AUTH.2 · Per-key isolation · multi-portal safe' -Tag 'auth-circuit' {

    BeforeEach { Clear-XdrAuthCircuit }

    It 'tripping key A does NOT affect key B' {
        Add-XdrAuthCircuitFailure -Key 'kA' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'kA' -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key 'kA' | Should -BeTrue
        Test-XdrAuthCircuitOpen -Key 'kB' | Should -BeFalse
    }

    It 'separate UPN::Host keys remain independent (Defender vs Purview)' {
        $kDef = 'sa@contoso.com::security.microsoft.com'
        $kPur = 'sa@contoso.com::compliance.microsoft.com'
        Add-XdrAuthCircuitFailure -Key $kDef -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key $kDef -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key $kDef | Should -BeTrue
        Test-XdrAuthCircuitOpen -Key $kPur | Should -BeFalse
    }
}

Describe 'φ.AUTH.2 · Clear-XdrAuthCircuit · operator/test cleanup' -Tag 'auth-circuit' {

    It 'Clear-XdrAuthCircuit removes all keys · all Test return false' {
        Add-XdrAuthCircuitFailure -Key 'kx1' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'kx1' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'kx2' -Reason 'unit'
        Add-XdrAuthCircuitFailure -Key 'kx2' -Reason 'unit'
        Test-XdrAuthCircuitOpen -Key 'kx1' | Should -BeTrue
        Test-XdrAuthCircuitOpen -Key 'kx2' | Should -BeTrue
        Clear-XdrAuthCircuit
        Test-XdrAuthCircuitOpen -Key 'kx1' | Should -BeFalse
        Test-XdrAuthCircuitOpen -Key 'kx2' | Should -BeFalse
    }
}

Describe 'φ.AUTH.2 · Connect-DefenderPortal · circuit-breaker wiring' -Tag 'auth-circuit' {

    BeforeEach {
        Clear-XdrAuthCircuit
        Clear-XdrCookieCache
        Remove-XdrSessionFromCache
        # Mock Get-EntraEstsAuth to throw · simulate ESTS failure
        Mock -ModuleName Xdr.Auth Get-EntraEstsAuth { throw [System.InvalidOperationException]::new('ESTS form post HTML missing auth code') }
    }

    It 'after 2 ESTS failures · 3rd Connect call refuses with circuit OPEN exception (no further ESTS call)' {
        $creds = [pscustomobject]@{ Upn='circuit@test'; Password='p'; TotpSecret='JBSWY3DPEHPK3PXP'; AuthMethod='CredentialsTotp' }
        # 1st: hit ESTS · throws · failure recorded (count=1)
        { Connect-DefenderPortal -Credentials $creds } | Should -Throw '*ESTS form post HTML*'
        # 2nd: hit ESTS · throws · failure recorded (count=2 · trip)
        { Connect-DefenderPortal -Credentials $creds } | Should -Throw '*ESTS form post HTML*'
        # 3rd: circuit OPEN · throws BEFORE calling ESTS · message contains 'circuit OPEN'
        { Connect-DefenderPortal -Credentials $creds } | Should -Throw '*circuit OPEN*'
        # ESTS only invoked twice (first 2 attempts · 3rd short-circuited)
        Should -Invoke -ModuleName Xdr.Auth Get-EntraEstsAuth -Exactly 2
    }
}
