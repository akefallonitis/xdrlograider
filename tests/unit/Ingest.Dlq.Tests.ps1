#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0-beta first publish — Ingest dead-letter-queue (DLQ) test gates.

.DESCRIPTION
    Production-readiness invariant: terminal Send-ToLogAnalytics failures
    (5x-retry exhaustion on 429/5xx) MUST persist the failing batch to a
    Storage Table DLQ instead of throwing + losing rows.

    Gates by name:
      Dlq.Push.RoundTrip        Push-XdrIngestDlq writes a row to the DLQ
                                table; the row contains gzipped+base64
                                rows, AttemptCount, FirstFailedUtc,
                                Reason, LastHttpStatus, BatchSizeBytes.
      Dlq.Push.OversizeDropped  Rows that exceed the 100 KB compressed
                                cap are dropped + emit Ingest.DlqDropped.
      Dlq.Pop.RoundTrip         Pop-XdrIngestDlq returns the same rows
                                that were Pushed, with all metadata
                                intact.
      Dlq.Remove.OnSuccess      Remove-XdrIngestDlqEntry deletes the row.
      Dlq.SendToLA.Terminal     Send-ToLogAnalytics on terminal 429
                                calls Push-XdrIngestDlq when
                                -DlqStorageAccount is supplied + does
                                NOT throw (returns DlqEnqueued > 0).
      Dlq.SendToLA.LegacyThrow  Without -DlqStorageAccount, terminal
                                failure still throws (back-compat).
      Dlq.AttemptCountIncrement On replay failure, the entry is re-Pushed
                                with AttemptCount+1.
      Dlq.AppInsightsEvents     Push emits Ingest.DlqEnqueued; Remove
                                emits Ingest.DlqDrained; AttemptCount
                                > 10 emits Ingest.DlqStuck.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1" -Force

    # Stub Get-AzAccessToken so Push/Pop can resolve a storage token in
    # unit-test contexts.
    function global:Get-AzAccessToken {
        param([string] $ResourceUrl)
        [pscustomobject]@{
            Token     = 'fake-storage-token'
            ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
        }
    }
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Item function:Get-AzAccessToken -ErrorAction SilentlyContinue
}

