#Requires -Modules Pester
<#
.SYNOPSIS
    Phase 4 polish P1 (Plan R++++++++++.AMEND-6): coverage lift for
    Get-XdrTenantStateCapability.ps1 (currently 0% line coverage).

.DESCRIPTION
    Architecture I (Plan R++++++++++): fast lookup of tenant capability flags
    cached daily by Set-XdrTenantStateCapability via Inventory-tier activity.
    Returns hashtable with capability flags + LicenseTier + Region OR $null
    if cache row doesn't exist (caller treats missing as "no cache yet").

    Per AMEND-1 #5 + R+++++.4 all-live policy: capability detection is
    WARNING-ONLY, never short-circuits polling.

    Tests cover:
      - Happy path: returns row data when cached
      - $null when row doesn't exist (Invoke-XdrStorageTableEntity returns $null)
      - $null when 404 TableNotFound (treats missing table as "no cache yet")
      - $null when ResourceNotFound (covers Az.Storage variants)
      - Other errors propagate (e.g. 403 Forbidden = real auth issue)
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonTelePsd1   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Telemetry' 'Xdr.Common.Telemetry.psd1'
    $script:CommonAuthPsd1   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:IngestPsd1       = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'

    Import-Module $script:CommonTelePsd1 -Force -Global -ErrorAction Stop
    Import-Module $script:CommonAuthPsd1 -Force -Global -ErrorAction Stop
    Import-Module $script:IngestPsd1     -Force -Global -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Get-XdrTenantStateCapability.HappyPath' {

    It 'returns full row when cached' {
        $tid = '00000000-1111-2222-3333-444444444444'
        $expected = @{
            PartitionKey   = 'Capability'
            RowKey         = $tid
            TenantId       = $tid
            IsMdiActive    = $true
            IsMdatpActive  = $true
            IsOatpActive   = $false
            IsXspmActive   = $true
            LicenseTier    = 'Plan2'
            Region         = 'westeurope'
            LastRefreshUtc = '2026-05-09T00:00:00.0000000Z'
        }
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return $expected }

        $result = Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid

        $result | Should -Not -BeNullOrEmpty
        $result.IsMdiActive   | Should -Be $true
        $result.IsMdatpActive | Should -Be $true
        $result.IsOatpActive  | Should -Be $false
        $result.IsXspmActive  | Should -Be $true
        $result.LicenseTier   | Should -Be 'Plan2'
        $result.Region        | Should -Be 'westeurope'
    }

    It 'queries Storage Table with PartitionKey=Capability + RowKey=TenantId' {
        $tid = '11111111-1111-1111-1111-111111111111'
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return @{ TenantId = $tid } }

        Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $PartitionKey -eq 'Capability' -and
            $RowKey       -eq $tid -and
            $Operation    -eq 'Get' -and
            $TableName    -eq 'XdrTenantState'
        }
    }
}

Describe 'Get-XdrTenantStateCapability.MissingCache' {

    It 'returns $null when Invoke-XdrStorageTableEntity returns $null (row missing)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return $null }

        $result = Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '22222222-2222-2222-2222-222222222222'

        $result | Should -BeNullOrEmpty
    }

    It 'returns $null on 404 TableNotFound (caller treats as no cache yet)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw 'TableNotFound 404'
        }

        $result = Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '33333333-3333-3333-3333-333333333333'

        $result | Should -BeNullOrEmpty
    }

    It 'returns $null on ResourceNotFound (covers Az.Storage variants)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw 'ResourceNotFound: the resource cannot be found'
        }

        $result = Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '44444444-4444-4444-4444-444444444444'

        $result | Should -BeNullOrEmpty
    }
}

Describe 'Get-XdrTenantStateCapability.RealErrors' {

    It 'propagates 403 Forbidden (real auth issue, NOT cache miss)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw '403 Forbidden — Storage Table access denied'
        }

        { Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '55555555-5555-5555-5555-555555555555' } |
                Should -Throw -ExpectedMessage '*403*'
    }

    It 'propagates 500 Server errors (transient infrastructure)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw '500 Internal Server Error'
        }

        { Get-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '66666666-6666-6666-6666-666666666666' } |
                Should -Throw -ExpectedMessage '*500*'
    }
}
