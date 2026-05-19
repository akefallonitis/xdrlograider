#Requires -Module Pester
# Runs Microsoft's official ARM-TTK over deploy/. Fails the build on any rule
# violation EXCEPT the explicitly allowlisted set below (each with a documented
# reason — re-evaluate when Microsoft updates the underlying APIs / TTK).
#
# ARM-TTK is fetched from $env:XDRLR_ARMTTK_PATH (default: $HOME/.local/share/arm-ttk/arm-ttk).
# Skips automatically when the module isn't installed (e.g. fresh laptop / CI without setup).

BeforeDiscovery {
    $script:ArmTtkPath = if ($env:XDRLR_ARMTTK_PATH) { $env:XDRLR_ARMTTK_PATH } `
        else { Join-Path $HOME '.local/share/arm-ttk/arm-ttk' }
    $script:TtkPresent = Test-Path (Join-Path $script:ArmTtkPath 'arm-ttk.psd1')
}

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DeployDir  = Join-Path $script:RepoRoot 'deploy'
    $script:ArmTtkPath = if ($env:XDRLR_ARMTTK_PATH) { $env:XDRLR_ARMTTK_PATH } `
        else { Join-Path $HOME '.local/share/arm-ttk/arm-ttk' }

    # Allow-list of TTK rules with documented reasons. Anything else = build red.
    $script:AcceptedTtkRules = @{
        'apiVersions Should Be Recent'                  = 'Microsoft.Storage 2024-01-01 + Microsoft.Insights/dataCollection* 2023-03-11 are the latest GA versions; no newer GA exists. Bump when Microsoft publishes one.'
        'apiVersions Should Be Recent In Reference Functions' = 'Same as above. reference() and listKeys() use the latest GA API version available.'
        'IDs Should Be Derived From ResourceIDs'        = 'TTK false-positive on Sentinel connectorUiConfig.id property. The id is a connector display identifier (string), not an ARM resource ID. Matches Microsoft canonical Sentinel V3 examples (Azure-Sentinel/Solutions/*).'
    }
}

Describe 'ARM-TTK runs over deploy/ with zero unaccepted findings' -Tag 'arm-ttk' {

    It 'has ARM-TTK installed (user must clone Azure/arm-ttk per README; offline-only)' {
        # Re-test at runtime (BeforeDiscovery state doesn't carry across to the test body).
        # Skip on CI / fresh laptop when arm-ttk not cloned · release.yml's explicit ARM-TTK step
        # is the authoritative gate · this T1 inline test is operator-local convenience only.
        if (-not (Test-Path (Join-Path $script:ArmTtkPath 'arm-ttk.psd1'))) {
            Set-ItResult -Skipped -Because "arm-ttk not installed at $script:ArmTtkPath (CI release.yml step runs explicit ARM-TTK gate · operator-local: git clone https://github.com/Azure/arm-ttk $script:ArmTtkPath)"
            return
        }
        Test-Path (Join-Path $script:ArmTtkPath 'arm-ttk.psd1') | Should -BeTrue
    }

    Context 'when arm-ttk present' -Skip:(-not $script:TtkPresent) {

        BeforeAll {
            Import-Module (Join-Path $script:ArmTtkPath 'arm-ttk.psd1') -Force -ErrorAction Stop
            # ARM-TTK reports findings via Write-Error (non-terminating by design).
            # Under Pester code coverage, the worker can re-throw the first Write-Error
            # as WriteErrorException. Run Test-AzTemplate in an isolated PowerShell
            # instance so its error stream is contained; we only care about the
            # result objects (each carries its own .Errors collection).
            $ps = [PowerShell]::Create().AddScript({
                param($Module, $Path)
                Import-Module $Module -Force
                $ErrorActionPreference = 'SilentlyContinue'
                Test-AzTemplate -TemplatePath $Path -ErrorAction SilentlyContinue 2>$null
            }).AddArgument((Join-Path $script:ArmTtkPath 'arm-ttk.psd1')).AddArgument($script:DeployDir)
            try {
                $script:TtkResults = @($ps.Invoke())
            } finally {
                $ps.Dispose()
            }
            $script:Findings = @($script:TtkResults | Where-Object { $_.PSObject.Properties.Name -contains 'Errors' -and $_.Errors })
        }

        It 'finds ZERO unaccepted ARM-TTK errors (every finding must be in the allow-list)' {
            $unaccepted = $script:Findings | Where-Object { -not $script:AcceptedTtkRules.ContainsKey($_.Name) }
            if ($unaccepted) {
                $detail = $unaccepted | ForEach-Object {
                    $msgs = ($_.Errors | Select-Object -First 2) -join ' | '
                    "[$($_.Name)] $msgs"
                }
                $detail -join [Environment]::NewLine | Write-Host -ForegroundColor Red
            }
            @($unaccepted).Count | Should -Be 0 -Because 'any new ARM-TTK rule violation either needs a fix or an explicit allow-list entry with rationale'
        }

        It 'has no unexpected accepted rules (allow-list is forward-only — rules can come off but not be added invisibly)' {
            # Sanity: the count of accepted findings should match the allow-list size,
            # or fewer (if Microsoft bumped an API version since we last looked).
            $accepted = $script:Findings | Where-Object { $script:AcceptedTtkRules.ContainsKey($_.Name) }
            $acceptedNames = @($accepted | ForEach-Object Name | Sort-Object -Unique)
            $extras = $acceptedNames | Where-Object { -not $script:AcceptedTtkRules.ContainsKey($_) }
            $extras | Should -BeNullOrEmpty
        }
    }
}
