#Requires -Module Pester
# Pipes the captured TenantContext live response THROUGH the real Xdr.Poll module
# (with Invoke-XdrAuthHttp mocked to return the fixture body) and verifies:
#   1. Invoke-DefenderApiproxy classifies it as a JSON 200, not HTML
#   2. The parsed body retains the canonical OrgId/GeoRegion/DataCenter shape
#   3. The size budget for one row stays under DCE 900 KB safe ceiling
#
# Raises T1 coverage by exercising Xdr.Poll's response-parsing path with real data.

BeforeDiscovery {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ResponseFx     = Join-Path $script:RepoRoot 'tests\fixtures\live\TenantContext\response.json'
    $script:FixturePresent = Test-Path $script:ResponseFx
}

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ResponseFx = Join-Path $script:RepoRoot 'tests\fixtures\live\TenantContext\response.json'
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Ingest\Xdr.Ingest.psd1') -Force
    $script:LiveBody = Get-Content $script:ResponseFx -Raw
}

Describe 'Live fixture pipe-through Xdr.Poll + Xdr.Ingest' -Tag 'fixture-replay' -Skip:(-not $script:FixturePresent) {

    Context 'Invoke-DefenderApiproxy against the live TenantContext body' {

        BeforeEach {
            Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
                [pscustomobject]@{
                    StatusCode = 200
                    Headers    = @{ 'Content-Type' = 'application/json' }
                    Content    = $script:LiveBody
                    Session    = $Session
                }
            }
        }

        It 'classifies the live response as JSON 200 (not HTML, not auth-lost)' {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext' -Session $session
            $r.StatusCode | Should -Be 200
            $r.IsHtml     | Should -BeFalse
            $r.Parsed     | Should -Not -BeNullOrEmpty
        }

        It 'parsed body retains the canonical OrgId / GeoRegion / DataCenter shape' {
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext' -Session $session
            $r.Parsed.OrgId      | Should -Not -BeNullOrEmpty
            $r.Parsed.GeoRegion  | Should -Not -BeNullOrEmpty
            $r.Parsed.DataCenter | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Xdr.Ingest pipeline (Split-IngestBatch + chunking)' {

        It 'fits in a single 900 KB chunk (verifies live size assumption)' {
            $row = [pscustomobject]@{
                TimeGenerated = (Get-Date).ToUniversalTime().ToString('o')
                RawJson       = $script:LiveBody
            }
            $chunks = Split-IngestBatch -Rows @($row)
            @($chunks).Count | Should -Be 1
        }

        It 'gzip-encodes to under 100 KB (DCE network savings)' {
            $rowJson = @{
                TimeGenerated = (Get-Date).ToUniversalTime().ToString('o')
                RawJson       = $script:LiveBody
            } | ConvertTo-Json -Depth 5 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($rowJson)
            $ms = [System.IO.MemoryStream]::new()
            $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal)
            $gz.Write($bytes, 0, $bytes.Length); $gz.Dispose()
            $gzSize = $ms.ToArray().Length
            $ms.Dispose()
            $gzSize | Should -BeLessThan 100KB
        }
    }
}