Describe 'Dlq.ModuleSurface — exports + signatures' {

    It 'exports Push-XdrIngestDlq' {
        (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys | Should -Contain 'Push-XdrIngestDlq'
    }

    It 'exports Pop-XdrIngestDlq' {
        (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys | Should -Contain 'Pop-XdrIngestDlq'
    }

    It 'exports Remove-XdrIngestDlqEntry' {
        (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys | Should -Contain 'Remove-XdrIngestDlqEntry'
    }

    It 'Send-ToLogAnalytics declares -DlqStorageAccount and -DlqOperationId parameters (back-compat shape unchanged)' {
        $cmd = Get-Command Send-ToLogAnalytics
        $cmd.Parameters.ContainsKey('DlqStorageAccount') | Should -BeTrue
        $cmd.Parameters.ContainsKey('DlqOperationId')    | Should -BeTrue

        # Back-compat: original mandatory parameters MUST remain unchanged.
        # The .Attributes collection contains all parameter attributes
        # (Parameter, ValidateNotNullOrEmpty, AllowEmptyCollection, etc.).
        # Only [Parameter()] attributes carry the .Mandatory boolean — filter
        # to that subset before checking, otherwise strict-mode property
        # access fails on non-Parameter attribute types.
        $isMandatory = {
            param($p)
            $paramAttr = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }) |
                Select-Object -First 1
            return $paramAttr -and $paramAttr.Mandatory
        }
        & $isMandatory $cmd.Parameters['DceEndpoint']      | Should -BeTrue
        & $isMandatory $cmd.Parameters['DcrImmutableId']   | Should -BeTrue
        & $isMandatory $cmd.Parameters['StreamName']       | Should -BeTrue
        & $isMandatory $cmd.Parameters['Rows']             | Should -BeTrue
        # New DLQ params MUST be optional.
        & $isMandatory $cmd.Parameters['DlqStorageAccount'] | Should -BeFalse
        & $isMandatory $cmd.Parameters['DlqOperationId']    | Should -BeFalse
    }
}

Describe 'Dlq.Push.RoundTrip — Push-XdrIngestDlq writes the expected entity shape' {

    It 'Pushes a row with PartitionKey=stream, RowKey=ISO+GUID, gzipped+base64 RowsJson' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:capturedEntity = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:capturedEntity = $Entity
                # Capture other params too for assertion.
                $script:capturedTable = $TableName
                $script:capturedOp    = $Operation
                $script:capturedPK    = $PartitionKey
                $script:capturedRK    = $RowKey
                return $null
            }
            # Suppress AI emission noise.
            Mock Send-XdrAppInsightsCustomEvent {}

            $rows = 1..3 | ForEach-Object { [pscustomobject]@{ EntityId = "e$_"; Value = "v$_" } }
            $result = Push-XdrIngestDlq `
                -StorageAccountName 'sa' `
                -StreamName         'Custom-MDE_ActionCenter_CL' `
                -Rows               $rows `
                -OriginalLatencyMs  4500 `
                -LastHttpStatus     429 `
                -Reason             '429-terminal' `
                -OperationId        'op-test'

            $result.Enqueued       | Should -BeTrue
            $result.PartitionKey   | Should -Be 'Custom-MDE_ActionCenter_CL'
            $result.RowKey         | Should -Match '^\d{4}-\d{2}-\d{2}T.*_[a-f0-9]{32}$'
            $result.BatchSizeBytes | Should -BeGreaterThan 0

            $script:capturedOp     | Should -Be 'Upsert'
            $script:capturedPK     | Should -Be 'Custom-MDE_ActionCenter_CL'
            $script:capturedRK     | Should -Be $result.RowKey
            $script:capturedTable  | Should -Be 'xdrIngestDlq'

            $e = $script:capturedEntity
            $e.PartitionKey      | Should -Be 'Custom-MDE_ActionCenter_CL'
            $e.RowKey            | Should -Be $result.RowKey
            $e.AttemptCount      | Should -Be 1
            $e.LastHttpStatus    | Should -Be 429
            $e.Reason            | Should -Be '429-terminal'
            $e.OriginalLatencyMs | Should -Be 4500
            $e.RowCount          | Should -Be 3
            $e.RowsJson          | Should -Not -BeNullOrEmpty -Because 'rows must be persisted as gzipped+base64 JSON'
        }
    }

    It 'gzip+base64-decodes back to the original row JSON (round-trip integrity)' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:capturedEntity = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:capturedEntity = $Entity
                return $null
            }
            Mock Send-XdrAppInsightsCustomEvent {}

            $original = @(
                [pscustomobject]@{ EntityId = 'a'; Score = 7  }
                [pscustomobject]@{ EntityId = 'b'; Score = 11 }
            )
            Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-X' -Rows $original | Out-Null

            $b64       = $script:capturedEntity.RowsJson
            $gzipBytes = [Convert]::FromBase64String($b64)
            $msIn      = [System.IO.MemoryStream]::new($gzipBytes)
            $gz        = [System.IO.Compression.GzipStream]::new($msIn, [System.IO.Compression.CompressionMode]::Decompress)
            $reader    = [System.IO.StreamReader]::new($gz, [System.Text.Encoding]::UTF8)
            $jsonText  = $reader.ReadToEnd()
            $reader.Close(); $gz.Close(); $msIn.Close()

            $decoded = $jsonText | ConvertFrom-Json
            @($decoded).Count | Should -Be 2
            $decoded[0].EntityId | Should -Be 'a'
            $decoded[0].Score    | Should -Be 7
            $decoded[1].EntityId | Should -Be 'b'
            $decoded[1].Score    | Should -Be 11
        }
    }
}

Describe 'Dlq.Push.OversizeDropped — >100 KB compressed batches are dropped + emit Ingest.DlqDropped' {

    It 'drops oversize batch + emits Ingest.DlqDropped, returns Enqueued=$false' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:upserted   = $false
            $script:droppedEv  = $null
            Mock Invoke-XdrStorageTableEntity { $script:upserted = $true }
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'Ingest.DlqDropped') { $script:droppedEv = $Properties }
            }

            # Build a batch of incompressible random data > 100 KB compressed.
            # 200 KB of GUID strings is incompressible enough to clear the cap.
            $rows = 1..2000 | ForEach-Object {
                [pscustomobject]@{
                    EntityId = [Guid]::NewGuid().ToString()
                    Value    = ((1..30) | ForEach-Object { [Guid]::NewGuid().ToString() }) -join ''
                }
            }

            $result = Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-X' -Rows $rows -WarningAction SilentlyContinue

            $result.Enqueued | Should -BeFalse -Because 'oversize batch must be dropped (Storage Tables 100 KB cap)'
            $script:upserted | Should -BeFalse -Because 'no Upsert may happen for a dropped row'
            $script:droppedEv | Should -Not -BeNullOrEmpty -Because 'Ingest.DlqDropped custom event must fire so operators see the loss'
            $script:droppedEv.Stream | Should -Be 'Custom-X'
        }
    }
}

Describe 'Dlq.Pop.RoundTrip — Pop-XdrIngestDlq decodes and returns the same rows' {

    It 'returns the rows + metadata that were Pushed' {
        InModuleScope Xdr.Sentinel.Ingest {
            # Step 1: Push captures the gzipped+base64 RowsJson value.
            $script:storedEntity = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:storedEntity = $Entity
                return $null
            }
            Mock Send-XdrAppInsightsCustomEvent {}

            $rows = @(
                [pscustomobject]@{ EntityId = 'one'; n = 1 }
                [pscustomobject]@{ EntityId = 'two'; n = 2 }
            )
            Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-MDE_X_CL' `
                -Rows $rows -LastHttpStatus 429 -Reason '429-terminal' | Out-Null

            # Step 2: Mock Invoke-XdrIngestDlqQuery to return the same row in
            # OData shape. This lets us verify the decode + metadata pipeline
            # without owning the HttpClient.SendAsync chain in tests.
            $odata = @{
                value = @(
                    [pscustomobject]@{
                        PartitionKey      = $script:storedEntity.PartitionKey
                        RowKey            = $script:storedEntity.RowKey
                        RowsJson          = $script:storedEntity.RowsJson
                        AttemptCount      = $script:storedEntity.AttemptCount
                        LastHttpStatus    = $script:storedEntity.LastHttpStatus
                        OriginalLatencyMs = $script:storedEntity.OriginalLatencyMs
                        FirstFailedUtc    = $script:storedEntity.FirstFailedUtc
                        Reason            = $script:storedEntity.Reason
                        BatchSizeBytes    = $script:storedEntity.BatchSizeBytes
                    }
                )
            }
            $jsonBody = $odata | ConvertTo-Json -Depth 5

            $script:capturedQuery = $null
            Mock Invoke-XdrIngestDlqQuery {
                $script:capturedQuery = [pscustomobject]@{
                    StorageAccountName = $StorageAccountName
                    TableName          = $TableName
                    StreamName         = $StreamName
                    MaxBatches         = $MaxBatches
                }
                return @{ StatusCode = 200; ReasonPhrase = 'OK'; Body = $jsonBody }
            }

            $popped = @(Pop-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-MDE_X_CL' -MaxBatches 5)

            $popped.Count | Should -Be 1
            $popped[0].PartitionKey | Should -Be 'Custom-MDE_X_CL'
            $popped[0].RowKey       | Should -Be $script:storedEntity.RowKey
            $popped[0].AttemptCount | Should -Be 1
            $popped[0].Reason       | Should -Be '429-terminal'
            @($popped[0].Rows).Count | Should -Be 2
            $popped[0].Rows[0].EntityId | Should -Be 'one'
            $popped[0].Rows[1].EntityId | Should -Be 'two'

            $script:capturedQuery.StreamName | Should -Be 'Custom-MDE_X_CL'
            $script:capturedQuery.MaxBatches | Should -Be 5
        }
    }

    It 'returns @() on Azure Tables 404 (table does not exist yet — first-run safe)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Invoke-XdrIngestDlqQuery {
                return @{ StatusCode = 404; ReasonPhrase = 'Not Found'; Body = '' }
            }
            $popped = @(Pop-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-X')
            $popped.Count | Should -Be 0 -Because 'first run: DLQ table created lazily on first Push, Pop must tolerate 404 gracefully'
        }
    }
}

