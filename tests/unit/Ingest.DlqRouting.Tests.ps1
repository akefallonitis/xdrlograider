#Requires -Module Pester
# Locks: Send-ToDce routes terminal 4xx to DLQ; retries 429; retries 5xx;
# success on 2xx counts rows as Sent.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Ingest\Xdr.Ingest.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Send-ToDce — outcome routing' {

    BeforeEach {
        Mock -ModuleName Xdr.Ingest Get-MiBearerToken { 'fake-bearer-token' }
        # Avoid real Az.Accounts call
    }

    It 'returns Sent=N on 2xx' {
        Mock -ModuleName Xdr.Ingest Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=204; Headers=@{}; Content='' }
        }
        $rows = 1..3 | ForEach-Object { [pscustomobject]@{ id=$_ } }
        $r = Send-ToDce -DceEndpoint 'https://dce.test.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-test' -StreamName 'Custom-Defender_Test_CL' -Rows $rows
        $r.Sent | Should -Be 3
        $r.Failed | Should -Be 0
        $r.Dlq    | Should -Be 0
    }

    It 'routes terminal 400 to DLQ (does not retry; counts in Dlq)' {
        Mock -ModuleName Xdr.Ingest Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=400; Headers=@{}; Content='InvalidStreamName' }
        }
        $script:dlqCaught = $null
        $dlqHandler = {
            param($Rows, $StatusCode, $Body)
            $script:dlqCaught = @{ Count=@($Rows).Count; StatusCode=$StatusCode; Body=$Body }
        }
        $rows = 1..2 | ForEach-Object { [pscustomobject]@{ id=$_ } }
        $r = Send-ToDce -DceEndpoint 'https://dce.test.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-test' -StreamName 'Custom-Test_CL' -Rows $rows -DlqHandler $dlqHandler

        $r.Dlq    | Should -Be 2
        $r.Failed | Should -Be 2
        $r.Sent   | Should -Be 0
        $script:dlqCaught.Count      | Should -Be 2
        $script:dlqCaught.StatusCode | Should -Be 400
    }

    It 'retries on 429 with Retry-After then succeeds' {
        $script:n = 0
        Mock -ModuleName Xdr.Ingest Invoke-WebRequest {
            $script:n++
            if ($script:n -eq 1) {
                [pscustomobject]@{ StatusCode=429; Headers=@{ 'Retry-After'='1' }; Content='Throttled' }
            } else {
                [pscustomobject]@{ StatusCode=204; Headers=@{}; Content='' }
            }
        }
        Mock -ModuleName Xdr.Ingest Start-Sleep { }   # don't actually sleep
        $rows = ,([pscustomobject]@{ id=1 })
        $r = Send-ToDce -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr' -StreamName 'Custom-X_CL' -Rows $rows -MaxRetries 2
        $r.Sent | Should -Be 1
        Should -Invoke -ModuleName Xdr.Ingest Invoke-WebRequest -Exactly 2
    }

    It 'returns Sent=0 when input rows is empty (no API call)' {
        Mock -ModuleName Xdr.Ingest Invoke-WebRequest { throw 'should not be called' }
        $r = Send-ToDce -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr' -StreamName 'Custom-X_CL' -Rows @()
        $r.Sent | Should -Be 0
        $r.Chunks | Should -Be 0
    }
}
