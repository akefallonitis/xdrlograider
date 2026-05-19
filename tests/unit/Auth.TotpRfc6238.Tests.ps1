#Requires -Module Pester
# Locks Get-XdrTotpCode against RFC 6238 reference test vectors.
# The reference vectors (Appendix B) use 'JBSWY3DPEHPK3PXP' for HMAC-SHA1 8-digit
# TOTP codes at specific Unix epoch times. We use the 6-digit form for parity
# with Microsoft authenticator apps.

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Get-XdrTotpCode — RFC 6238 reference vectors' {

    # RFC 6238 Appendix B reference vectors. Secret = "12345678901234567890" (ASCII,
    # 20 bytes) -> base32 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'. The RFC lists 8-digit
    # TOTPs; the 6-digit form is the last 6 digits of the 8-digit code.
    # T=59s, 8-digit code = 94287082 → 6-digit = 287082
    It 'matches RFC 6238 reference vector at T=59s (6-digit 287082)' {
        $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
        $t = [datetime]::new(1970,1,1,0,0,59,[DateTimeKind]::Utc)
        $code = Get-XdrTotpCode -Base32Secret $secret -Now $t
        $code | Should -Be '287082'
    }

    # T=1111111109s, 8-digit = 07081804 → 6-digit = 081804
    It 'matches RFC 6238 reference vector at T=1111111109s (6-digit 081804)' {
        $secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
        $t = [datetime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc).AddSeconds(1111111109)
        $code = Get-XdrTotpCode -Base32Secret $secret -Now $t
        $code | Should -Be '081804'
    }

    It 'returns 6 digits for any valid base32 input' {
        (Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP').Length | Should -Be 6
    }

    It 'returns a different code for a different time window' {
        $t1 = [datetime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
        $t2 = $t1.AddMinutes(1)
        $a = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $t1
        $b = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP' -Now $t2
        $a | Should -Not -Be $b
    }

    It 'accepts base32 with padding chars and ignores them' {
        $t = [datetime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
        $without = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'   -Now $t
        $with    = Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PXP==' -Now $t
        $with | Should -Be $without
    }

    It 'throws on invalid base32 character' {
        { Get-XdrTotpCode -Base32Secret 'JBSWY3DPEHPK3PX!' } | Should -Throw
    }
}
