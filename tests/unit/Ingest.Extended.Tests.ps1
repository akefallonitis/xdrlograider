#Requires -Modules Pester
<#
.SYNOPSIS
    Extended coverage for XdrLogRaider.Ingest — batching, token caching,
    heartbeat/auth-test row schemas, checkpoint edge cases.

    These fill the gaps not covered by Send-ToLogAnalytics + error-handling suites.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module "$script:Root/src/Modules/XdrLogRaider.Ingest/XdrLogRaider.Ingest.psd1" -Force
}

AfterAll {
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Send-ToLogAnalytics — batching' {

    It 'splits a large row set into multiple batches under MaxBatchBytes' {
        InModuleScope XdrLogRaider.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep {}
            $script:posts = 0
            Mock Invoke-WebRequest {
                $script:posts++
                @{ StatusCode = 204 }
            }

            # Build 50 rows of ~25 KB each ≈ 1.25 MB total → forces 2+ batches at 900 KB default
            $rows = 1..50 | ForEach-Object {
                [pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o'); payload = 'x' * 25000 }
            }

            $r = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-Test_CL' `
                -Rows $rows

            $r.RowsSent | Should -Be 50
            $r.BatchesSent | Should -BeGreaterThan 1 -Because '50×25KB rows exceeds 900KB single-batch limit'
            $script:posts | Should -Be $r.BatchesSent
        }
    }

    It 'single small row produces exactly 1 batch' {
        InModuleScope XdrLogRaider.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep {}
            Mock Invoke-WebRequest { @{ StatusCode = 204 } }

            $r = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-Test_CL' `
                -Rows @([pscustomobject]@{ foo = 'bar' })

            $r.BatchesSent | Should -Be 1
            $r.RowsSent    | Should -Be 1
        }
    }

    It 'surfaces LatencyMs in the result' {
        InModuleScope XdrLogRaider.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep {}
            Mock Invoke-WebRequest { @{ StatusCode = 204 } }

            $r = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-Test_CL' `
                -Rows @([pscustomobject]@{ foo = 'bar' })

            $r.LatencyMs | Should -BeGreaterOrEqual 0
            $r.StreamName | Should -Be 'Custom-Test_CL'
        }
    }
}

Describe 'Get-MonitorIngestionToken — caching' {

    It 'caches the token across calls until within the 5-min expiry buffer' {
        InModuleScope XdrLogRaider.Ingest {
            $script:MonitorTokenCache = 'cached-token'
            $script:MonitorTokenExpiry = [datetime]::UtcNow.AddMinutes(30)
            $token = Get-MonitorIngestionToken
            $token | Should -Be 'cached-token'
        }
    }

    It 'refreshes when within 5-min buffer' {
        InModuleScope XdrLogRaider.Ingest {
            # Stub Get-AzAccessToken so Mock has a command to intercept
            if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
                function script:Get-AzAccessToken { param($ResourceUrl, $ErrorAction) @{ Token = 'stub'; ExpiresOn = [datetime]::UtcNow.AddHours(1) } }
            }
            $script:MonitorTokenCache = 'stale-token'
            $script:MonitorTokenExpiry = [datetime]::UtcNow.AddMinutes(3)   # under 5-min buffer

            # ExpiresOn must be DateTimeOffset — newer Az returns that type and
            # Get-MonitorIngestionToken parses via [datetime]::Parse on string form.
            Mock Get-AzAccessToken {
                @{ Token = 'fresh-token'; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) }
            }

            $token = Get-MonitorIngestionToken
            $token | Should -Not -BeNullOrEmpty
            $token | Should -Not -Be 'stale-token' -Because 'cache within 5-min buffer must refresh'
        }
    }
}

