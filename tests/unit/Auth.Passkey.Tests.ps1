#Requires -Module Pester
# φ.AUTH.6 · Passkey crypto primitives · ECDSA-P256 WebAuthn assertion sign.
# Locks: deterministic byte-level test vectors for base64url codec · sign primitive
# produces verifiable signature (independently verified with the corresponding public key) ·
# clientDataJSON matches WebAuthn spec shape · authData has correct rpIdHash + flags + signCount.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Auth/Xdr.Auth.psd1') -Force

    # Generate a deterministic ECDSA-P256 keypair at test-suite startup · stable across
    # all tests in this Describe but fresh per test run (not embedded in source · avoids
    # accidentally publishing a "secret" that's actually a test fixture).
    $script:TestEcdsa  = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
    $script:TestPemPk  = $script:TestEcdsa.ExportPkcs8PrivateKeyPem()
    $script:TestPubKey = $script:TestEcdsa.ExportSubjectPublicKeyInfo()

    $script:Passkey = [pscustomobject]@{
        credentialId  = 'abc-credential-id-base64url-format'
        privateKeyPem = $script:TestPemPk
        rpId          = 'login.microsoft.com'
        userHandle    = 'cmFuZG9tLXVzZXItaGFuZGxl'
    }
}

AfterAll {
    if ($script:TestEcdsa) { $script:TestEcdsa.Dispose() }
}

Describe 'φ.AUTH.6 · Base64URL codec round-trip' -Tag 'passkey' {

    It 'encodes single byte produces predictable 1-2 chars · no padding' {
        # [byte]0 → 'AA' in base64 · trimmed to 'AA' in base64url (no =)
        $enc = InModuleScope Xdr.Auth { ConvertTo-XdrBase64Url -Bytes ([byte[]]@(0)) }
        $enc | Should -Be 'AA'
        $enc | Should -Not -Match '='
    }

    It 'round-trips arbitrary byte sequence' {
        $bytes = [byte[]]@(0,1,2,3,255,128,64,32,16,8)
        $enc = InModuleScope Xdr.Auth { param($b) ConvertTo-XdrBase64Url -Bytes $b } -Parameters @{ b = $bytes }
        $dec = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $enc }
        # Byte-by-byte equality
        $dec.Length | Should -Be $bytes.Length
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $dec[$i] | Should -Be $bytes[$i]
        }
    }

    It 'uses URL-safe alphabet (- _) instead of standard (+ /)' {
        # Bytes that would produce + and / in standard base64
        $bytes = [byte[]]@(0xFF,0xFE,0xFD,0xFC,0xFB,0xFA,0xF9,0xF8,0xF7)
        $enc = InModuleScope Xdr.Auth { param($b) ConvertTo-XdrBase64Url -Bytes $b } -Parameters @{ b = $bytes }
        $enc | Should -Not -Match '[+/=]'
    }
}

