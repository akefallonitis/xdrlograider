#Requires -Module Pester
# φ.AUTH.3 · Invoke-XdrKmsiSsoRefresh interrupt walker
# Locks: KmsiInterrupt/CmsiInterrupt/ConvergedProofUpRedirect pgids walked via Resolve-EntraInterruptPage
# instead of giving up. On walked-to-portal success: returns refreshed session (no TOTP burn).
# On walker failure: emits Auth.KmsiSsoInterruptUnresolved + returns $null (TOTP fallback).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    function New-PrevSessionWithKmsi {
        # Build a prior session containing a valid ESTSAUTHPERSISTENT cookie + companion state cookies.
        $sess = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $kmsi = [System.Net.Cookie]::new('ESTSAUTHPERSISTENT','kmsi-90d','/','login.microsoftonline.com')
        $kmsi.Expires = ([datetime]::UtcNow.AddDays(90)).ToLocalTime()
        $sess.Cookies.Add($kmsi)
        # Companion state cookies (esctx · fpc · brcap) for full SSO context
        foreach ($n in 'esctx','fpc','brcap','stsservicecookie','ESTSAUTHLIGHT') {
            $c = [System.Net.Cookie]::new($n,'companion','/','login.microsoftonline.com')
            $c.Expires = ([datetime]::UtcNow.AddDays(30)).ToLocalTime()
            $sess.Cookies.Add($c)
        }
        $sess
    }

    # Test helpers · Invoke-WebRequest is mocked per-test to return canned responses
    function New-EstsKmsiInterruptHtml {
        @'
<html><body><script>
$Config = {"pgid":"KmsiInterrupt","sCtx":"ctx-abc","sFT":"flow-tk","canary":"can-1","correlationId":"00000000-0000-0000-0000-000000000001","iMaxStackForKnockoutAsyncUpdates":10};
</script></body></html>
'@
    }

    function New-PortalSuccessHtml {
        @'
<html><body><script>
window.appConfig = { tenantId: "abc-tenant" };
</script><h1>Defender Security Portal</h1></body></html>
'@
    }
}

Describe 'φ.AUTH.3 · KmsiInterrupt walked to portal · returns refreshed session (no TOTP)' -Tag 'kmsi-interrupt' {

    BeforeEach { Clear-XdrCookieCache; Clear-XdrAuthCircuit }

    It 'KmsiInterrupt walked via Resolve-EntraInterruptPage · sccauth issued · success' {
        $prev = New-PrevSessionWithKmsi
        # Sequence of Invoke-WebRequest responses:
        #   1st (Invoke-XdrKmsiSsoRefresh GET portal-root) → KmsiInterrupt HTML
        #   2nd (Resolve-EntraInterruptPage POST /kmsi) → portal HTML + sccauth cookie issued
        $script:WebCallIdx = 0
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            $script:WebCallIdx++
            if ($script:WebCallIdx -eq 1) {
                # First call · portal-root GET · returns KmsiInterrupt page
                return [pscustomobject]@{ StatusCode = 200; Content = (New-EstsKmsiInterruptHtml) }
            } else {
                # Second call · Resolve-EntraInterruptPage POST /kmsi → portal success
                # Side-effect · ESTS issues sccauth via Set-Cookie (we simulate by mutating session)
                if ($WebSession) {
                    $sccauth = [System.Net.Cookie]::new('sccauth','fresh-after-walk','/','security.microsoft.com')
                    $sccauth.Expires = [datetime]::MinValue  # session cookie
                    $WebSession.Cookies.Add($sccauth)
                }
                return [pscustomobject]@{ StatusCode = 200; Content = (New-PortalSuccessHtml) }
            }
        }

        $refreshed = InModuleScope Xdr.Auth -ScriptBlock {
            param($P) Invoke-XdrKmsiSsoRefresh -PrevSession $P -PortalHost 'security.microsoft.com'
        } -Parameters @{ P = $prev }

        $refreshed | Should -Not -BeNullOrEmpty
        # >= 2 Invoke-WebRequest calls (portal-root GET + interrupt walker POST)
        $script:WebCallIdx | Should -BeGreaterOrEqual 2
        # Refreshed session carries the post-walk sccauth
        @($refreshed.Cookies.GetAllCookies() | Where-Object Name -eq 'sccauth').Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'φ.AUTH.3 · Interrupt-walked but still no portal · returns $null (TOTP fallback)' -Tag 'kmsi-interrupt' {

    BeforeEach { Clear-XdrCookieCache; Clear-XdrAuthCircuit }

    It 'walker invoked but final response still ESTS form · returns null (signals TOTP needed)' {
        $prev = New-PrevSessionWithKmsi
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            # Return ESTS interrupt forever · simulates walker loop reaching iter-limit without
            # ever reaching portal page (e.g. tenant CA injects continual ProofUpRedirect)
            return [pscustomobject]@{ StatusCode = 200; Content = (New-EstsKmsiInterruptHtml) }
        }
        $refreshed = InModuleScope Xdr.Auth -ScriptBlock {
            param($P) Invoke-XdrKmsiSsoRefresh -PrevSession $P -PortalHost 'security.microsoft.com'
        } -Parameters @{ P = $prev }
        $refreshed | Should -BeNullOrEmpty
    }
}

Describe 'φ.AUTH.3 · Real LoginPage (NOT walkable) · skips walker · returns $null' -Tag 'kmsi-interrupt' {

    BeforeEach { Clear-XdrCookieCache; Clear-XdrAuthCircuit }

    It 'pgid=LoginPage · walker NOT invoked · fast TOTP fallback signal' {
        $prev = New-PrevSessionWithKmsi
        $script:WebCallIdx = 0
        Mock -ModuleName Xdr.Auth Invoke-WebRequest {
            $script:WebCallIdx++
            # LoginPage is a REAL login prompt (tenant CA blocks SSO) · walker should NOT trigger
            return [pscustomobject]@{ StatusCode = 200; Content = '<html><script>$Config = {"pgid":"LoginPage","sFTName":"foo"};</script></html>' }
        }
        $refreshed = InModuleScope Xdr.Auth -ScriptBlock {
            param($P) Invoke-XdrKmsiSsoRefresh -PrevSession $P -PortalHost 'security.microsoft.com'
        } -Parameters @{ P = $prev }
        $refreshed | Should -BeNullOrEmpty
        # Walker NOT invoked · exactly 1 Invoke-WebRequest (the portal-root GET only)
        $script:WebCallIdx | Should -Be 1
    }
}
