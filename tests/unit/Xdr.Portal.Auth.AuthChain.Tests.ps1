#Requires -Modules Pester

# Fixture-based Pester 5 unit tests for the Entra auth chain in Xdr.Portal.Auth.
# All HTTP is mocked via InModuleScope on Invoke-WebRequest / Invoke-RestMethod.
# NO live network calls. NO duplication of Get-TotpCode / Test-MDEPortalAuth
# cases already covered in Xdr.Portal.Auth.Tests.ps1.

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Portal.Auth' 'Xdr.Portal.Auth.psd1'
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # --- Fixture HTML variables ---------------------------------------------
    # Canonical Entra login page with $Config = {...}; followed by newline.
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

    # Entra login HTML with $Config = {...};</script> terminator (no trailing newline).
    $script:EntraLoginHtmlScriptTerminator = @'
<!DOCTYPE html><html><body><script>$Config = {"pgid":"Login","sFT":"FT-SCRIPT","sCtx":"CTX-SCRIPT","canary":"CAN-SCRIPT","urlPost":"/common/login"};</script></body></html>
'@

    # Bare JSON (no $Config prefix) — exercises the fallback outer-brace match.
    $script:EntraGreedyBraceHtml = @'
<html><body>{"pgid":"Login","sFT":"fallback-ft","sCtx":"fallback-ctx","canary":"fallback-canary","urlPost":"/common/login"}</body></html>
'@

    # $Config present but JSON body malformed (unbalanced braces → ConvertFrom-Json fails).
    $script:EntraMalformedJsonHtml = @'
<html><body><script>$Config = {"pgid":"Login","broken":"value,,missing_close;
</script></body></html>
'@

    # ConvergedTFA with PhoneAppOTP proof available for MFA challenge.
    $script:ConvergedTfaHtml = @'
<html><body><script>$Config = {"pgid":"ConvergedTFA","sFT":"mfa-ft","sCtx":"mfa-ctx","canary":"mfa-canary","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP","display":"TOTP"}]};
</script></body></html>
'@

    # ConvergedTFA with only PhoneAppNotification (no PhoneAppOTP) — should throw.
    $script:ConvergedTfaNoTotpHtml = @'
<html><body><script>$Config = {"pgid":"ConvergedTFA","sFT":"mfa-ft","sCtx":"mfa-ctx","canary":"mfa-canary","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppNotification","display":"Push"}]};
</script></body></html>
'@

    # KmsiInterrupt after MFA — state page asking stay-signed-in.
    $script:KmsiInterruptHtml = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sFT":"ft-after-mfa","sCtx":"ctx-after-mfa","canary":"canary-after-mfa","urlPost":"/kmsi"};
</script></body></html>
'@

    # After KMSI — form_post landing page with all three hidden inputs.
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

    # form_post with method attribute listed BEFORE action (order-variation).
    $script:PortalFormPostHtmlMethodFirst = @'
<html><body>
<form method="POST" action="https://security.microsoft.com/">
  <input type="hidden" name="code"     value="reorder-code"/>
  <input type="hidden" name="id_token" value="reorder-id"/>
  <input type="hidden" name="state"    value="reorder-state"/>
</form>
</body></html>
'@

    # No form tag; just a redirect-container page. Triggers the fallback portal-root GET.
    $script:PortalNoFormHtml = @'
<html><body><p>Redirecting...</p></body></html>
'@

    # A page whose $Config.sPostBackUrl points at the portal (alternate form-action source).
    $script:PortalPostBackBlobHtml = @'
