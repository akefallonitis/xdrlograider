#Requires -Version 7.4
# CR2 RED pin (audit 2026-06-12) · a 403 csrf/xsrf-token-mismatch is AUTH-LOSS (a stale/rotated XSRF on an
# otherwise-valid sccauth), NOT capability-absence. The old code let EVERY terminal 403 fall to capability-absent
# posture → the op posture-skipped FOREVER (silent zero-rows stall while ExpiresUtc kept the session "alive").
# A csrf 403 must throw AuthChainBroken so Invoke-XdrAuthenticated re-captures a fresh sccauth+XSRF. A NON-csrf
# 403 (real license/capability gap) must stay terminal → posture.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'CR2 · 403 csrf-token-mismatch → AuthChainBroken (reauth), not capability-absent' {
    It 'a 403 with a CSRF/XSRF body throws AuthChainBroken (reauth re-captures XSRF)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest { @{ StatusCode = 403; Content = '{"error":"CSRF token validation failed"}'; Headers = @{} } }
        Mock -ModuleName Xdr.Common.Runtime Write-Host { }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $err = { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/x' } | Should -Throw -PassThru
        $err.Exception.GetType().Name | Should -Be 'AuthChainBrokenException'
    }
    It 'a 403 WITHOUT a csrf body stays terminal (real license/capability gap → posture upstream)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest { @{ StatusCode = 403; Content = '{"error":"Forbidden: tenant not licensed"}'; Headers = @{} } }
        Mock -ModuleName Xdr.Common.Runtime Write-Host { }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $err = { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' } | Should -Throw -PassThru
        $err.Exception.GetType().Name | Should -Be 'XdrPortalTerminalException'
    }
}
