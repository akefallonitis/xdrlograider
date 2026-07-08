#Requires -Version 7.4
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.5.0' }

# Pester · U2 LICENSE-INDEPENDENCE · plan §16.2 U2 + §16.3 (offline gate)
#
# WHAT THIS PROVES (verification only · NO runtime change):
#   The connector ships the SAME FA/zip to ANY operator tenant regardless of its Defender SKU/product mix.
#   License-independence is achieved by R3 dynamic capability discovery (Get-XdrTenantCapabilities at
#   cold-start → tenant Products list) feeding the 4-gate G-Capability dispatch filter (Test-XdrRequiresProducts).
#   This file pins that the R3 capability GATE behaves correctly across EVERY relevant SKU combination so a
#   minimal-license tenant still polls and a richer tenant polls more — with NO per-tenant code change.
#
#   The gate's three required behaviours (plan §16.2 U2 a/b/c):
#     (a) ADMIT  · RequiresProducts ∩ tenantProducts ≠ ∅  → op scheduled.
#     (b) SKIP   · RequiresProducts ∩ tenantProducts = ∅  → op not scheduled (license absent).
#     (c) FAIL-OPEN · tenantProducts null/empty (R3 discovery unresolved / minimal tenant) → ADMIT, so a
#                     minimal-license tenant still polls rather than silently dropping data.
#
# The gate predicate tested here is EXACTLY the one the production dispatcher applies — see the 4-gate
# G-Capability block in src/functions/XdrDefenderRefresh/run.ps1 (Test-XdrRequiresProducts -RequiresProducts
# $op.RequiresProducts -TenantProducts $tenantProducts → `continue` when $false). We re-derive the tenant
# Products list through the REAL ConvertTo-XdrProductList (the R3 flag→product mapper) per SKU combo, then
# drive the REAL gate, so this is an end-to-end license-independence proof of the discovery→gate path.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    $modulesRoot = Join-Path $repoRoot 'src/Modules'
    foreach ($mod in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Cache','Xdr.Common.Auth','Xdr.Common.Runtime','Xdr.Common.Capabilities')) {
        $psd1 = Join-Path $modulesRoot "$mod/$mod.psd1"
        $psm1 = Join-Path $modulesRoot "$mod/$mod.psm1"
        $loadPath = if (Test-Path $psd1) { $psd1 } elseif (Test-Path $psm1) { $psm1 } else { $null }
        if ($loadPath) { try { Import-Module $loadPath -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    $script:HasRequiresProductsTest = [bool](Get-Command Test-XdrRequiresProducts -ErrorAction SilentlyContinue)
    $script:HasCapabilities         = [bool](Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue)
}

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    # Re-import in the RUN phase (BeforeDiscovery's imports + $script: flags do NOT persist into BeforeAll/It).
    $modulesRoot = Join-Path $repoRoot 'src/Modules'
    foreach ($mod in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Cache','Xdr.Common.Auth','Xdr.Common.Runtime','Xdr.Common.Capabilities')) {
        $psd1 = Join-Path $modulesRoot "$mod/$mod.psd1"
        $psm1 = Join-Path $modulesRoot "$mod/$mod.psm1"
        $loadPath = if (Test-Path $psd1) { $psd1 } elseif (Test-Path $psm1) { $psm1 } else { $null }
        if ($loadPath) { try { Import-Module $loadPath -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    $script:HasCapabilities = [bool](Get-Command Get-XdrTenantCapabilities -ErrorAction SilentlyContinue)

    # The production G-Capability gate, isolated EXACTLY as src/functions/XdrDefenderRefresh/run.ps1 applies it:
    #   $allowed = Test-XdrRequiresProducts -RequiresProducts $op.RequiresProducts -TenantProducts $tenantProducts
    #   if (-not $allowed) { ...Track 'Entry.RequiresProducts.Skipped'... ; continue }
    # i.e. an op is DISPATCHED iff the gate returns $true. This wrapper returns the dispatch decision so the
    # tests assert the SAME boolean the dispatcher branches on.
    function Test-DispatchAllowed {
        param($RequiresProducts, $TenantProducts)
        return [bool](Test-XdrRequiresProducts -RequiresProducts $RequiresProducts -TenantProducts $TenantProducts)
    }

    # Resolve a tenant's R3 Products list from raw TenantContext flags THROUGH the real mapper (so the SKU
    # combos below are grounded in the actual flag→product taxonomy, not a hand-typed product list). Returns
    # @() when the mapper is unavailable (caller still exercises the gate with explicit product arrays).
    function Resolve-TenantProducts {
        param([hashtable] $Flags)
        if (-not $script:HasCapabilities) { return @() }
        return InModuleScope Xdr.Common.Capabilities -Parameters @{ Flags = $Flags } {
            param($Flags)
            @(ConvertTo-XdrProductList -TenantContext $Flags)
        }
    }

    # All-off baseline flag set; spread operators on top per SKU combo.
    $script:OffFlags = @{
        IsMdatpActive = $false; IsOatpActive = $false; IsItpActive = $false; IsMdiActive = $false
        IsMdcActive = $false; IsMapgActive = $false; IsAadIpActive = $false; IsDlpActive = $false
        IsIrmActive = $false; IsSentinelActive = $false; IsMtpEligible = $false
    }
    function New-SkuFlags { param([hashtable]$On) $f = $script:OffFlags.Clone(); foreach ($k in $On.Keys) { $f[$k] = $On[$k] }; return $f }

    # Representative tenant SKU profiles spanning minimal → rich. Each maps (via the real R3 mapper) to a
    # Products list; the comment states the products it should yield.
    $script:SkuProfiles = @{
        'MDE-only'        = (New-SkuFlags @{ IsMdatpActive = $true })                                            # → MDE, MDVM
        'MDO-only'        = (New-SkuFlags @{ IsOatpActive = $true })                                             # → MDO
        'MDI-only'        = (New-SkuFlags @{ IsMdiActive = $true })                                              # → MDI
        'MDC-only'        = (New-SkuFlags @{ IsMdcActive = $true })                                              # → MDC
        'MDE+MDO+MDI'     = (New-SkuFlags @{ IsMdatpActive = $true; IsOatpActive = $true; IsMdiActive = $true }) # → MDE,MDVM,MDO,MDI
        'MDE+MAPG (XSPM)' = (New-SkuFlags @{ IsMdatpActive = $true; IsMapgActive = $true })                      # → MDE,MAPG,MDVM,XSPM
        'E5-rich'         = (New-SkuFlags @{ IsMdatpActive = $true; IsOatpActive = $true; IsMdiActive = $true; IsMdcActive = $true; IsMapgActive = $true; IsAadIpActive = $true; IsSentinelActive = $true; IsMtpEligible = $true })
    }
}

Describe 'U2 · License-independence · R3 capability gate (Test-XdrRequiresProducts)' -Skip:(-not $HasRequiresProductsTest) {

    Context '(a) ADMIT · RequiresProducts ∩ tenantProducts ≠ ∅ · across SKU combos' {

        It 'admits an MDE op on every SKU profile that includes MDE' {
            foreach ($name in @('MDE-only','MDE+MDO+MDI','MDE+MAPG (XSPM)','E5-rich')) {
                $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles[$name]
                $tenant | Should -Contain 'MDE' -Because "$name profile must derive MDE"
                Test-DispatchAllowed -RequiresProducts @('MDE') -TenantProducts $tenant |
                    Should -BeTrue -Because "$name has MDE → the MDE op (ActionCenter.GetHistory class) must dispatch"
            }
        }

        It 'admits when ANY ONE of several RequiresProducts intersects (OR semantics)' {
            $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles['MDO-only']   # → MDO only
            # An op requiring MDE OR MDO must still admit on an MDO-only tenant (MDO satisfies the OR).
            Test-DispatchAllowed -RequiresProducts @('MDE','MDO') -TenantProducts $tenant | Should -BeTrue
        }

        It 'admits the MDE+MAPG-derived XSPM op on the XSPM SKU (bundled-product inference)' {
            $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles['MDE+MAPG (XSPM)']
            $tenant | Should -Contain 'XSPM'   # ConvertTo-XdrProductList infers XSPM from MDE+MAPG
            Test-DispatchAllowed -RequiresProducts @('XSPM') -TenantProducts $tenant | Should -BeTrue
        }

        It 'the SAME op definition dispatches on a rich tenant and on a minimal-matching tenant (no per-tenant code)' {
            $op = @{ OperationKey = 'GetHistory'; RequiresProducts = @('MDE') }   # one immutable op def
            $rich    = Resolve-TenantProducts -Flags $script:SkuProfiles['E5-rich']
            $minimal = Resolve-TenantProducts -Flags $script:SkuProfiles['MDE-only']
            Test-DispatchAllowed -RequiresProducts $op.RequiresProducts -TenantProducts $rich    | Should -BeTrue
            Test-DispatchAllowed -RequiresProducts $op.RequiresProducts -TenantProducts $minimal | Should -BeTrue
        }
    }

    Context '(b) SKIP · RequiresProducts ∩ tenantProducts = ∅ · license absent' {

        It 'skips an MDO-requiring op on an MDE-only tenant' {
            $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles['MDE-only']
            $tenant | Should -Not -Contain 'MDO'
            Test-DispatchAllowed -RequiresProducts @('MDO') -TenantProducts $tenant |
                Should -BeFalse -Because 'MDE-only tenant lacks MDO → the MDO op must NOT dispatch'
        }

        It 'skips an MDI-requiring op on an MDO-only tenant' {
            $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles['MDO-only']
            Test-DispatchAllowed -RequiresProducts @('MDI') -TenantProducts $tenant | Should -BeFalse
        }

        It 'skips when NONE of several required products are present' {
            $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles['MDE-only']   # → MDE, MDVM
            Test-DispatchAllowed -RequiresProducts @('MDO','MDI','MDC') -TenantProducts $tenant | Should -BeFalse
        }

        It 'admit/skip partition holds for EVERY SKU profile (intersection ⇔ dispatch)' {
            # The gate decision MUST equal the set-intersection test for every profile · no spurious admit/skip.
            foreach ($name in $script:SkuProfiles.Keys) {
                $tenant = Resolve-TenantProducts -Flags $script:SkuProfiles[$name]
                foreach ($req in @(@('MDE'), @('MDO'), @('MDI'), @('MDC'), @('MAPG'), @('XSPM'), @('MDE','MDC'))) {
                    $intersects = @($req | Where-Object { $tenant -contains $_ }).Count -gt 0
                    Test-DispatchAllowed -RequiresProducts $req -TenantProducts $tenant |
                        Should -Be $intersects -Because "profile=$name req=$($req -join '+') · gate must equal intersection"
                }
            }
        }
    }

    Context '(c) FAIL-OPEN · minimal/empty-license tenant still polls (R3 discovery unresolved)' {

        It 'admits when tenantProducts is $null (capability discovery transiently failed → fail-open)' {
            # Mirrors run.ps1: $tenantProducts = if ($caps) { $caps.Products } else { $null } → must still dispatch.
            Test-DispatchAllowed -RequiresProducts @('MDE') -TenantProducts $null | Should -BeTrue
        }

        It 'admits when tenantProducts is an empty array (no products discovered → fail-open)' {
            Test-DispatchAllowed -RequiresProducts @('MDE') -TenantProducts @() | Should -BeTrue
        }

        It 'a tenant whose R3 discovery returns NO products still polls every op (minimal-license floor)' {
            # An all-off tenant maps to an empty Products list; the gate fail-opens so the op still dispatches.
            $tenant = Resolve-TenantProducts -Flags $script:OffFlags
            @($tenant).Count | Should -Be 0
            foreach ($req in @(@('MDE'), @('MDO'), @('MDI'), @('MDC'))) {
                Test-DispatchAllowed -RequiresProducts $req -TenantProducts $tenant |
                    Should -BeTrue -Because "empty discovery → fail-open → req=$($req -join '+') still polls"
            }
        }

        It 'admits when the op declares NO RequiresProducts (no gate) on every tenant incl. empty' {
            foreach ($tenant in @($null, @(), @('MDE'))) {
                Test-DispatchAllowed -RequiresProducts $null -TenantProducts $tenant | Should -BeTrue
                Test-DispatchAllowed -RequiresProducts @()   -TenantProducts $tenant | Should -BeTrue
            }
        }
    }
}
