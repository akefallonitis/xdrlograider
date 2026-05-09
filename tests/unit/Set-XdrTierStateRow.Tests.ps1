#Requires -Modules Pester
<#
.SYNOPSIS
    Phase 4 polish P1 (Plan R++++++++++.AMEND-6): coverage lift for
    Set-XdrTierStateRow.ps1 (currently 0% line coverage).

.DESCRIPTION
    Set-XdrTierStateRow is called by Xdr-PollStream activity FINAL step (after
    Send-ToLogAnalytics succeeds) to write the per-stream tier-state row to
    Storage Table 'XdrTierState'. Connector-Heartbeat aggregator reads this
    table to compute per-(Portal, Tier) StreamsSucceeded metrics that drive
    the Sentinel data-connector card's connectivityCriteria query.

    Tests cover:
      - Happy path: writes entity to Invoke-XdrStorageTableEntity with
        correct PartitionKey/RowKey/columns
      - SuccessKind classification: Reason col carries truth-signal per
        Section R++.A
      - Mandatory parameter validation
      - ValidateSet enforcement on Portal + Tier + Reason
      - 404 TableNotFound throws actionable error pointing at ARM remediation
      - Other errors propagate
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

Describe 'Set-XdrTierStateRow.HappyPath' {

    BeforeEach {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return $null }
    }

    It 'writes entity with PartitionKey=Portal-Tier composite + RowKey=Stream' {
        Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'ActionCenter' `
            -Stream             'MDE_ActionCenter_CL' `
            -RowsIngested       5 `
            -Success            $true `
            -OperationId        'op-123'

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $PartitionKey -eq 'Defender|ActionCenter' -and
            $RowKey       -eq 'MDE_ActionCenter_CL' -and
            $Operation    -eq 'Upsert' -and
            $TableName    -eq 'XdrTierState'
        }
    }

    It 'TableName defaults to XdrTierState' {
        Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'XspmGraph' `
            -Stream             'MDE_XspmAttackPaths_CL'

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $TableName -eq 'XdrTierState'
        }
    }

    It 'RowsIngested defaults to 0 + Success defaults to true' {
        Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'Inventory' `
            -Stream             'MDE_Machines_CL'

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $Entity.RowsIngested -eq 0 -and
            $Entity.Success      -eq $true
        }
    }

    It 'entity carries Reason + HttpStatus + OperationId for telemetry stitching' {
        Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'Configuration' `
            -Stream             'MDE_AdvancedFeatures_CL' `
            -Success            $false `
            -ErrorText          'auth chain failed' `
            -Reason             'error' `
            -HttpStatus         401 `
            -OperationId        'orch-instance-abc'

        Assert-MockCalled -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -Times 1 -ParameterFilter {
            $Entity.Reason       -eq 'error' -and
            $Entity.HttpStatus   -eq 401 -and
            $Entity.OperationId  -eq 'orch-instance-abc' -and
            $Entity.ErrorText    -eq 'auth chain failed'
        }
    }
}

Describe 'Set-XdrTierStateRow.ValidateSet' {

    BeforeEach {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity { return $null }
    }

    It 'rejects unknown Portal (multi-portal future-proofing)' {
        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'NotAPortal' `
            -Tier               'ActionCenter' `
            -Stream             'MDE_X_CL' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'rejects unknown Tier (5 tiers only)' {
        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'NotATier' `
            -Stream             'MDE_X_CL' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'rejects unknown Reason (truth-signal classification)' {
        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'ActionCenter' `
            -Stream             'MDE_X_CL' `
            -Reason             'invented-kind' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'accepts all valid Reason values per Section R++.A truth-signal' {
        foreach ($reason in 'live','live-empty','tenant-gated','error','') {
            { Set-XdrTierStateRow `
                -StorageAccountName 'xdrlrst' `
                -Portal             'Defender' `
                -Tier               'ActionCenter' `
                -Stream             'MDE_X_CL' `
                -Reason             $reason } | Should -Not -Throw
        }
    }
}

Describe 'Set-XdrTierStateRow.ErrorPaths' {

    It '404 TableNotFound throws actionable error pointing at ARM remediation' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw 'The specified resource does not exist (TableNotFound 404)'
        }

        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'ActionCenter' `
            -Stream             'MDE_X_CL' } |
                Should -Throw -ExpectedMessage '*XdrTierState*does not exist*ARM template MUST provision*Microsoft.Storage*tableServices*'
    }

    It 'other errors propagate unchanged' {
        Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity {
            throw '403 Forbidden'
        }

        { Set-XdrTierStateRow `
            -StorageAccountName 'xdrlrst' `
            -Portal             'Defender' `
            -Tier               'ActionCenter' `
            -Stream             'MDE_X_CL' } | Should -Throw -ExpectedMessage '*403*'
    }
}
