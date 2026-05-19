#Requires -Module Pester
# Locks B-25: Invoke-XdrAuthHttp serialization checks `-isnot [string]` FIRST.
# A pre-encoded string body MUST pass through unchanged (not double-JSON-encoded).
#
# Uses Pester 5's `Should -Invoke ... -ParameterFilter` to assert what was passed
# to the mocked Invoke-WebRequest, avoiding cross-scope variable capture issues.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Invoke-XdrAuthHttp — B-25 type-trap guard' {

    It 'passes a pre-encoded JSON STRING body through unchanged (no double-encode)' {
        $preEncoded = '{"Method":"BeginAuth","FlowToken":"tok"}'
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='{"ok":true}' }
        }
        $null = Invoke-XdrAuthHttp -Uri 'https://example.test' -Method POST -Body $preEncoded -ContentType 'application/json'
        Should -Invoke -ModuleName Xdr.Auth Invoke-WebRequest -Exactly 1 -ParameterFilter { $Body -eq $preEncoded }
    }

    It 'serializes a hashtable body to JSON when content-type is JSON' {
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='{}' }
        }
        $body = @{ Method='BeginAuth'; FlowToken='tok' }
        $null = Invoke-XdrAuthHttp -Uri 'https://example.test' -Method POST -Body $body -ContentType 'application/json'
        Should -Invoke -ModuleName Xdr.Auth Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $Body -is [string] -and ($Body | ConvertFrom-Json).Method -eq 'BeginAuth'
        }
    }

    It 'passes hashtable through unchanged for form-urlencoded content-type' {
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='' }
        }
        $body = @{ UPN='user@tenant'; Password='p' }
        $null = Invoke-XdrAuthHttp -Uri 'https://example.test' -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded'
        Should -Invoke -ModuleName Xdr.Auth Invoke-WebRequest -Exactly 1 -ParameterFilter {
            $Body -is [hashtable] -and $Body.UPN -eq 'user@tenant'
        }
    }

    It 'returns a structured response object with StatusCode/Headers/Content/Session' {
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            [pscustomobject]@{ StatusCode=200; Headers=@{ 'X-T'='1' }; Content='{"ok":true}' }
        }
        $r = Invoke-XdrAuthHttp -Uri 'https://example.test' -Method GET
        $r.StatusCode | Should -Be 200
        $r.Content    | Should -Be '{"ok":true}'
    }

    It 'returns a structured error object on HTTP failure (does not throw)' {
        Mock -ModuleName Xdr.Auth Invoke-WebRequest { throw 'network down' }
        $r = Invoke-XdrAuthHttp -Uri 'https://example.test' -Method GET
        $r.StatusCode | Should -Be -1
        $r.Error      | Should -Not -BeNullOrEmpty
    }
}
