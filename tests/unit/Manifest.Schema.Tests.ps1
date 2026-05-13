#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Manifest schema invariants — locks Phase 1 structure across rebuilds.

Describe 'manifests/defender.psd1 schema invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ManifestPath = Join-Path $script:RepoRoot 'manifests' 'defender.psd1'

        # Import via scriptblock-eval (manifest >95KB exceeds Import-PowerShellDataFile)
        $sb = [scriptblock]::Create((Get-Content -Raw $script:ManifestPath))
        $script:Manifest = & $sb

        $script:Phase1SubAreas = @(
            'action_center', 'attack_simulator', 'cloud_apps', 'configuration', 'data_lake',
            'endpoint_configuration', 'endpoint_devices', 'entity_pivots', 'exposure_management',
            'files', 'identity', 'multi_tenant', 'portal_services', 'secure_score',
            'sentinel_precision', 'streaming', 'threat_analytics', 'vulnerability_management'
        )
    }

    It 'has Defaults and Endpoints top-level keys' {
        $script:Manifest.Keys | Should -Contain 'Defaults'
        $script:Manifest.Keys | Should -Contain 'Endpoints'
    }

    It 'has exactly 493 endpoint entries (492 read + 1 synthetic TenantContext)' {
        $script:Manifest.Endpoints.Count | Should -Be 493
    }

    It 'covers all 18 Phase 1 sub-areas (excludes AH/AI/LR)' {
        $present = @($script:Manifest.Endpoints | ForEach-Object { $_['SubArea'] } | Sort-Object -Unique)
        $present.Count | Should -Be 18
        foreach ($s in $script:Phase1SubAreas) {
            $present | Should -Contain $s
        }
        # Wholesale-excluded
        $present | Should -Not -Contain 'advanced_hunting'
        $present | Should -Not -Contain 'alerts_incidents'
        $present | Should -Not -Contain 'live_response'
    }

    It 'every entry has EntryKey (unique per row)' {
        $keys = @($script:Manifest.Endpoints | ForEach-Object { $_['EntryKey'] })
        ($keys | Where-Object { -not $_ }).Count | Should -Be 0
        ($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
    }

    It 'every entry has the 7 mandatory fields' {
        $required = @('EntryKey','Stream','Path','Tier','SubArea','Slug','Availability')
        $missing = @()
        foreach ($e in $script:Manifest.Endpoints) {
            foreach ($f in $required) {
                if (-not $e.ContainsKey($f) -or [string]::IsNullOrWhiteSpace([string]$e[$f])) {
                    $missing += "$($e['EntryKey']) missing $f"
                }
            }
        }
        $missing.Count | Should -Be 0 -Because ($missing -join '; ')
    }

    It 'every Stream follows Defender_<PascalSubArea>_CL convention (Rule 5)' {
        $bad = @($script:Manifest.Endpoints | Where-Object {
            $_['Stream'] -notmatch '^Defender_[A-Z][A-Za-z0-9]+_CL$'
        })
        $bad.Count | Should -Be 0 -Because (($bad | Select-Object -First 3 | ForEach-Object { $_['Stream'] }) -join '; ')
    }

    It 'every entry has Availability=live (Rule 23 — license-gating is runtime)' {
        $nonLive = @($script:Manifest.Endpoints | Where-Object { $_['Availability'] -ne 'live' })
        $nonLive.Count | Should -Be 0
    }

    It 'MaxPages cap matches Rule 14 per-sub-area' {
        $expected = @{
            'vulnerability_management' = 1000
            'endpoint_devices'         = 200
            'cloud_apps'               = 200
            'identity'                 = 200
            'exposure_management'      = 200
        }
        foreach ($sub in $expected.Keys) {
            $sample = @($script:Manifest.Endpoints | Where-Object { $_['SubArea'] -eq $sub } | Select-Object -First 1)[0]
            $sample['MaxPages'] | Should -Be $expected[$sub] -Because "$sub MaxPages cap per Rule 14"
        }
    }

    It 'synthetic TenantContext entry present' {
        $tc = @($script:Manifest.Endpoints | Where-Object { $_['EntryKey'] -eq 'portal_services::GetTenantContext' })
        $tc.Count | Should -Be 1
        $tc[0]['Path'] | Should -Match 'sccManagement/mgmt/TenantContext'
    }

    It 'Custom Collection path corrected to /mtp/mdeCustomCollection (NOT /mtp/customDataCollection)' {
        $cc = @($script:Manifest.Endpoints | Where-Object { $_['Path'] -match 'CustomCollection|customDataCollection|mdeCustomCollection' })
        $cc.Count | Should -BeGreaterThan 0
        foreach ($e in $cc) {
            $e['Path'] | Should -Match '/mtp/mdeCustomCollection'
            $e['Path'] | Should -Not -Match '/mtp/customDataCollection'
        }
    }
}
