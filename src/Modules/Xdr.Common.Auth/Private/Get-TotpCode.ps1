function Get-TotpCode {
    <#
    .SYNOPSIS
        Generates a TOTP code per RFC 6238 from a Base32-encoded secret.

    .DESCRIPTION
        Implements HOTP truncation (RFC 4226) over HMAC-SHA1 with a time-based counter
        (RFC 6238). Standard TOTP parameters: 30-second time step, 6-digit code, T0 = Unix epoch.

        Portal-agnostic: this is a pure crypto primitive. Used by L1 Complete-TotpMfa and
        callable directly by tests with RFC 6238 Appendix B vectors.

    .PARAMETER Base32Secret
        Base32-encoded shared secret, as displayed by Entra/Authenticator enrollment.

    .PARAMETER Timestamp
        Override the current time (defaults to now). Primarily for unit testing.

    .OUTPUTS
        [string] 6-digit TOTP code with leading zeros preserved.

    .EXAMPLE
        Get-TotpCode -Base32Secret 'JBSWY3DPEHPK3PXP'

    .NOTES
        Unit-tested against RFC 6238 Appendix B test vectors.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Base32Secret,

        [datetime] $Timestamp = [datetime]::UtcNow
    )

    # --- Decode Base32 secret to bytes ---
    $s = ($Base32Secret -replace '\s', '').ToUpperInvariant().TrimEnd('=')
    if ($s -notmatch '^[A-Z2-7]+$') {
        throw "Invalid Base32 secret: contains characters outside A-Z/2-7"
    }

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = [System.Text.StringBuilder]::new($s.Length * 5)
    foreach ($ch in $s.ToCharArray()) {
        $val = $alphabet.IndexOf($ch)
        [void] $bits.Append([Convert]::ToString($val, 2).PadLeft(5, '0'))
    }
    $bitString = $bits.ToString()
    $byteCount = [math]::Floor($bitString.Length / 8)
    $keyBytes  = [byte[]]::new($byteCount)
    for ($i = 0; $i -lt $byteCount; $i++) {
        $keyBytes[$i] = [Convert]::ToByte($bitString.Substring($i * 8, 8), 2)
    }

    # --- Time counter: seconds since epoch / 30 ---
    $epoch    = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $seconds  = [int64](($Timestamp.ToUniversalTime() - $epoch).TotalSeconds)
    $counter  = [int64][math]::Floor($seconds / 30)

    # --- 8-byte big-endian counter ---
    $counterBytes = [BitConverter]::GetBytes($counter)
    if ([BitConverter]::IsLittleEndian) {
        [array]::Reverse($counterBytes)
    }

    # --- HMAC-SHA1 ---
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($keyBytes)
    try {
        $hash = $hmac.ComputeHash($counterBytes)
    } finally {
        $hmac.Dispose()
    }

    # --- Dynamic truncation (RFC 4226 §5.3) ---
    $offset = $hash[-1] -band 0x0F
    $binaryCode =
        (([int]$hash[$offset    ] -band 0x7F) -shl 24) -bor `
        (([int]$hash[$offset + 1] -band 0xFF) -shl 16) -bor `
        (([int]$hash[$offset + 2] -band 0xFF) -shl  8) -bor `
         ([int]$hash[$offset + 3] -band 0xFF)

    $code = $binaryCode % 1000000
    return $code.ToString('D6')
}
