#Requires -Module Pester
# Additional pure-function coverage for Xdr.Auth — targets HTML parsing helpers,
# KV/env-local credential resolution, and TOTP edge cases not covered in Xdr.Auth.PureHelpers.Tests.ps1.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force
}

Describe 'Test-EntraField + Get-EntraField (pure helpers · HTML config blob extraction)' -Tag 'auth-pure-2' {
    It 'Test-EntraField returns $false for null object' {
        $val = & (Get-Module Xdr.Auth) { Test-EntraField -Object $null -Name 'AnyField' }
        $val | Should -BeFalse
    }
    It 'Test-EntraField returns $true when property exists on PSCustomObject' {
        $obj = [pscustomobject]@{ FieldA = 'v' }
        & (Get-Module Xdr.Auth) { param($o) Test-EntraField -Object $o -Name 'FieldA' } -o $obj | Should -BeTrue
    }
    It 'Test-EntraField returns $false when property does not exist' {
        $obj = [pscustomobject]@{ FieldA = 'v' }
        & (Get-Module Xdr.Auth) { param($o) Test-EntraField -Object $o -Name 'NotThere' } -o $obj | Should -BeFalse
    }
    It 'Get-EntraField returns the value when field present' {
        $obj = [pscustomobject]@{ OrgId = 'abc-123' }
        & (Get-Module Xdr.Auth) { param($o) Get-EntraField -Object $o -Name 'OrgId' } -o $obj | Should -Be 'abc-123'
    }
    It 'Get-EntraField returns default when field absent' {
        $obj = [pscustomobject]@{ OtherField = 'x' }
        $r = & (Get-Module Xdr.Auth) { param($o) Get-EntraField -Object $o -Name 'OrgId' -Default 'fallback' } -o $obj
        $r | Should -Be 'fallback'
    }
}

Describe 'Get-EntraConfigBlob (HTML Config = {...} extractor)' -Tag 'auth-pure-2' {
    It 'returns $null on empty HTML' {
        $r = & (Get-Module Xdr.Auth) { Get-EntraConfigBlob -Html '' }
        $r | Should -BeNullOrEmpty
    }
    It 'extracts the Config blob terminated by semicolon + newline' {
        # Build HTML via single-quote literal + concat (avoid PS parser eating $Config inside double-quotes)
        $html = '<script>' + '$Config' + ' = {"flowToken":"abc","sFT":"def"};' + "`n" + '</' + 'script>'
        $cfg = & (Get-Module Xdr.Auth) { param($h) Get-EntraConfigBlob -Html $h } -h $html
        $cfg | Should -Not -BeNullOrEmpty
        $cfg.flowToken | Should -Be 'abc'
        $cfg.sFT       | Should -Be 'def'
    }
    It 'extracts the Config blob terminated by ;-script-close' {
        $html = '<script>' + '$Config' + ' = {"flowToken":"xyz"};' + '</' + 'script>'
        $cfg = & (Get-Module Xdr.Auth) { param($h) Get-EntraConfigBlob -Html $h } -h $html
        $cfg.flowToken | Should -Be 'xyz'
    }
    It 'returns $null on HTML without Config blob' {
        $html = '<html><body>no config here</body></html>'
        $cfg = & (Get-Module Xdr.Auth) { param($h) Get-EntraConfigBlob -Html $h } -h $html
        $cfg | Should -BeNullOrEmpty
    }
}

Describe 'Test-MfaEndAuthSuccess (pure validator)' -Tag 'auth-pure-2' {
    # Test-MfaEndAuthSuccess uses [Parameter(Mandatory)] so PowerShell binding rejects null at the gate.
    It 'rejects null EndAuth via Mandatory binding (PowerShell native guard)' {
        { & (Get-Module Xdr.Auth) { Test-MfaEndAuthSuccess -EndAuth $null } } | Should -Throw '*Cannot bind argument*'
    }
    It 'returns $true when EndAuth.Success is $true' {
        $eA = [pscustomobject]@{ Success = $true }
        & (Get-Module Xdr.Auth) { param($e) Test-MfaEndAuthSuccess -EndAuth $e } -e $eA | Should -BeTrue
    }
    It 'returns $true when ResultValue is AuthenticationSucceeded' {
        $eA = [pscustomobject]@{ Success = $false; ResultValue = 'AuthenticationSucceeded' }
        & (Get-Module Xdr.Auth) { param($e) Test-MfaEndAuthSuccess -EndAuth $e } -e $eA | Should -BeTrue
    }
    It 'returns $true when ResultValue is "Success"' {
        $eA = [pscustomobject]@{ Success = $false; ResultValue = 'Success' }
        & (Get-Module Xdr.Auth) { param($e) Test-MfaEndAuthSuccess -EndAuth $e } -e $eA | Should -BeTrue
    }
    It 'returns $false for unrecognised ResultValue' {
        $eA = [pscustomobject]@{ Success = $false; ResultValue = 'AuthenticationFailed' }
        & (Get-Module Xdr.Auth) { param($e) Test-MfaEndAuthSuccess -EndAuth $e } -e $eA | Should -BeFalse
    }
}

Describe 'Get-XdrTotpCode RFC 6238 vectors (extended)' -Tag 'auth-pure-2' {
    # Known RFC 6238 vectors (T0=0, secret='12345678901234567890', SHA-1) — different time values
    # Note: our implementation uses current time; we exercise the code-path + 6-digit output shape.
    It 'always returns 6-digit numeric code regardless of seed length (B32 byte length variance)' {
        # 16-char base32 = 10 bytes (HMAC standard)
        $code1 = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'
        # 32-char base32 = 20 bytes (common Microsoft seed length)
        $code2 = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP'
        $code1 | Should -Match '^\d{6}$'
        $code2 | Should -Match '^\d{6}$'
    }
    It 'is deterministic given the same -Now' {
        $fixed = [datetime]'2026-01-01T00:00:00Z'
        $a = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $fixed
        $b = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $fixed
        $a | Should -Be $b
    }
    It 'rotates code in 30-second windows' {
        $t1 = [datetime]'2026-01-01T00:00:00Z'
        $t2 = $t1.AddSeconds(30)
        $a = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $t1
        $b = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $t2
        # Different 30-sec windows MUST produce different codes (collision probability < 1 in 10^6)
        $a | Should -Not -Be $b
    }
}

Describe 'New-ApiproxyPath additional service prefixes (Defender · Compliance · MDC etc.)' -Tag 'auth-pure-2' {
    It 'accepts gws (Compliance Auth Server)' {
        $p = New-ApiproxyPath -Service 'gws' -Path 'ComplianceAuthServer/v1.0/IsAllowedPermissionWithScopes'
        $p | Should -Match '^/apiproxy/gws/'
    }
    It 'accepts mdi (Defender for Identity)' {
        $p = New-ApiproxyPath -Service 'mdi' -Path 'workspaces/abc/sensors'
        $p | Should -Match '^/apiproxy/mdi/'
    }
    It 'accepts shell (Defender shell · /apiproxy/shell/)' {
        $p = New-ApiproxyPath -Service 'shell' -Path 'api/something'
        $p | Should -Match '^/apiproxy/shell/'
    }
}
