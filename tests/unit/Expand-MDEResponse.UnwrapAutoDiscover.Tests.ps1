#Requires -Modules Pester
<#
.SYNOPSIS
    AMEND-9 Phase A.4 (2026-05-09): regression-locker for the wrapper
    auto-discovery fallback added in `_EndpointHelpers.ps1:304-380`.

.DESCRIPTION
    Live regression 2026-05-08T18:44 saw 4 streams (MDE_ActionCenter_CL +
    MDE_MtoTenants_CL + MDE_AlertTuning_CL + MDE_IdentityServiceAccounts_CL)
    go dry due to upstream Defender portal API response shape drift —
    declared UnwrapProperty target became null in the response body.

    Phase A.2 fix: when declared UnwrapProperty returns null AND the
    response object has OTHER non-null array-typed properties, scan + use
    the largest array. Emits Ingest.UnwrapAutoDiscovered customEvent with
    OriginalUnwrap + DiscoveredUnwrap + RowCount. Falls through to original
    Ingest.BoundaryMarker / @() return only if no array property found.

    This test file mocks Send-XdrAppInsightsCustomEvent at module scope and
    exercises Expand-MDEResponse with controlled inputs to verify all 4
    branches:
      1. UnwrapProperty target null + response has 1 non-null array property
         -> auto-discovers + uses that array + emits UnwrapAutoDiscovered
      2. UnwrapProperty target null + response has 0 array properties
         -> original behavior preserved (BoundaryMarker + @())
      3. UnwrapProperty target null + response has multiple arrays
         -> picks largest by .Count
      4. UnwrapProperty returns valid value (negative test)
         -> original path unchanged; NO UnwrapAutoDiscovered event
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonTele = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1'
    $script:CommonAuth = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1'
    $script:CommonMani = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1'
    $script:DefAuth    = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1'
    $script:Client     = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1'

    Import-Module $script:CommonTele -Force -Global -ErrorAction Stop
    Import-Module $script:CommonAuth -Force -Global -ErrorAction Stop
    Import-Module $script:CommonMani -Force -Global -ErrorAction Stop
    Import-Module $script:DefAuth    -Force -Global -ErrorAction Stop
    Import-Module $script:Client     -Force -Global -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Manifest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
}

Describe 'Expand-MDEResponse.UnwrapAutoDiscover' {

    BeforeEach {
        Mock -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent { }
    }

    It '1. UnwrapProperty=Results null + response has data array (2 items) -> auto-discovers data' {
        # Simulates upstream API drift: declared "Results" wrapper changed to "data"
        $response = [pscustomobject]@{
            Results = $null
            data    = @(
                [pscustomobject]@{ id = 'item-1'; name = 'first' },
                [pscustomobject]@{ id = 'item-2'; name = 'second' }
            )
        }

        $result = Expand-MDEResponse -Response $response -Stream 'MDE_TestStream_CL' -UnwrapProperty 'Results' -IdProperty @('id')

        @($result).Count | Should -Be 2 -Because 'auto-discovered data array has 2 items'
        # Verify UnwrapAutoDiscovered event fired
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 1 -ParameterFilter {
            $EventName -eq 'Ingest.UnwrapAutoDiscovered' -and
            $Properties.OriginalUnwrap -eq 'Results' -and
            $Properties.DiscoveredUnwrap -eq 'data' -and
            $Properties.RowCount -eq 2
        }
        # Verify NO BoundaryMarker fired (auto-discovery succeeded)
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 0 -ParameterFilter {
            $EventName -eq 'Ingest.BoundaryMarker' -and $Properties.Reason -eq 'unwrap-target-null'
        }
    }

    It '2. UnwrapProperty=Results returns null + no array properties anywhere -> original BoundaryMarker + @()' {
        # No fallback array — preserve original behavior
        $response = [pscustomobject]@{
            Results = $null
            metadata = [pscustomobject]@{ version = '1.0' }
            count    = 0
        }

        $result = Expand-MDEResponse -Response $response -Stream 'MDE_TestStream_CL' -UnwrapProperty 'Results'

        @($result).Count | Should -Be 0 -Because 'no array fallback found; expect ZERO rows (original behavior)'
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 1 -ParameterFilter {
            $EventName -eq 'Ingest.BoundaryMarker' -and
            $Properties.Reason -eq 'unwrap-target-null' -and
            $Properties.UnwrapProperty -eq 'Results'
        }
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 0 -ParameterFilter {
            $EventName -eq 'Ingest.UnwrapAutoDiscovered'
        }
    }

    It '3. UnwrapProperty=Results returns null + multiple arrays -> picks largest by Count' {
        # 3 candidate arrays; largest is "items" with 5 elements
        $response = [pscustomobject]@{
            Results = $null
            small   = @([pscustomobject]@{ id = 'a' })
            items   = @(
                [pscustomobject]@{ id = 'i-1' },
                [pscustomobject]@{ id = 'i-2' },
                [pscustomobject]@{ id = 'i-3' },
                [pscustomobject]@{ id = 'i-4' },
                [pscustomobject]@{ id = 'i-5' }
            )
            medium  = @([pscustomobject]@{ id = 'm-1' }, [pscustomobject]@{ id = 'm-2' })
        }

        $result = Expand-MDEResponse -Response $response -Stream 'MDE_TestStream_CL' -UnwrapProperty 'Results' -IdProperty @('id')

        @($result).Count | Should -Be 5 -Because 'largest array (items, 5 elements) auto-discovered'
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 1 -ParameterFilter {
            $EventName -eq 'Ingest.UnwrapAutoDiscovered' -and
            $Properties.DiscoveredUnwrap -eq 'items' -and
            $Properties.RowCount -eq 5
        }
    }

    It '4. UnwrapProperty=Results returns valid array -> original path unchanged; NO UnwrapAutoDiscovered (negative)' {
        # Healthy response: declared wrapper present + populated
        $response = [pscustomobject]@{
            Results = @(
                [pscustomobject]@{ id = 'r-1'; name = 'alpha' },
                [pscustomobject]@{ id = 'r-2'; name = 'beta' },
                [pscustomobject]@{ id = 'r-3'; name = 'gamma' }
            )
            other   = @([pscustomobject]@{ id = 'o-1' })
        }

        $result = Expand-MDEResponse -Response $response -Stream 'MDE_TestStream_CL' -UnwrapProperty 'Results' -IdProperty @('id')

        @($result).Count | Should -Be 3 -Because 'declared Results wrapper has 3 items'
        # NO UnwrapAutoDiscovered event (negative test)
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 0 -ParameterFilter {
            $EventName -eq 'Ingest.UnwrapAutoDiscovered'
        }
        # NO BoundaryMarker either (happy path)
        Assert-MockCalled -ModuleName Xdr.Defender.Client Send-XdrAppInsightsCustomEvent -Times 0 -ParameterFilter {
            $EventName -eq 'Ingest.BoundaryMarker' -and $Properties.Reason -eq 'unwrap-target-null'
        }
    }
}
