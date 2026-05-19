#Requires -Module Pester
# Locks: Write-Heartbeat emits exactly 1 row to Custom-Defender_Health_CL stream
# with the schema the Sentinel card freshness KQL expects.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Ingest\Xdr.Ingest.psd1'
    Import-Module $ModulePath -Force

    # Helper visible to Pester filter blocks: decompress gzip bytes -> hashtable[]
    function Read-GzipJson {
        param([byte[]]$Bytes)
        $ms = [System.IO.MemoryStream]::new($Bytes)
        $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
        $sr = [System.IO.StreamReader]::new($gz)
        $json = $sr.ReadToEnd()
        $sr.Dispose(); $gz.Dispose(); $ms.Dispose()
        $json | ConvertFrom-Json
    }
}

Describe 'Write-Heartbeat' {

    BeforeEach {
        Mock -ModuleName Xdr.Ingest Get-MiBearerToken { 'fake-bearer-token' }
        Mock -ModuleName Xdr.Ingest Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=204; Headers=@{}; Content='' }
        }
    }

    It 'emits exactly 1 row to Custom-XdrConnectorHealth_CL stream (P-5 default · Reinforcement-B/C)' {
        $r = Write-Heartbeat -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr-health' -Status 'OK' -Note 'test'
        $r.Sent | Should -Be 1
        Should -Invoke -ModuleName Xdr.Ingest Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $Uri -match 'streams/Custom-XdrConnectorHealth_CL'
        }
    }

    It 'sets SuccessKind=live and Endpoint=heartbeat when Status=OK' {
        $null = Write-Heartbeat -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr-health' -Status 'OK'
        Should -Invoke -ModuleName Xdr.Ingest Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $rows = Read-GzipJson -Bytes $Body
            $rows[0].SuccessKind -eq 'live' -and
            $rows[0].Endpoint    -eq 'heartbeat' -and
            $rows[0].SourceSystem -eq 'xdrlograider'
        }
    }

    It 'sets SuccessKind=error when Status != OK' {
        $null = Write-Heartbeat -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr-health' -Status 'AuthFatal' -Note 'reauth failed'
        Should -Invoke -ModuleName Xdr.Ingest Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $rows = Read-GzipJson -Bytes $Body
            $rows[0].SuccessKind -eq 'error' -and $rows[0].Status -eq 'AuthFatal'
        }
    }

    It 'sets TimeGenerated within 10 seconds of now (round-trip-safe)' {
        $null = Write-Heartbeat -DceEndpoint 'https://dce.test' -DcrImmutableId 'dcr-health'
        Should -Invoke -ModuleName Xdr.Ingest Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $rows = Read-GzipJson -Bytes $Body
            # ConvertFrom-Json auto-converts ISO strings to [datetime]; accept either form.
            $tg = if ($rows[0].TimeGenerated -is [datetime]) {
                $rows[0].TimeGenerated
            } else {
                [DateTimeOffset]::Parse([string]$rows[0].TimeGenerated).UtcDateTime
            }
            ([datetime]::UtcNow - $tg.ToUniversalTime()).TotalSeconds -lt 10
        }
    }
}