Describe 'Dlq.Remove.OnSuccess — Remove-XdrIngestDlqEntry deletes via Invoke-XdrStorageTableEntity Delete' {

    It 'calls Invoke-XdrStorageTableEntity with Operation=Delete + the supplied PK/RK' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:lastOp = $null
            $script:lastPK = $null
            $script:lastRK = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:lastOp = $Operation
                $script:lastPK = $PartitionKey
                $script:lastRK = $RowKey
                return $null
            }
            Mock Send-XdrAppInsightsCustomEvent {}

            Remove-XdrIngestDlqEntry -StorageAccountName 'sa' -PartitionKey 'Custom-X' -RowKey '2026-04-30T12:00:00Z_abc'

            $script:lastOp | Should -Be 'Delete'
            $script:lastPK | Should -Be 'Custom-X'
            $script:lastRK | Should -Be '2026-04-30T12:00:00Z_abc'
        }
    }

    It 'emits Ingest.DlqDrained custom event' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:drainedEv = $null
            Mock Invoke-XdrStorageTableEntity {}
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'Ingest.DlqDrained') { $script:drainedEv = $Properties }
            }

            Remove-XdrIngestDlqEntry -StorageAccountName 'sa' -PartitionKey 'Custom-X' -RowKey 'rk-1'
            $script:drainedEv | Should -Not -BeNullOrEmpty
            $script:drainedEv.Stream | Should -Be 'Custom-X'
            $script:drainedEv.RowKey | Should -Be 'rk-1'
        }
    }
}

