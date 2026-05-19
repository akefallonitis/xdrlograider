#Requires -Module Pester
# Locks: every Xdr.* module .psd1 passes Test-ModuleManifest AND every
# function declared in FunctionsToExport is actually defined in the .psm1.
# Catches the recurring "psd1 lies about its exports" failure class
# (e.g. the empty-module-shell trap from prior xdrlograider-v3).

BeforeDiscovery {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ModuleDir  = Join-Path $script:RepoRoot 'src\Modules'
    $script:Manifests  = @(Get-ChildItem -Path $script:ModuleDir -Filter '*.psd1' -Recurse | ForEach-Object {
        @{ Name = $_.BaseName; ManifestPath = $_.FullName; ModulePath = $_.Directory.FullName }
    })
}

Describe 'Module manifest validity' -Tag 'module-manifest' -ForEach $script:Manifests {

    It "<Name>.psd1 passes Test-ModuleManifest" {
        { Test-ModuleManifest -Path $ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It "<Name>.psd1 declares RootModule that exists" {
        $m = Import-PowerShellDataFile -Path $ManifestPath
        $root = Join-Path $ModulePath $m.RootModule
        Test-Path $root | Should -BeTrue
    }

    It "<Name>.psd1 FunctionsToExport every entry is defined in the .psm1" {
        $m = Import-PowerShellDataFile -Path $ManifestPath
        $declared = @($m.FunctionsToExport)
        if ($declared -contains '*') { return }   # wildcard exports are valid; skip
        $rootContent = Get-Content (Join-Path $ModulePath $m.RootModule) -Raw
        foreach ($fn in $declared) {
            $rootContent | Should -Match "function\s+$([regex]::Escape($fn))\b" -Because "$Name.psd1 declares '$fn' in FunctionsToExport but it's not defined in $($m.RootModule)"
        }
    }

    It "<Name>.psd1 every Export-ModuleMember in .psm1 matches a declared FunctionsToExport entry" {
        $m = Import-PowerShellDataFile -Path $ManifestPath
        $declared = @($m.FunctionsToExport)
        if ($declared -contains '*') { return }
        $rootContent = Get-Content (Join-Path $ModulePath $m.RootModule) -Raw
        $exports = [regex]::Matches($rootContent, "Export-ModuleMember[\s\S]*?-Function\s+([^\r\n#]+)")
        foreach ($e in $exports) {
            $names = $e.Groups[1].Value -split '[,\s`]+' | Where-Object { $_ -and $_ -notmatch '^[#`]' } |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
            foreach ($n in $names) {
                $declared | Should -Contain $n -Because "$Name.psm1 calls Export-ModuleMember -Function $n but $Name.psd1's FunctionsToExport doesn't list it"
            }
        }
    }
}
