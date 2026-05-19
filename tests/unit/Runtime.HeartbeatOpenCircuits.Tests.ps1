#Requires -Module Pester
# Π11.4g · OpenCircuits surfaced in heartbeat row · operator visibility without App Insights grep.
# Tests Write-Heartbeat parameter wiring · row schema includes OpenCircuits array · empty default.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psd1') -Force

    # Capture the row Write-Heartbeat would send · don't actually POST to DCE
    $script:CapturedRows = @()
    Mock -ModuleName Xdr.Ingest Send-ToDce {
        param($DceEndpoint, $DcrImmutableId, $StreamName, $Rows, $MaxRetries, $DlqHandler)
        $script:CapturedRows = @($Rows)
        return [pscustomobject]@{ Sent = $Rows.Count; Chunks = 1; Failed = 0; Dlq = 0 }
    }
}

Describe 'Π11.4g · Write-Heartbeat -OpenCircuits parameter wiring' -Tag 'tier1','unit' {

    BeforeEach {
        $script:CapturedRows = @()
    }

    It 'accepts -OpenCircuits string[] parameter without throwing' {
        { Write-Heartbeat -DceEndpoint 'https://test.dce' -DcrImmutableId 'dcr-x' -Status 'OK' -OpenCircuits @('ExposureManagement','CloudApps') } | Should -Not -Throw
    }

    It 'emits OpenCircuits array onto the heartbeat row' {
        Write-Heartbeat -DceEndpoint 'https://test.dce' -DcrImmutableId 'dcr-x' -Status 'OK' -OpenCircuits @('ExposureManagement','CloudApps')
        $script:CapturedRows.Count | Should -Be 1
        $script:CapturedRows[0].OpenCircuits | Should -Not -BeNullOrEmpty
        $script:CapturedRows[0].OpenCircuits.Count | Should -Be 2
        $script:CapturedRows[0].OpenCircuits | Should -Contain 'ExposureManagement'
        $script:CapturedRows[0].OpenCircuits | Should -Contain 'CloudApps'
    }

    It 'defaults to empty array when -OpenCircuits omitted (no breaking change for old callers)' {
        Write-Heartbeat -DceEndpoint 'https://test.dce' -DcrImmutableId 'dcr-x' -Status 'OK'
        $script:CapturedRows.Count | Should -Be 1
        $row = $script:CapturedRows[0]
        $row.PSObject.Properties.Name | Should -Contain 'OpenCircuits'
        @($row.OpenCircuits).Count | Should -Be 0
    }

    It 'empty array (-OpenCircuits @()) emits empty array · CircuitOpen flag stays separate' {
        Write-Heartbeat -DceEndpoint 'https://test.dce' -DcrImmutableId 'dcr-x' -Status 'OK' -CircuitOpen $false -OpenCircuits @()
        $row = $script:CapturedRows[0]
        @($row.OpenCircuits).Count | Should -Be 0
        $row.CircuitOpen | Should -BeFalse
    }

    It 'preserves all other heartbeat columns (Note · Status · SentLastCycle · CircuitOpen)' {
        Write-Heartbeat -DceEndpoint 'https://test.dce' -DcrImmutableId 'dcr-x' `
            -Status 'OK' -Note 'cycle complete' -SentLastCycle 42 -FailedLastCycle 1 `
            -CircuitOpen $true -OpenCircuits @('SubA','SubB')
        $row = $script:CapturedRows[0]
        $row.Status        | Should -Be 'OK'
        $row.Note          | Should -Be 'cycle complete'
        $row.SentLastCycle | Should -Be 42
        $row.FailedLastCycle | Should -Be 1
        $row.CircuitOpen   | Should -BeTrue
        @($row.OpenCircuits).Count | Should -Be 2
    }
}
