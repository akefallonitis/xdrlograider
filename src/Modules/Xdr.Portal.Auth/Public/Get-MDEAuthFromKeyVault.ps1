function Get-MDEAuthFromKeyVault {
    <#
    .SYNOPSIS
        Retrieves MDE portal auth material from Key Vault.

    .DESCRIPTION
        Reads the appropriate secret(s) from Key Vault based on the auth method.
        Returns a hashtable ready to pass as -Credential to Connect-MDEPortal.

        For credentials_totp:  reads mde-portal-upn, mde-portal-password, mde-portal-totp
        For passkey:           reads mde-portal-passkey (JSON bundle)

    .PARAMETER VaultUri
        KV URI, e.g., https://myvault.vault.azure.net

    .PARAMETER SecretName
        Prefix for secrets (default 'mde-portal-auth').

    .PARAMETER AuthMethod
        'CredentialsTotp' or 'Passkey'.

    .OUTPUTS
        [hashtable] matching Connect-MDEPortal's -Credential expectation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $VaultUri,
        [string] $SecretName = 'mde-portal-auth',
        [Parameter(Mandatory)]
        [ValidateSet('CredentialsTotp', 'Passkey', 'DirectCookies', 'credentials_totp', 'passkey', 'direct_cookies')]
        [string] $AuthMethod
    )

    # Normalize method
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
            $upnSecret   = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-upn' -AsPlainText -ErrorAction Stop
            $pwSecret    = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-password' -AsPlainText -ErrorAction Stop
            $totpSecret  = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-totp' -AsPlainText -ErrorAction Stop

            return @{
                upn        = $upnSecret
                password   = $pwSecret
                totpBase32 = $totpSecret
            }
        }
        'Passkey' {
            $passkeyJson = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-passkey' -AsPlainText -ErrorAction Stop
            $passkey = $passkeyJson | ConvertFrom-Json -ErrorAction Stop
            return @{
                upn     = $passkey.upn
                passkey = $passkey
            }
        }
        'DirectCookies' {
            $upn     = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-upn'     -AsPlainText -ErrorAction Stop
            $sccauth = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-sccauth' -AsPlainText -ErrorAction Stop
            $xsrf    = Get-AzKeyVaultSecret -VaultName $vaultName -Name 'mde-portal-xsrf'    -AsPlainText -ErrorAction Stop
            return @{
                upn       = $upn
                sccauth   = $sccauth
                xsrfToken = $xsrf
            }
        }
    }
}