<html><body><script>$Config = {"pgid":"Final","sPostBackUrl":"https://security.microsoft.com/signin-oidc","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    # Wrong password error page.
    $script:WrongPasswordHtml = @'
<html><body><script>$Config = {"pgid":"Login","sErrorCode":"50126","sErrTxt":"Error validating credentials due to invalid username or password.","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    $script:LockedAccountHtml = @'
<html><body><script>$Config = {"pgid":"Login","sErrorCode":"50053","sErrTxt":"Your account is locked.","sFT":"x","sCtx":"y","canary":"z","urlPost":"/common/login"};
</script></body></html>
'@

    # Post-credentials without MFA (pgid=KmsiInterrupt direct).
    $script:NoMfaHtml = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sFT":"nomfa-ft","sCtx":"nomfa-ctx","canary":"nomfa-canary","urlPost":"/kmsi"};
</script></body></html>
'@

    # ConvergedProofUpRedirect with skip days remaining.
    $script:ProofUpRedirectSkippableHtml = @'
<html><body><script>$Config = {"pgid":"ConvergedProofUpRedirect","iRemainingDaysToSkipMfaRegistration":7,"sProofUpAuthState":"proof-state","sFT":"pu-ft","sCtx":"pu-ctx","canary":"pu-canary","urlPost":"/common/SAS/ProcessAuth"};
</script></body></html>
'@

    # ConvergedProofUpRedirect with zero skip days.
    $script:ProofUpRedirectBlockingHtml = @'
<html><body><script>$Config = {"pgid":"ConvergedProofUpRedirect","iRemainingDaysToSkipMfaRegistration":0,"sFT":"pu-ft","sCtx":"pu-ctx","canary":"pu-canary","urlPost":"/common/SAS/ProcessAuth"};
</script></body></html>
'@

    # Passkey-capable page with FIDO challenge pre-populated.
    $script:PasskeyHtml = @'
<html><body><script>$Config = {"pgid":"Login","sFT":"pk-ft","sCtx":"pk-ctx","canary":"pk-canary","urlPost":"/common/login","urlPostAad":"/common/login-aad","urlPostMsa":"/common/login-msa","urlRefresh":"/common/refresh","urlResume":"/common/resume","correlationId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","oGetCredTypeResult":{"Credentials":{"HasFido":true,"FidoParams":{"Challenge":"challenge-fixture-abc","AllowList":[]}},"FlowToken":"reload-flow-token"}};
</script></body></html>
'@

    # Final done/redirect HTML after passkey SSO reload.
    $script:PasskeyFinalHtml = @'
<html><body><script>$Config = {"pgid":"KmsiInterrupt","sFT":"pk-final-ft","sCtx":"pk-final-ctx","canary":"pk-final-canary","urlPost":"/kmsi"};
</script></body></html>
'@

    # --- Mock web response factory ------------------------------------------
    $script:NewMockWebResponse = {
        param(
            [int]     $StatusCode = 200,
            [string]  $Content    = '',
            [array]   $InputFields = @(),
            [hashtable] $Headers  = @{},
            [string]  $FinalUri   = 'https://login.microsoftonline.com/'
        )

        $baseResponseStub = [pscustomobject]@{
            RequestMessage = [pscustomobject]@{
                RequestUri = [uri]$FinalUri
            }
        }

        [pscustomobject]@{
            StatusCode       = $StatusCode
            Content          = $Content
            RawContentLength = $Content.Length
            InputFields      = $InputFields
            Headers          = $Headers
            BaseResponse     = $baseResponseStub
        }
    }
}

AfterAll {
    Remove-Module Xdr.Portal.Auth -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Get-EntraConfigBlob
# ============================================================================
Describe 'Get-EntraConfigBlob' {
    It 'returns populated object when canonical $Config = {...}; newline pattern is present' {
        InModuleScope Xdr.Portal.Auth -Parameters @{ Html = $script:CanonicalEntraLoginHtml } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result       | Should -Not -BeNullOrEmpty
            $result.pgid  | Should -Be 'Login'
            $result.sFT   | Should -Be 'ft-12345'
            $result.sCtx  | Should -Be 'ctx-abcd'
        }
    }

    It 'returns populated object when $Config ends with script-tag terminator (no newline)' {
        InModuleScope Xdr.Portal.Auth -Parameters @{ Html = $script:EntraLoginHtmlScriptTerminator } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result      | Should -Not -BeNullOrEmpty
            $result.sFT  | Should -Be 'FT-SCRIPT'
            $result.sCtx | Should -Be 'CTX-SCRIPT'
        }
    }

    It 'returns populated object via greedy outer-brace fallback when $Config prefix absent' {
        InModuleScope Xdr.Portal.Auth -Parameters @{ Html = $script:EntraGreedyBraceHtml } {
            param($Html)
            $result = Get-EntraConfigBlob -Html $Html
            $result      | Should -Not -BeNullOrEmpty
            $result.sFT  | Should -Be 'fallback-ft'
            $result.pgid | Should -Be 'Login'
        }
    }

    It 'returns $null when HTML has no $Config pattern and no outer braces' {
        InModuleScope Xdr.Portal.Auth {
            # Plain-text string with no braces at all — all regex patterns fail.
            (Get-EntraConfigBlob -Html 'no config blob here at all') | Should -BeNullOrEmpty
        }
    }

    It 'returns $null when the JSON is malformed (ConvertFrom-Json fails)' {
        InModuleScope Xdr.Portal.Auth -Parameters @{ Html = $script:EntraMalformedJsonHtml } {
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
        InModuleScope Xdr.Portal.Auth {
            $obj = [pscustomobject]@{ a = 1; b = 'x' }
            (Test-EntraField -Object $obj -Name 'a') | Should -BeTrue
            (Test-EntraField -Object $obj -Name 'b') | Should -BeTrue
        }
    }

    It 'returns $false when Test-EntraField is called on a missing field' {
        InModuleScope Xdr.Portal.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Test-EntraField -Object $obj -Name 'z') | Should -BeFalse
        }
    }

    It 'returns $false when Test-EntraField is called with $null object' {
        InModuleScope Xdr.Portal.Auth {
            (Test-EntraField -Object $null -Name 'whatever') | Should -BeFalse
        }
    }

    It 'returns the field value when Get-EntraField is called on a present field' {
        InModuleScope Xdr.Portal.Auth {
            $obj = [pscustomobject]@{ name = 'alice' }
            (Get-EntraField -Object $obj -Name 'name') | Should -Be 'alice'
        }
    }

    It 'returns the supplied default when Get-EntraField is called on a missing field with default' {
        InModuleScope Xdr.Portal.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Get-EntraField -Object $obj -Name 'missing' -Default 'fallback') | Should -Be 'fallback'
        }
    }

    It 'returns $null when Get-EntraField is called on a missing field without default' {
        InModuleScope Xdr.Portal.Auth {
            $obj = [pscustomobject]@{ a = 1 }
            (Get-EntraField -Object $obj -Name 'missing') | Should -BeNullOrEmpty
        }
    }

    It 'returns nested-object value when Get-EntraField drills one level down via chain' {
        InModuleScope Xdr.Portal.Auth {
            $inner = [pscustomobject]@{ deep = 'deep-val' }
            $obj   = [pscustomobject]@{ nested = $inner }
            $outer = Get-EntraField -Object $obj -Name 'nested'
            (Get-EntraField -Object $outer -Name 'deep') | Should -Be 'deep-val'
        }
    }

    It 'returns an empty array when Get-EntraFieldNames receives $null' {
        InModuleScope Xdr.Portal.Auth {
            # PowerShell unravels @() on return into $null — so assert via .Count
            # wrapping. @(...) forces array-context, which gives .Count on any
            # enumerable (including $null).
            $names = Get-EntraFieldNames -Object $null
            @($names).Count | Should -Be 0
        }
    }

    It 'returns declared property names when Get-EntraFieldNames receives a populated object' {
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'AuthenticationSucceeded' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $true when ResultValue is Success (NEW Entra format)' {
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'Success' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $true when Success property is $true (boolean — most reliable)' {
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ Success = $true }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeTrue
        }
    }

    It 'returns $false when ResultValue is OathCodeIncorrect' {
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ ResultValue = 'OathCodeIncorrect' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }

    It 'returns $false when the object has neither Success nor ResultValue (unrelated props only)' {
        # Note: the function also has an internal $null guard but the param is
        # [Parameter(Mandatory)] so we cannot pass $null directly. Use an object
        # with an unrelated property so StrictMode's property-list lookup succeeds
        # but neither Success nor ResultValue is present.
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ SessionId = 'irrelevant' }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }

    It 'returns $false when Success=false and ResultValue is absent' {
        InModuleScope Xdr.Portal.Auth {
            $endAuth = [pscustomobject]@{ Success = $false }
            (Test-MfaEndAuthSuccess -EndAuth $endAuth) | Should -BeFalse
        }
    }
}