Describe 'Write-Heartbeat — schema' {

    # v0.1.0-beta: Send-ToLogAnalytics gzip-compresses POST bodies by default.
    # Test mocks receive $Body as byte[] instead of raw JSON string. Inlined
    # decompression per-mock (script-scope helpers don't traverse InModuleScope
    # cleanly in Pester 5).

    It 'builds a row with all required fields + POSTs to DCE' {
        InModuleScope XdrLogRaider.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:sent = $null
            Mock Invoke-WebRequest {
                $decoded = if ($Body -is [byte[]]) {
                    $ms = [System.IO.MemoryStream]::new($Body)
                    $gz = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
                    $reader = [System.IO.StreamReader]::new($gz)
                    $text = $reader.ReadToEnd()
                    $reader.Close(); $gz.Close(); $ms.Close()
                    $text
                } else { $Body }
                $script:sent = ($decoded | ConvertFrom-Json) | Select-Object -First 1
                @{ StatusCode = 204 }
            }

            Write-Heartbeat `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -FunctionName 'poll-p0-compliance-1h' `
                -Tier 'P0' `
                -StreamsAttempted 19 `
                -StreamsSucceeded 13 `
                -RowsIngested 412 `
                -LatencyMs 4300 | Out-Null

            $script:sent                   | Should -Not -BeNullOrEmpty
            $script:sent.TimeGenerated     | Should -Not -BeNullOrEmpty
            $script:sent.FunctionName      | Should -Be 'poll-p0-compliance-1h'
            $script:sent.Tier              | Should -Be 'P0'
            $script:sent.StreamsAttempted  | Should -Be 19
            $script:sent.StreamsSucceeded  | Should -Be 13
            $script:sent.RowsIngested      | Should -Be 412
            $script:sent.LatencyMs         | Should -Be 4300
        }
    }

    It 'serialises Notes object into the row' {
        InModuleScope XdrLogRaider.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:sent = $null
            Mock Invoke-WebRequest {
                $decoded = if ($Body -is [byte[]]) {
                    $ms = [System.IO.MemoryStream]::new($Body)
                    $gz = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
                    $reader = [System.IO.StreamReader]::new($gz)
                    $text = $reader.ReadToEnd()
                    $reader.Close(); $gz.Close(); $ms.Close()
                    $text
                } else { $Body }
                $script:sent = ($decoded | ConvertFrom-Json) | Select-Object -First 1
                @{ StatusCode = 204 }
            }

            $notes = [pscustomobject]@{ errors = @{ MDE_Foo_CL = 'boom' } }

            Write-Heartbeat `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -FunctionName 'poll-test' `
                -Tier 'P0' `
                -StreamsAttempted 1 `
                -StreamsSucceeded 0 `
                -RowsIngested 0 `
                -LatencyMs 100 `
                -Notes $notes | Out-Null

            $script:sent.Notes | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Write-AuthTestResult — schema' {

    It 'invokes Send-ToLogAnalytics with the correct stream name + Success field' {
        InModuleScope XdrLogRaider.Ingest {
            $script:sentStream = $null
            $script:sentSuccess = $null
            Mock Send-ToLogAnalytics {
                param($DceEndpoint, $DcrImmutableId, $StreamName, $Rows)
                $script:sentStream = $StreamName
                $script:sentSuccess = $Rows[0].Success
                @{ RowsSent = 1 }
            }

            $authRes = [pscustomobject]@{
                Success       = $true
                Stage         = 'complete'
                Method        = 'CredentialsTotp'
                PortalHost    = 'security.microsoft.com'
                Upn           = 'svc@test.com'
                FailureReason = $null
                StageTimings  = @{ estsMs = 100; sccauthMs = 50 }
                SampleCallHttpCode = 200
                SampleCallLatencyMs = 120
                SccauthAcquiredUtc = [datetime]::UtcNow
            }

            Write-AuthTestResult `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -TestResult $authRes | Out-Null

            $script:sentStream  | Should -Be 'Custom-MDE_AuthTestResult_CL'
            $script:sentSuccess | Should -BeTrue
        }
    }
}

Describe 'Set-CheckpointTimestamp / Get-CheckpointTimestamp — edge cases' {

    BeforeAll {
        InModuleScope XdrLogRaider.Ingest {
            if (-not (Get-Command New-AzStorageContext -ErrorAction SilentlyContinue -CommandType Function)) {
                function script:New-AzStorageContext { param($StorageAccountName, [switch]$UseConnectedAccount, $ErrorAction) @{} }
            }
            if (-not (Get-Command Get-AzStorageTable -ErrorAction SilentlyContinue -CommandType Function)) {
                function script:Get-AzStorageTable { param($Name, $Context, $ErrorAction) @{ CloudTable = @{} } }
            }
            if (-not (Get-Command New-AzStorageTable -ErrorAction SilentlyContinue -CommandType Function)) {
                function script:New-AzStorageTable { param($Name, $Context, $ErrorAction) @{ CloudTable = @{} } }
            }
            if (-not (Get-Command Add-AzTableRow -ErrorAction SilentlyContinue -CommandType Function)) {
                function script:Add-AzTableRow { param($Table, $PartitionKey, $RowKey, $Property, [switch]$UpdateExisting, $ErrorAction) $null }
            }
            if (-not (Get-Command Get-AzTableRow -ErrorAction SilentlyContinue -CommandType Function)) {
                function script:Get-AzTableRow { param($Table, $PartitionKey, $RowKey, $ErrorAction) $null }
            }
        }
    }

    It 'Get-CheckpointTimestamp returns MinValue when no row exists (first run)' {
        InModuleScope XdrLogRaider.Ingest {
            Mock New-AzStorageContext { @{} }
            Mock Get-AzStorageTable { @{ CloudTable = @{} } }
            Mock Get-AzTableRow { $null }

            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL'
            # Function returns [datetime]::MinValue sentinel (not $null) — caller
            # compares against MinValue to decide "first run? use default window".
            $r | Should -Be ([datetime]::MinValue)
        }
    }

    It 'Get-CheckpointTimestamp parses stored UTC ISO-8601 from LastPolledUtc field' {
        InModuleScope XdrLogRaider.Ingest {
            Mock New-AzStorageContext { @{} }
            Mock Get-AzStorageTable { @{ CloudTable = @{} } }
            Mock Get-AzTableRow {
                [pscustomobject]@{ LastPolledUtc = '2026-04-23T10:00:00Z' }
            }

            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL'
            $r | Should -Not -BeNullOrEmpty
            $r.Year  | Should -Be 2026
            $r.Month | Should -Be 4
            $r.Day   | Should -Be 23
        }
    }

    It 'Get-CheckpointTimestamp returns MinValue on table-missing (fails closed)' {
        InModuleScope XdrLogRaider.Ingest {
            Mock New-AzStorageContext { @{} }
            Mock Get-AzStorageTable { $null }

            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL'
            $r | Should -Be ([datetime]::MinValue)
        }
    }

    It 'Set-CheckpointTimestamp does not throw on first call (creates table if missing)' {
        InModuleScope XdrLogRaider.Ingest {
            Mock New-AzStorageContext { @{} }
            Mock Get-AzStorageTable  { $null }                         # table missing
            Mock New-AzStorageTable  { @{ CloudTable = @{} } }         # will be created
            Mock Add-AzTableRow {}

            { Set-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL' } |
                Should -Not -Throw
        }
    }
}
