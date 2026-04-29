#Requires -Modules Pester

<#
.SYNOPSIS
    Fixture-based Pester 5 unit tests for the L1 Entra auth chain in
    Xdr.Common.Auth (iter-14.0 Phase 1).

.DESCRIPTION
    Migrated out of tests/unit/Xdr.Portal.Auth.AuthChain.Tests.ps1 when the
    monolithic Xdr.Portal.Auth was split. All HTTP is mocked via InModuleScope
    on Invoke-WebRequest / Invoke-RestMethod. NO live network calls.

    Function-name mapping:
        Get-EntraConfigBlob, Test-EntraField, Get-EntraField, Get-EntraFieldNames,
        Test-MfaEndAuthSuccess, Get-EntraErrorMessage  → Xdr.Common.Auth Private
        Resolve-InterruptPage  → Resolve-EntraInterruptPage (Xdr.Common.Auth Public)
        Complete-PortalRedirectChain → Submit-EntraFormPost (Xdr.Common.Auth Private)
        Complete-CredentialsFlow / Complete-TotpMfa / Complete-PasskeyFlow → unchanged
            names; now Xdr.Common.Auth Private (separate files).
        Get-EstsCookie → Get-EntraEstsAuth (Xdr.Common.Auth Public). Signature
            change: -ClientId + -PortalHost are now MANDATORY (the portalClients
            map went away — caller passes them).
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # --- Fixture HTML variables (same fixtures as the legacy AuthChain tests) ---
    $script:CanonicalEntraLoginHtml = @'
<!DOCTYPE html>
<html><head><title>Sign in</title></head><body>
<script type="text/javascript">
//<![CDATA[
$Config = {"pgid":"Login","sFT":"ft-12345","sCtx":"ctx-abcd","canary":"canary-xyz","urlPost":"/common/login","correlationId":"11111111-2222-3333-4444-555555555555"};
//]]>
</script>
</body></html>
'@

    $script:EntraLoginHtmlScriptTerminator = @'
<!DOCTYPE html><html><body><script>$Config = {"pgid":"Login","sFT":"FT-SCRIPT","sCtx":"CTX-SCRIPT","canary":"CAN-SCRIPT","urlPost":"/common/login"};</script></body></html>
'@

    $script:EntraGreedyBraceHtml = @'
<html><body>{"pgid":"Login","sFT":"fallback-ft","sCtx":"fallback-ctx","canary":"fallback-canary","urlPost":"/common/login"}</body></html>
'@

    $script:EntraMalformedJsonHtml = @'
<html><body><script>$Config = {"pgid":"Login","broken":"value,,missing_close;
</script></body></html>
'@

    $script:ConvergedTfaHtml = @'
<html><body><script>$Config = {"pgid":"ConvergedTFA","sFT":"mfa-ft","sCtx":"mfa-ctx","canary":"mfa-canary","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP","display":"TOTP"}]};
</script></body></html>
'@

    $script:KmsiInterruptHtml = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sFT":"ft-after-mfa","sCtx":"ctx-after-mfa","canary":"canary-after-mfa","urlPost":"/kmsi"};
</script></body></html>
'@

    $script:PortalFormPostHtml = @'
<html><body>
<form action="https://security.microsoft.com/" method="POST">
  <input type="hidden" name="code"     value="0.AAAA-oidc-code-fixture"/>
  <input type="hidden" name="id_token" value="eyJ.fixture.id"/>
  <input type="hidden" name="state"    value="state-fixture-abc"/>
</form>
<script>document.forms[0].submit();</script>
</body></html>
'@

    $script:PortalFormPostHtmlMethodFirst = @'
<html><body>
<form method="POST" action="https://security.microsoft.com/">
  <input type="hidden" name="code"     value="reorder-code"/>
  <input type="hidden" name="id_token" value="reorder-id"/>
  <input type="hidden" name="state"    value="reorder-state"/>
</form>
</body></html>
'@

    $script:PortalNoFormHtml = @'
<html><body><p>Redirecting...</p></body></html>
'@

    $script:PortalPostBackBlobHtml = @'
