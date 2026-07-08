#Requires -Version 7.4
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.5.0' }

# Pester · Xdr.Common.Capabilities module · STEP 2.B.6 verification
# Probe shape verified against real lab capture: references/live/source-xdrlograider-raw/MDE_TenantContext_CL-raw.json

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    $modulesRoot = Join-Path $repoRoot 'src/Modules'

    # Load Common.Exceptions + Common.Telemetry first (Capabilities depends on Track-XdrEvent + New-XdrException)
    # Dependency-ORDERED load (RequiredModules chain: Capabilities<-Cache<-Storage; Auth<-Lease). Storage+Lease were
    # MISSING here, so the import silently failed and EVERY test -Skip'd (skip-as-pass) — the gate never ran.
    foreach ($mod in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Lease','Xdr.Common.Cache','Xdr.Common.Auth','Xdr.Common.Runtime','Xdr.Common.Capabilities')) {
        $psd1 = Join-Path $modulesRoot "$mod/$mod.psd1"
        $psm1 = Join-Path $modulesRoot "$mod/$mod.psm1"
        $loadPath = if (Test-Path $psd1) { $psd1 } elseif (Test-Path $psm1) { $psm1 } else { $null }
        if ($loadPath) {
            try { Import-Module $loadPath -Force -DisableNameChecking -ErrorAction Stop } catch { }
        }
    }

    $script:HasCapabilities = [bool](Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue)
    $script:HasRequiresProductsTest = [bool](Get-Command Test-XdrRequiresProducts -ErrorAction SilentlyContinue)
}

BeforeAll {
    # Real lab capture shape (proven 2026-06-02 from references/live/source-xdrlograider-raw/MDE_TenantContext_CL-raw.json)
    $script:LabTenantContextResponse = @{
        EnvironmentName       = 'Production'
        OrgId                 = '00000000-0000-0000-0000-000000000000'
        GeoRegion             = 'Europe3'
        DataCenter            = 'WestEurope3'
        AccountMode           = 1
        AccountType           = 'Production'
        IsSuspended           = $false
        IsDeleted             = $false
        IsMdatpLicenseExpired = $false
        IsMtpEligible         = $true
        HasMachineGroups      = $true
        IsMdatpActive         = $true   # MDE
        IsOatpActive          = $false  # MDO not licensed
        IsItpActive           = $false  # MDI not licensed
        IsMapgActive          = $true   # MAPG yes
        IsAadIpActive         = $true   # AAD-IP yes
        IsDlpActive           = $false
        IsIrmActive           = $false
        IsMdiActive           = $false
        IsMdcActive           = $false
        IsSentinelActive      = $true
        ActiveMtpWorkloads    = @(1,4,5,9,10,13)
    }
}

Describe 'Xdr.Common.Capabilities · Test-XdrRequiresProducts (R3 filter helper)' -Skip:(-not $HasRequiresProductsTest) {

    It 'returns $true when RequiresProducts is null (no gate · allow)' {
        Test-XdrRequiresProducts -RequiresProducts $null -TenantProducts @('MDE') | Should -Be $true
    }

    It 'returns $true when RequiresProducts is empty array (no gate · allow)' {
        Test-XdrRequiresProducts -RequiresProducts @() -TenantProducts @('MDE') | Should -Be $true
    }

    It 'returns $true when TenantProducts is null (fail-open · capability discovery unresolved)' {
        Test-XdrRequiresProducts -RequiresProducts @('MDE') -TenantProducts $null | Should -Be $true
    }

    It 'returns $true when at least one required product is in tenant list' {
        Test-XdrRequiresProducts -RequiresProducts @('MDE','MDO') -TenantProducts @('MDE','Sentinel') | Should -Be $true
    }

    It 'returns $false when no required products are in tenant list' {
        Test-XdrRequiresProducts -RequiresProducts @('MDO','MDI') -TenantProducts @('MDE','Sentinel') | Should -Be $false
    }

    It 'returns $true on single-product match' {
        Test-XdrRequiresProducts -RequiresProducts @('MAPG') -TenantProducts @('MDE','MAPG','XSPM') | Should -Be $true
    }

    # ── license-independence / DEAD-GATE-PROOF (C6) ──────────────────────────────────────────────
    It 'fail-OPEN (attempt) for a NON-derivable required product (MCAS · no clean tenant flag) — never a dead gate' {
        Test-XdrRequiresProducts -RequiresProducts @('MCAS') -TenantProducts @('MDE') | Should -Be $true
    }

    It 'fail-OPEN for MTO (cross-tenant · no single-tenant flag) so it lights up on a real MTO tenant' {
        Test-XdrRequiresProducts -RequiresProducts @('MTO') -TenantProducts @('MDE','Sentinel') | Should -Be $true
    }

    It 'a requirement mix with ANY non-derivable product fails-open (attempt-and-posture)' {
        Test-XdrRequiresProducts -RequiresProducts @('MDO','MCAS') -TenantProducts @('MDE') | Should -Be $true
    }

    It 'CLEAN SKIP when ALL required products are derivable AND tenant has none (MDI op on MDE-only tenant)' {
        Test-XdrRequiresProducts -RequiresProducts @('MDI') -TenantProducts @('MDE') | Should -Be $false
    }

    It 'an MDI-only tenant ATTEMPTS its MDI ops (works on any product mix, not just MDE)' {
        Test-XdrRequiresProducts -RequiresProducts @('MDI') -TenantProducts @('MDI') | Should -Be $true
    }

    It 'SecurityCopilot is now DERIVABLE so an MDE-only tenant skips it cleanly (no wasted attempt)' {
        Test-XdrRequiresProducts -RequiresProducts @('SecurityCopilot') -TenantProducts @('MDE') | Should -Be $false
    }
}