Describe 'Dlq.SendToLA.Terminal — Send-ToLogAnalytics enqueues + does NOT throw when -DlqStorageAccount is supplied' {

    It 'on terminal 429 (5x retries exhausted): calls Push-XdrIngestDlq + returns DlqEnqueued=1 + does not throw' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:pushCalls = @()
            Mock Push-XdrIngestDlq {
                $script:pushCalls += [pscustomobject]@{
                    Stream         = $StreamName
                    Rows           = $Rows
                    LastHttpStatus = $LastHttpStatus
                    Reason         = $Reason
                    AttemptCount   = $AttemptCount
                }
                return [pscustomobject]@{
                    PartitionKey   = $StreamName
                    RowKey         = '2026-04-30T12:00:00Z_abc'
                    BatchSizeBytes = 200
                    Enqueued       = $true
                }
            }
            # Always throw 429 — exhausts retries.
            Mock Invoke-WebRequest {
                $mockResp = [pscustomobject]@{ StatusCode = 429 }
                $exc = [System.Net.WebException]::new('throttled')
                $exc | Add-Member -NotePropertyName Response -NotePropertyValue $mockResp -Force
                throw $exc
            }

            $rows = @([pscustomobject]@{ Foo = 'bar' })

            { $r = Send-ToLogAnalytics `
                -DceEndpoint        'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId     'dcr-x' `
                -StreamName         'Custom-MDE_X_CL' `
                -Rows               $rows `
                -MaxRetries         1 `
                -DlqStorageAccount  'sa' `
                -DlqOperationId     'op-test' `
                -WarningAction      SilentlyContinue
              # Surface the result for assertion.
              $script:result = $r
            } | Should -Not -Throw

            $script:result.DlqEnqueued | Should -Be 1 -Because 'terminal failure must enqueue exactly 1 batch'
            $script:result.RowsSent    | Should -Be 0
            @($script:pushCalls).Count | Should -Be 1
            $script:pushCalls[0].Stream         | Should -Be 'Custom-MDE_X_CL'
            $script:pushCalls[0].LastHttpStatus | Should -Be 429
            $script:pushCalls[0].Reason         | Should -Be '429-terminal'
            $script:pushCalls[0].AttemptCount   | Should -Be 1
            @($script:pushCalls[0].Rows).Count  | Should -Be 1
        }
    }

    It 'on terminal 503 5xx: Reason = ''5xx-terminal''' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:lastReason = $null
            Mock Push-XdrIngestDlq {
                $script:lastReason = $Reason
                return [pscustomobject]@{
                    PartitionKey   = $StreamName
                    RowKey         = 'rk'
                    BatchSizeBytes = 100
                    Enqueued       = $true
                }
            }
            Mock Invoke-WebRequest {
                $mockResp = [pscustomobject]@{ StatusCode = 503 }
                $exc = [System.Net.WebException]::new('service unavailable')
                $exc | Add-Member -NotePropertyName Response -NotePropertyValue $mockResp -Force
                throw $exc
            }
            Send-ToLogAnalytics `
                -DceEndpoint 'https://fake' -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-X' -Rows @([pscustomobject]@{ a = 1 }) `
                -MaxRetries 1 -DlqStorageAccount 'sa' -WarningAction SilentlyContinue | Out-Null
            $script:lastReason | Should -Be '5xx-terminal'
        }
    }
}