# ============================================================================
#  Get-BestEstsCookie — NOT IMPLEMENTED in current module (skipped).
# ============================================================================
Describe 'Get-BestEstsCookie (skipped — function not present in module)' -Skip {
    # Schema mismatch: the brief refers to a Get-BestEstsCookie helper that
    # preferentially returns ESTSAUTHPERSISTENT > ESTSAUTH > ESTSAUTHLIGHT. The
    # current Get-EstsCookie implementation reads sccauth + XSRF-TOKEN directly
    # from the portal-scoped session and never exposes a cookie-picker helper.
    # Tests parked (Skip) so future re-introduction of the helper is easy.
    It 'placeholder' {
        $true | Should -BeTrue
    }
}

# ============================================================================
#  Get-EntraErrorMessage
# ============================================================================
Describe 'Get-EntraErrorMessage' {
    It 'returns the mapped human string when code is 50126 (invalid credentials)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '50126') | Should -Match 'Invalid username or password'
        }
    }

    It 'returns the mapped human string when code is 50053 (account locked)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '50053') | Should -Match 'locked'
        }
    }

    It 'returns the mapped human string when code is 50057 (account disabled)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '50057') | Should -Match 'disabled'
        }
    }

    It 'returns the mapped human string when code is 50055 (password expired)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '50055') | Should -Match 'expired'
        }
    }

    It 'returns the mapped human string when code is 50058 (insufficient session info)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '50058') | Should -Match 'single-sign-on|ESTS'
        }
    }

    It 'returns the mapped human string when code is 53003 (Conditional Access block)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '53003') | Should -Match 'Conditional Access'
        }
    }

    It 'returns the mapped human string when code is 900144 (missing client_id)' {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '900144') | Should -Match 'client_id'
        }
    }

    It 'returns the DefaultText when code is 9000410 (unknown) and DefaultText is supplied' {
        InModuleScope Xdr.Portal.Auth {
            $msg = Get-EntraErrorMessage -Code '9000410' -DefaultText 'Malformed JSON body.'
            $msg | Should -Be 'Malformed JSON body.'
        }
    }

    It "returns 'Entra error CODE' fallback when code is unknown and no DefaultText is supplied" {
        InModuleScope Xdr.Portal.Auth {
            (Get-EntraErrorMessage -Code '9999999') | Should -Be 'Entra error 9999999'
        }
    }
}