Describe 'φ.AUTH.6 · Invoke-XdrPasskeyChallenge · WebAuthn sign primitive' -Tag 'passkey' {

    It 'requires credentialId in PasskeyJson' {
        $bad = [pscustomobject]@{ privateKeyPem = $script:TestPemPk }
        InModuleScope Xdr.Auth {
            param($p) { Invoke-XdrPasskeyChallenge -PasskeyJson $p -Challenge 'x' -Origin 'https://login.microsoft.com' } | Should -Throw '*credentialId required*'
        } -Parameters @{ p = $bad }
    }

    It 'requires privateKeyPem in PasskeyJson' {
        $bad = [pscustomobject]@{ credentialId = 'x' }
        InModuleScope Xdr.Auth {
            param($p) { Invoke-XdrPasskeyChallenge -PasskeyJson $p -Challenge 'x' -Origin 'https://login.microsoft.com' } | Should -Throw '*privateKeyPem required*'
        } -Parameters @{ p = $bad }
    }

    It 'returns 4 expected base64url fields' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'test-challenge-base64url'
        } -Parameters @{ pk = $script:Passkey }
        $sig.Keys | Sort-Object | Should -Be @('authenticatorData','clientDataJSON','credentialId','signature')
        # All values base64url (no + / =)
        foreach ($k in 'clientDataJSON','authenticatorData','signature') {
            $sig[$k] | Should -Not -Match '[+/=]'
            $sig[$k] | Should -Not -BeNullOrEmpty
        }
        $sig.credentialId | Should -Be $script:Passkey.credentialId
    }

    It 'clientDataJSON decodes to JSON with type/challenge/origin' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'chal-XYZ' -Origin 'https://login.microsoft.com'
        } -Parameters @{ pk = $script:Passkey }
        $clientBytes = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.clientDataJSON }
        $clientJson = [System.Text.Encoding]::UTF8.GetString($clientBytes)
        $obj = $clientJson | ConvertFrom-Json
        $obj.type      | Should -Be 'webauthn.get'
        $obj.challenge | Should -Be 'chal-XYZ'
        $obj.origin    | Should -Be 'https://login.microsoft.com'
    }

    It 'authData has correct length 37 (32B rpIdHash + 1B flags + 4B signCount)' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'c'
        } -Parameters @{ pk = $script:Passkey }
        $authData = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.authenticatorData }
        $authData.Length | Should -Be 37
        # Flags byte at index 32 must be 0x05 (UP=1 · UV=1)
        $authData[32] | Should -Be 0x05
        # signCount bytes (33..36) all zero (software auth)
        for ($i = 33; $i -lt 37; $i++) { $authData[$i] | Should -Be 0 }
    }

    It 'authData rpIdHash matches SHA-256("login.microsoft.com")' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'c'
        } -Parameters @{ pk = $script:Passkey }
        $authData = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.authenticatorData }
        $expectedHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes('login.microsoft.com'))
        for ($i = 0; $i -lt 32; $i++) { $authData[$i] | Should -Be $expectedHash[$i] }
    }

    It 'signature verifies against the corresponding public key (proves real ECDSA-P256)' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'verify-test'
        } -Parameters @{ pk = $script:Passkey }
        # Independently reconstruct what was signed: authData || SHA-256(clientDataJSON)
        $authBytes   = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.authenticatorData }
        $clientBytes = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.clientDataJSON }
        $sigBytes    = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.signature }
        $clientHash = [System.Security.Cryptography.SHA256]::HashData($clientBytes)
        $toVerify = [byte[]]::new($authBytes.Length + $clientHash.Length)
        [array]::Copy($authBytes, 0, $toVerify, 0, $authBytes.Length)
        [array]::Copy($clientHash, 0, $toVerify, $authBytes.Length, $clientHash.Length)
        # Verify with the PUBLIC key (proves sign used the matching PRIVATE key · no MITM)
        $verifier = [System.Security.Cryptography.ECDsa]::Create()
        try {
            $bytesRead = 0
            $verifier.ImportSubjectPublicKeyInfo($script:TestPubKey, [ref]$bytesRead)
            $ok = $verifier.VerifyData($toVerify, $sigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
            $ok | Should -BeTrue
        } finally {
            $verifier.Dispose()
        }
    }

    It 'rejects signature verification when tampered (negative test)' {
        $sig = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'tamper-test'
        } -Parameters @{ pk = $script:Passkey }
        $authBytes   = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.authenticatorData }
        $clientBytes = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.clientDataJSON }
        $sigBytes    = InModuleScope Xdr.Auth { param($s) ConvertFrom-XdrBase64Url -Text $s } -Parameters @{ s = $sig.signature }
        # Tamper clientData hash by flipping last byte
        $clientHash = [System.Security.Cryptography.SHA256]::HashData($clientBytes)
        $clientHash[31] = $clientHash[31] -bxor 0xFF
        $toVerify = [byte[]]::new($authBytes.Length + $clientHash.Length)
        [array]::Copy($authBytes, 0, $toVerify, 0, $authBytes.Length)
        [array]::Copy($clientHash, 0, $toVerify, $authBytes.Length, $clientHash.Length)
        $verifier = [System.Security.Cryptography.ECDsa]::Create()
        try {
            $bytesRead = 0
            $verifier.ImportSubjectPublicKeyInfo($script:TestPubKey, [ref]$bytesRead)
            $ok = $verifier.VerifyData($toVerify, $sigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
            $ok | Should -BeFalse
        } finally {
            $verifier.Dispose()
        }
    }

    It 'different challenges produce different signatures (no constant signature bug)' {
        $sig1 = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'challenge-A'
        } -Parameters @{ pk = $script:Passkey }
        $sig2 = InModuleScope Xdr.Auth {
            param($pk) Invoke-XdrPasskeyChallenge -PasskeyJson $pk -Challenge 'challenge-B'
        } -Parameters @{ pk = $script:Passkey }
        $sig1.clientDataJSON | Should -Not -Be $sig2.clientDataJSON
        # signatures will differ too (different challenges → different clientDataHash → different toSign)
        # Note · ECDSA signing is non-deterministic so even SAME challenge can produce different signatures
        # · but DIFFERENT challenges MUST produce different signatures (otherwise we have a bug)
        $sig1.signature | Should -Not -Be $sig2.signature
    }
}

Describe 'φ.AUTH.6 · Complete-XdrPasskeyFlow · pre-conditions' -Tag 'passkey' {

    It 'throws when Credential lacks passkey field' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $sessionInfo = [pscustomobject]@{ sCtx='c'; sFT='f'; canary='k' }
        $cred = @{ upn = 'sa@contoso.com' }   # no passkey
        $cid = [guid]::NewGuid()
        InModuleScope Xdr.Auth {
            param($s, $si, $c, $g) { Complete-XdrPasskeyFlow -Session $s -SessionInfo $si -Credential $c -CorrelationId $g } | Should -Throw "*'passkey'*"
        } -Parameters @{ s = $session; si = $sessionInfo; c = $cred; g = $cid }
    }

    It 'throws when SessionInfo has no FIDO challenge (HasFido=false or absent)' {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $sessionInfo = [pscustomobject]@{ sCtx='c'; sFT='f'; canary='k' }   # no oGetCredTypeResult / sFidoChallenge
        $cred = @{ upn = 'sa@contoso.com'; passkey = $script:Passkey }
        $cid = [guid]::NewGuid()
        InModuleScope Xdr.Auth {
            param($s, $si, $c, $g) { Complete-XdrPasskeyFlow -Session $s -SessionInfo $si -Credential $c -CorrelationId $g } | Should -Throw '*passkey not available*'
        } -Parameters @{ s = $session; si = $sessionInfo; c = $cred; g = $cid }
    }
}