<html><body><script>$Config = {"pgid":"Final","sPostBackUrl":"https://security.microsoft.com/signin-oidc","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    $script:WrongPasswordHtml = @'
<html><body><script>$Config = {"pgid":"Login","sErrorCode":"50126","sErrTxt":"Error validating credentials due to invalid username or password.","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    $script:LockedAccountHtml = @'
<html><body><script>$Config = {"pgid":"Login","sErrorCode":"50053","sErrTxt":"Your account is locked.","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    $script:NoMfaHtml = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sFT":"nomfa-ft","sCtx":"nomfa-ctx","canary":"nomfa-canary","urlPost":"/kmsi"};
</script></body></html>
'@
}

AfterAll {
    Remove-Module Xdr.Common.Auth -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Get-EntraConfigBlob (private)
# ============================================================================
Describe 'Get-EntraConfigBlob' {
    It 'returns populated object when canonical $Config = {...}; newline pattern is present' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Html = $script:CanonicalEntraLoginHtml } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result       | Should -Not -BeNullOrEmpty
            $result.pgid  | Should -Be 'Login'
            $result.sFT   | Should -Be 'ft-12345'
            $result.sCtx  | Should -Be 'ctx-abcd'
        }
    }

    It 'returns populated object when $Config ends with script-tag terminator (no newline)' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Html = $script:EntraLoginHtmlScriptTerminator } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result      | Should -Not -BeNullOrEmpty
            $result.sFT  | Should -Be 'FT-SCRIPT'
            $result.sCtx | Should -Be 'CTX-SCRIPT'
        }
    }

    It 'returns populated object via greedy outer-brace fallback when $Config prefix absent' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Html = $script:EntraGreedyBraceHtml } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result      | Should -Not -BeNullOrEmpty
            $result.sFT  | Should -Be 'fallback-ft'
            $result.pgid | Should -Be 'Login'
        }
    }

    It 'returns $null when HTML has no $Config pattern and no outer braces' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraConfigBlob -Html 'no config blob here at all') | Should -BeNullOrEmpty
        }
    }

    It 'returns $null when the JSON is malformed (ConvertFrom-Json fails)' {
        InModuleScope Xdr.Common.Auth -Parameters @{ Html = $script:EntraMalformedJsonHtml } {
            param($Html)
            (Get-EntraConfigBlob -Html $Html) | Should -BeNullOrEmpty
        }
    }
}

# ============================================================================
#  Test-EntraField / Get-EntraField / Get-EntraFieldNames
# ============================================================================
Describe 'Test-EntraField / Get-EntraField / Get-EntraFieldNames' {
    It 'returns $true when Test-EntraField is called on a present field' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ a = 1; b = 'x' }
            (Test-EntraField -Object $obj -Name 'a') | Should -BeTrue
            (Test-EntraField -Object $obj -Name 'b') | Should -BeTrue
        }
    }

    It 'returns $false when Test-EntraField is called on a missing field' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Test-EntraField -Object $obj -Name 'z') | Should -BeFalse
        }
    }

    It 'returns $false when Test-EntraField is called with $null object' {
        InModuleScope Xdr.Common.Auth {
            (Test-EntraField -Object $null -Name 'whatever') | Should -BeFalse
        }
    }

    It 'returns the field value when Get-EntraField is called on a present field' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ name = 'alice' }
            (Get-EntraField -Object $obj -Name 'name') | Should -Be 'alice'
        }
    }

    It 'returns the supplied default when Get-EntraField is called on a missing field with default' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Get-EntraField -Object $obj -Name 'missing' -Default 'fallback') | Should -Be 'fallback'
        }
    }

    It 'returns $null when Get-EntraField is called on a missing field without default' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Get-EntraField -Object $obj -Name 'missing') | Should -BeNullOrEmpty
        }
    }

    It 'returns nested-object value when Get-EntraField drills one level down via chain' {
        InModuleScope Xdr.Common.Auth {
            $inner = [pscustomobject]@{ deep = 'deep-val' }
            $obj   = [pscustomobject]@{ nested = $inner }
            $outer = Get-EntraField -Object $obj -Name 'nested'
            (Get-EntraField -Object $outer -Name 'deep') | Should -Be 'deep-val'
        }
    }

    It 'returns an empty array when Get-EntraFieldNames receives $null' {
        InModuleScope Xdr.Common.Auth {
            $names = Get-EntraFieldNames -Object $null
            @($names).Count | Should -Be 0
        }
    }

    It 'returns declared property names when Get-EntraFieldNames receives a populated object' {
        InModuleScope Xdr.Common.Auth {
            $obj = [pscustomobject]@{ alpha = 1; beta = 2; gamma = 3 }
            $names = Get-EntraFieldNames -Object $obj
            ($names | Sort-Object) -join ',' | Should -Be 'alpha,beta,gamma'
        }
    }
}

# ============================================================================
#  Test-MfaEndAuthSuccess
# ============================================================================
Describe 'Test-MfaEndAuthSuccess' {
    It 'returns $true when ResultValue is AuthenticationSucceeded' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'AuthenticationSucceeded' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $true when ResultValue is Success (NEW Entra format)' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'Success' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $true when Success property is $true (boolean — most reliable)' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ Success = $true }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $false when ResultValue is OathCodeIncorrect' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'OathCodeIncorrect' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }

    It 'returns $false when the object has neither Success nor ResultValue (unrelated props only)' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ SessionId = 'irrelevant' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }

    It 'returns $false when Success=false and ResultValue is absent' {
        InModuleScope Xdr.Common.Auth {
            $endAuth = [pscustomobject]@{ Success = $false }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }
}