# ============================================================================
#  Complete-PortalRedirectChain
# ============================================================================
Describe 'Complete-PortalRedirectChain' {
    It 'posts back to the form action URL when LastResponse has a form element with code/id_token/state' {
        InModuleScope Xdr.Portal.Auth -Parameters @{
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
            Complete-PortalRedirectChain -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/' -and $Method -eq 'Post'
            }
        }
    }

    It 'still posts to the form action when method attribute appears before action attribute' {
        InModuleScope Xdr.Portal.Auth -Parameters @{
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
            Complete-PortalRedirectChain -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/' -and $Method -eq 'Post'
            }
        }
    }

    It 'falls back to a portal-root GET when LastResponse has no form tag' {
        InModuleScope Xdr.Portal.Auth -Parameters @{
            NoFormHtml = $script:PortalNoFormHtml
        } {
            param($NoFormHtml)

            Mock Invoke-WebRequest { return $null }

            $lastResponse = [pscustomobject]@{ Content = $NoFormHtml; InputFields = @() }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Complete-PortalRedirectChain -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            # No POST should have happened — only the GET nudge at portal root.
            Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Post' }
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://security.microsoft.com/' }
        }
    }

    It 'uses $Config.sPostBackUrl as the form action when no form tag but blob points at portal' {
        InModuleScope Xdr.Portal.Auth -Parameters @{
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
            Complete-PortalRedirectChain -Session $session -PortalHost 'security.microsoft.com' -LastResponse $lastResponse

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://security.microsoft.com/signin-oidc' -and $Method -eq 'Post'
            }
        }
    }

    It 'still pings the portal root (no throw) when LastResponse is $null' {
        InModuleScope Xdr.Portal.Auth {
            Mock Invoke-WebRequest { return $null }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            { Complete-PortalRedirectChain -Session $session -PortalHost 'security.microsoft.com' -LastResponse $null } |
                Should -Not -Throw
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://security.microsoft.com/' }
        }
    }
}

