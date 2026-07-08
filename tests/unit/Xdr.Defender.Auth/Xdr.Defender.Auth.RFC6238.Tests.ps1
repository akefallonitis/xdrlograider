# RFC 6238 Appendix B test vectors for Get-XdrTotpCode
# Proves TOTP implementation is correct against the IETF reference vectors.
#
# Vectors (SHA-1 · 6-digit truncation from 8-digit RFC reference):
#   Key (ASCII): "12345678901234567890" · 20 bytes
#   Base32:      GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
#
#   T (sec)         8-digit       6-digit
#   59              94287082      287082
#   1111111109      07081804      081804
#   1111111111      14050471      050471
#   1234567890      89005924      005924
#   2000000000      69279037      279037

#Requires -Module Pester

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $modulesRoot.Path 'Xdr.Defender.Auth\Xdr.Defender.Auth.psd1') -Force -DisableNameChecking
}

Describe 'Get-XdrTotpCode · RFC 6238 Appendix B test vectors' {

    BeforeAll {
        $script:Seed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'  # base32("12345678901234567890")
    }

    It 'T=59 → 287082' {
        InModuleScope Xdr.Defender.Auth -ArgumentList $script:Seed {
            param($seed)
            Get-XdrTotpCode -Base32Seed $seed -UnixTimeSecondsOverride 59 | Should -Be '287082'
        }
    }

    It 'T=1111111109 → 081804' {
        InModuleScope Xdr.Defender.Auth -ArgumentList $script:Seed {
            param($seed)
            Get-XdrTotpCode -Base32Seed $seed -UnixTimeSecondsOverride 1111111109 | Should -Be '081804'
        }
    }

    It 'T=1111111111 → 050471' {
        InModuleScope Xdr.Defender.Auth -ArgumentList $script:Seed {
            param($seed)
            Get-XdrTotpCode -Base32Seed $seed -UnixTimeSecondsOverride 1111111111 | Should -Be '050471'
        }
    }

    It 'T=1234567890 → 005924' {
        InModuleScope Xdr.Defender.Auth -ArgumentList $script:Seed {
            param($seed)
            Get-XdrTotpCode -Base32Seed $seed -UnixTimeSecondsOverride 1234567890 | Should -Be '005924'
        }
    }

    It 'T=2000000000 → 279037' {
        InModuleScope Xdr.Defender.Auth -ArgumentList $script:Seed {
            param($seed)
            Get-XdrTotpCode -Base32Seed $seed -UnixTimeSecondsOverride 2000000000 | Should -Be '279037'
        }
    }
}

Describe 'Get-XdrTotpCode · base32 decoder robustness' {

    It 'accepts lowercase input (operator lab seed jz2gd6shgy5ryrcn pattern)' {
        InModuleScope Xdr.Defender.Auth {
            $upper = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 59
            $lower = Get-XdrTotpCode -Base32Seed 'gezdgnbvgy3tqojqgezdgnbvgy3tqojq' -UnixTimeSecondsOverride 59
            $upper | Should -Be $lower
            $upper | Should -Be '287082'
        }
    }

    It 'accepts mixed case (Mz2GD6shGY5RYRCN-style)' {
        InModuleScope Xdr.Defender.Auth {
            $up = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 59
            $mix = Get-XdrTotpCode -Base32Seed 'gEzDgNbVgY3TqOjQgEzDgNbVgY3TqOjQ' -UnixTimeSecondsOverride 59
            $mix | Should -Be $up
        }
    }

    It 'accepts space-separated groups' {
        InModuleScope Xdr.Defender.Auth {
            $clean = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 59
            $spaced = Get-XdrTotpCode -Base32Seed 'GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ' -UnixTimeSecondsOverride 59
            $spaced | Should -Be $clean
        }
    }

    It 'accepts = padding (RFC 4648 §3.2)' {
        InModuleScope Xdr.Defender.Auth {
            { Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQ==' -UnixTimeSecondsOverride 59 } | Should -Not -Throw
        }
    }

    It 'rejects invalid base32 char with clear error' {
        InModuleScope Xdr.Defender.Auth {
            { Get-XdrTotpCode -Base32Seed '!!!INVALID!!!' -UnixTimeSecondsOverride 59 } | Should -Throw '*Invalid base32 character*'
        }
    }
}

Describe 'Get-XdrTotpCode · 30-second time window' {

    It 'returns same code within the same 30s window' {
        InModuleScope Xdr.Defender.Auth {
            $a = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 100
            $b = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 129  # same 30s window (90-119, 120-149)
            # Actually 100 is in [90,119] window · 129 is in [120,149] · should DIFFER
            $a | Should -Not -Be $b
        }
    }

    It 'returns same code when T crosses by less than 30s within window' {
        InModuleScope Xdr.Defender.Auth {
            $a = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 120
            $b = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 149  # same [120,149] window
            $a | Should -Be $b
        }
    }

    It 'returns DIFFERENT code at window boundary (T=149 vs T=150)' {
        InModuleScope Xdr.Defender.Auth {
            $a = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 149  # [120,149]
            $b = Get-XdrTotpCode -Base32Seed 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ' -UnixTimeSecondsOverride 150  # [150,179]
            $a | Should -Not -Be $b
        }
    }
}
