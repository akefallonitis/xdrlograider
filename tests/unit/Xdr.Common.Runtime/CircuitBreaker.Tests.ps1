#Requires -Version 7.4
# Circuit breaker (F6 · plan §4.3) — open after N consecutive failures, cool down, half-open trial, close on success.
# Previously provisioned-but-unimplemented (the recovery/Verify D10 gates were vacuous · §31.3). These prove real logic.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

Describe 'Circuit breaker · Test-XdrCircuitClosed (cooldown logic · pure)' {
    It 'Closed → may run' { Test-XdrCircuitClosed -CircuitState @{ State = 'Closed' } | Should -BeTrue }
    It 'HalfOpen → may run' { Test-XdrCircuitClosed -CircuitState @{ State = 'HalfOpen' } | Should -BeTrue }
    It 'Open within cooldown → may NOT run' {
        Test-XdrCircuitClosed -CircuitState @{ State = 'Open'; OpenedUtc = ([DateTime]::UtcNow).ToString('o') } | Should -BeFalse
    }
    It 'Open past 15min cooldown → may run (half-open trial)' {
        Test-XdrCircuitClosed -CircuitState @{ State = 'Open'; OpenedUtc = ([DateTime]::UtcNow.AddMinutes(-20)).ToString('o') } | Should -BeTrue
    }
    It 'Open with unparseable OpenedUtc → fail-safe allow' {
        Test-XdrCircuitClosed -CircuitState @{ State = 'Open'; OpenedUtc = 'garbage' } | Should -BeTrue
    }
}

Describe 'Circuit breaker · Update-XdrCircuitState (transitions)' {
    BeforeEach {
        Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity { @{ Success = $true; StatusCode = 204 } }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
    }

    It 'failure AT threshold (5th) opens the breaker + emits Breaker.Opened' {
        Update-XdrCircuitState -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Success $false -CircuitState @{ State = 'Closed'; FailureCount = 4 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter { $Properties['State'] -eq 'Open' -and $Properties['FailureCount'] -eq 5 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -Times 1 -Exactly -ParameterFilter { $Name -eq 'Breaker.Opened' }
    }

    It 'failure BELOW threshold stays Closed + increments' {
        Update-XdrCircuitState -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Success $false -CircuitState @{ State = 'Closed'; FailureCount = 1 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter { $Properties['State'] -eq 'Closed' -and $Properties['FailureCount'] -eq 2 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -Times 0 -Exactly -ParameterFilter { $Name -eq 'Breaker.Opened' }
    }

    It 'success after Open closes the breaker (reset to 0) + emits Breaker.Closed' {
        Update-XdrCircuitState -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Success $true -CircuitState @{ State = 'Open'; FailureCount = 5; OpenedUtc = ([DateTime]::UtcNow).ToString('o') }
        Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter { $Properties['State'] -eq 'Closed' -and $Properties['FailureCount'] -eq 0 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Track-XdrEvent -Times 1 -Exactly -ParameterFilter { $Name -eq 'Breaker.Closed' }
    }

    It 'success when already Closed/0 is a no-op write (no churn)' {
        Update-XdrCircuitState -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Success $true -CircuitState @{ State = 'Closed'; FailureCount = 0 }
        Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 0 -Exactly
    }

    It 'CR1 · a FAILED half-open trial RE-STAMPS OpenedUtc=now (restarts the cooldown · no permanent half-open hammer)' {
        # Was: a failed trial KEPT the original OpenedUtc → after the first 15-min cooldown elapsed, every cycle
        # re-trialled (1,440 failing portal hits/day). The cooldown must restart on each failed trial.
        $old = ([DateTime]::UtcNow.AddMinutes(-30)).ToString('o')
        Update-XdrCircuitState -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' -Success $false -CircuitState @{ State = 'Open'; FailureCount = 5; OpenedUtc = $old }
        Should -Invoke -ModuleName Xdr.Common.Runtime Set-XdrTableEntity -Times 1 -Exactly -ParameterFilter {
            $Properties['State'] -eq 'Open' -and
            ([DateTime]::Parse($Properties['OpenedUtc'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) -gt [DateTime]::UtcNow.AddMinutes(-5))
        }
    }
}
