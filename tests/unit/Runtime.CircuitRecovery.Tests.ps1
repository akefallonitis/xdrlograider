#Requires -Module Pester
# Π11 ITER2-R3 · XdrTierState recovery write-back · when a sub-area transitions
# Open/HalfOpen → Closed in-memory, the durable XdrTierState Storage Table row
# MUST be flipped to Closed too. Otherwise the stale Open row survives cold-start
# and the next 30-min cooldown elapses needlessly. Also exercises ITER2-R4 (UPSERT
# verb validation).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Ingest/Xdr.Ingest.psd1') -Force
}

Describe 'Π11 ITER2-R4 · Invoke-XdrStorageTableEntity ValidateSet · UPSERT verb' -Tag 'tier1','unit' {

    It 'accepts -Verb UPSERT (was missing · 3 run.ps1 call-sites would runtime-throw)' {
        # Mock Invoke-RestMethod to swallow the network call · we only care about ValidateSet acceptance
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            return [pscustomobject]@{ Token = ConvertTo-SecureString 'mock-bearer' -AsPlainText -Force }
        }
        Mock -ModuleName Xdr.Ingest Invoke-RestMethod { return $null }
        {
            Invoke-XdrStorageTableEntity -Verb UPSERT `
                -StorageAccount 'sa' -Table 'XdrTierState' `
                -PartitionKey 'Defender' -RowKey 'CloudApps' `
                -Entity @{ State='Closed'; Failures=0; OpenedAt='' }
        } | Should -Not -Throw
    }

    It 'UPSERT uses PUT with If-Match:* header (Azure Table insert-or-replace semantics)' {
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            return [pscustomobject]@{ Token = ConvertTo-SecureString 'mock-bearer' -AsPlainText -Force }
        }
        $script:CapturedMethod = $null
        $script:CapturedHeaders = $null
        Mock -ModuleName Xdr.Ingest Invoke-RestMethod {
            param($Uri, $Method, $Headers, $Body, $ErrorAction)
            $script:CapturedMethod = $Method
            $script:CapturedHeaders = $Headers
            return $null
        }
        $result = Invoke-XdrStorageTableEntity -Verb UPSERT `
            -StorageAccount 'sa' -Table 'XdrTierState' `
            -PartitionKey 'Defender' -RowKey 'CloudApps' `
            -Entity @{ State='Closed' }
        $script:CapturedMethod | Should -Be 'PUT'
        $script:CapturedHeaders.'If-Match' | Should -Be '*'
        $result.StatusCode | Should -Be 204
    }

    It 'UPSERT throws if PartitionKey/RowKey/Entity missing (input validation parity with UPDATE)' {
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            return [pscustomobject]@{ Token = ConvertTo-SecureString 'mock-bearer' -AsPlainText -Force }
        }
        {
            Invoke-XdrStorageTableEntity -Verb UPSERT -StorageAccount 'sa' -Table 'T' `
                -RowKey 'r' -Entity @{x=1}
        } | Should -Throw '*requires*'
    }
}