# ============================================================================
#  Get-EntraErrorMessage
# ============================================================================
Describe 'Get-EntraErrorMessage' {
    It 'returns the mapped human string when code is 50126 (invalid credentials)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '50126') | Should -Match 'Invalid username or password'
        }
    }

    It 'returns the mapped human string when code is 50053 (account locked)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '50053') | Should -Match 'locked'
        }
    }

    It 'returns the mapped human string when code is 50057 (account disabled)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '50057') | Should -Match 'disabled'
        }
    }

    It 'returns the mapped human string when code is 50055 (password expired)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '50055') | Should -Match 'expired'
        }
    }

    It 'returns the mapped human string when code is 50058 (insufficient session info)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '50058') | Should -Match 'single-sign-on|ESTS'
        }
    }

    It 'returns the mapped human string when code is 53003 (Conditional Access block)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '53003') | Should -Match 'Conditional Access'
        }
    }

    It 'returns the mapped human string when code is 900144 (missing client_id)' {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '900144') | Should -Match 'client_id'
        }
    }

    It 'returns the DefaultText when code is 9000410 (unknown) and DefaultText is supplied' {
        InModuleScope Xdr.Common.Auth {
            $msg = Get-EntraErrorMessage -Code '9000410' -DefaultText 'Malformed JSON body.'
            $msg | Should -Be 'Malformed JSON body.'
        }
    }

    It "returns 'Entra error CODE' fallback when code is unknown and no DefaultText is supplied" {
        InModuleScope Xdr.Common.Auth {
            (Get-EntraErrorMessage -Code '9999999') | Should -Be 'Entra error 9999999'
        }
    }
}

# ============================================================================
#  Submit-EntraFormPost (formerly Complete-PortalRedirectChain)
# ============================================================================
Describe 'Submit-EntraFormPost (formerly Complete-PortalRedirectChain)' {
    It 'posts back to the form action URL when LastResponse has a form element with code/id_token/state' {
        InModuleScope Xdr.Common.Auth -Parameters @{
            FormHtml = $script:PortalFormPostHtml
        } {
            param($FormHtml)

            Mock Invoke-WebRequest { return $null }

            $inputFields = @(
                [pscustomobject]@{ Name = 'code';     Value = '0.AAAA-oidc-code-fixture' },
                [pscustomobject]@{ Name = 'id_token'; Value = 'eyJ.fixture.id' },
                [pscustomobject]@{ Name = 'state';    Value = 'state-fixture-abc' }
            )
            $lastResponse = [pscustomobject]@{
                Content     = $FormHtml
                InputFields = $inputFields
            }

            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Submit-EntraFormPost -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/' -and $Method -eq 'Post'
            }
        }
    }

    It 'still posts to the form action when method attribute appears before action attribute' {
        InModuleScope Xdr.Common.Auth -Parameters @{
            FormHtml = $script:PortalFormPostHtmlMethodFirst
        } {
            param($FormHtml)

            Mock Invoke-WebRequest { return $null }

            $inputFields = @(
                [pscustomobject]@{ Name = 'code';     Value = 'reorder-code' },
                [pscustomobject]@{ Name = 'id_token'; Value = 'reorder-id' },
                [pscustomobject]@{ Name = 'state';    Value = 'reorder-state' }
            )
            $lastResponse = [pscustomobject]@{
                Content     = $FormHtml
                InputFields = $inputFields
            }

            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Submit-EntraFormPost -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/' -and $Method -eq 'Post'
            }
        }
    }

    It 'falls back to a portal-root GET when LastResponse has no form tag' {
        InModuleScope Xdr.Common.Auth -Parameters @{
            NoFormHtml = $script:PortalNoFormHtml
        } {
            param($NoFormHtml)

            Mock Invoke-WebRequest { return $null }

            $lastResponse = [pscustomobject]@{ Content = $NoFormHtml; InputFields = @() }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Submit-EntraFormPost -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Post' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://security.microsoft.com/' }
        }
    }

    It 'uses $Config.sPostBackUrl as the form action when no form tag but blob points at portal' {
        InModuleScope Xdr.Common.Auth -Parameters @{
            PostBackHtml = $script:PortalPostBackBlobHtml
        } {
            param($PostBackHtml)

            Mock Invoke-WebRequest { return $null }

            $inputFields = @(
                [pscustomobject]@{ Name = 'code';     Value = 'postback-code' },
                [pscustomobject]@{ Name = 'id_token'; Value = 'postback-id' },
                [pscustomobject]@{ Name = 'state';    Value = 'postback-state' }
            )
            $lastResponse = [pscustomobject]@{
                Content     = $PostBackHtml
                InputFields = $inputFields
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Submit-EntraFormPost -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/signin-oidc' -and $Method -eq 'Post'
            }
        }
    }

    It 'still pings the portal root (no throw) when LastResponse is $null' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest { return $null }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            { Submit-EntraFormPost -Session $session -PortalHost 'security.microsoft.com' -LastResponse $null } |
                Should -Not -Throw
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://security.microsoft.com/' }
        }
    }
}

