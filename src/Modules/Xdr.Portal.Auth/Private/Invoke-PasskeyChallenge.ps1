function Invoke-PasskeyChallenge {
    <#
    .SYNOPSIS
        Signs a WebAuthn assertion challenge using a software passkey (ECDSA-P256).

    .DESCRIPTION
        Implements the client side of WebAuthn Level 2 §7.2 "Verifying an Authentication Assertion".
        Takes an Entra-issued challenge + the user's software passkey (PEM-encoded private key
        and base64url credential ID) and returns a signed assertion ready to submit back to
        login.microsoftonline.com.

        Flow:
          1. Build clientDataJSON from challenge + origin + type
          2. Compute rpIdHash = SHA-256(rpId)
          3. Build authData = rpIdHash || flags || signCount || (optional attested credential)
          4. Sign (authData || SHA-256(clientDataJSON)) with ECDSA-P256
          5. Return signedAssertion components

    .PARAMETER PasskeyJson
        Object parsed from the user's passkey JSON file. Required fields:
          - credentialId  (base64url string)
          - privateKeyPem (PEM-encoded ECDSA-P256 private key)
          - upn           (service account UPN, cosmetic)
          - rpId          (relying party ID, e.g., 'login.microsoft.com')

    .PARAMETER Challenge
        Base64url-encoded challenge bytes from the server.

    .PARAMETER Origin
        Origin to embed in clientDataJSON (e.g., 'https://login.microsoft.com').

    .OUTPUTS
        [hashtable] with:
          - credentialId      (base64url)
          - clientDataJSON    (base64url)
          - authenticatorData (base64url)
          - signature         (base64url)

    .EXAMPLE
        $passkey = Get-Content ./my-passkey.json -Raw | ConvertFrom-Json
        Invoke-PasskeyChallenge -PasskeyJson $passkey -Challenge 'abc...' -Origin 'https://login.microsoft.com'

    .NOTES
        Unit-tested against W3C WebAuthn §7.2 example vectors.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $PasskeyJson,
        [Parameter(Mandatory)] [string] $Challenge,
        [Parameter(Mandatory)] [string] $Origin
    )

    # --- 1. Build clientDataJSON ---
    # WebAuthn spec requires exactly these fields in this order.
    $clientData = [ordered]@{
        type      = 'webauthn.get'
        challenge = $Challenge       # base64url, passed through
        origin    = $Origin
    }
    $clientDataBytes = [System.Text.Encoding]::UTF8.GetBytes(($clientData | ConvertTo-Json -Compress))

    # --- 2. Compute rpIdHash ---
    $rpId = if ($PasskeyJson.rpId) { $PasskeyJson.rpId } else { 'login.microsoft.com' }
    $rpIdHash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($rpId))

    # --- 3. Build authData ---
    # Flags: UP=1 (user present), UV=1 (user verified) = 0x05
    # SignCount: 0 (software authenticator doesn't track)
    $flags = [byte]0x05
    $signCountBytes = [byte[]]@(0, 0, 0, 0)
    $authData = [byte[]]::new(37)
    [array]::Copy($rpIdHash, 0, $authData, 0, 32)
    $authData[32] = $flags
    [array]::Copy($signCountBytes, 0, $authData, 33, 4)

    # --- 4. Compute signature base = authData || SHA-256(clientDataJSON) ---
    $clientDataHash = [System.Security.Cryptography.SHA256]::HashData($clientDataBytes)
    $toSign = [byte[]]::new($authData.Length + $clientDataHash.Length)
    [array]::Copy($authData, 0, $toSign, 0, $authData.Length)
    [array]::Copy($clientDataHash, 0, $toSign, $authData.Length, $clientDataHash.Length)

    # --- 5. Sign with ECDSA-P256 private key ---
    $ecdsa = [System.Security.Cryptography.ECDsa]::Create()
    try {
        $ecdsa.ImportFromPem($PasskeyJson.privateKeyPem)
        # DER-encoded signature (WebAuthn requires DER, not IEEE P1363)
        $sig = $ecdsa.SignData($toSign, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } finally {
        $ecdsa.Dispose()
    }

    return @{
        credentialId      = $PasskeyJson.credentialId
        clientDataJSON    = ConvertTo-Base64Url -Bytes $clientDataBytes
        authenticatorData = ConvertTo-Base64Url -Bytes $authData
        signature         = ConvertTo-Base64Url -Bytes $sig
    }
}

function ConvertTo-Base64Url {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [byte[]] $Bytes
    )
    process {
        return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

function ConvertFrom-Base64Url {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Text
    )
    process {
        $padded = $Text.Replace('-', '+').Replace('_', '/')
        $mod = $padded.Length % 4
        if ($mod) { $padded = $padded + ('=' * (4 - $mod)) }
        return [Convert]::FromBase64String($padded)
    }
}
