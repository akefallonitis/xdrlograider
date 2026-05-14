#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Locks the invariant: all 7 modules load cleanly in dep order with expected exports.

Describe 'Module load invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:LoadOrder = @(
            'Xdr.Common.Auth',
            'Xdr.Common.Manifest',
            'Xdr.Common.Telemetry',
            'Xdr.Defender.Auth',
            'Xdr.Defender.Client',
            'Xdr.Sentinel.Ingest',
            'Xdr.Connector.Orchestrator'
        )
    }

    It 'has exactly 7 modules (no V2 suffixes anywhere)' {
        $modulesDir = Join-Path $script:RepoRoot 'src' 'Modules'
        $dirs = @(Get-ChildItem -Path $modulesDir -Directory)
        $dirs.Count | Should -Be 7
        @($dirs | Where-Object { $_.Name -match 'V2' }).Count | Should -Be 0
    }

    It 'loads every module without errors' {
        foreach ($m in $script:LoadOrder) {
            $psd1 = Join-Path $script:RepoRoot 'src' 'Modules' $m "$m.psd1"
            { Import-Module $psd1 -Force -ErrorAction Stop } | Should -Not -Throw -Because "module $m should load"
        }
    }

    It 'Xdr.Defender.Client exports the 4 new public functions' {
        Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force
        $exports = @(Get-Command -Module Xdr.Defender.Client | Select-Object -ExpandProperty Name)
        $exports | Should -Contain 'Get-DefenderTenantContext'
        $exports | Should -Contain 'Get-XdrCustomCollectionRule'
        $exports | Should -Contain 'Get-XdrCustomCollectionRuleById'
        $exports | Should -Contain 'Get-XdrCustomCollectionModel'
    }

    It 'Xdr.Common.Auth contains the SharePoint MFA private fn' {
        $shp = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Private' 'Complete-TotpMfa-SharePoint.ps1'
        Test-Path $shp | Should -BeTrue
    }

    It 'Xdr.Sentinel.Ingest exports the Decision 18 circuit-breaker helper' {
        Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force
        $exports = @(Get-Command -Module Xdr.Sentinel.Ingest | Select-Object -ExpandProperty Name)
        $exports | Should -Contain 'Get-XdrCircuitBreakerNextState'
    }

    It 'Xdr.Defender.Client does NOT export the retired Invoke-MDETierPoll (v1 dead code)' {
        Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force
        $exports = @(Get-Command -Module Xdr.Defender.Client | Select-Object -ExpandProperty Name)
        $exports | Should -Not -Contain 'Invoke-MDETierPoll'
    }
}
