#Requires -Module Pester
# Locks B-8: HTML body in apiproxy response triggers reauth (not ingest).

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Poll\Xdr.Poll.psd1'
    $AuthPath   = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $AuthPath -Force
    Import-Module $ModulePath -Force
}

Describe 'Invoke-DefenderApiproxy — HTML sniff (B-8)' {

    It 'flags IsHtml=true when body starts with <!DOCTYPE' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='<!DOCTYPE html><html></html>'; Session=$Session }
        }
        # Suppress reauth attempt — return same mock so test stays offline
        Mock -ModuleName Xdr.Poll Connect-DefenderPortal { $null }
        Mock -ModuleName Xdr.Poll Get-XdrAuthFromKeyVault {
            [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='s'; AuthMethod='CredentialsTotp' }
        }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 0
        $r.IsHtml | Should -BeTrue
        $r.Parsed | Should -BeNullOrEmpty
    }

    It 'flags IsHtml=true when Content-Type header is text/html' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{
                StatusCode=200
                Headers=@{ 'Content-Type'='text/html; charset=utf-8' }
                Content='not html-prefixed but Content-Type says html'
                Session=$Session
            }
        }
        Mock -ModuleName Xdr.Poll Connect-DefenderPortal { $null }
        Mock -ModuleName Xdr.Poll Get-XdrAuthFromKeyVault {
            [pscustomobject]@{ Upn='x@y'; Password='p'; TotpSecret='s'; AuthMethod='CredentialsTotp' }
        }

        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 0
        $r.IsHtml | Should -BeTrue
    }

    It 'returns parsed JSON when body is valid JSON' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='{"tenantId":"abc","orgId":"def"}'; Session=$Session }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext' -Session $session
        $r.IsHtml | Should -BeFalse
        $r.Parsed | Should -Not -BeNullOrEmpty
        $r.Parsed.tenantId | Should -Be 'abc'
    }
}
