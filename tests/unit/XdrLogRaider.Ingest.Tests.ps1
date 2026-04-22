#Requires -Modules Pester

BeforeAll {
    $script:IngestModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psd1'

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
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'XdrLogRaider.Ingest module surface' {
    It 'exports Send-ToLogAnalytics, Write-Heartbeat, Write-AuthTestResult, Get-CheckpointTimestamp, Set-CheckpointTimestamp' {
        $exported = (Get-Module XdrLogRaider.Ingest).ExportedFunctions.Keys
        $exported | Should -Contain 'Send-ToLogAnalytics'
        $exported | Should -Contain 'Write-Heartbeat'
        $exported | Should -Contain 'Write-AuthTestResult'
        $exported | Should -Contain 'Get-CheckpointTimestamp'
        $exported | Should -Contain 'Set-CheckpointTimestamp'
    }

    It 'has PowerShell 7.4+ requirement' {
        $manifest = Import-PowerShellDataFile -Path $script:IngestModulePath
        $manifest.PowerShellVersion | Should -Be '7.4'
        $manifest.CompatiblePSEditions | Should -Contain 'Core'
    }
}

Describe 'Send-ToLogAnalytics' {
    It 'returns zero-row summary for empty input' {
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        InModuleScope XdrLogRaider.Ingest {
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
        It 'returns $true when checkpoint row exists with Success=true' {
            Mock -ModuleName XdrLogRaider.Ingest Get-AzTableRow -MockWith {
                [pscustomobject]@{ Success = $true; TimeUtc = [datetime]::UtcNow }
            }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeTrue
        }

        It 'returns $false when checkpoint row exists with Success=false' {
            Mock -ModuleName XdrLogRaider.Ingest Get-AzTableRow -MockWith {
                [pscustomobject]@{ Success = $false; TimeUtc = [datetime]::UtcNow }
            }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeFalse
        }

        It 'returns $false when no checkpoint row exists yet (first deployment)' {
            Mock -ModuleName XdrLogRaider.Ingest Get-AzTableRow -MockWith { $null }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeFalse
        }

        It 'returns $false (fails closed) when the table does not exist yet' {
            Mock -ModuleName XdrLogRaider.Ingest Get-AzStorageTable -MockWith { $null }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck'
            $result | Should -BeFalse
        }

        It 'returns $false (fails closed) when New-AzStorageContext throws' {
            Mock -ModuleName XdrLogRaider.Ingest New-AzStorageContext -MockWith { throw 'auth failure' }
            $result = Get-XdrAuthSelfTestFlag -StorageAccountName 'st' -CheckpointTable 'ck' -WarningAction SilentlyContinue
            $result | Should -BeFalse
        }
    }
}