# ============================================================================
#  Resolve-EntraInterruptPage (formerly Resolve-InterruptPage; now PUBLIC)
# ============================================================================
Describe 'Resolve-EntraInterruptPage (formerly Resolve-InterruptPage)' {
    It 'POSTs to /kmsi with LoginOptions=1 + type=28 when pgid=KmsiInterrupt' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    Content      = '<html>done</html>'
                    StatusCode   = 200
                    InputFields  = @()
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'KmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/kmsi' -and
                $Method -eq 'Post' -and
                $Body.LoginOptions -eq 1 -and
                $Body.type -eq 28
            }
            $result | Should -Not -BeNullOrEmpty
        }
    }

    It 'POSTs to /appverify with ContinueAuth=true when pgid=CmsiInterrupt' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    Content      = '<html>done</html>'
                    StatusCode   = 200
                    InputFields  = @()
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'CmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/appverify' -and
                $Method -eq 'Post' -and
                $Body.ContinueAuth -eq 'true'
            }
        }
    }

    It 'skips MFA registration via ProcessAuth when iRemainingDaysToSkipMfaRegistration > 0' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    Content      = '<html>done</html>'
                    StatusCode   = 200
                    InputFields  = @()
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{
                pgid = 'ConvergedProofUpRedirect'
                iRemainingDaysToSkipMfaRegistration = 7
                sProofUpAuthState = 'proof-state'
                sCtx = 'c'; sFT = 'f'; canary = 'cn'
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/common/SAS/ProcessAuth' -and
                $Body.type -eq 22 -and
                $Body.request -eq 'proof-state'
            }
        }
    }

    It 'throws when ConvergedProofUpRedirect has iRemainingDaysToSkipMfaRegistration = 0' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest { }

            $state = [pscustomobject]@{
                pgid = 'ConvergedProofUpRedirect'
                iRemainingDaysToSkipMfaRegistration = 0
                sCtx = 'c'; sFT = 'f'; canary = 'cn'
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }
            } | Should -Throw "*MFA registration required*"
        }
    }

    It 'breaks after at most 10 iterations even when alternating pgids keep appearing' {
        InModuleScope Xdr.Common.Auth {
            $script:iteration = 0
            Mock Invoke-WebRequest {
                $script:iteration++
                $next = if ($script:iteration % 2 -eq 1) { 'KmsiInterrupt' } else { 'CmsiInterrupt' }
                return [pscustomobject]@{
                    StatusCode   = 200
                    InputFields  = @()
                    Content      = @"
<html><body><script>`$Config = {"pgid":"$next","sCtx":"ctx$next","sFT":"ft$next","canary":"can$next"};
</script></body></html>
"@
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'CmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 10 -Exactly -ParameterFilter { $true }
        }
    }

    It 'breaks when pgid repeats on two consecutive iterations (same-pgid short-circuit)' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    InputFields = @()
                    Content     = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"cc","sFT":"ff","canary":"dd"};
</script></body></html>
'@
                }
            }
            Mock Start-Sleep {}

            $state = [pscustomobject]@{ pgid = 'KmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $true }
        }
    }

    It 'returns immediately without calls when pgid is empty/missing' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-WebRequest { }

            $state = [pscustomobject]@{ pgid = ''; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Resolve-EntraInterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }

            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $true }
            $result.State | Should -Not -BeNullOrEmpty
        }
    }
}

# ============================================================================
#  Complete-CredentialsFlow
# ============================================================================
Describe 'Complete-CredentialsFlow (mocked)' {
    It 'returns state without MFA when cred POST yields pgid=KmsiInterrupt' {
        InModuleScope Xdr.Common.Auth -Parameters @{ NoMfaHtml = $script:NoMfaHtml } {
            param($NoMfaHtml)

            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = $NoMfaHtml
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT = 'ft'; sCtx = 'ctx'; canary = 'canary'; urlPost = '/common/login'
                correlationId = 'c1'
            }
            $credential = @{ upn = 'x@y.com'; password = 'pw'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            $result = Complete-CredentialsFlow `
                -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                -SessionInfo   $sessionInfo `
                -UrlPost       'https://login.microsoftonline.com/common/login' `
                -Credential    $credential `
                -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                -CorrelationId ([Guid]::NewGuid())

            $result.State.pgid | Should -Be 'KmsiInterrupt'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/common/login' -and $Method -eq 'Post'
            }
        }
    }

    It 'delegates to Complete-TotpMfa when cred POST yields pgid=ConvergedTFA' {
        InModuleScope Xdr.Common.Auth -Parameters @{ MfaHtml = $script:ConvergedTfaHtml } {
            param($MfaHtml)

            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = $MfaHtml
                    InputFields = @()
                }
            }
            Mock Complete-TotpMfa {
                return @{
                    State = [pscustomobject]@{ pgid = 'KmsiInterrupt'; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
                    LastResponse = [pscustomobject]@{ StatusCode = 200; Content = '<html></html>'; InputFields = @() }
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT = 'ft'; sCtx = 'ctx'; canary = 'canary'; urlPost = '/common/login'
            }
            $credential = @{ upn = 'x@y.com'; password = 'pw'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            $result = Complete-CredentialsFlow `
                -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                -SessionInfo   $sessionInfo `
                -UrlPost       'https://login.microsoftonline.com/common/login' `
                -Credential    $credential `
                -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                -CorrelationId ([Guid]::NewGuid())

            Should -Invoke Complete-TotpMfa -Times 1 -Exactly
            $result.State.pgid | Should -Be 'KmsiInterrupt'
        }
    }

    It 'throws AADSTS50126 message when cred POST yields sErrorCode=50126' {
        InModuleScope Xdr.Common.Auth -Parameters @{ WrongPwHtml = $script:WrongPasswordHtml } {
            param($WrongPwHtml)

            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = $WrongPwHtml
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT = 'ft'; sCtx = 'ctx'; canary = 'canary'; urlPost = '/common/login'
            }
            $credential = @{ upn = 'x@y.com'; password = 'badpw'; totpBase32 = 'JBSWY3DPEHPK3PXP' }

            {
                Complete-CredentialsFlow `
                    -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo   $sessionInfo `
                    -UrlPost       'https://login.microsoftonline.com/common/login' `
                    -Credential    $credential `
                    -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*AADSTS50126*"
        }
    }

    It 'throws AADSTS50053 account-locked message when cred POST yields sErrorCode=50053' {
        InModuleScope Xdr.Common.Auth -Parameters @{ LockedHtml = $script:LockedAccountHtml } {
            param($LockedHtml)

            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = $LockedHtml
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT = 'ft'; sCtx = 'ctx'; canary = 'canary'; urlPost = '/common/login'
            }
            $credential = @{ upn = 'x@y.com'; password = 'pw'; totpBase32 = 'JBSWY3DPEHPK3PXP' }

            {
                Complete-CredentialsFlow `
                    -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo   $sessionInfo `
                    -UrlPost       'https://login.microsoftonline.com/common/login' `
                    -Credential    $credential `
                    -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*AADSTS50053*"
        }
    }

    It "throws when Credential lacks 'password'" {
        InModuleScope Xdr.Common.Auth {
            $sessionInfo = [pscustomobject]@{ sFT='ft'; sCtx='ctx'; canary='cn'; urlPost='/common/login' }
            $credential = @{ upn = 'x@y.com'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            {
                Complete-CredentialsFlow `
                    -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo   $sessionInfo `
                    -UrlPost       'https://login.microsoftonline.com/common/login' `
                    -Credential    $credential `
                    -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*password*"
        }
    }

    It "throws when Credential lacks 'totpBase32'" {
        InModuleScope Xdr.Common.Auth {
            $sessionInfo = [pscustomobject]@{ sFT='ft'; sCtx='ctx'; canary='cn'; urlPost='/common/login' }
            $credential = @{ upn = 'x@y.com'; password = 'pw' }
            {
                Complete-CredentialsFlow `
                    -Session       ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo   $sessionInfo `
                    -UrlPost       'https://login.microsoftonline.com/common/login' `
                    -Credential    $credential `
                    -ClientId      '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*totpBase32*"
        }
    }
}

# ============================================================================
#  Complete-TotpMfa
# ============================================================================
Describe 'Complete-TotpMfa (mocked)' {
    It 'POSTs to SAS/BeginAuth with AuthMethodId=PhoneAppOTP when TOTP method is available' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '123456' }
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{
                        Success   = $true
                        SessionId = 'sid-abc'
                        FlowToken = 'ft-begin'
                        Ctx       = 'ctx-begin'
                    }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{
                        Success     = $true
                        ResultValue = 'Success'
                        FlowToken   = 'ft-end'
                        Ctx         = 'ctx-end'
                    }
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }
            Mock Start-Sleep {}

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid())

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -match 'BeginAuth' -and $Body -match 'PhoneAppOTP'
            }
            $result.State.pgid | Should -Be 'KmsiInterrupt'
        }
    }

    It 'throws when arrUserProofs lacks a PhoneAppOTP method' {
        InModuleScope Xdr.Common.Auth {
            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppNotification' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*No PhoneAppOTP method*"
        }
    }

    It 'calls ProcessAuth when BeginAuth+EndAuth succeed on the first try' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '123456' }
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }
            Mock Start-Sleep {}

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid()) | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match 'ProcessAuth' }
        }
    }

    It 'retries EndAuth after waiting when first EndAuth Message contains DuplicateCodeEntered' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '123456' }
            $script:endAuthCalls = 0
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    $script:endAuthCalls++
                    if ($script:endAuthCalls -eq 1) {
                        return [pscustomobject]@{ Success = $false; Message = 'DuplicateCodeEntered - try next window' }
                    }
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }
            Mock Start-Sleep {}

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid()) | Out-Null

            Should -Invoke Invoke-RestMethod -Times 2 -ParameterFilter { $Uri -match 'EndAuth' }
            Should -Invoke Start-Sleep -Times 1
        }
    }

    It 'throws when EndAuth returns a non-retryable terminal error' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '111111' }
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $false; Message = 'OathCodeIncorrect'; ResultValue = 'OathCodeIncorrect' }
                }
            }
            Mock Start-Sleep {}

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*TOTP rejected*"
        }
    }

    It 'throws when BeginAuth returns Success=false' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $false; Message = 'BeginAuth declined' }
                }
            }

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*BeginAuth*"
        }
    }

    It 'throws "ProcessAuth failed: AADSTS9000410" when ProcessAuth returns HTTP 500 with AADSTS9000410' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '123456' }
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 500
                    Content     = '{"error":"AADSTS9000410: Malformed JSON body submitted to ProcessAuth"}'
                    InputFields = @()
                }
            }
            Mock Start-Sleep {}

            $authState = [pscustomobject]@{
                sCtx = 'ctx'; sFT = 'ft'; canary = 'cn'; pgid = 'ConvergedTFA'
                arrUserProofs = @([pscustomobject]@{ authMethodId = 'PhoneAppOTP' })
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Complete-TotpMfa -Session $session -AuthState $authState -TotpBase32 'JBSWY3DPEHPK3PXP' -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*AADSTS9000410*"
        }
    }
}

# ============================================================================
#  Complete-PasskeyFlow
# ============================================================================
Describe 'Complete-PasskeyFlow (mocked)' {
    It 'returns @{State; LastResponse} when HasFido=true and Challenge is present' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-PasskeyChallenge {
                return [pscustomobject]@{
                    credentialId      = 'cid'
                    clientDataJSON    = 'cdj'
                    authenticatorData = 'ad'
                    signature         = 'sig'
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k","sCrossDomainCanary":"x","sessionId":"sid"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT = 'pk-ft'; sCtx = 'pk-ctx'; canary = 'pk-canary'
                urlPost = '/common/login'; urlPostAad = '/aad'; urlPostMsa = '/msa'
                urlRefresh = '/refresh'; urlResume = '/resume'; correlationId = '11111111-2222-3333-4444-555555555555'
                oGetCredTypeResult = [pscustomobject]@{
                    Credentials = [pscustomobject]@{
                        HasFido = $true
                        FidoParams = [pscustomobject]@{ Challenge = 'challenge-abc'; AllowList = @() }
                    }
                    FlowToken = 'reload-token'
                }
            }
            $credential = @{ upn = 'pk@y.com'; passkey = [pscustomobject]@{
                credentialId = 'cid'
                userHandle   = 'uh'
                privateKeyPem = 'pem'
            }}
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Complete-PasskeyFlow -Session $session -SessionInfo $sessionInfo `
                -Credential $credential -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                -CorrelationId ([Guid]::NewGuid())

            $result | Should -Not -BeNullOrEmpty
            $result.State | Should -Not -BeNullOrEmpty
            $result.LastResponse | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-PasskeyChallenge -Times 1 -Exactly -ParameterFilter {
                $Challenge -eq 'challenge-abc' -and $Origin -eq 'https://login.microsoft.com'
            }
        }
    }

    It 'throws when HasFido=false' {
        InModuleScope Xdr.Common.Auth {
            $sessionInfo = [pscustomobject]@{
                sFT = 'pk-ft'; sCtx = 'pk-ctx'; canary = 'pk-canary'
                urlPost = '/common/login'; urlPostAad = '/aad'; urlPostMsa = '/msa'
                urlRefresh = '/refresh'; urlResume = '/resume'
                oGetCredTypeResult = [pscustomobject]@{
                    Credentials = [pscustomobject]@{ HasFido = $false }
                    FlowToken = 'reload-token'
                }
            }
            $credential = @{ upn = 'pk@y.com'; passkey = [pscustomobject]@{ credentialId='cid' } }
            {
                Complete-PasskeyFlow -Session ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo $sessionInfo -Credential $credential `
                    -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*Passkey not available*"
        }
    }

    It 'throws when Challenge is missing' {
        InModuleScope Xdr.Common.Auth {
            $sessionInfo = [pscustomobject]@{
                sFT = 'pk-ft'; sCtx = 'pk-ctx'; canary = 'pk-canary'
                urlPost = '/common/login'; urlPostAad = '/aad'; urlPostMsa = '/msa'
                urlRefresh = '/refresh'; urlResume = '/resume'
                oGetCredTypeResult = [pscustomobject]@{
                    Credentials = [pscustomobject]@{
                        HasFido = $true
                        FidoParams = [pscustomobject]@{ Challenge = ''; AllowList = @() }
                    }
                }
            }
            $credential = @{ upn = 'pk@y.com'; passkey = [pscustomobject]@{ credentialId='cid' } }
            {
                Complete-PasskeyFlow -Session ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                    -SessionInfo $sessionInfo -Credential $credential `
                    -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                    -CorrelationId ([Guid]::NewGuid())
            } | Should -Throw "*ChallengePresent=False*"
        }
    }

    It 'calls pre-verify (/common/fido/get) + assertion POST (/common/login) + SSO reload in order' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-PasskeyChallenge {
                return [pscustomobject]@{
                    credentialId = 'cid'; clientDataJSON = 'cdj'
                    authenticatorData = 'ad'; signature = 'sig'
                }
            }
            $script:uriLog = New-Object System.Collections.Generic.List[string]
            Mock Invoke-WebRequest {
                $script:uriLog.Add([string]$Uri) | Out-Null
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k","sCrossDomainCanary":"x"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT='pk-ft'; sCtx='pk-ctx'; canary='pk-canary'
                urlPost='/common/login'; urlPostAad='/aad'; urlPostMsa='/msa'
                urlRefresh='/refresh'; urlResume='/resume'
                oGetCredTypeResult = [pscustomobject]@{
                    Credentials = [pscustomobject]@{ HasFido = $true; FidoParams = [pscustomobject]@{ Challenge = 'ch'; AllowList = @() } }
                    FlowToken = 'reload-token'
                }
            }
            $credential = @{ upn = 'pk@y.com'; passkey = [pscustomobject]@{ credentialId='cid'; userHandle='uh' } }
            Complete-PasskeyFlow -Session ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                -SessionInfo $sessionInfo -Credential $credential `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                -CorrelationId ([Guid]::NewGuid()) | Out-Null

            ($script:uriLog | Where-Object { $_ -match '/common/fido/get' } | Measure-Object).Count | Should -Be 1
            ($script:uriLog | Where-Object { $_ -match 'sso_reload=true' } | Measure-Object).Count | Should -Be 1
            $firstIdx  = [array]::FindIndex($script:uriLog.ToArray(), [Predicate[string]]{ param($s) $s -match '/common/fido/get' })
            $assertIdx = [array]::FindIndex($script:uriLog.ToArray(), [Predicate[string]]{ param($s) $s -match 'login\.microsoftonline\.com/common/login$' })
            $reloadIdx = [array]::FindIndex($script:uriLog.ToArray(), [Predicate[string]]{ param($s) $s -match 'sso_reload=true' })
            $firstIdx  | Should -BeLessThan $assertIdx
            $assertIdx | Should -BeLessThan $reloadIdx
        }
    }

    It 'returns an @{State; LastResponse} hashtable shape' {
        InModuleScope Xdr.Common.Auth {
            Mock Invoke-PasskeyChallenge {
                return [pscustomobject]@{
                    credentialId='cid'; clientDataJSON='cdj'
                    authenticatorData='ad'; signature='sig'
                }
            }
            Mock Invoke-WebRequest {
                return [pscustomobject]@{
                    StatusCode  = 200
                    Content     = '<html><script>$Config = {"pgid":"KmsiInterrupt","sCtx":"c","sFT":"f","canary":"cn","urlPost":"/k"};' + [char]10 + '</script></html>'
                    InputFields = @()
                }
            }

            $sessionInfo = [pscustomobject]@{
                sFT='pk-ft'; sCtx='pk-ctx'; canary='pk-canary'
                urlPost='/common/login'; urlPostAad='/aad'; urlPostMsa='/msa'
                urlRefresh='/refresh'; urlResume='/resume'
                oGetCredTypeResult = [pscustomobject]@{
                    Credentials = [pscustomobject]@{ HasFido = $true; FidoParams = [pscustomobject]@{ Challenge='ch'; AllowList=@() } }
                    FlowToken = 'reload-token'
                }
            }
            $credential = @{ upn = 'pk@y.com'; passkey = [pscustomobject]@{ credentialId='cid'; userHandle='uh' } }
            $result = Complete-PasskeyFlow -Session ([Microsoft.PowerShell.Commands.WebRequestSession]::new()) `
                -SessionInfo $sessionInfo -Credential $credential `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' `
                -CorrelationId ([Guid]::NewGuid())

            $result.Keys | Sort-Object | Should -Be @('LastResponse', 'State')
        }
    }
}

