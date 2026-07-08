#Requires -Version 7.4
# F-REQHEADERS (2026-06-25) · GENERIC per-op REQUEST-HEADER overlay (the tvm/analytics `api-version` REQUEST-header class).
# The Defender tvm/analytics backend (all TVM + ASR ops) requires an `api-version` REQUEST HEADER — the query-string form
# 400s. The value is per-route DATA: it rides the manifest Entry (RequestHeaders) and the runtime MUST merge it into the
# outgoing HTTP request. These tests pin the three seams of the data-driven flow:
#   (a) ENGINE  · Invoke-XdrPortalHttp merges -ExtraHeaders into the request header set, leaving the base + auth headers
#                 intact, AND is byte-identical when -ExtraHeaders is empty/absent (no regression for every existing op).
#   (c) POLL    · the self-heal wrapper Invoke-XdrAuthenticated threads -ExtraHeaders through to Invoke-XdrPortalHttp (the
#                 exact seam the poll path uses · Runtime.psm1:910 passes the Entry's RequestHeaders here).
# RED before the fix: Invoke-XdrPortalHttp had no -ExtraHeaders param (param-bind error) and the wrapper dropped headers.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'F-REQHEADERS (a) · Invoke-XdrPortalHttp merges per-op ExtraHeaders' {
    It 'sends the per-op api-version REQUEST header WITH the base Accept + auth (cookie) headers intact' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc'; XsrfToken = 'xyz' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/tvm/x' `
                -ExtraHeaders @{ 'api-version' = '1.0' }
            $script:cap['api-version']   | Should -Be '1.0' -Because 'the per-op REQUEST header must be sent (tvm/analytics 400s without it)'
            $script:cap['Accept']        | Should -Be 'application/json' -Because 'the base header must survive the overlay'
            $script:cap['Cookie']        | Should -Match 'sccauth=abc' -Because 'the auth header must survive the overlay'
            $script:cap['X-XSRF-TOKEN']  | Should -Be 'xyz' -Because 'the csrf header must survive the overlay'
        }
    }

    It 'merges MULTIPLE per-op headers (generic · not api-version-specific)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/x' `
                -ExtraHeaders @{ 'api-version' = '2.0'; 'x-ms-feature' = 'on' }
            $script:cap['api-version']  | Should -Be '2.0'
            $script:cap['x-ms-feature'] | Should -Be 'on'
        }
    }

    It 'EMPTY ExtraHeaders → byte-identical header set (regression guard · exactly Accept + Cookie + X-XSRF-TOKEN, no extras)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc'; XsrfToken = 'xyz' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/x' -ExtraHeaders @{}
            @($script:cap.Keys | Sort-Object) | Should -Be @('Accept', 'Cookie', 'X-XSRF-TOKEN') -Because 'an empty overlay must not add or remove any header (no regression)'
        }
    }

    It 'DEFAULT (param omitted entirely) → byte-identical header set (the existing 5 callers pass no headers)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc'; XsrfToken = 'xyz' } -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/x'
            @($script:cap.Keys | Sort-Object) | Should -Be @('Accept', 'Cookie', 'X-XSRF-TOKEN')
        }
    }

    It 'a per-op header on a BEARER portal rides alongside Authorization (AuthMode-agnostic overlay)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Entra'; AccessToken = 'tok123' } `
                -Method 'GET' -Url 'https://entra.microsoft.com/apiproxy/x' -ExtraHeaders @{ 'api-version' = '1.0' }
            $script:cap['Authorization'] | Should -Be 'Bearer tok123'
            $script:cap['api-version']   | Should -Be '1.0'
        }
    }
}

Describe 'F-REQHEADERS (c) · Invoke-XdrAuthenticated threads ExtraHeaders to Invoke-XdrPortalHttp (the poll seam)' {
    It 'forwards the per-op RequestHeaders the poll path read from the manifest Entry' {
        InModuleScope Xdr.Common.Runtime {
            $script:fwd = $null
            # Stub the session resolve + the inner transport so we observe ONLY the wrapper's forwarding.
            Mock Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'abc' } }
            Mock Invoke-XdrPortalHttp { $script:fwd = $ExtraHeaders; @{ StatusCode = 200; Body = @{}; RawBody = '{}'; Headers = @{} } }
            $null = Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/tvm/y' -ExtraHeaders @{ 'api-version' = '1.0' }
            $script:fwd                  | Should -Not -BeNullOrEmpty
            $script:fwd['api-version']   | Should -Be '1.0' -Because 'the wrapper must pass the per-op headers through to the engine, else the poll never sends them'
        }
    }

    It 'DEFAULT (no ExtraHeaders) forwards an empty overlay (no regression for the 2 wrapper callers that pass none)' {
        InModuleScope Xdr.Common.Runtime {
            $script:fwd = $null
            Mock Connect-XdrPortal { @{ Portal = 'Defender'; Sccauth = 'abc' } }
            Mock Invoke-XdrPortalHttp { $script:fwd = $ExtraHeaders; @{ StatusCode = 200; Body = @{}; RawBody = '{}'; Headers = @{} } }
            $null = Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y'
            @($script:fwd.Keys).Count | Should -Be 0 -Because 'absent ExtraHeaders default to an empty overlay (byte-identical request)'
        }
    }
}

Describe 'F-REQHEADERS (c2) · the poll-path Entry read shape (mirrors Runtime.psm1 RequestHeaders read)' {
    # Pins the exact read logic the poll path uses to turn a manifest Entry['RequestHeaders'] into the [hashtable] it
    # passes as -ExtraHeaders: an IDictionary entry yields a string->string map (empty/non-string keys dropped); an
    # ABSENT entry yields @{} (the SPARSE invariant → byte-identical request for every op without a declaration).
    It 'an Entry with a RequestHeaders IDictionary yields a string->string overlay' {
        $Entry = @{ RequestHeaders = @{ 'api-version' = '1.0' } }
        [hashtable]$reqHeaders = if ($Entry['RequestHeaders'] -is [System.Collections.IDictionary]) {
            $rh = @{}
            foreach ($rk in @($Entry['RequestHeaders'].Keys)) { if (-not [string]::IsNullOrEmpty([string]$rk)) { $rh[[string]$rk] = [string]$Entry['RequestHeaders'][$rk] } }
            $rh
        } else { @{} }
        $reqHeaders['api-version'] | Should -Be '1.0'
    }
    It 'an Entry WITHOUT RequestHeaders yields an empty overlay (SPARSE · no regression)' {
        $Entry = @{ OperationKey = 'GetSomething' }
        [hashtable]$reqHeaders = if ($Entry['RequestHeaders'] -is [System.Collections.IDictionary]) { @{ never = 'reached' } } else { @{} }
        @($reqHeaders.Keys).Count | Should -Be 0
    }
}
