#Requires -Version 7.4
# F-APIVERSION (2026-06-25) · GENERIC api-version NEGOTIATION wired into the transport (Invoke-XdrPortalHttp).
# The /tvm/analytics/ Defender backend REQUIRES an `api-version` REQUEST header whose working value VARIES BY ROUTE
# (1.0 for assets/products/advisories/certificates/extensions/changeEvents · 2.0 for sca/topPerDay) with NO single
# default — each route REJECTS the other version (400/405). The engine negotiates UNIFORMLY (NO per-op curation):
# send a candidate, on a 400/405 version-reject retry the next, CACHE the winner per route-prefix.
#
# DEFECT-CLASS GUARD (manual-audit catch · 2026-06-25): the §F-APIVERSION helpers (Test-XdrIsTvmAnalyticsUrl ·
# Get-XdrApiVersionRoutePrefix · the candidates + cache) were once DEFINED-BUT-UNWIRED — zero call sites in the
# transport. The prepush gauntlet stayed green (the helpers unit-test fine in isolation) while EVERY tvm/analytics op
# would 400 live (no api-version sent · per-op curation removed). These tests pin the WIRING (the helper being CALLED
# from Invoke-XdrPortalHttp), which a unit test of the helpers alone cannot see. RED before the wiring.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'F-APIVERSION · the negotiation is WIRED into Invoke-XdrPortalHttp (defect-class guard)' {
    BeforeEach { InModuleScope Xdr.Common.Runtime { $script:XdrApiVersionCache = @{} } }   # reset the per-route cache between cases

    It 'a /tvm/analytics/ URL sends api-version EVEN WITH NO ExtraHeaders (the engine negotiates it · 1.0-first)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/products'
            $script:cap['api-version'] | Should -Be '1.0' -Because 'UNWIRED = 400 live · the engine MUST supply api-version for tvm/analytics with no per-op curation'
        }
    }

    It 'a NON-tvm/analytics URL sends NO api-version (regression guard · byte-identical for every other surface)' {
        InModuleScope Xdr.Common.Runtime {
            $script:cap = $null
            Mock Invoke-WebRequest { $script:cap = $Headers; [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/incidents'
            $script:cap.ContainsKey('api-version') | Should -BeFalse -Because 'non-tvm/analytics requests stay byte-identical (no api-version header · no regression)'
        }
    }

    It 'on a 400 version-reject the negotiation RETRIES the next candidate and succeeds (sca/topPerDay → 2.0)' {
        InModuleScope Xdr.Common.Runtime {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $v = [string]$Headers['api-version']; $script:sent.Add($v)
                if ($v -eq '1.0') { [pscustomobject]@{ StatusCode = 400; Content = '{"error":"UnsupportedApiVersion"}'; Headers = @{} } }
                else              { [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            }
            $r = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/changeEvents/sca/topPerDay'
            @($script:sent) | Should -Be @('1.0', '2.0') -Because '1.0 first (rejected), then 2.0 (accepted)'
            $r.StatusCode    | Should -Be 200
        }
    }

    It 'a 405 version-reject is ALSO negotiated (the reject is 400 OR 405 per the live matrix)' {
        InModuleScope Xdr.Common.Runtime {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $v = [string]$Headers['api-version']; $script:sent.Add($v)
                if ($v -eq '1.0') { [pscustomobject]@{ StatusCode = 405; Content = ''; Headers = @{} } }
                else              { [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            }
            $r = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/changeEvents/sca/topPerDay'
            @($script:sent) | Should -Be @('1.0', '2.0')
            $r.StatusCode    | Should -Be 200
        }
    }

    It 'CACHES the winning version per route-prefix → a 2nd call sends ONLY the cached version (one send · no re-probe)' {
        InModuleScope Xdr.Common.Runtime {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $v = [string]$Headers['api-version']; $script:sent.Add($v)
                if ($v -eq '1.0') { [pscustomobject]@{ StatusCode = 405; Content = ''; Headers = @{} } }
                else              { [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            }
            $url = 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/changeEvents/sca/topPerDay'
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } -Method 'GET' -Url $url   # negotiates 1.0(405)→2.0
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } -Method 'GET' -Url $url   # cached → 2.0 only
            @($script:sent) | Should -Be @('1.0', '2.0', '2.0') -Because 'first call probes 1.0→2.0; second is cached to 2.0 (no 1.0 re-probe)'
        }
    }

    It 'the 1.0-first default matches the live matrix (assets/products = 1.0 on the FIRST send · no wasted probe)' {
        InModuleScope Xdr.Common.Runtime {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest { $script:sent.Add([string]$Headers['api-version']); [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} } }
            $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/assets/topVulnerable'
            @($script:sent) | Should -Be @('1.0') -Because '10 of 11 ships are 1.0 → 1.0-first hits on the first send for them (no negotiation round-trip)'
        }
    }

    It 'a NON-version 400 (e.g. Wrong pagination parameters) does NOT re-probe the next version — it surfaces (precision guard · masked-pagination-400 defect)' {
        InModuleScope Xdr.Common.Runtime {
            $script:sent = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $v = [string]$Headers['api-version']; $script:sent.Add($v)
                [pscustomobject]@{ StatusCode = 400; Content = '{"error":"Wrong pagination parameters"}'; Headers = @{} }   # a REAL (non-version) 400
            }
            # The prior over-broad (any-400/405) retry mis-negotiated 1.0->2.0 and MASKED this pagination 400 as
            # UnsupportedApiVersion (the engine logged the wrong cause · live-proven 2026-06-25). The precise guard retries
            # ONLY on a version-marker body (UnsupportedApiVersion / 'expected header') -> it sends ONLY 1.0 and the real 400 surfaces.
            try { $null = Invoke-XdrPortalHttp -Session @{ Portal = 'Defender'; Sccauth = 'abc' } `
                -Method 'GET' -Url 'https://security.microsoft.com/apiproxy/mtp/tvm/analytics/products' } catch { }
            @($script:sent) | Should -Be @('1.0') -Because 'a non-version 400 must NOT trigger a version re-probe (it would mask the real error)'
        }
    }
}
