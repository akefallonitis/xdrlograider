#Requires -Version 7.4
# F1.4b · Invoke-XdrPortalHttp · AuthMode-routed transport + response Headers (the multi-portal transport seam).
# BEFORE: the transport was COOKIE-ONLY — it built Cookie + X-XSRF-TOKEN from the session and had no bearer path, and
# the success return dropped the response Headers (so RFC5988 `Link:`-header cursor pagination — Graph / Entra /
# SharePoint — could never run). The Portal Registry's AuthMode now routes the auth header: Bearer → Authorization:
# Bearer <token>; Cookie → the Defender path (byte-identical). Fail-safe: unknown/unregistered portal → Cookie path.
# ADDITIVE · Defender behavior unchanged. RED before: the bearer branch + the returned Headers are absent.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'F1.4b · Invoke-XdrPortalHttp · AuthMode-routed transport + response Headers' {
    It 'COOKIE portal (Defender) → Cookie + X-XSRF-TOKEN, NO Authorization (byte-identical regression guard)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc'; XsrfToken = 'xyz' } -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/x'
            $script:cap['Cookie']       | Should -Match 'sccauth=abc'
            $script:cap['X-XSRF-TOKEN'] | Should -Be 'xyz'
            $script:cap.ContainsKey('Authorization') | Should -BeFalse -Because 'a cookie portal must NEVER send a bearer header'
        }
    }
    It 'BEARER portal (Entra) → Authorization: Bearer <token>, NO Cookie (the net-new transport path)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Entra'; AccessToken = 'tok123' } -Method 'GET' -Url 'https://entra.microsoft.com/apiproxy/x'
            $script:cap['Authorization'] | Should -Be 'Bearer tok123'
            $script:cap.ContainsKey('Cookie') | Should -BeFalse -Because 'a bearer portal must NEVER send a cookie header'
        }
    }
    It 'BEARER fail-safe · session AccessToken absent → no Authorization emitted (no malformed "Bearer ")' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Entra' } -Method 'GET' -Url 'https://entra.microsoft.com/apiproxy/x'
            $script:cap.ContainsKey('Authorization') | Should -BeFalse
        }
    }
    It 'returns response Headers (RFC5988 Link header-cursor readiness · the dropped-Headers fix)' {
        InModuleScope Xdr.Common.Runtime {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{ Link = '<https://x/next>; rel="next"' } } }
            $r = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } -Method 'GET' -Url 'https://x'
            $r.ContainsKey('Headers') | Should -BeTrue
            $r.Headers['Link']        | Should -Match 'rel="next"'
        }
    }
}