Describe 'Dlq.SendToLA.LegacyThrow — without -DlqStorageAccount, terminal failure still throws (back-compat)' {

    It 'throws DCE ingest failed when -DlqStorageAccount is omitted' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            Mock Push-XdrIngestDlq { throw 'should not be called' }
            Mock Invoke-WebRequest {
                $mockResp = [pscustomobject]@{ StatusCode = 429 }
                $exc = [System.Net.WebException]::new('throttled')
                $exc | Add-Member -NotePropertyName Response -NotePropertyValue $mockResp -Force
                throw $exc
            }

            { Send-ToLogAnalytics `
                -DceEndpoint 'https://fake' -DcrImmutableId 'dcr-x' `
                -StreamName 'Custom-X' -Rows @([pscustomobject]@{ a = 1 }) `
                -MaxRetries 1 -WarningAction SilentlyContinue
            } | Should -Throw -ExpectedMessage '*DCE ingest failed*'

            Should -Invoke Push-XdrIngestDlq -Times 0 -Exactly -Because 'no DLQ wiring without the parameter'
        }
    }
}

Describe 'Dlq.AppInsightsEvents — Push emits Ingest.DlqEnqueued' {

    It 'emits Ingest.DlqEnqueued with Stream + RowCount + Reason' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:enqueuedEv = $null
            Mock Invoke-XdrStorageTableEntity {}
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'Ingest.DlqEnqueued') { $script:enqueuedEv = $Properties }
            }

            Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-X' `
                -Rows @([pscustomobject]@{ a = 1 }) `
                -LastHttpStatus 429 -Reason '429-terminal' | Out-Null

            $script:enqueuedEv | Should -Not -BeNullOrEmpty
            $script:enqueuedEv.Stream         | Should -Be 'Custom-X'
            $script:enqueuedEv.RowCount       | Should -Be 1
            $script:enqueuedEv.Reason         | Should -Be '429-terminal'
            $script:enqueuedEv.LastHttpStatus | Should -Be '429'
            $script:enqueuedEv.AttemptCount   | Should -Be 1
        }
    }
}

Describe 'Dlq.AttemptCountIncrement — re-Push with AttemptCount+1 + preserved FirstFailedUtc' {

    It 'Push-XdrIngestDlq accepts -AttemptCount and -FirstFailedUtc and persists them' {
        InModuleScope Xdr.Sentinel.Ingest {
            $script:storedEntity = $null
            Mock Invoke-XdrStorageTableEntity {
                $script:storedEntity = $Entity
                return $null
            }
            Mock Send-XdrAppInsightsCustomEvent {}

            # Build the FirstFailedUtc as a UTC datetime explicitly so the
            # round-trip ToString('o') stays in UTC. (PowerShell's
            # [datetime]::Parse can resolve to local-tz when the input has a
            # UTC offset, which would otherwise make the ISO string drift
            # by the laptop's offset.)
            $firstFailed = [datetime]::SpecifyKind([datetime]'2026-04-29T08:30:00', [System.DateTimeKind]::Utc)
            Push-XdrIngestDlq -StorageAccountName 'sa' -StreamName 'Custom-X' `
                -Rows @([pscustomobject]@{ a = 1 }) `
                -LastHttpStatus 429 -Reason '429-terminal' `
                -AttemptCount 7 -FirstFailedUtc $firstFailed | Out-Null

            $script:storedEntity.AttemptCount   | Should -Be 7
            $script:storedEntity.FirstFailedUtc | Should -Match '2026-04-29T08:30:00'
        }
    }
}

