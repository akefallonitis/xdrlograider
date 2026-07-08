#Requires -Version 7.4
# F1.4d · Get-XdrTenantCapabilities must accept ANY portal with a registered probe endpoint, NOT a closed
# [ValidateSet] of 5 hardcoded portals — so onboarding a portal = a DATA entry ($PortalProbeEndpoints, already a
# per-portal map), zero engine edits. An unregistered portal throws the onboard-by-DATA contract. Defender unchanged.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Lease','Xdr.Common.Cache','Xdr.Common.Auth','Xdr.Common.Runtime','Xdr.Common.Capabilities')) {
        Import-Module $m -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }
}

Describe 'F1.4d · Get-XdrTenantCapabilities · registry-driven portal validation (not a closed ValidateSet)' {
    It 'the $Portal param has NO closed [ValidateSet] (onboarding a portal = data, not an engine edit)' {
        $portalParam = (Get-Command Get-XdrTenantCapabilities).Parameters['Portal']
        $vs = $portalParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        $vs | Should -BeNullOrEmpty -Because 'a closed ValidateSet structurally blocks onboarding a portal as data'
    }
    It 'an UNREGISTERED portal (no probe endpoint) throws the onboard-by-DATA contract' {
        { Get-XdrTenantCapabilities -Portal 'NoSuchPortal' } | Should -Throw -ExpectedMessage '*probe endpoint*'
    }
    It 'a portal WITH a registered probe endpoint passes validation (not a parameter-binding rejection)' {
        # P2 single-SoT: onboard the test portal in the ONE registry (Runtime) — Capabilities reads its probe via Get-XdrPortalConfig.
        InModuleScope Xdr.Common.Runtime { $script:XdrPortalRegistry['TestPortal'] = @{ BaseUrl = 'https://test.example.com'; UrlGrammar = 'ApiProxy'; AuthMode = 'Cookie'; PartitionPrefix = 'TestPortal'; ProbeEndpoint = @{ SubPortal = 'x'; Path = '/y'; Method = 'GET' } } }
        try {
            $err = $null
            try { Get-XdrTenantCapabilities -Portal 'TestPortal' } catch { $err = $_ }
            if ($err) { $err.Exception.GetType().Name | Should -Not -Be 'ParameterBindingValidationException' -Because 'a registered portal must clear validation (downstream session failure is fine)' }
        } finally { InModuleScope Xdr.Common.Runtime { $script:XdrPortalRegistry.Remove('TestPortal') } }
    }
}
