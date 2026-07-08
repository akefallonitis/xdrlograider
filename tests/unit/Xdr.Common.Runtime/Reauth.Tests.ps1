#Requires -Version 7.4
# Self-healing reauth state machine (Invoke-XdrAuthenticated) + the BROADENED HTML-at-JSON detector.
#
# Context: the connector DETECTED auth-loss (Invoke-XdrPortalHttp throws AuthChainBroken on an HTML-at-JSON body)
# but NEVER recovered — the DEAD session stayed cached → identical failure next cycle = crash-loop. Invoke-XdrAuthenticated
# closes the loop: on AuthLost it invalidates the dead session (L1-ONLY · the KMSI L2 row is PRESERVED so Connect -Force's
# T2 KMSI silent re-mint stays TOTP-free) and reauths ONCE via Connect-XdrPortal -Force. This proves:
#   A · AuthLost then success   → returns the retried 200 · exactly ONE -Force reauth · L1 invalidation · KMSI preserved
#   B · AuthLost EVERY time     → throws after exactly ONE -Force reauth (bounded · crash-loop broken, not infinite)
#   C · a transient/terminal    → NOT treated as AuthLost (no reauth · rethrown immediately)
#   detector · a BOM/comment-prefixed HTML body (<!-- c --><!DOCTYPE html>) trips HtmlResponse AuthChainBroken
#             (the prior `^\s*(<!DOCTYPE|<html)` anchor MISSED a leading comment — this pins the broaden).

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@xdrtest.local'

    # Counter for the per-call throw/return sequencing in the mocked Invoke-XdrPortalHttp. Mock bodies run in
    # module scope; $global: is visible both there and here (the ExactlyOnce.Tests pattern).
    $global:XdrReauthHttpCalls = 0
}

