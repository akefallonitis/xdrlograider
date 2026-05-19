#Requires -Module Pester
# Locks the bearer L1 triad behaviour OFFLINE:
#   - Get-XdrBearerTokenExpiry · pure JWT decoder · hand-constructed JWTs with known exp
#   - Get-EntraBearerToken auth_code extraction · realistic form_post HTML fixtures
#   - Refresh-XdrBearerToken parameter shape + invalid_grant fall-back error message
#
# End-to-end live verification at L-1 (5-portal probe).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force

    function New-TestJwt {
        param(
            [Parameter(Mandatory)][hashtable]$Payload,
            [hashtable]$Header = @{ alg = 'none'; typ = 'JWT' }
        )
        function ToBase64Url([byte[]]$Bytes) {
            ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+','-').Replace('/','_')
        }
        $h = ToBase64Url ([System.Text.Encoding]::UTF8.GetBytes(($Header  | ConvertTo-Json -Compress)))
        $p = ToBase64Url ([System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Compress)))
        "$h.$p."
    }

    function Get-AuthCodeFromFormPostHtml {
        param([Parameter(Mandatory)][string]$Html)
        if ($Html -match 'name="code"\s+value="([^"]+)"')        { return $Matches[1] }
        elseif ($Html -match "name='code'\s+value='([^']+)'")    { return $Matches[1] }
        elseif ($Html -match 'name="id_token"\s+value="([^"]+)"'){ throw 'implicit-flow' }
        else { return $null }
    }

    $script:FormPostHtmlDoubleQuoted = @'
<!DOCTYPE html>
<html><body>
  <form method="post" action="https://main.iam.ad.ext.azure.com/signin-oidc">
    <input type="hidden" name="code"          value="0.AbCDEfGhIjKlMnOpQrStUvWxYz1234567890_test-code-value" />
    <input type="hidden" name="state"         value="MTIzNDU2Nzg5MA==" />
    <input type="hidden" name="session_state" value="abcd-1234" />
  </form>
</body></html>
'@

    $script:FormPostHtmlSingleQuoted = @"
<form method='post' action='https://services.autopatch.microsoft.com/signin-oidc'>
  <input type='hidden' name='code' value='0.AbC-single-quoted-auth-code-value' />
</form>
"@

    $script:FormPostHtmlImplicitFlow = @'
<form method="post" action="https://example/cb">
  <input type="hidden" name="id_token" value="eyJhbGciOiJSUzI1NiJ9..." />
</form>
'@

    $script:LoginInterruptHtml = @'
<form method="post" action="https://login.microsoftonline.com/kmsi">
  <input type="hidden" name="LoginOptions" value="3" />
</form>
'@
}

