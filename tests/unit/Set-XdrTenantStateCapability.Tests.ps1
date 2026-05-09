#Requires -Modules Pester
<#
.SYNOPSIS
    Phase 4 polish P1 (Plan R++++++++++.AMEND-6): coverage lift for
    Set-XdrTenantStateCapability.ps1 (currently 0% line coverage).

.DESCRIPTION
    Architecture I (Plan R++++++++++): caches per-tenant capability flags read
    from MDE_TenantContext_CL on the Inventory cadence (24h). The orchestrator
    consults Get-XdrTenantStateCapability before fanning out streams to enrich
    operator-visible context.

    Per Plan AMEND-1 #5 + R+++++.4 all-live policy: capability detection is
    WARNING-ONLY, never short-circuits polling.

    Tests cover:
      - Happy path: writes entity to Invoke-XdrStorageTableEntity with
        PartitionKey='Capability' + RowKey=<TenantId>
      - Default values for capability flags (false) + license tier ('') + region ('')
      - Custom values propagate correctly
      - LastRefreshUtc is ISO 8601 UTC
      - 404 TableNotFound throws actionable error pointing at ARM remediation
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

Describe 'Set-XdrTenantStateCapability.HappyPath' {

    BeforeEach {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return $null }
    }

    It 'writes entity with PartitionKey=Capability + RowKey=TenantId' {
        $tid = '00000000-1111-2222-3333-444444444444'
        Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid `
            -IsMdiActive        $true `
            -IsMdatpActive      $true `
            -LicenseTier        'Plan2' `
            -Region             'westeurope'

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $PartitionKey -eq 'Capability' -and
            $RowKey       -eq $tid -and
            $Operation    -eq 'Upsert' -and
            $TableName    -eq 'XdrTenantState'
        }
    }

    It 'capability flags default to false; license tier + region default to empty' {
        $tid = '11111111-1111-1111-1111-111111111111'
        Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $Entity.IsMdiActive   -eq $false -and
            $Entity.IsMdatpActive -eq $false -and
            $Entity.IsOatpActive  -eq $false -and
            $Entity.IsXspmActive  -eq $false -and
            $Entity.LicenseTier   -eq '' -and
            $Entity.Region        -eq ''
        }
    }

    It 'all 4 capability flags propagate correctly' {
        $tid = '22222222-2222-2222-2222-222222222222'
        Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid `
            -IsMdiActive        $true `
            -IsMdatpActive      $true `
            -IsOatpActive       $false `
            -IsXspmActive       $true

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $Entity.IsMdiActive   -eq $true  -and
            $Entity.IsMdatpActive -eq $true  -and
            $Entity.IsOatpActive  -eq $false -and
            $Entity.IsXspmActive  -eq $true
        }
    }

    It 'LastRefreshUtc is ISO 8601 with offset (round-trip parseable)' {
        $tid = '33333333-3333-3333-3333-333333333333'
        $captured = $null
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            $script:captured = $Entity
            return $null
        }

        Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid

        $script:captured.LastRefreshUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        # Round-trip parse to confirm format
        { [DateTime]::Parse($script:captured.LastRefreshUtc) } | Should -Not -Throw
    }

    It 'TableName defaults to XdrTenantState' {
        $tid = '44444444-4444-4444-4444-444444444444'
        Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           $tid

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $TableName -eq 'XdrTenantState'
        }
    }
}

Describe 'Set-XdrTenantStateCapability.ErrorPaths' {

    It '404 TableNotFound throws actionable error pointing at ARM remediation' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw 'The specified resource does not exist (TableNotFound 404)'
        }

        { Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '55555555-5555-5555-5555-555555555555' } |
                Should -Throw -ExpectedMessage '*XdrTenantState*does not exist*ARM template MUST provision*'
    }

    It 'other errors propagate unchanged (e.g. 403 Forbidden)' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw '403 Forbidden'
        }

        { Set-XdrTenantStateCapability `
            -StorageAccountName 'xdrlrst' `
            -TenantId           '66666666-6666-6666-6666-666666666666' } | Should -Throw -ExpectedMessage '*403*'
    }
}
