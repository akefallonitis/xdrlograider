#Requires -Version 7.4
# R-ENGINE(3) · ConvertTo-XdrProductList must be StrictMode-safe: a TenantContext hashtable that OMITS a product flag
# (a tenant lacking that product) must NOT throw PropertyNotFoundException. Pre-fix it DOT-accessed absent keys
# ($TenantContext.IsOatpActive …) which throws under `Set-StrictMode -Version Latest` (empirically confirmed: hashtable
# dot-access of an absent key throws), escaping Get-XdrTenantCapabilities → fail-open (products=$null → R3 let ALL ops
# through, license-independence silently degraded). RED pre-fix: the partial-context call throws.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth',
                     'Xdr.Common.OAuthBearer','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Capabilities',
                     'Xdr.Common.Runtime','Xdr.Defender.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'R-ENGINE(3) · ConvertTo-XdrProductList StrictMode-safe on a partial TenantContext (absent flags ≠ throw)' {
    It 'does NOT throw when product flags are OMITTED (tenant lacking a product)' {
        InModuleScope Xdr.Common.Capabilities {
            { ConvertTo-XdrProductList -TenantContext @{ IsMdatpActive = $true } } | Should -Not -Throw
        }
    }
    It 'returns the present products (MDE + derived MDVM) and not the absent ones' {
        InModuleScope Xdr.Common.Capabilities {
            $r = ConvertTo-XdrProductList -TenantContext @{ IsMdatpActive = $true }
            $r | Should -Contain 'MDE'
            $r | Should -Contain 'MDVM'
            $r | Should -Not -Contain 'MDO'
        }
    }
    It 'returns empty (no throw) for a non-dictionary input (raw-string parse fallback)' {
        InModuleScope Xdr.Common.Capabilities {
            { ConvertTo-XdrProductList -TenantContext 'not-a-dict' } | Should -Not -Throw
            @(ConvertTo-XdrProductList -TenantContext 'not-a-dict').Count | Should -Be 0
        }
    }
}
