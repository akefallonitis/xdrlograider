#Requires -Module Pester
# φ.I · Build pipeline · ARM defenderSubAreas auto-sync + release.yml Build-SolutionPackage step
# Locks: Build-FunctionAppZip auto-syncs ARM from manifest · release.yml builds solution + uploads

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BuildScript    = Join-Path $script:RepoRoot 'tools\Build-FunctionAppZip.ps1'
    $script:ReleaseYaml    = Join-Path $script:RepoRoot '.github\workflows\release.yml'
    $script:ManifestPath   = Join-Path $script:RepoRoot 'manifests\defender.psd1'
    $script:ArmPath        = Join-Path $script:RepoRoot 'deploy\mainTemplate.json'
}

Describe 'φ.I · Build-FunctionAppZip · ARM defenderSubAreas auto-sync' -Tag 'phase-i' {

    It 'Build-FunctionAppZip.ps1 has Update-ArmDefenderSubAreas function' {
        $src = Get-Content -Raw -LiteralPath $script:BuildScript
        $src | Should -Match 'function Update-ArmDefenderSubAreas'
    }

    It 'Build-FunctionAppZip.ps1 has -SyncArmDefenderSubAreas param defaulting to $true' {
        $src = Get-Content -Raw -LiteralPath $script:BuildScript
        $src | Should -Match '\[bool\]\$SyncArmDefenderSubAreas\s*=\s*\$true'
    }

    It 'Update-ArmDefenderSubAreas reads manifest + writes ARM mainTemplate.json' {
        $src = Get-Content -Raw -LiteralPath $script:BuildScript
        $src.Contains("Get-Content -Raw -LiteralPath `$manifestPath") | Should -BeTrue
        $src.Contains("Set-Content -LiteralPath `$armPath") | Should -BeTrue
    }

    It 'ARM defenderSubAreas variable matches manifest SubArea distinct (drift-free)' {
        $manifest = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:ManifestPath)))
        $manifestSubAreas = @($manifest.Entries | ForEach-Object SubArea | Sort-Object -Unique)
        $arm = Get-Content -Raw -LiteralPath $script:ArmPath | ConvertFrom-Json
        $armSubAreas = @($arm.variables.defenderSubAreas | Sort-Object)
        $armSubAreas.Count | Should -Be $manifestSubAreas.Count
        for ($i = 0; $i -lt $manifestSubAreas.Count; $i++) {
            $armSubAreas[$i] | Should -Be $manifestSubAreas[$i] -Because "ARM defenderSubAreas[$i] must match manifest (drift)"
        }
    }
}

Describe 'φ.I · release.yml · Build-SolutionPackage step + Solution zip upload' -Tag 'phase-i' {

    It 'release.yml contains "Build Sentinel Solution V3 package" step' {
        $yml = Get-Content -Raw -LiteralPath $script:ReleaseYaml
        $yml | Should -Match 'Build Sentinel Solution V3 package'
        $yml | Should -Match 'Build-SolutionPackage\.ps1'
    }

    It 'release.yml packs Solution zip from dist/ into out/ for release upload' {
        $yml = Get-Content -Raw -LiteralPath $script:ReleaseYaml
        $yml | Should -Match 'cp dist/\*\.zip out/'
    }

    It 'release.yml still has T1 + ARM-TTK + module-contracts + cosign gates' {
        $yml = Get-Content -Raw -LiteralPath $script:ReleaseYaml
        $yml | Should -Match 'Run-Tests\.ps1 -Tier 1'
        $yml | Should -Match 'arm-ttk'
        $yml | Should -Match 'Validate-ModuleContracts'
        $yml | Should -Match 'cosign sign-blob'
    }
}
