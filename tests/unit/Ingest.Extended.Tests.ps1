#Requires -Modules Pester
<#
.SYNOPSIS
    Extended coverage for XdrLogRaider.Ingest — batching, token caching,
    heartbeat/auth-test row schemas, checkpoint edge cases.

    These fill the gaps not covered by Send-ToLogAnalytics + error-handling suites.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1" -Force
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Send-ToLogAnalytics — batching' {

    It 'splits a large row set into multiple batches under MaxBatchBytes' {
        InModuleScope Xdr.Sentinel.Ingest {
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
        InModuleScope Xdr.Sentinel.Ingest {
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
        InModuleScope Xdr.Sentinel.Ingest {
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
        InModuleScope Xdr.Sentinel.Ingest {
            $script:MonitorTokenCache = 'cached-token'
            $script:MonitorTokenExpiry = [datetime]::UtcNow.AddMinutes(30)
            $token = Get-MonitorIngestionToken
            $token | Should -Be 'cached-token'
        }
    }

    It 'refreshes when within 5-min buffer' {
        InModuleScope Xdr.Sentinel.Ingest {
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
        InModuleScope Xdr.Sentinel.Ingest {
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
                -FunctionName 'Defender-ActionCenter-Refresh' `
                -Tier 'ActionCenter' `
                -StreamsAttempted 19 `
                -StreamsSucceeded 13 `
                -RowsIngested 412 `
                -LatencyMs 4300 | Out-Null

            $script:sent                   | Should -Not -BeNullOrEmpty
            $script:sent.TimeGenerated     | Should -Not -BeNullOrEmpty
            $script:sent.FunctionName      | Should -Be 'Defender-ActionCenter-Refresh'
            $script:sent.Tier              | Should -Be 'ActionCenter'
            $script:sent.StreamsAttempted  | Should -Be 19
            $script:sent.StreamsSucceeded  | Should -Be 13
            $script:sent.RowsIngested      | Should -Be 412
            $script:sent.LatencyMs         | Should -Be 4300
        }
    }

    It 'serialises Notes object into the row' {
        InModuleScope Xdr.Sentinel.Ingest {
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
                -Tier 'ActionCenter' `
                -StreamsAttempted 1 `
                -StreamsSucceeded 0 `
                -RowsIngested 0 `
                -LatencyMs 100 `
                -Notes $notes | Out-Null

            $script:sent.Notes | Should -Not -BeNullOrEmpty
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

# NOTE: Get-XdrAuthSelfTestFlag tests removed in v0.1.0-beta post-deploy
# hardening — see tests/unit/ModuleCoverage.Extended.Tests.ps1 for rationale.

Describe 'Set-CheckpointTimestamp / Get-CheckpointTimestamp — edge cases (via Invoke-XdrStorageTableEntity)' {
    # Iter 13.15: tests refactored to mock the unified helper instead of the
    # legacy AzTable / Az.Storage cmdlet chain. Public function contracts
    # (MinValue on missing/error, parses LastPolledUtc, no throw on first call)
    # are preserved across the refactor.

    It 'Get-CheckpointTimestamp returns MinValue when no row exists (first run)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrStorageTableEntity { $null }
            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL'
            # Function returns [datetime]::MinValue sentinel (not $null) — caller
            # compares against MinValue to decide "first run? use default window".
            $r | Should -Be ([datetime]::MinValue)
        }
    }

    It 'Get-CheckpointTimestamp parses stored UTC ISO-8601 from LastPolledUtc field' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrStorageTableEntity {
                [pscustomobject]@{ LastPolledUtc = '2026-04-23T10:00:00Z' }
            }
            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL'
            $r | Should -Not -BeNullOrEmpty
            $r.Year  | Should -Be 2026
            $r.Month | Should -Be 4
            $r.Day   | Should -Be 23
        }
    }

    It 'Get-CheckpointTimestamp returns MinValue when helper throws (fails closed)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrStorageTableEntity { throw 'simulated table failure' }
            $r = Get-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL' -WarningAction SilentlyContinue
            $r | Should -Be ([datetime]::MinValue)
        }
    }

    It 'Set-CheckpointTimestamp does not throw on first call (helper Upsert creates row)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrStorageTableEntity {}
            { Set-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL' } |
                Should -Not -Throw
        }
    }

    It 'Set-CheckpointTimestamp uses Upsert operation (not Get/Delete) — iter-13.15 contract' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:capturedOp = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:capturedOp = $Operation
            } -ParameterFilter { $true }
            Set-CheckpointTimestamp -StorageAccountName 'sa' -TableName 'cp' -StreamName 'MDE_Foo_CL' -WarningAction SilentlyContinue
            $script:capturedOp | Should -Be 'Upsert' -Because 'Set must call helper with -Operation Upsert (PUT WITHOUT If-Match = Insert-Or-Replace)'
        }
    }
}
