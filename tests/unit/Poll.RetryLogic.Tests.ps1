#Requires -Module Pester
# Locks: 401 silent reauth + retry; 429 Retry-After backoff.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Poll\Xdr.Poll.psd1'
    $AuthPath   = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $AuthPath -Force
    Import-Module $ModulePath -Force
}

Describe 'Invoke-DefenderApiproxy — retry logic' {

    # ITER6 R4+R5 · in-proxy silent reauth removed (was using -FromEnvLocal which throws in production FA).
    # New contract: simple retry-once on 401/HTML; 2nd failure throws [AuthChainBrokenException] so the
    # outer cycle catch in run.ps1 owns the -Force reauth via Connect-DefenderPortal + retry-once pattern.
    It 'retries once on 401 then returns success on 200 (no in-proxy reauth · single auth-cascade)' {
        $script:callCount = 0
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            $script:callCount++
            if ($script:callCount -eq 1) {
                [pscustomobject]@{ StatusCode=401; Headers=@{}; Content='Unauthorized'; Session=$Session }
            } else {
                [pscustomobject]@{ StatusCode=200; Headers=@{}; Content='{"ok":true}'; Session=$Session }
            }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 1
        $r.StatusCode | Should -Be 200
        $r.Reauthed   | Should -BeTrue
        $r.Attempts   | Should -Be 2
    }

    It 'throws AuthChainBrokenException on persistent 401 (2nd attempt also fails · run.ps1 outer catch handles reauth)' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{ StatusCode=401; Headers=@{}; Content='Unauthorized'; Session=$Session }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 1 } |
            Should -Throw -ExpectedMessage '*Apiproxy auth chain broken*'
    }

    It 'throws AuthChainBrokenException on persistent HTML-at-JSON (auth-chain stale)' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{ StatusCode=200; Headers=@{'Content-Type'='text/html'}; Content='<!DOCTYPE html><html>login</html>'; Session=$Session }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 1 } |
            Should -Throw -ExpectedMessage '*Apiproxy auth chain broken*'
    }

    It 'respects 429 Retry-After header (capped at 60s; we set MaxRetries=0 to skip the actual sleep loop)' {
        Mock -ModuleName Xdr.Poll Invoke-XdrAuthHttp {
            [pscustomobject]@{
                StatusCode=429
                Headers=@{ 'Retry-After'='5' }
                Content='Throttled'
                Session=$Session
            }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $r = Invoke-DefenderApiproxy -Path '/apiproxy/mtp/foo' -Session $session -MaxRetries 0
        $r.StatusCode | Should -Be 429
    }
}