Describe 'Invoke-XdrAuthenticated · self-healing reauth (crash-loop broken)' {
    BeforeEach {
        $global:XdrReauthHttpCalls = 0
        Mock -ModuleName Xdr.Common.Runtime Connect-XdrPortal { @{ Portal = $Portal; Sccauth = 'x'; XsrfToken = 'y' } }
        Mock -ModuleName Xdr.Common.Runtime Invalidate-XdrCache { }
        Mock -ModuleName Xdr.Common.Runtime Track-XdrEvent { }
    }

    It 'Remove-XdrL2Session is GONE (WS3.1) — the TOTP-burn class is impossible by construction, not by discipline' {
        Get-Command Remove-XdrL2Session -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'A · AuthLost on call #1 then 200 on call #2 → returns the 200 · ONE -Force reauth · L1 invalidation (KMSI preserved)' {
        # First HTTP attempt = AuthChainBroken (HTML-at-JSON), second = a clean 200. New-XdrException is in module
        # scope, so the mock builds the SAME typed AuthChainBrokenException the production path throws.
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $global:XdrReauthHttpCalls++
            if ($global:XdrReauthHttpCalls -eq 1) {
                throw (New-XdrException -Type AuthChainBroken -Message 'html at json' -Properties @{ Portal = 'Defender'; FailureStage = 'HtmlResponse' })
            }
            @{ StatusCode = 200; Body = @{ ok = $true }; RawBody = '{}' }
        }

        $r = Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y'
        $r.StatusCode | Should -Be 200
        $r.Body.ok | Should -BeTrue
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
        Should -Invoke -ModuleName Xdr.Common.Runtime Connect-XdrPortal -Times 1 -Exactly -ParameterFilter { $Force -eq $true }
        # L1-ONLY invalidation now (KMSI L2 row preserved → Connect -Force's T2 KMSI re-mint stays TOTP-free).
        Should -Invoke -ModuleName Xdr.Common.Runtime Invalidate-XdrCache -Times 1 -Exactly
    }

    It 'A2 · AuthLost with EMPTY service-account UPN → self-heal still proceeds via L1 invalidation (no Mandatory-UPN binding throw · V2)' {
        # V2 (§21.1): on the cache-hit fast-path Connect-XdrPortal returns a cached session WITHOUT Get-XdrCredentials
        # (the only UPN validator), so $env:XDRLR_SERVICE_ACCOUNT_UPN can be empty at the reauth catch. Remove-XdrL2Session's
        # Mandatory [string]$UPN rejects '' → THROWS inside the catch → self-heal ABORTS (masking AuthChainBroken). The fix
        # routes empty UPN to Invalidate-XdrCache (L1 prefix · tolerates empty) instead; Connect -Force then overwrites L2.
        $saved = $env:XDRLR_SERVICE_ACCOUNT_UPN
        Remove-Item Env:XDRLR_SERVICE_ACCOUNT_UPN -ErrorAction SilentlyContinue
        try {
            Mock -ModuleName Xdr.Common.Runtime Invalidate-XdrCache { }
            Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
                $global:XdrReauthHttpCalls++
                if ($global:XdrReauthHttpCalls -eq 1) {
                    throw (New-XdrException -Type AuthChainBroken -Message 'html at json' -Properties @{ Portal = 'Defender'; FailureStage = 'HtmlResponse' })
                }
                @{ StatusCode = 200; Body = @{ ok = $true }; RawBody = '{}' }
            }
            $r = Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y'
            $r.StatusCode | Should -Be 200
            # empty UPN → L1 fallback fired; Remove-XdrL2Session NOT called (it would have thrown on ''); reauth completed.
            Should -Invoke -ModuleName Xdr.Common.Runtime Invalidate-XdrCache -Times 1 -Exactly
            Should -Invoke -ModuleName Xdr.Common.Runtime Connect-XdrPortal -Times 1 -Exactly -ParameterFilter { $Force -eq $true }
        } finally {
            if ($null -ne $saved) { $env:XDRLR_SERVICE_ACCOUNT_UPN = $saved } else { Remove-Item Env:XDRLR_SERVICE_ACCOUNT_UPN -ErrorAction SilentlyContinue }
        }
    }

    It 'B · AuthLost on EVERY call → throws after exactly ONE -Force reauth (bounded · not an infinite loop)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $global:XdrReauthHttpCalls++
            throw (New-XdrException -Type AuthChainBroken -Message 'html at json' -Properties @{ Portal = 'Defender'; FailureStage = 'HtmlResponse' })
        }

        { Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y' } | Should -Throw
        # Bounded: initial attempt + ONE retry = exactly 2 HTTP calls, exactly 1 -Force reauth. The L1 hot session is
        # dropped and Connect -Force re-mints fresh (overwriting L2) — crash-loop broken, not re-armed. KMSI L2 preserved.
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 2 -Exactly
        Should -Invoke -ModuleName Xdr.Common.Runtime Connect-XdrPortal -Times 1 -Exactly -ParameterFilter { $Force -eq $true }
        Should -Invoke -ModuleName Xdr.Common.Runtime Invalidate-XdrCache -Times 1 -Exactly
    }

    It 'C · a PortalTransient is NOT auth-loss → NO reauth · rethrown immediately' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            $global:XdrReauthHttpCalls++
            throw (New-XdrException -Type PortalTransient -Message 'HTTP 503' -Properties @{ StatusCode = 503; OperationKey = 'op'; RetryAfterSeconds = 30 })
        }

        { Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y' } | Should -Throw
        # No reauth: only the single initial attempt ran, NO -Force, NO L2 invalidation. The breaker/backoff layer
        # owns transient recovery — the reauth wrapper must not steal a transient and burn a TOTP.
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 1 -Exactly
        Should -Invoke -ModuleName Xdr.Common.Runtime Connect-XdrPortal -Times 0 -Exactly -ParameterFilter { $Force -eq $true }
    }

    It 'C2 · a PortalTerminal is NOT auth-loss → NO reauth · rethrown immediately' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp {
            throw (New-XdrException -Type PortalTerminal -Message 'HTTP 403' -Properties @{ StatusCode = 403; OperationKey = 'op'; ResponseBody = 'forbidden' })
        }

        { Invoke-XdrAuthenticated -Portal 'Defender' -Method 'GET' -Url 'https://x/y' } | Should -Throw
        Should -Invoke -ModuleName Xdr.Common.Runtime Invoke-XdrPortalHttp -Times 1 -Exactly
        Should -Invoke -ModuleName Xdr.Common.Runtime Connect-XdrPortal -Times 0 -Exactly -ParameterFilter { $Force -eq $true }
    }
}