# ============================================================================
#  Resolve-InterruptPage
# ============================================================================
Describe 'Resolve-InterruptPage' {
    It 'POSTs to /kmsi with LoginOptions=1 + type=28 when pgid=KmsiInterrupt' {
        InModuleScope Xdr.Portal.Auth {
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
            $result = Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }

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
        InModuleScope Xdr.Portal.Auth {
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
            Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/appverify' -and
                $Method -eq 'Post' -and
                $Body.ContinueAuth -eq 'true'
            }
        }
    }

    It 'skips MFA registration via ProcessAuth when iRemainingDaysToSkipMfaRegistration > 0' {
        InModuleScope Xdr.Portal.Auth {
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
            Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://login.microsoftonline.com/common/SAS/ProcessAuth' -and
                $Body.type -eq 22 -and
                $Body.request -eq 'proof-state'
            }
        }
    }

    It 'throws when ConvergedProofUpRedirect has iRemainingDaysToSkipMfaRegistration = 0' {
        InModuleScope Xdr.Portal.Auth {
            Mock Invoke-WebRequest { }

            $state = [pscustomobject]@{
                pgid = 'ConvergedProofUpRedirect'
                iRemainingDaysToSkipMfaRegistration = 0
                sCtx = 'c'; sFT = 'f'; canary = 'cn'
            }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            {
                Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }
            } | Should -Throw "*MFA registration required*"
        }
    }

    It 'breaks after at most 10 iterations even when alternating pgids keep appearing' {
        InModuleScope Xdr.Portal.Auth {
            # Alternate the response pgid each call so the same-pgid break does not
            # trip. Each call flips: KmsiInterrupt -> CmsiInterrupt -> KmsiInterrupt ...
            # The hard 10-loop cap must then be the only exit condition.
            $script:iteration = 0
            Mock Invoke-WebRequest {
                $script:iteration++
                # Flip so that two consecutive iterations never see the same pgid:
                #   iter 1 emits KmsiInterrupt (state was CmsiInterrupt).
                #   iter 2 emits CmsiInterrupt.  etc.
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
            Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            # Hard cap is 10. Assert exactly 10 to prove the hard cap fired, not
            # the same-pgid short-circuit nor any other premature exit.
            Should -Invoke Invoke-WebRequest -Times 10 -Exactly -ParameterFilter { $true }
        }
    }

    It 'breaks when pgid repeats on two consecutive iterations (same-pgid short-circuit)' {
        InModuleScope Xdr.Portal.Auth {
            # KmsiInterrupt -> KmsiInterrupt: first call runs the handler; the
            # response parses back to pgid=KmsiInterrupt again, which tripping
            # the $pgid -eq $lastPgid break in the loop head.
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
            Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null } | Out-Null

            # Only one handler POST runs before same-pgid triggers break.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $true }
        }
    }

    It 'returns immediately without calls when pgid is empty/missing' {
        InModuleScope Xdr.Portal.Auth {
            Mock Invoke-WebRequest { }

            $state = [pscustomobject]@{ pgid = ''; sCtx = 'c'; sFT = 'f'; canary = 'cn' }
            $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $result = Resolve-InterruptPage -Session $session -AuthResult @{ State = $state; LastResponse = $null }

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
        InModuleScope Xdr.Portal.Auth -Parameters @{ NoMfaHtml = $script:NoMfaHtml } {
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
        InModuleScope Xdr.Portal.Auth -Parameters @{ MfaHtml = $script:ConvergedTfaHtml } {
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
        InModuleScope Xdr.Portal.Auth -Parameters @{ WrongPwHtml = $script:WrongPasswordHtml } {
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
        InModuleScope Xdr.Portal.Auth -Parameters @{ LockedHtml = $script:LockedAccountHtml } {
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
        InModuleScope Xdr.Portal.Auth {
            $sessionInfo = [pscustomobject]@{ sFT='ft'; sCtx='ctx'; canary='cn'; urlPost='/common/login' }
            $credential = @{ upn = 'x@y.com'; totpBase32 = 'JBSWY3DPEHPK3PXP' }   # no password
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
        InModuleScope Xdr.Portal.Auth {
            $sessionInfo = [pscustomobject]@{ sFT='ft'; sCtx='ctx'; canary='cn'; urlPost='/common/login' }
            $credential = @{ upn = 'x@y.com'; password = 'pw' }   # no totpBase32
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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

            # EndAuth called twice: first dup, second success.
            Should -Invoke Invoke-RestMethod -Times 2 -ParameterFilter { $Uri -match 'EndAuth' }
            # Start-Sleep invoked between retries (Pester 5 Should -Invoke without
            # -Exactly means "at least N times").
            Should -Invoke Start-Sleep -Times 1
        }
    }

    It 'throws when EndAuth returns a non-retryable terminal error' {
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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
        InModuleScope Xdr.Portal.Auth {
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

            # Expected order: fido/get pre-verify, /common/login (assertion), /common/login?sso_reload=true
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
        InModuleScope Xdr.Portal.Auth {
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
#  Get-EstsCookie integration-level (HTTP fully mocked)
# ============================================================================
Describe 'Get-EstsCookie (integration-level, HTTP fully mocked)' {
    It 'returns @{Session; Sccauth; XsrfToken; TenantId; AcquiredUtc} through the CredentialsTotp path' {
        InModuleScope Xdr.Portal.Auth {
            # Mock credential chain:
            #  1. GET portal -> canonical login HTML
            #  2. POST creds -> MFA page
            #  3. BeginAuth / EndAuth / ProcessAuth via Invoke-RestMethod + Invoke-WebRequest
            #  4. KmsiInterrupt interrupt POST (handled by Resolve-InterruptPage)
            #  5. Form_post back to portal
            #  6. TenantContext rest call
            #
            # Cookies sccauth + XSRF-TOKEN are seeded manually on the session
            # to simulate the portal setting them during the 302 chain.

            Mock Get-TotpCode { return '654321' }

            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                } elseif ($Uri -match 'TenantContext') {
                    return [pscustomobject]@{
                        AuthInfo = [pscustomobject]@{ TenantId = 'aa11bb22-cc33-dd44-ee55-ff6677889900' }
                    }
                }
            }

            $script:wrCall = 0
            Mock Invoke-WebRequest {
                $script:wrCall++
                # Seed sccauth + XSRF-TOKEN on the session after the first call,
                # mimicking the portal setting them across the redirect chain.
                if ($script:wrCall -eq 1 -and $WebSession) {
                    $c1 = [System.Net.Cookie]::new('sccauth', 'fake-sccauth-value-base64', '/', 'security.microsoft.com')
                    $c2 = [System.Net.Cookie]::new('XSRF-TOKEN', 'fake-xsrf-token-value', '/', 'security.microsoft.com')
                    $WebSession.Cookies.Add($c1)
                    $WebSession.Cookies.Add($c2)
                }

                # Step 1: GET portal -> login HTML with $Config
                if ($script:wrCall -eq 1) {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"Login","sFT":"ft1","sCtx":"ctx1","canary":"can1","urlPost":"/common/login","correlationId":"12345678-1234-1234-1234-123456789abc"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/oauth2/authorize' } }
                    }
                }

                # Step 2: credentials POST -> ConvergedTFA
                if ($Uri -match 'login\.microsoftonline\.com/common/login' -and -not ($Uri -match 'sso_reload')) {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"ConvergedTFA","sFT":"ft-mfa","sCtx":"ctx-mfa","canary":"can-mfa","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP"}]};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/login' } }
                    }
                }

                # Step 3: ProcessAuth -> KmsiInterrupt
                if ($Uri -match 'ProcessAuth') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"KmsiInterrupt","sFT":"ft-kmsi","sCtx":"ctx-kmsi","canary":"can-kmsi","urlPost":"/kmsi"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/SAS/ProcessAuth' } }
                    }
                }

                # Step 4: KMSI -> form_post HTML
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

                # Step 5: final portal POST or portal-root pings
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
            $result = Get-EstsCookie -Method CredentialsTotp -Credential $credential -PortalHost 'security.microsoft.com'

            $result | Should -Not -BeNullOrEmpty
            $result.Session   | Should -BeOfType [Microsoft.PowerShell.Commands.WebRequestSession]
            $result.Sccauth   | Should -Be 'fake-sccauth-value-base64'
            $result.XsrfToken | Should -Be 'fake-xsrf-token-value'
            $result.TenantId  | Should -Be 'aa11bb22-cc33-dd44-ee55-ff6677889900'
            $result.AcquiredUtc | Should -BeOfType [datetime]
        }
    }

    It 'throws when portal-scoped ESTS flow returns a session without sccauth' {
        InModuleScope Xdr.Portal.Auth {
            # Simulate the happy-path HTML flow, but never seed sccauth cookies
            # on the session. Get-EstsCookie should throw with the "sccauth not
            # issued" message so Test-MDEPortalAuth can categorise the failure.
            Mock Get-TotpCode { return '000000' }

            Mock Invoke-RestMethod {
                if ($Uri -match 'BeginAuth') {
                    return [pscustomobject]@{ Success = $true; SessionId = 's'; FlowToken = 'f'; Ctx = 'c' }
                } elseif ($Uri -match 'EndAuth') {
                    return [pscustomobject]@{ Success = $true; FlowToken = 'f2'; Ctx = 'c2' }
                }
            }

            $script:wr2 = 0
            Mock Invoke-WebRequest {
                $script:wr2++
                if ($script:wr2 -eq 1) {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"Login","sFT":"f1","sCtx":"c1","canary":"k1","urlPost":"/common/login"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/oauth2/authorize' } }
                    }
                }
                if ($Uri -match 'login\.microsoftonline\.com/common/login') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"ConvergedTFA","sFT":"f","sCtx":"c","canary":"k","urlPost":"/common/login","arrUserProofs":[{"authMethodId":"PhoneAppOTP"}]};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/login' } }
                    }
                }
                if ($Uri -match 'ProcessAuth') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @()
                        Content = '<html><script>$Config = {"pgid":"KmsiInterrupt","sFT":"f","sCtx":"c","canary":"k","urlPost":"/kmsi"};' + [char]10 + '</script></html>'
                        BaseResponse = [pscustomobject]@{ RequestMessage = [pscustomobject]@{ RequestUri = [uri]'https://login.microsoftonline.com/common/SAS/ProcessAuth' } }
                    }
                }
                # Resolve-InterruptPage hits /kmsi. Return a form_post HTML so the
                # auth state parses cleanly and the flow continues to the cookie
                # check (which should be the failure point under test).
                if ($Uri -match '/kmsi$') {
                    return [pscustomobject]@{
                        StatusCode       = 200
                        RawContentLength = 10
                        InputFields      = @(
                            [pscustomobject]@{ Name='code';     Value='0.AAAA' }
                            [pscustomobject]@{ Name='id_token'; Value='eyJ' }
                            [pscustomobject]@{ Name='state';    Value='s' }
                        )
                        Content = '<html><form action="https://security.microsoft.com/" method="POST"><input name="code" value="0.AAAA"/></form></html>'
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

            $credential = @{ upn='svc@test.com'; password='pw'; totpBase32='JBSWY3DPEHPK3PXP' }
            {
                Get-EstsCookie -Method CredentialsTotp -Credential $credential -PortalHost 'security.microsoft.com'
            } | Should -Throw "*sccauth*"
        }
    }

    It 'passes the portal-scoped client_id 80ccca67... in redirect_uri / OIDC chain (module-level constant)' {
        InModuleScope Xdr.Portal.Auth {
            # Prove the portalClients map binds security.microsoft.com to the
            # Defender XDR public client. This is asserted by reading back
            # the source — the client_id is emitted inside Complete-CredentialsFlow's
            # POST body rather than the GET URL, so we assert the client_id reaches
            # Invoke-WebRequest via the credential POST body.

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
                if ($script:wr3 -eq 1 -and $WebSession) {
                    $c1 = [System.Net.Cookie]::new('sccauth', 's', '/', 'security.microsoft.com')
                    $c2 = [System.Net.Cookie]::new('XSRF-TOKEN', 'x', '/', 'security.microsoft.com')
                    $WebSession.Cookies.Add($c1)
                    $WebSession.Cookies.Add($c2)
                }
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
            Get-EstsCookie -Method CredentialsTotp -Credential $credential -PortalHost 'security.microsoft.com' | Out-Null

            # The credentials POST must carry client_id=80ccca67-54bd-44ab-8625-4b79c4dc7775.
            # (Pester 5 Should -Invoke without -Exactly treats -Times as minimum count.)
            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $Uri -match 'login\.microsoftonline\.com/common/login' -and
                $Body -and ($Body.client_id -eq '80ccca67-54bd-44ab-8625-4b79c4dc7775')
            }
        }
    }

    It 'throws when PortalHost is not in the portalClients map' {
        InModuleScope Xdr.Portal.Auth {
            $credential = @{ upn='svc@test.com'; password='pw'; totpBase32='JBSWY3DPEHPK3PXP' }
            {
                Get-EstsCookie -Method CredentialsTotp -Credential $credential -PortalHost 'unknown.microsoft.com'
            } | Should -Throw "*Unknown portal host*"
        }
    }

    It "throws when Credential lacks 'upn'" {
        InModuleScope Xdr.Portal.Auth {
            {
                Get-EstsCookie -Method CredentialsTotp -Credential @{ password='pw'; totpBase32='x' } -PortalHost 'security.microsoft.com'
            } | Should -Throw "*upn*"
        }
    }
}
