#Requires -Version 7.4
# Φ1 · Passkey (FIDO2) headless assertion. Proves the ported WebAuthn ECDSA-P256 assertion is cryptographically VALID
# (the signature verifies against the public key over authenticatorData||SHA256(clientDataJSON)), inputs are guarded,
# and the Passkey auth branch is no longer a throw-stub. RED on the pre-port code: New-XdrPasskeyAssertion was absent
# and Get-XdrEntraEstsAuth's Passkey branch threw 'Passkey path not yet adopted in v0.1.0'. v0.1.0 deliverable (§3/§7/Φ1).

BeforeAll {
    $script:repo  = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $modulesRoot  = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@xdrtest.local'
    # Import in deterministic order (same as prod profile.ps1) so Defender.Auth's load-time Register-XdrPortalHandler resolves.
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Auth',
                     'Xdr.Common.OAuthBearer','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Capabilities',
                     'Xdr.Common.Runtime','Xdr.Defender.Auth')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'Φ1 · Passkey headless assertion (WebAuthn ECDSA-P256)' {
    It 'New-XdrPasskeyAssertion produces a signature that VERIFIES against the public key' {
        InModuleScope Xdr.Defender.Auth {
            $ec  = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $pem = $ec.ExportPkcs8PrivateKeyPem()
            $challenge = 'dGVzdC1jaGFsbGVuZ2U'
            $a = New-XdrPasskeyAssertion -Challenge $challenge -PrivateKeyPem $pem -CredentialId 'AAAABBBB' -RpId 'login.microsoft.com'
            $dec = { param($s) $t = $s.Replace('-', '+').Replace('_', '/'); switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }; [Convert]::FromBase64String($t) }
            $ad  = & $dec $a.AuthenticatorData
            $cdj = & $dec $a.ClientDataJSON
            $ad.Length | Should -Be 37 -Because 'authenticatorData = 32B rpIdHash + 1B flags + 4B signCount'
            $signed = $ad + [System.Security.Cryptography.SHA256]::HashData($cdj)
            $verified = $ec.VerifyData($signed, (& $dec $a.Signature), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
            $verified | Should -BeTrue -Because 'the assertion must be a valid ECDSA-P256 signature over authenticatorData||SHA256(clientDataJSON)'
            $j = [System.Text.Encoding]::UTF8.GetString($cdj) | ConvertFrom-Json
            $j.type      | Should -Be 'webauthn.get'
            $j.challenge | Should -Be $challenge
        }
    }

    It 'rejects empty PrivateKeyPem / CredentialId / Challenge (never signs with missing inputs)' {
        InModuleScope Xdr.Defender.Auth {
            { New-XdrPasskeyAssertion -Challenge 'x' -PrivateKeyPem ''    -CredentialId 'y' } | Should -Throw
            { New-XdrPasskeyAssertion -Challenge 'x' -PrivateKeyPem 'pem' -CredentialId ''  } | Should -Throw
            { New-XdrPasskeyAssertion -Challenge ''  -PrivateKeyPem 'pem' -CredentialId 'y' } | Should -Throw
        }
    }

    It 'the Passkey auth branch is WIRED (Complete-XdrPasskeyFlow exists · the throw-stub is gone)' {
        InModuleScope Xdr.Defender.Auth {
            (Get-Command Complete-XdrPasskeyFlow -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
        $src = Get-Content "$script:repo\src\Modules\Xdr.Defender.Auth\Xdr.Defender.Auth.psm1" -Raw
        $src | Should -Not -Match 'Passkey path not yet adopted'
        $src | Should -Match 'Complete-XdrPasskeyFlow'
    }
}
