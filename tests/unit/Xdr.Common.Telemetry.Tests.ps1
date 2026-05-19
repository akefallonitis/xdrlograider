#Requires -Module Pester
# Xdr.Common.Telemetry · pure-function coverage for correlation-ID + Write-XdrTelemetry.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
}

Describe 'Set-XdrCorrelationId / Get-XdrCorrelationId' -Tag 'telemetry-pure' {
    It 'Set-XdrCorrelationId returns a fresh GUID when no arg given' {
        $id = Set-XdrCorrelationId
        $id | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    }
    It 'Set-XdrCorrelationId accepts an explicit ID and round-trips it via Get' {
        $explicit = '11111111-2222-3333-4444-555555555555'
        Set-XdrCorrelationId -CorrelationId $explicit
        Get-XdrCorrelationId | Should -Be $explicit
    }
    It 'Get-XdrCorrelationId auto-generates an ID on first call when none set' {
        # Force reset by reloading module
        Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
        $id = Get-XdrCorrelationId
        $id | Should -Match '^[0-9a-fA-F]{8}-'
    }
    It 'Multiple Get calls return the SAME ID until Set rotates' {
        Set-XdrCorrelationId -CorrelationId 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        (Get-XdrCorrelationId) | Should -Be (Get-XdrCorrelationId)
    }
    It 'Set rotates the ID (subsequent Get returns new value)' {
        Set-XdrCorrelationId -CorrelationId 'first-fixed-id-aaaa-bbbb-cccccccccccc'
        $second = Set-XdrCorrelationId   # auto-generate fresh
        $second | Should -Not -Be 'first-fixed-id-aaaa-bbbb-cccccccccccc'
        Get-XdrCorrelationId | Should -Be $second
    }
}

Describe 'Write-XdrTelemetry · structured event emission' -Tag 'telemetry-pure' {
    It 'is exported · param Level + Message + Properties + EventName' {
        $cmd = Get-Command Write-XdrTelemetry
        foreach ($p in @('Level','Message','Properties','EventName')) {
            $cmd.Parameters.Keys | Should -Contain $p
        }
    }
    It 'Level parameter is constrained to canonical 5 values' {
        $cmd = Get-Command Write-XdrTelemetry
        $vSet = $cmd.Parameters['Level'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                Select-Object -First 1
        $vSet | Should -Not -BeNullOrEmpty
        @($vSet.ValidValues) | Should -Contain 'Verbose'
        @($vSet.ValidValues) | Should -Contain 'Information'
        @($vSet.ValidValues) | Should -Contain 'Warning'
        @($vSet.ValidValues) | Should -Contain 'Error'
        @($vSet.ValidValues) | Should -Contain 'Critical'
    }
    It 'emits a log line containing the CorrelationId + EventName + Message' {
        Set-XdrCorrelationId -CorrelationId 'cid-trace-fixed-1234-5678'
        $output = Write-XdrTelemetry -Level 'Information' -Message 'unit-test event' -EventName 'TestSuite' 6>&1
        # Write-Host writes to information stream · capture via 6>&1 redirection
        $line = ($output | Out-String).Trim()
        $line | Should -Match 'TestSuite'
        $line | Should -Match 'unit-test event'
        $line | Should -Match 'cid-trace-fixed-1234-5678'
    }
    It 'merges custom Properties into the structured payload (φ.AUTH.4 · JSON line)' {
        Set-XdrCorrelationId -CorrelationId 'cid-trace-fixed-aaaa-bbbb'
        $output = Write-XdrTelemetry -Message 'test-with-props' -Properties @{ Portal='Defender'; Slug='TenantContext' } -EventName 'TestEvt' 6>&1
        $line = ($output | Out-String).Trim()
        # φ.AUTH.4 · payload is now JSON (Write-Information) · parse + assert
        $payload = $line | ConvertFrom-Json
        $payload.Portal | Should -Be 'Defender'
        $payload.Slug   | Should -Be 'TenantContext'
    }
    It 'auto-resolves EventName from caller when EventName param omitted' {
        function TestEvent-CallerNameResolution { Write-XdrTelemetry -Message 'auto-evt' 6>&1 }
        $output = TestEvent-CallerNameResolution
        $line = ($output | Out-String).Trim()
        # EventName should resolve to TestEvent-CallerNameResolution
        $line | Should -Match 'TestEvent-CallerNameResolution'
    }
}

Describe 'Module surface contract' -Tag 'telemetry-pure' {
    It 'exports exactly 3 functions (Set-XdrCorrelationId · Get-XdrCorrelationId · Write-XdrTelemetry)' {
        $m = Get-Module Xdr.Common.Telemetry
        $m | Should -Not -BeNullOrEmpty
        $exported = @($m.ExportedFunctions.Keys | Sort-Object)
        @($exported).Count | Should -Be 3
        $exported | Should -Contain 'Set-XdrCorrelationId'
        $exported | Should -Contain 'Get-XdrCorrelationId'
        $exported | Should -Contain 'Write-XdrTelemetry'
    }
}
