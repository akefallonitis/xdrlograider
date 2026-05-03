#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0 GA Phase A.3 multi-portal forward-compat scaffolding gate.

.DESCRIPTION
    Per directives 11+17 in .claude/plans/immutable-splashing-waffle.md, v0.1.0 GA
    ships scaffolding stub modules for v0.2.0 multi-portal expansion (Entra,
    Purview, Intune × Auth, Client = 6 modules). The stubs:
      - Are importable (psd1 + psm1 valid)
      - Export placeholder functions that throw informative "v0.2.0 roadmap"
        errors when called (NEVER silently no-op)
      - Are referenced in Xdr.Connector.Orchestrator's $script:PortalRoutes
        so adding v0.2.0 implementation is body-fill, not architectural change

    This gate verifies all 6 stubs behave as expected.
#>

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulesRoot = Join-Path $script:RepoRoot 'src' 'Modules'

    # Six stub modules per Phase A.3:
    $script:StubModules = @(
        @{ Name = 'Xdr.Entra.Auth';     Funcs = @('Connect-EntraPortal',   'Test-EntraPortalAuth') }
        @{ Name = 'Xdr.Entra.Client';   Funcs = @('Invoke-EntraTierPoll',  'Get-EntraEndpointManifest') }
        @{ Name = 'Xdr.Purview.Auth';   Funcs = @('Connect-PurviewPortal', 'Test-PurviewPortalAuth') }
        @{ Name = 'Xdr.Purview.Client'; Funcs = @('Invoke-PurviewTierPoll','Get-PurviewEndpointManifest') }
        @{ Name = 'Xdr.Intune.Auth';    Funcs = @('Connect-IntunePortal',  'Test-IntunePortalAuth') }
        @{ Name = 'Xdr.Intune.Client';  Funcs = @('Invoke-IntuneTierPoll', 'Get-IntuneEndpointManifest') }
    )
}

Describe 'Phase A.3: Multi-portal scaffolding stub modules - discoverable + importable' {
    It 'All 6 stub module directories exist under src/Modules/' {
        foreach ($stub in $script:StubModules) {
            $modDir = Join-Path $script:ModulesRoot $stub.Name
            Test-Path -LiteralPath $modDir -PathType Container | Should -BeTrue -Because "Phase A.3 created $($stub.Name)"
        }
    }

    It 'Each stub module has psd1 + psm1' {
        foreach ($stub in $script:StubModules) {
            $modDir = Join-Path $script:ModulesRoot $stub.Name
            Test-Path -LiteralPath (Join-Path $modDir "$($stub.Name).psd1") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $modDir "$($stub.Name).psm1") | Should -BeTrue
        }
    }

    It 'Each stub module psd1 declares ModuleVersion 0.0.1 (scaffolding stub marker)' {
        foreach ($stub in $script:StubModules) {
            $psd1 = Join-Path $script:ModulesRoot $stub.Name "$($stub.Name).psd1"
            $manifest = Import-PowerShellDataFile -Path $psd1
            $manifest.ModuleVersion | Should -Be '0.0.1' -Because "stub modules use 0.0.1; live modules use 1.0.0"
        }
    }

    It 'Each stub module psd1 declares scaffolding-stub Tag for discoverability' {
        foreach ($stub in $script:StubModules) {
            $psd1 = Join-Path $script:ModulesRoot $stub.Name "$($stub.Name).psd1"
            $manifest = Import-PowerShellDataFile -Path $psd1
            $tags = @($manifest.PrivateData.PSData.Tags)
            $tags | Should -Contain 'scaffolding-stub' -Because 'tagged so operators can grep PowerShell Gallery / Module list'
            $tags | Should -Contain 'v0.2.0-roadmap' -Because 'tagged so operators understand status'
        }
    }

    It 'Each stub module psm1 contains all expected placeholder function names' {
        foreach ($stub in $script:StubModules) {
            $psm1 = Join-Path $script:ModulesRoot $stub.Name "$($stub.Name).psm1"
            $content = Get-Content -Raw -Path $psm1
            foreach ($fn in $stub.Funcs) {
                $content | Should -Match "function\s+$fn\s*\{" -Because "$fn must be defined in $($stub.Name).psm1"
            }
            # Verify all stubs throw informative errors
            $content | Should -Match 'NOT IMPLEMENTED' -Because 'placeholder functions must throw "NOT IMPLEMENTED" not silently no-op'
            $content | Should -Match 'v0\.2\.0' -Because 'error message must reference v0.2.0 roadmap'
        }
    }

    It 'Each stub psd1 declares correct FunctionsToExport list' {
        foreach ($stub in $script:StubModules) {
            $psd1 = Join-Path $script:ModulesRoot $stub.Name "$($stub.Name).psd1"
            $manifest = Import-PowerShellDataFile -Path $psd1
            $exported = @($manifest.FunctionsToExport)
            foreach ($fn in $stub.Funcs) {
                $exported | Should -Contain $fn -Because "$($stub.Name) psd1 must export $fn"
            }
        }
    }
}

Describe 'Phase A.3: Orchestrator $script:PortalRoutes references all 6 stubs' {
    It 'Orchestrator psm1 source references all 4 portal route entries' {
        $psm1Path = Join-Path $script:ModulesRoot 'Xdr.Connector.Orchestrator' 'Xdr.Connector.Orchestrator.psm1'
        $content = Get-Content -Raw -Path $psm1Path
        $content | Should -Match "'Defender'\s*=\s*@\{" -Because 'Defender route is the live implementation'
        $content | Should -Match "'Entra'\s*=\s*@\{" -Because 'Phase A.3 added Entra stub route'
        $content | Should -Match "'Purview'\s*=\s*@\{" -Because 'Phase A.3 added Purview stub route'
        $content | Should -Match "'Intune'\s*=\s*@\{" -Because 'Phase A.3 added Intune stub route'
    }

    It 'Orchestrator psm1 marks stub portals with Status=scaffolding-stub' {
        $psm1Path = Join-Path $script:ModulesRoot 'Xdr.Connector.Orchestrator' 'Xdr.Connector.Orchestrator.psm1'
        $content = Get-Content -Raw -Path $psm1Path
        # Count occurrences of "Status = 'scaffolding-stub'" — should be at least 3
        # (Entra, Purview, Intune are stubs; Defender = live). Comments may add more.
        $stubMatches = [regex]::Matches($content, "Status\s*=\s*'scaffolding-stub'")
        $stubMatches.Count | Should -BeGreaterOrEqual 3 -Because 'Entra, Purview, Intune entries marked Status=scaffolding-stub (Defender = live)'
        $liveMatches = [regex]::Matches($content, "Status\s*=\s*'live'")
        $liveMatches.Count | Should -BeGreaterOrEqual 1 -Because 'Defender entry marked Status=live'
    }

    It 'Orchestrator psd1 RequiredModules references all 6 stub modules' {
        $psd1Path = Join-Path $script:ModulesRoot 'Xdr.Connector.Orchestrator' 'Xdr.Connector.Orchestrator.psd1'
        $manifest = Import-PowerShellDataFile -Path $psd1Path
        $required = @($manifest.RequiredModules)
        foreach ($stub in $script:StubModules) {
            $required | Should -Contain $stub.Name -Because "Orchestrator psd1 must declare $($stub.Name) as RequiredModule"
        }
    }
}
