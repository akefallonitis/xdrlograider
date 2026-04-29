function Get-XdrAuthFromKeyVault {
    <#
    .SYNOPSIS
        L1 portal-generic auth-material loader from Azure Key Vault.

    .DESCRIPTION
        Reads the auth secrets for a given service account from Key Vault and returns
        a hashtable ready to pass as -Credential to a Connect-<Portal>Portal function.

        Secret naming pattern (parameterized via -SecretPrefix):
          <prefix>-upn         (always)
          <prefix>-password    (CredentialsTotp)
          <prefix>-totp        (CredentialsTotp; Base32 secret)
          <prefix>-passkey     (Passkey; JSON bundle)
          <prefix>-sccauth     (DirectCookies; Defender-specific cookie name)
          <prefix>-xsrf        (DirectCookies; Defender-specific cookie name)

        Default `-SecretPrefix = 'mde-portal'` for backward-compatibility with
        v0.1.0-beta deployments. v0.2.0 multi-portal deployments will use distinct
        prefixes per portal (e.g., `purview-portal`, `intune-portal`).

    .PARAMETER VaultUri
        KV URI, e.g., https://myvault.vault.azure.net

    .PARAMETER SecretPrefix
        Prefix for secrets (default 'mde-portal'). Other portal modules will pass
        their own prefix (e.g., 'purview-portal' for Xdr.Purview.Auth in v0.2.0).

    .PARAMETER AuthMethod
        'CredentialsTotp', 'Passkey', or 'DirectCookies'. Snake-case aliases accepted
        (`credentials_totp`, `passkey`, `direct_cookies`) per ARM env-var convention.

    .OUTPUTS
        [hashtable] matching the target Connect-<Portal>Portal function's -Credential
        expectation.

    .NOTES
        DirectCookies returns Defender-specific cookie names (sccauth, xsrf). Other
        portals will need a portal-specific KV loader if they want DirectCookies
        support — but DirectCookies is testing-only and not the production auth path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $VaultUri,
        [string] $SecretPrefix = 'mde-portal',
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'DirectCookies', 'credentials_totp', 'passkey', 'direct_cookies')]
        [string] $AuthMethod
    )

    # Normalize method (ARM env-vars arrive in snake_case)
    $method = switch ($AuthMethod) {
        'credentials_totp' { 'CredentialsTotp' }
        'passkey'          { 'Passkey' }
        'direct_cookies'   { 'DirectCookies' }
        default            { $AuthMethod }
    }

    # Extract vault short name from URI
    $vaultName = ([uri]$VaultUri).Host.Split('.')[0]

    switch ($method) {
        'CredentialsTotp' {
            $upnSecret   = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-upn"      -AsPlainText -ErrorAction Stop
            $pwSecret    = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-password" -AsPlainText -ErrorAction Stop
            $totpSecret  = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-totp"     -AsPlainText -ErrorAction Stop

            return @{
                upn        = $upnSecret
                password   = $pwSecret
                totpBase32 = $totpSecret
            }
        }
        'Passkey' {
            $passkeyJson = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-passkey" -AsPlainText -ErrorAction Stop
            $passkey = $passkeyJson | ConvertFrom-Json -ErrorAction Stop
            return @{
                upn     = $passkey.upn
                passkey = $passkey
            }
        }
        'DirectCookies' {
            $upn     = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-upn"     -AsPlainText -ErrorAction Stop
            $sccauth = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-sccauth" -AsPlainText -ErrorAction Stop
            $xsrf    = Get-AzKeyVaultSecret -VaultName $vaultName -Name "$SecretPrefix-xsrf"    -AsPlainText -ErrorAction Stop
            return @{
                upn       = $upn
                sccauth   = $sccauth
                xsrfToken = $xsrf
            }
        }
    }
}
