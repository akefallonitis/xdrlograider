#Requires -Modules Pester

BeforeAll {
    $script:IngestModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'

    # Az.Accounts + Az.Storage + Az.Table are runtime dependencies (declared in
    # src/requirements.psd1 for the Function App). For unit tests they're stubbed.
    function global:Get-AzAccessToken {
        param([string]$ResourceUrl)
        return [pscustomobject]@{
            Token     = 'fake-stub-token'
            ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
        }
    }
    function global:New-AzStorageContext {
        param([string]$StorageAccountName, [switch]$UseConnectedAccount)
        return [pscustomobject]@{ StorageAccountName = $StorageAccountName }
    }
    function global:Get-AzStorageTable {
        param([string]$Name, $Context)
        return [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } }
    }
    function global:New-AzStorageTable {
        param([string]$Name, $Context)
        return [pscustomobject]@{ Name = $Name; CloudTable = [pscustomobject]@{ Name = $Name } }
    }
    function global:Get-AzTableRow {
        param($Table, [string]$PartitionKey, [string]$RowKey)
        return $null
    }
    function global:Add-AzTableRow {
        param($Table, [string]$PartitionKey, [string]$RowKey, $Property, [switch]$UpdateExisting)
    }

    Import-Module $script:IngestModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'XdrLogRaider.Ingest module surface' {
    It 'exports Send-ToLogAnalytics, Write-Heartbeat, Write-AuthTestResult, Get/Set-CheckpointTimestamp, Get-XdrAuthSelfTestFlag, Invoke-XdrStorageTableEntity' {
        $exported = (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys
        $exported | Should -Contain 'Send-ToLogAnalytics'
        $exported | Should -Contain 'Write-Heartbeat'
        $exported | Should -Contain 'Write-AuthTestResult'
        $exported | Should -Contain 'Get-CheckpointTimestamp'
        $exported | Should -Contain 'Set-CheckpointTimestamp'
        $exported | Should -Contain 'Get-XdrAuthSelfTestFlag'
        # Iter 13.15: unified Storage Table HttpClient helper
        $exported | Should -Contain 'Invoke-XdrStorageTableEntity'
    }

    It 'has PowerShell 7.4+ requirement' {
        $manifest = Import-PowerShellDataFile -Path $script:IngestModulePath
        $manifest.PowerShellVersion | Should -Be '7.4'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }
}

Describe 'Send-ToLogAnalytics' {
    It 'returns zero-row summary for empty input' {
        InModuleScope Xdr.Sentinel.Ingest {
            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @()
            $result.RowsSent | Should -Be 0
            $result.BatchesSent | Should -Be 0
        }
    }

    It 'batches rows and POSTs to the correct URI' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { return 'test-token' }
            Mock Invoke-WebRequest { return @{ StatusCode = 204 } }

            $rows = 1..3 | ForEach-Object {
                [pscustomobject]@{
                    TimeGenerated = [datetime]::UtcNow.ToString('o')
                    SourceStream  = 'MDE_Test_CL'
                    EntityId      = "entity-$_"
                    RawJson       = '{}'
                }
            }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc123' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows $rows

            $result.RowsSent | Should -Be 3
            $result.BatchesSent | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -like 'https://test.ingest.monitor.azure.com/dataCollectionRules/dcr-abc123/streams/Custom-MDE_Test_CL?api-version=*'
            }
        }
    }

    It 'retries on 429 transient failure' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { return 'test-token' }
            $script:callCount = 0
            Mock Invoke-WebRequest {
                $script:callCount++
                if ($script:callCount -lt 3) {
                    $err = [System.Net.WebException]::new('rate limited')
                    $resp = @{ StatusCode = 429 }
                    $err | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
                    throw $err
                }
                return @{ StatusCode = 204 }
            }
            Mock Start-Sleep {}

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @([pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); SourceStream = 'MDE_Test_CL'; EntityId = 'x'; RawJson = '{}' }) `
                -MaxRetries 5

            $result.RowsSent | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }
    }

    It 'splits large payloads across multiple batches' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { return 'test-token' }
            Mock Invoke-WebRequest { return @{ StatusCode = 204 } }

            # 10 rows where each is ~500 bytes; MaxBatchBytes = 2000 should produce ~3 batches
            $rows = 1..10 | ForEach-Object {
                [pscustomobject]@{
                    TimeGenerated = [datetime]::UtcNow.ToString('o')
                    SourceStream  = 'MDE_Test_CL'
                    EntityId      = "entity-$_"
                    RawJson       = ('x' * 400)
                }
            }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows $rows `
                -MaxBatchBytes 2000

            $result.RowsSent | Should -Be 10
            $result.BatchesSent | Should -BeGreaterThan 1
        }
    }

    It 'skips rows that individually exceed MaxBatchBytes' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { return 'test-token' }
            Mock Invoke-WebRequest { return @{ StatusCode = 204 } }

            $bigRow   = [pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); SourceStream = 'MDE_Test_CL'; EntityId = 'x'; RawJson = ('y' * 10000) }
            $smallRow = [pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); SourceStream = 'MDE_Test_CL'; EntityId = 'y'; RawJson = 'small' }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @($bigRow, $smallRow) `
                -MaxBatchBytes 5000

            $result.RowsSent | Should -Be 1  # only the small row
        }
    }
}

Describe 'Write-Heartbeat' {
    It 'builds and POSTs a heartbeat row' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Send-ToLogAnalytics { return [pscustomobject]@{ RowsSent = 1; BatchesSent = 1; LatencyMs = 42 } }

            Write-Heartbeat `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -FunctionName 'poll-p0-compliance-1h' `
                -Tier 'P0' `
                -StreamsAttempted 19 `
                -StreamsSucceeded 18 `
                -RowsIngested 450 `
                -LatencyMs 8200

            Should -Invoke Send-ToLogAnalytics -Times 1 -Exactly -ParameterFilter {
                $StreamName -eq 'Custom-MDE_Heartbeat_CL' -and
                $Rows.Count -eq 1 -and
                $Rows[0].FunctionName -eq 'poll-p0-compliance-1h' -and
                $Rows[0].Tier -eq 'P0' -and
                $Rows[0].StreamsAttempted -eq 19
            }
        }
    }
}

Describe 'Write-AuthTestResult' {
    It 'builds and POSTs an auth-test-result row' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Send-ToLogAnalytics { return [pscustomobject]@{ RowsSent = 1; BatchesSent = 1; LatencyMs = 20 } }

            $testResult = [pscustomobject]@{
                Method = 'CredentialsTotp'
                PortalHost = 'security.microsoft.com'
                Upn = 'svc@test.com'
                Success = $true
                Stage = 'complete'
                StageTimings = [ordered]@{ estsMs = 245; sccauthMs = 312 }
                FailureReason = $null
                SampleCallHttpCode = 200
                SampleCallLatencyMs = 412
                SccauthAcquiredUtc = [datetime]::UtcNow
            }

            Write-AuthTestResult `
                -DceEndpoint 'https://test.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-abc' `
                -TestResult $testResult

            Should -Invoke Send-ToLogAnalytics -Times 1 -Exactly -ParameterFilter {
                $StreamName -eq 'Custom-MDE_AuthTestResult_CL' -and
                $Rows.Count -eq 1 -and
                $Rows[0].Success -eq $true -and
                $Rows[0].Stage -eq 'complete'
            }
        }
    }

    Describe 'Get-XdrAuthSelfTestFlag' {
        # Iter 13.15: Get-XdrAuthSelfTestFlag now delegates to
        # Invoke-XdrStorageTableEntity (the unified Storage Table HttpClient
        # helper). Mocks target the helper directly so we exercise the
        # function's mapping logic (helper returns null vs entity → bool flag)
        # without depending on REST/HTTP semantics.
        It 'returns $true when checkpoint row exists with Success=true' {
            Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -MockWith {
                [pscustomobject]@{ Success = $true; LastRunUtc = [datetime]::UtcNow.ToString('o') }
            }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeTrue
        }

        It 'returns $false when checkpoint row exists with Success=false' {
            Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -MockWith {
                [pscustomobject]@{ Success = $false; LastRunUtc = [datetime]::UtcNow.ToString('o') }
            }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeFalse
        }

        It 'returns $false when no checkpoint row exists yet (helper returns $null on 404)' {
            Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -MockWith { $null }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }

        It 'returns $false (fails closed) when the helper throws' {
            Mock -ModuleName Xdr.Sentinel.Ingest Invoke-XdrStorageTableEntity -MockWith { throw 'token acquisition failed' }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }
    }
}

Describe 'Send-ToLogAnalytics — gzip compression (v0.1.0-beta)' {

    It 'compresses body with Content-Encoding: gzip by default and returns GzipBytes' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:captured = $null
            Mock Invoke-WebRequest {
                $script:captured = [pscustomobject]@{
                    Body = $Body
                    Headers = $Headers
                    IsBytes = ($Body -is [byte[]])
                    HasGzipHeader = $Headers.ContainsKey('Content-Encoding') -and $Headers['Content-Encoding'] -eq 'gzip'
                }
                @{ StatusCode = 204 }
            }

            $rows = 1..50 | ForEach-Object { [pscustomobject]@{ EntityId = "e$_"; Name = "name$_"; Value = "v$_ " * 20 } }
            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows $rows

            $script:captured.IsBytes | Should -BeTrue -Because 'gzip-compressed body is byte[]'
            $script:captured.HasGzipHeader | Should -BeTrue -Because 'Content-Encoding: gzip must be set'
            $result.GzipBytes | Should -BeGreaterThan 0 -Because 'GzipBytes must be surfaced to caller for heartbeat'
            $result.GzipBytes | Should -BeLessThan ($rows.Count * 200) -Because 'gzip should compress the synthetic repetitive payload substantially'
        }
    }

    It 'sends raw JSON body (not byte[]) when -DisableGzip is passed' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:captured = $null
            Mock Invoke-WebRequest {
                $script:captured = [pscustomobject]@{
                    IsBytes = ($Body -is [byte[]])
                    IsString = ($Body -is [string])
                    HasGzipHeader = $Headers.ContainsKey('Content-Encoding')
                }
                @{ StatusCode = 204 }
            }

            $rows = @([pscustomobject]@{ EntityId = 'e1'; Value = 'x' })
            Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows $rows -DisableGzip | Out-Null

            $script:captured.IsBytes | Should -BeFalse
            $script:captured.IsString | Should -BeTrue
            $script:captured.HasGzipHeader | Should -BeFalse
        }
    }
}

Describe 'Send-ToLogAnalytics — 413 split-and-retry (v0.1.0-beta)' {

    It 'halves the batch and recurses when DCE returns 413 Payload Too Large' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:postCount = 0
            $script:batchSizes = @()
            # First call returns 413, subsequent calls return 204 (simulating
            # the halved retries succeed).
            Mock Invoke-WebRequest {
                $script:postCount++
                # Estimate batch size from body length. Always collect a sample.
                $script:batchSizes += if ($Body -is [byte[]]) { $Body.Length } else { $Body.Length }
                if ($script:postCount -eq 1) {
                    # Throw 413 exactly like Invoke-WebRequest would on a real 413
                    $resp = [System.Net.HttpWebResponse]::new()
                    $mockResp = [pscustomobject]@{ StatusCode = 413 }
                    $exc = [System.Net.WebException]::new('payload too large')
                    $exc | Add-Member -NotePropertyName Response -NotePropertyValue $mockResp -Force
                    throw $exc
                }
                @{ StatusCode = 204 }
            }

            $rows = 1..10 | ForEach-Object { [pscustomobject]@{ EntityId = "e$_"; Value = 'x' } }
            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows $rows -MaxRetries 0 -WarningAction SilentlyContinue

            # Must have called Invoke-WebRequest more than once (split path hit)
            $script:postCount | Should -BeGreaterThan 1 -Because '413 must trigger split-and-retry'
            # All 10 rows should eventually ingest (via the split-recurse)
            $result.RowsSent | Should -Be 10
        }
    }
}