Describe 'Invoke-XdrPortalHttp · BROADENED HTML-at-JSON detector (leading BOM/comment shape)' {
    # Drives the REAL Invoke-XdrPortalHttp with Invoke-WebRequest mocked to return a 200 whose body is the LIVE
    # login-page shape: a Microsoft copyright COMMENT *before* <!DOCTYPE html>. The prior anchor `^\s*(<!DOCTYPE|<html)`
    # treated the leading comment as non-whitespace and MISSED it; the broadened detector trims BOM+whitespace and
    # matches <!-- / <!DOCTYPE / <html → AuthChainBroken (FailureStage=HtmlResponse).
    It 'a comment-then-DOCTYPE-prefixed HTML body trips HtmlResponse AuthChainBroken' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '<!-- c --><!DOCTYPE html><html><body>login</body></html>'; Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $caught = $null
        try { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' }
        catch { $caught = $_.Exception }
        $caught | Should -Not -BeNullOrEmpty
        $caught.GetType().Name | Should -Be 'AuthChainBrokenException'
        $caught.FailureStage | Should -Be 'HtmlResponse'
    }

    It 'a BOM-prefixed DOCTYPE-html body also trips HtmlResponse AuthChainBroken' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = ([char]0xFEFF + "  `r`n<!DOCTYPE html><html></html>"); Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $caught = $null
        try { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'AuthChainBrokenException'
        $caught.FailureStage | Should -Be 'HtmlResponse'
    }

    It 'a genuine JSON 200 does NOT trip the detector (no false positive)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"id":1}]}'; Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $r = Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y'
        $r.StatusCode | Should -Be 200
        $r.Body.value[0].id | Should -Be 1
    }

    # F1 · auth-loss by STATUS (complements the HTML-at-JSON shape): an expired/revoked cookie or bearer can surface
    # as a literal 401/440 on the data endpoint. These pin that 401/440 → AuthChainBroken (self-heal), while a 400
    # genuine contract error stays PortalTerminal (fail-loud) — the boundary must not drift.
    It 'a literal HTTP 401 (auth-loss by status) trips AuthChainBroken · FailureStage=Http401 (F1)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 401; Content = '{"error":"unauthorized"}'; Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $caught = $null
        try { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'AuthChainBrokenException'
        $caught.FailureStage | Should -Be 'Http401'
    }

    It 'a literal HTTP 440 (Microsoft login-timeout) trips AuthChainBroken · FailureStage=Http440 (F1)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 440; Content = 'login timeout'; Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $caught = $null
        try { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'AuthChainBrokenException'
        $caught.FailureStage | Should -Be 'Http440'
    }

    It 'a literal HTTP 400 (genuine contract error) stays PortalTerminal — NOT auth-loss (boundary pin)' {
        Mock -ModuleName Xdr.Common.Runtime Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 400; Content = '{"Error":"InvalidProxyPrefix"}'; Headers = @{} }
        }
        $session = @{ Portal = 'Defender'; Sccauth = 'x'; XsrfToken = 'y' }
        $caught = $null
        try { Invoke-XdrPortalHttp -Session $session -Method 'GET' -Url 'https://x/y' }
        catch { $caught = $_.Exception }
        $caught.GetType().Name | Should -Be 'XdrPortalTerminalException'
    }
}