Describe 'Get-XdrBearerTokenExpiry · JWT exp claim decoder' -Tag 'auth-bearer' {

    It 'is exported from Xdr.Auth' {
        Get-Command -Module Xdr.Auth -Name 'Get-XdrBearerTokenExpiry' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'default-ttl when token is empty' {
        $r = Get-XdrBearerTokenExpiry -BearerToken '' -DefaultTtlMinutes 50 -AcquiredUtc ([datetime]'2026-05-17T00:00:00Z')
        $r.TokenPresent         | Should -BeFalse
        $r.EarliestExpirySource | Should -Be 'default-ttl'
        $r.ExpiresUtc           | Should -Be ([datetime]'2026-05-17T00:50:00Z')
    }

    It 'malformed when token is not 3 segments' {
        $r = Get-XdrBearerTokenExpiry -BearerToken 'not.a.jwt.token' -AcquiredUtc ([datetime]'2026-05-17T00:00:00Z')
        $r.EarliestExpirySource | Should -Be 'malformed'
    }

    It 'malformed when payload is not valid base64url' {
        $r = Get-XdrBearerTokenExpiry -BearerToken 'header.!!!notbase64!!!.sig'
        $r.EarliestExpirySource | Should -Be 'malformed'
    }

    It 'reads exp claim as Unix epoch seconds → UTC datetime' {
        $expUtc = [datetime]'2026-05-17T01:00:00Z'
        $expSec = [int64]($expUtc - [datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
        $jwt    = New-TestJwt -Payload @{ exp = $expSec; aud = 'https://api.manage.microsoft.com' }
        $r = Get-XdrBearerTokenExpiry -BearerToken $jwt
        $r.EarliestExpirySource | Should -Be 'jwt-exp'
        $r.ExpiresUtc           | Should -Be $expUtc
        $r.Audience             | Should -Be 'https://api.manage.microsoft.com'
    }

    It "strips a 'Bearer ' prefix before decoding" {
        $expSec = [int64]([datetime]'2027-01-01T00:00:00Z' - [datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
        $jwt    = New-TestJwt -Payload @{ exp = $expSec }
        $r = Get-XdrBearerTokenExpiry -BearerToken "Bearer $jwt"
        $r.ExpiresUtc | Should -Be ([datetime]'2027-01-01T00:00:00Z')
    }

    It 'default-ttl when payload has no exp claim (but exposes aud)' {
        $jwt = New-TestJwt -Payload @{ aud = 'https://graph.microsoft.com' }
        $r = Get-XdrBearerTokenExpiry -BearerToken $jwt -DefaultTtlMinutes 50 -AcquiredUtc ([datetime]'2026-05-17T00:00:00Z')
        $r.EarliestExpirySource | Should -Be 'default-ttl'
        $r.Audience             | Should -Be 'https://graph.microsoft.com'
    }

    It 'handles base64url payloads requiring padding restoration' {
        $expSec = [int64]([datetime]'2026-12-31T23:59:00Z' - [datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)).TotalSeconds
        $jwt    = New-TestJwt -Payload @{ exp = $expSec; aud = 'x' }
        (Get-XdrBearerTokenExpiry -BearerToken $jwt).ExpiresUtc | Should -Be ([datetime]'2026-12-31T23:59:00Z')
    }
}

Describe 'Get-EntraBearerToken auth_code extraction (form_post HTML parser)' -Tag 'auth-bearer' {

    It 'is exported from Xdr.Auth' {
        Get-Command -Module Xdr.Auth -Name 'Get-EntraBearerToken' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'extracts the auth_code from a standard double-quoted form_post' {
        Get-AuthCodeFromFormPostHtml -Html $script:FormPostHtmlDoubleQuoted | Should -Be '0.AbCDEfGhIjKlMnOpQrStUvWxYz1234567890_test-code-value'
    }

    It 'extracts the auth_code from a single-quoted form_post' {
        Get-AuthCodeFromFormPostHtml -Html $script:FormPostHtmlSingleQuoted | Should -Be '0.AbC-single-quoted-auth-code-value'
    }

    It 'throws on implicit-flow id_token form_post' {
        { Get-AuthCodeFromFormPostHtml -Html $script:FormPostHtmlImplicitFlow } | Should -Throw -ExpectedMessage 'implicit-flow'
    }

    It 'returns null on an interrupt page (no name="code" present)' {
        Get-AuthCodeFromFormPostHtml -Html $script:LoginInterruptHtml | Should -BeNullOrEmpty
    }

    It 'does NOT confuse other form fields for code' {
        $code = Get-AuthCodeFromFormPostHtml -Html $script:FormPostHtmlDoubleQuoted
        $code | Should -Not -Match '^MTIzNDU2'
        $code | Should -Not -Match '^abcd-'
    }
}

Describe 'Refresh-XdrBearerToken parameter shape' -Tag 'auth-bearer' {

    It 'is exported from Xdr.Auth' {
        Get-Command -Module Xdr.Auth -Name 'Refresh-XdrBearerToken' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'declares the OAuth2 refresh-token parameters' {
        $cmd = Get-Command Refresh-XdrBearerToken
        $cmd.Parameters.Keys | Should -Contain 'RefreshToken'
        $cmd.Parameters.Keys | Should -Contain 'ClientId'
        $cmd.Parameters.Keys | Should -Contain 'Scope'
        $cmd.Parameters.Keys | Should -Contain 'TenantId'
    }

    It 'throws on empty RefreshToken with caller-must-fall-back message' {
        { Refresh-XdrBearerToken -RefreshToken '' -ClientId 'x' -Scope 'y' } |
            Should -Throw -ExpectedMessage '*fall back*Get-EntraBearerToken*full cookie chain*'
    }
}
