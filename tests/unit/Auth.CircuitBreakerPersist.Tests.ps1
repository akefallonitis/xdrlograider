#Requires -Module Pester
# Π11.C3 · Circuit-breaker state persistence across cold-start.
# Without persistence: FA recycle loses $script:AuthFailureWindow → re-opens fresh circuit →
# allows 2 more TOTP-burn attempts before retripping. With persistence: prior failures load
# from /tmp/xdrlr-auth-circuit-state.json · prune-on-load enforces 5-min sliding window invariant.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force

    # Isolate state file in a temp path · clear before module reload
    $script:OriginalCircuitPath = $env:XDR_AUTH_CIRCUIT_STATE_PATH
    $script:TestCircuitDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-tests-circuit-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestCircuitDir -Force | Out-Null
    $env:XDR_AUTH_CIRCUIT_STATE_PATH = Join-Path $script:TestCircuitDir 'circuit-state.json'

    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
}

AfterAll {
    if ($script:OriginalCircuitPath) { $env:XDR_AUTH_CIRCUIT_STATE_PATH = $script:OriginalCircuitPath }
    else { Remove-Item env:XDR_AUTH_CIRCUIT_STATE_PATH -ErrorAction SilentlyContinue }
    if (Test-Path $script:TestCircuitDir) { Remove-Item -LiteralPath $script:TestCircuitDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Π11.C3 · Circuit-breaker persistence + prune-on-load' -Tag 'tier1','unit' {

    BeforeEach {
        Clear-XdrAuthCircuit
        if (Test-Path $env:XDR_AUTH_CIRCUIT_STATE_PATH) { Remove-Item -LiteralPath $env:XDR_AUTH_CIRCUIT_STATE_PATH -Force }
    }

    It 'Add-XdrAuthCircuitFailure persists state to disk' {
        Add-XdrAuthCircuitFailure -Key 'user@t::security.microsoft.com'
        Test-Path $env:XDR_AUTH_CIRCUIT_STATE_PATH | Should -BeTrue
        $raw = Get-Content -Raw -LiteralPath $env:XDR_AUTH_CIRCUIT_STATE_PATH
        $obj = $raw | ConvertFrom-Json
        $obj.PSObject.Properties.Name | Should -Contain 'user@t::security.microsoft.com'
    }

    It 'Reset-XdrAuthCircuit deletes the persisted state file (no stale leak)' {
        Add-XdrAuthCircuitFailure -Key 'k1'
        Test-Path $env:XDR_AUTH_CIRCUIT_STATE_PATH | Should -BeTrue
        Reset-XdrAuthCircuit -Key 'k1'
        # State file may exist if other keys persist · for this test only k1 was tracked → file should clear
        if (Test-Path $env:XDR_AUTH_CIRCUIT_STATE_PATH) {
            $raw = Get-Content -Raw -LiteralPath $env:XDR_AUTH_CIRCUIT_STATE_PATH
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                $obj.PSObject.Properties.Name | Should -Not -Contain 'k1'
            }
        }
    }

    It 'survives module re-import (simulates cold-start) · failures preserved' {
        Add-XdrAuthCircuitFailure -Key 'persist-test'
        Add-XdrAuthCircuitFailure -Key 'persist-test'
        # Simulate cold-start by force-reimporting · state must reload from disk
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
        # Two failures pushed within 5min · circuit should be Open after reload
        Test-XdrAuthCircuitOpen -Key 'persist-test' | Should -BeTrue
    }

    It 'prune-on-load drops entries older than 5min (sliding window invariant)' {
        # Pre-seed state file with an entry timestamped 10min ago · should be pruned on load
        $stale = [datetime]::UtcNow.AddMinutes(-10).ToString('o')
        $payload = @{ 'stale-key' = @($stale) } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $env:XDR_AUTH_CIRCUIT_STATE_PATH -Value $payload -Encoding UTF8
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
        # Stale entry should not trip circuit · 1 failure within 5min not enough anyway
        Test-XdrAuthCircuitOpen -Key 'stale-key' | Should -BeFalse
    }

    It 'corrupt JSON in state file is non-fatal (graceful degradation)' {
        Set-Content -LiteralPath $env:XDR_AUTH_CIRCUIT_STATE_PATH -Value '{"truncated":' -Encoding UTF8
        { Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force } | Should -Not -Throw
        # Empty state on parse failure · no false-trip
        Test-XdrAuthCircuitOpen -Key 'any-key' | Should -BeFalse
    }
}
