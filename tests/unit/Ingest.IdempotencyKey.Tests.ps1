#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0-beta production-readiness polish — DCE idempotency-key gates.

.DESCRIPTION
    Send-ToLogAnalytics MUST stamp each batch POST with a fresh
    x-ms-client-request-id GUID so the DCE side can dedupe transient retries.
    Without this, a 429-storm + retry can produce duplicate rows in the
    target Log Analytics table (DCE-side replay protection requires the
    client request id header).

    Gates by name:
      Idempotency.HeaderPresent     POST request includes
                                    x-ms-client-request-id header.
      Idempotency.FreshPerBatch     Two consecutive batches in one
                                    Send-ToLogAnalytics call generate
                                    DIFFERENT request ids.
      Idempotency.DepStamped        The request id is stamped into the
                                    dependency telemetry properties so
                                    operators can correlate end-to-end.
      Idempotency.RetryReuse        On a transient retry of the SAME batch,
                                    the request id is REUSED (so the DCE
                                    actually dedupes).
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1" -Force
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Idempotency.HeaderPresent — Send-ToLogAnalytics stamps x-ms-client-request-id on every POST' {

    It 'Invoke-WebRequest is called with a x-ms-client-request-id header on the success path' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            $script:capturedHeaders = @()
            Mock Invoke-WebRequest {
                $script:capturedHeaders += ,$Headers
                return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            Mock Send-XdrAppInsightsDependency  {}
            Mock Send-XdrAppInsightsCustomMetric {}

            $result = Send-ToLogAnalytics `
                -DceEndpoint    'https://fake.eastus.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName     'Custom-MDE_X_CL' `
                -Rows           @([pscustomobject]@{ a = 1 })

            $result.RowsSent    | Should -Be 1
            $result.BatchesSent | Should -Be 1

            @($script:capturedHeaders).Count | Should -Be 1
            $h = $script:capturedHeaders[0]
            $h.ContainsKey('x-ms-client-request-id') | Should -BeTrue -Because 'DCE-side dedup requires this header on every POST'
            $h['x-ms-client-request-id'] | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        }
    }
}

Describe 'Idempotency.FreshPerBatch — distinct request ids across distinct batches' {

    It 'two POSTs in one call (split batches) carry DIFFERENT x-ms-client-request-id values' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            $script:capturedHeaders = @()
            Mock Invoke-WebRequest {
                $script:capturedHeaders += ,$Headers
                return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            Mock Send-XdrAppInsightsDependency  {}
            Mock Send-XdrAppInsightsCustomMetric {}

            # Force two batches with a tight per-batch byte cap so the
            # batching logic emits 2 separate POSTs — each must have its
            # own fresh request id.
            $rowA = [pscustomobject]@{ payload = ('a' * 200) }
            $rowB = [pscustomobject]@{ payload = ('b' * 200) }
            Send-ToLogAnalytics `
                -DceEndpoint    'https://fake.eastus.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName     'Custom-MDE_X_CL' `
                -Rows           @($rowA, $rowB) `
                -MaxBatchBytes  300 | Out-Null

            @($script:capturedHeaders).Count | Should -Be 2 -Because 'tight byte cap forces 2 batches'
            $script:capturedHeaders[0]['x-ms-client-request-id'] |
                Should -Not -Be $script:capturedHeaders[1]['x-ms-client-request-id'] `
                -Because 'each batch must carry a fresh GUID — distinct batches must NOT share an id'
        }
    }
}

Describe 'Idempotency.DepStamped — the request id is stamped on the dependency telemetry' {

    It 'Send-XdrAppInsightsDependency receives BatchId in -Properties matching the POST header' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            $script:capturedHeaders = @()
            Mock Invoke-WebRequest {
                $script:capturedHeaders += ,$Headers
                return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            $script:capturedDepProps = @()
            Mock Send-XdrAppInsightsDependency {
                $script:capturedDepProps += ,$Properties
            }
            Mock Send-XdrAppInsightsCustomMetric {}

            Send-ToLogAnalytics `
                -DceEndpoint    'https://fake.eastus.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName     'Custom-MDE_X_CL' `
                -Rows           @([pscustomobject]@{ a = 1 }) | Out-Null

            @($script:capturedDepProps).Count | Should -BeGreaterOrEqual 1
            $headerId = $script:capturedHeaders[0]['x-ms-client-request-id']
            $depProps = $script:capturedDepProps[0]
            $depProps.ContainsKey('BatchId') | Should -BeTrue
            [string]$depProps['BatchId'] | Should -Be $headerId -Because 'dependency telemetry must carry the same id stamped on the wire'
        }
    }
}

Describe 'Idempotency.RetryReuse — same batch retried = same request id' {

    It 'on transient 503 retry, the second POST reuses the request id from the first attempt' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'tok' }
            Mock Start-Sleep {}
            $script:capturedHeaders = @()
            $script:callCount = 0
            Mock Invoke-WebRequest {
                $script:capturedHeaders += ,$Headers
                $script:callCount++
                if ($script:callCount -eq 1) {
                    # First call — fail with 503 so the retry loop spins.
                    $resp = [pscustomobject]@{ StatusCode = 503 }
                    $exc = [System.Net.WebException]::new('flaky')
                    $exc | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
                    throw $exc
                }
                return [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            Mock Send-XdrAppInsightsDependency  {}
            Mock Send-XdrAppInsightsCustomMetric {}

            Send-ToLogAnalytics `
                -DceEndpoint    'https://fake.eastus.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-x' `
                -StreamName     'Custom-MDE_X_CL' `
                -Rows           @([pscustomobject]@{ a = 1 }) `
                -MaxRetries     3 `
                -WarningAction  SilentlyContinue | Out-Null

            @($script:capturedHeaders).Count | Should -Be 2 -Because 'first call 503; second call success'
            $script:capturedHeaders[0]['x-ms-client-request-id'] |
                Should -Be $script:capturedHeaders[1]['x-ms-client-request-id'] `
                -Because 'DCE dedup requires the SAME id on retried calls'
        }
    }
}