# ============================================================================
#  Get-EntraEstsAuth integration-level (HTTP fully mocked)
#  Replaces the legacy Get-EstsCookie integration tests. Note: Get-EntraEstsAuth
#  no longer returns Sccauth/XsrfToken/TenantId — those are L2 concerns now (the
#  L2 module's Get-DefenderSccauth verifies them). Get-EntraEstsAuth returns
#  @{Session, State, LastResponse, AcquiredUtc, ClientId, PortalHost}.
# ============================================================================
Describe 'Get-EntraEstsAuth (integration-level, HTTP fully mocked)' {
    It 'returns @{Session; State; AcquiredUtc; ClientId; PortalHost} through the CredentialsTotp path' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '654321' }

            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }

            $script:wrCall = 0
            Mock Invoke-WebRequest {
                $script:wrCall++

                if ($script:wrCall -eq 1) {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"Login","sFT":"ft1","sCtx":"ctx1","canary":"can1","urlPost":"/common/login","correlationId":"12345678-1234-1234-1234-123456789abc"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/oauth2/authorize' } }
                    }
                }

                if ($Uri -match 'login\.microsoftonline\.com/common/login' -and -not ($Uri -match 'sso_reload')) {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"ConvergedTFA","sFT":"ft-mfa","sCtx":"ctx-mfa","canary":"can-mfa","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP"}]};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/login' } }
                    }
                }

                if ($Uri -match 'ProcessAuth') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"KmsiInterrupt","sFT":"ft-kmsi","sCtx":"ctx-kmsi","canary":"can-kmsi","urlPost":"/kmsi"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/SAS/ProcessAuth' } }
                    }
                }

                if ($Uri -match '/kmsi$') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @(
                            [pscustomobject]@{ Name='code';     Value='0.AAAA' }
                            [pscustomobject]@{ Name='id_token'; Value='eyJ.id' }
                            [pscustomobject]@{ Name='state';    Value='stt' }
                        )
                        Content = '<html><form action="https://security.microsoft.com/" method="POST"><input name="code" value="0.AAAA"/><input name="id_token" value="eyJ.id"/><input name="state" value="stt"/></form></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/kmsi' } }
                    }
                }

                return [pscustomobject]@{
                    StatusCode       = 200
                    RawContentLength = 0
                    InputFields      = @()
                    Content          = ''
                    BaseResponse     = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://security.microsoft.com/' } }
                }
            }
            Mock Start-Sleep {}

            $credential = @{ upn = 'svc@test.com'; password = 'pw'; totpBase32 = 'JBSWY3DPEHPK3PXP' }
            $result = Get-EntraEstsAuth -Method CredentialsTotp -Credential $credential `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'security.microsoft.com'

            $result | Should -Not -BeNullOrEmpty
            $result.Session     | Should -BeOfType [Microsoft.PowerShell.Commands.WebRequestSession]
            $result.AcquiredUtc | Should -BeOfType [datetime]
            $result.ClientId    | Should -Be '80ccca67-54bd-44ab-8625-4b79c4dc7775'
            $result.PortalHost  | Should -Be 'security.microsoft.com'
        }
    }

    It 'passes the supplied client_id in the credentials POST body (mandatory for AADSTS900144 avoidance)' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-TotpCode { return '000000' }
            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }
            $script:wr3 = 0
            Mock Invoke-WebRequest {
                $script:wr3++
                if ($script:wr3 -eq 1) {
                    return [pscustomobject]@{
                        StatusCode=200; RawContentLength=10; InputFields=@()
                        Content = '<html><script>$Config = {"pgid":"Login","sFT":"f","sCtx":"c","canary":"k","urlPost":"/common/login"};' + [char]10 + '</script></html>'
                        BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]'https://login.microsoftonline.com/common/oauth2/authorize'}}
                    }
                }
                if ($Uri -match 'login\.microsoftonline\.com/common/login') {
                    return [pscustomobject]@{
                        StatusCode=200; RawContentLength=10; InputFields=@()
                        Content = '<html><script>$Config = {"pgid":"ConvergedTFA","sFT":"f","sCtx":"c","canary":"k","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP"}]};' + [char]10 + '</script></html>'
                        BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]'https://login.microsoftonline.com/common/login'}}
                    }
                }
                if ($Uri -match 'ProcessAuth') {
                    return [pscustomobject]@{
                        StatusCode=200; RawContentLength=10; InputFields=@()
                        Content = '<html><script>$Config = {"pgid":"KmsiInterrupt","sFT":"f","sCtx":"c","canary":"k","urlPost":"/kmsi"};' + [char]10 + '</script></html>'
                        BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]'https://login.microsoftonline.com/common/SAS/ProcessAuth'}}
                    }
                }
                if ($Uri -match '/kmsi$') {
                    return [pscustomobject]@{
                        StatusCode=200; RawContentLength=10
                        InputFields=@([pscustomobject]@{Name='code';Value='0.AAAA'}, [pscustomobject]@{Name='id_token';Value='eyJ'}, [pscustomobject]@{Name='state';Value='s'})
                        Content = '<html><form action="https://security.microsoft.com/" method="POST"><input name="code" value="0.AAAA"/></form></html>'
                        BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]'https://login.microsoftonline.com/kmsi'}}
                    }
                }
                return [pscustomobject]@{
                    StatusCode=200; RawContentLength=0; InputFields=@(); Content=''
                    BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]'https://security.microsoft.com/'}}
                }
            }
            Mock Start-Sleep {}

            $credential = @{ upn='svc@test.com'; password='pw'; totpBase32='JBSWY3DPEHPK3PXP' }
            Get-EntraEstsAuth -Method CredentialsTotp -Credential $credential `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'security.microsoft.com' | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -match 'login\.microsoftonline\.com/common/login' -and
                $Body -and ($Body.client_id -eq '80ccca67-54bd-44ab-8625-4b79c4dc7775')
            }
        }
    }

    It "throws when Credential lacks 'upn'" {
        {
            Get-EntraEstsAuth -Method CredentialsTotp -Credential @{ password='pw'; totpBase32='x' } `
                -ClientId '80ccca67-54bd-44ab-8625-4b79c4dc7775' -PortalHost 'security.microsoft.com'
        } | Should -Throw "*upn*"
    }
}
