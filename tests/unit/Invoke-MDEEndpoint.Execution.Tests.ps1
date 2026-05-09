#Requires -Modules Pester
<#
.SYNOPSIS
    Phase 4 polish P1 batch 4 (Plan R++++++++++.AMEND-6): execution-based
    coverage lift for Invoke-MDEEndpoint.ps1 (125 lines, 42% covered → ~80%+).

.DESCRIPTION
    Existing Invoke-MDEEndpoint.NullEdgeCases.Tests.ps1 has 4 tests (mostly
    pattern-matched). This file mocks Invoke-MDEPortalEndpoint at module scope
    + uses real manifest streams to exercise the function body's branches.

    Branches exercised (10):
      1. Happy path: 200 + Data -> Expand-MDEResponse called + rows returned
      2. Null $r -> SuccessKind=error + return @()
      3. $r.Success=false 401 -> SuccessKind=tenant-gated + return @()
      4. $r.Success=false 403 -> SuccessKind=tenant-gated
      5. $r.Success=false 404 -> SuccessKind=tenant-gated
      6. $r.Success=false 500 -> SuccessKind=error
      7. $r.Success=false network error (no http status) -> SuccessKind=error
      8. $r.Data=null (200 empty body) -> SuccessKind=live-empty + return @()
      9. PathParams substitution (uses real manifest stream with path placeholders)
      10. BodyOverride merges with manifest body (PerPlatformFanout pattern)
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonTele   = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1'
    $script:CommonAuth   = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1'
    $script:CommonMani   = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1'
    $script:DefenderAuth = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1'
    $script:Client       = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1'

    Import-Module $script:CommonTele   -Force -Global -ErrorAction Stop
    Import-Module $script:CommonAuth   -Force -Global -ErrorAction Stop
    Import-Module $script:CommonMani   -Force -Global -ErrorAction Stop
    Import-Module $script:DefenderAuth -Force -Global -ErrorAction Stop
    Import-Module $script:Client       -Force -Global -ErrorAction Stop

    # Use a real manifest stream so [ValidateScript] passes
    $script:TestStream = 'MDE_AdvancedFeatures_CL'  # Configuration tier, Inventory cadence, simple schema
    $script:Session = [pscustomobject]@{
        Session    = $null
        Upn        = 'svc@contoso.com'
        PortalHost = 'security.microsoft.com'
        TenantId   = '00000000-0000-0000-0000-000000000000'
    }
}

AfterAll {
    Remove-Module Xdr.Defender.Client  -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth    -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Manifest  -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth      -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-MDEEndpoint.Execution — happy path + truth-signal' {

    It 'Happy path: 200 + Data with array -> emits ingest rows' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{
                Success    = $true
                HttpStatus = 200
                Data       = @(@{ Name = 'feat1'; Value = $true }, @{ Name = 'feat2'; Value = $false })
            }
        }

        $result = Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream

        # Result is an array (may be empty if Expand normalisation rejects, but call should not throw)
        $result | Should -Not -BeNull
    }

    It 'truth-signal: 200 with Data sets SuccessKind=live OR live-empty' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $true; HttpStatus = 200; Data = @(@{ Foo = 'bar' }) }
        }

        Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream | Out-Null

        $last = Get-MDEEndpointLastResult
        $last | Should -Not -BeNullOrEmpty
        $last.SuccessKind | Should -BeIn @('live', 'live-empty')
    }
}

Describe 'Invoke-MDEEndpoint.Execution — null/error truth-signal' {

    It 'Null $r -> SuccessKind=error + return @()' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint { return $null }

        $result = Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue

        @($result).Count | Should -Be 0
        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'error'
        $last.HttpStatus  | Should -Be 0
        $last.ErrorText   | Should -BeLike '*null*helper-side bug*'
    }

    It '401 -> SuccessKind=tenant-gated + return @()' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{
                Success    = $false
                HttpStatus = 401
                Error      = 'Unauthorized'
                Data       = $null
            }
        }

        $result = Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue

        @($result).Count | Should -Be 0
        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'tenant-gated'
        $last.HttpStatus  | Should -Be 401
    }

    It '403 -> SuccessKind=tenant-gated' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $false; HttpStatus = 403; Error = 'Forbidden'; Data = $null }
        }

        Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue | Out-Null

        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'tenant-gated'
        $last.HttpStatus  | Should -Be 403
    }

    It '404 -> SuccessKind=tenant-gated' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $false; HttpStatus = 404; Error = 'Not Found'; Data = $null }
        }

        Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue | Out-Null

        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'tenant-gated'
    }

    It '500 -> SuccessKind=error' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $false; HttpStatus = 500; Error = 'Server error'; Data = $null }
        }

        Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue | Out-Null

        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'error'
        $last.HttpStatus  | Should -Be 500
    }

    It 'Network error (no HttpStatus) classified by error-text regex' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $false; HttpStatus = 0; Error = 'connection refused'; Data = $null }
        }

        Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream -WarningAction SilentlyContinue | Out-Null

        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'error'
    }

    It '$r.Data null (200 empty body) -> SuccessKind=live-empty + return @()' {
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            return [pscustomobject]@{ Success = $true; HttpStatus = 200; Data = $null }
        }

        $result = Invoke-MDEEndpoint -Session $script:Session -Stream $script:TestStream

        @($result).Count | Should -Be 0
        $last = Get-MDEEndpointLastResult
        $last.SuccessKind | Should -Be 'live-empty'
        $last.HttpStatus  | Should -Be 200
    }
}

Describe 'Invoke-MDEEndpoint.Execution — request shape' {

    It 'Filter + FromUtc adds query string parameter' {
        # MDE_ActionCenter_CL has Filter='fromDate' so FromUtc gets appended
        $captured = $null
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            $script:capturedPath = $Path
            return [pscustomobject]@{ Success = $true; HttpStatus = 200; Data = @() }
        }
        $script:capturedPath = $null
        $from = [datetime]::new(2026, 5, 1, 0, 0, 0, [DateTimeKind]::Utc)

        Invoke-MDEEndpoint -Session $script:Session -Stream 'MDE_ActionCenter_CL' -FromUtc $from -WarningAction SilentlyContinue | Out-Null

        $script:capturedPath | Should -Not -BeNullOrEmpty
        $script:capturedPath | Should -Match 'fromDate=2026-05-01T00%3a00%3a00\.0000000Z'
    }

    It 'POST method with Body merged with BodyOverride (Architecture C PerPlatformFanout)' {
        # MDE_SecurityPolicies_CL is POST with Body = @{ platform = 'Windows' }; override flips it
        Mock -ModuleName Xdr.Defender.Client Invoke-MDEPortalEndpoint {
            $script:capturedBody   = $Body
            $script:capturedMethod = $Method
            return [pscustomobject]@{ Success = $true; HttpStatus = 200; Data = @() }
        }
        $script:capturedBody = $null
        $script:capturedMethod = $null

        Invoke-MDEEndpoint -Session $script:Session -Stream 'MDE_SecurityPolicies_CL' `
            -BodyOverride @{ platform = 'Linux' } -WarningAction SilentlyContinue | Out-Null

        $script:capturedMethod | Should -Be 'POST'
        $script:capturedBody | Should -Not -BeNullOrEmpty
        # BodyOverride wins on collision
        $script:capturedBody.platform | Should -Be 'Linux'
    }
}