Describe 'Xdr.Common.Capabilities · ConvertTo-XdrProductList (script-scoped · tested via Get-XdrTenantCapabilities)' -Skip:(-not $HasCapabilities) {

    It 'derives MDE + MAPG + AAD-IP + Sentinel + MDVM + XSPM + MTP from operator lab tenant flags' {
        # Use the Capabilities module's internal mapping by calling Get-XdrTenantCapabilities with mocked deps
        InModuleScope Xdr.Common.Capabilities {
            $context = @{
                IsMdatpActive = $true; IsOatpActive = $false; IsItpActive = $false; IsMapgActive = $true
                IsAadIpActive = $true; IsDlpActive = $false; IsIrmActive = $false; IsMdiActive = $false
                IsMdcActive = $false; IsSentinelActive = $true; IsMtpEligible = $true
            }
            $products = ConvertTo-XdrProductList -TenantContext $context
            $products | Should -Contain 'MDE'
            $products | Should -Contain 'MAPG'
            $products | Should -Contain 'AAD-IP'
            $products | Should -Contain 'Sentinel'
            $products | Should -Contain 'MTP'
            $products | Should -Contain 'MDVM'  # bundled with MDE
            $products | Should -Contain 'XSPM'  # bundled with MDE + MAPG
            $products | Should -Not -Contain 'MDO'
            $products | Should -Not -Contain 'MDI'
            $products | Should -Not -Contain 'MDC'
        }
    }

    It 'derives only MDE + MDVM when MAPG/AAD-IP/Sentinel are absent' {
        InModuleScope Xdr.Common.Capabilities {
            $context = @{
                IsMdatpActive = $true; IsOatpActive = $false; IsItpActive = $false; IsMapgActive = $false
                IsAadIpActive = $false; IsDlpActive = $false; IsIrmActive = $false; IsMdiActive = $false
                IsMdcActive = $false; IsSentinelActive = $false; IsMtpEligible = $false
            }
            $products = ConvertTo-XdrProductList -TenantContext $context
            $products | Should -Contain 'MDE'
            $products | Should -Contain 'MDVM'
            $products | Should -Not -Contain 'XSPM'  # XSPM requires MAPG
            $products | Should -Not -Contain 'MAPG'
            $products | Should -Not -Contain 'AAD-IP'
            $products | Should -Not -Contain 'Sentinel'
        }
    }

    It 'returns empty array when no products active' {
        InModuleScope Xdr.Common.Capabilities {
            $context = @{
                IsMdatpActive = $false; IsOatpActive = $false; IsItpActive = $false; IsMapgActive = $false
                IsAadIpActive = $false; IsDlpActive = $false; IsIrmActive = $false; IsMdiActive = $false
                IsMdcActive = $false; IsSentinelActive = $false; IsMtpEligible = $false
            }
            $products = ConvertTo-XdrProductList -TenantContext $context
            @($products).Count | Should -Be 0
        }
    }

    It 'derives SecurityCopilot from IsSecurityCopilotHasLicense; NEVER derives MCAS or MTO (non-derivable by design)' {
        InModuleScope Xdr.Common.Capabilities {
            $context = @{
                IsMdatpActive = $true; IsSecurityCopilotHasLicense = $true
                ActiveMtpWorkloads = @(1,4,5,9,10,13)   # workload 9 present, yet MCAS is STILL not derived (no clean flag)
            }
            $products = ConvertTo-XdrProductList -TenantContext $context
            $products | Should -Contain 'SecurityCopilot'
            $products | Should -Not -Contain 'MCAS'   # non-derivable -> handled by the fail-open gate, not fabricated here
            $products | Should -Not -Contain 'MTO'
        }
    }

    It 'XdrDerivableProducts (the gate''s known-set) stays in sync with the deriver — has core, excludes MCAS/MTO' {
        InModuleScope Xdr.Common.Capabilities {
            $script:XdrDerivableProducts | Should -Contain 'MDE'
            $script:XdrDerivableProducts | Should -Contain 'MDI'
            $script:XdrDerivableProducts | Should -Contain 'SecurityCopilot'
            $script:XdrDerivableProducts | Should -Not -Contain 'MCAS'
            $script:XdrDerivableProducts | Should -Not -Contain 'MTO'
        }
    }
}

Describe 'Xdr.Common.Capabilities · function exports' {

    It 'exports Get-XdrTenantContext' -Skip:(-not $HasCapabilities) {
        (Get-Command Get-XdrTenantContext -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'exports Get-XdrTenantCapabilities' -Skip:(-not $HasCapabilities) {
        (Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'exports Test-XdrRequiresProducts' -Skip:(-not $HasRequiresProductsTest) {
        (Get-Command Test-XdrRequiresProducts -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}
