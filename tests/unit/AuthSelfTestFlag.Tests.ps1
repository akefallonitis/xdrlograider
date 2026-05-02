#Requires -Modules Pester
<#
.SYNOPSIS
    Lock the auth-selftest gate state machine introduced in v0.1.0-beta
    post-deploy hardening:

      ABSENT                       → proceed (first-deploy bootstrap)
      {Success=true}               → proceed (steady state)
      {Success=false, age<TTL}     → SKIP   (cooldown — don't spam portal)
      {Success=false, age>=TTL}    → proceed (cooldown elapsed; auto-retry)

.DESCRIPTION
    The v0.1.0-beta initial publish had the GATE (Get-XdrAuthSelfTestFlag +
    skip-on-false in Invoke-TierPollWithHeartbeat) but no WRITER, causing
    every poll-* to deadlock with reason='auth not validated' on first
    deploy. The post-deploy hardening adds Set-XdrAuthSelfTestFlag +
    wires it into the success / failure paths of the poll loop, plus a
    cooldown TTL for the failed-state to avoid both
      (a) infinite retry on persistent bad credentials, AND
      (b) requiring operator to manually clear the flag.

    Test gates by name:
      AuthSelfTestFlag.Set.Schema             — Upserts row with required cols
      AuthSelfTestFlag.Set.Failure            — Includes Reason on Success=false
      AuthSelfTestFlag.Set.Idempotent         — Two consecutive Upserts work
      AuthSelfTestFlag.Set.WriteFailureNonFatal — Storage error → Warning, no throw
      AuthSelfTestFlag.Module.Exports         — Set-XdrAuthSelfTestFlag is exported
#>

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:IngestPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    Import-Module $script:IngestPsd1 -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'AuthSelfTestFlag.Module.Exports' {
    It 'Xdr.Sentinel.Ingest exports both Get-XdrAuthSelfTestFlag and Set-XdrAuthSelfTestFlag' {
        $exported = (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-XdrAuthSelfTestFlag'
        $exported | Should -Contain 'Set-XdrAuthSelfTestFlag'
    }

    It 'Set-XdrAuthSelfTestFlag declares the required parameters with correct types' {
        $cmd = Get-Command Set-XdrAuthSelfTestFlag
        $cmd.Parameters.ContainsKey('StorageAccountName') | Should -BeTrue
        $cmd.Parameters.ContainsKey('CheckpointTable')    | Should -BeTrue
        $cmd.Parameters.ContainsKey('Success')            | Should -BeTrue
        $cmd.Parameters.ContainsKey('Stage')              | Should -BeTrue
        $cmd.Parameters.ContainsKey('Reason')             | Should -BeTrue

        $cmd.Parameters['Success'].ParameterType.FullName | Should -Be 'System.Boolean'
        $cmd.Parameters['Stage'].ParameterType.FullName   | Should -Be 'System.String'
        $cmd.Parameters['Reason'].ParameterType.FullName  | Should -Be 'System.String'
    }
}

Describe 'AuthSelfTestFlag.Set.Schema' {

    It 'Set-XdrAuthSelfTestFlag with Success=true upserts row with Success+Stage+TimeUtc (no Reason)' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:capturedEntity = $null
            $script:capturedPK     = $null
            $script:capturedRK     = $null
            $script:capturedOp     = $null
            Mock Invoke-XdrStorageTableEntity {
                param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
                $script:capturedEntity = $Entity
                $script:capturedPK     = $PartitionKey
                $script:capturedRK     = $RowKey
                $script:capturedOp     = $Operation
            }

            Set-XdrAuthSelfTestFlag `
                -StorageAccountName 'sa1' -CheckpointTable 'connectorCheckpoints' `
                -Success $true -Stage 'complete'

            $script:capturedOp | Should -Be 'Upsert'
            $script:capturedPK | Should -Be 'auth-selftest'
            $script:capturedRK | Should -Be 'latest'
            $script:capturedEntity['Success'] | Should -Be $true
            $script:capturedEntity['Stage']   | Should -Be 'complete'
            $script:capturedEntity.ContainsKey('TimeUtc') | Should -BeTrue
            # Reason omitted on success.
            $script:capturedEntity.ContainsKey('Reason') | Should -BeFalse
        }
    }
}

Describe 'AuthSelfTestFlag.Set.Failure' {

    It 'Set-XdrAuthSelfTestFlag with Success=false includes the Reason column' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:capturedEntity = $null
            Mock Invoke-XdrStorageTableEntity {
                param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
                $script:capturedEntity = $Entity
            }

            Set-XdrAuthSelfTestFlag `
                -StorageAccountName 'sa1' -CheckpointTable 'connectorCheckpoints' `
                -Success $false -Stage 'aadsts-error' -Reason 'AADSTS50126: invalid creds'

            $script:capturedEntity['Success'] | Should -Be $false
            $script:capturedEntity['Stage']   | Should -Be 'aadsts-error'
            $script:capturedEntity['Reason']  | Should -Be 'AADSTS50126: invalid creds'
        }
    }
}

Describe 'AuthSelfTestFlag.Set.Idempotent' {

    It 'two consecutive Upserts do not throw and both call through with Operation=Upsert' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:upsertCalls = 0
            Mock Invoke-XdrStorageTableEntity {
                param($StorageAccountName, $TableName, $PartitionKey, $RowKey, $Operation, $Entity)
                $script:upsertCalls++
                if ($Operation -ne 'Upsert') { throw 'unexpected operation' }
            }

            Set-XdrAuthSelfTestFlag -StorageAccountName 'sa1' -CheckpointTable 'tbl' -Success $true -Stage 'complete'
            Set-XdrAuthSelfTestFlag -StorageAccountName 'sa1' -CheckpointTable 'tbl' -Success $true -Stage 'complete'

            $script:upsertCalls | Should -Be 2
        }
    }
}

Describe 'AuthSelfTestFlag.Set.WriteFailureNonFatal' {

    It 'storage write failure surfaces a Warning but does not throw — caller continues' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrStorageTableEntity { throw 'simulated storage 503' }

            { Set-XdrAuthSelfTestFlag -StorageAccountName 'sa1' -CheckpointTable 'tbl' -Success $true -Stage 'complete' } |
                Should -Not -Throw -Because 'flag-write failures must be non-fatal so caller (Invoke-TierPollWithHeartbeat) still completes its work'
        }
    }
}
