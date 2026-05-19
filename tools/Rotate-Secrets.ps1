#Requires -Version 7.4
<#
.SYNOPSIS
    Rotates the SA password / TOTP / UPN in the connector's Key Vault.

.DESCRIPTION
    Sets new values for defender-upn / defender-password / defender-totp.
    The FA picks up the new secret on the next Connect-DefenderPortal call
    (cache evicts when the cookie minted with the old secret expires).

.PARAMETER ResourceGroup
.PARAMETER KeyVaultName  (auto-resolves from latest deployment if omitted)
.PARAMETER NewUpn        (optional)
.PARAMETER NewPassword   (SecureString; prompted if omitted and -SetPassword)
.PARAMETER NewTotpSecret (SecureString; prompted if omitted and -SetTotp)

.EXAMPLE
    pwsh ./tools/Rotate-Secrets.ps1 -ResourceGroup rg-xdrlr-test -SetPassword -SetTotp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$KeyVaultName,
    [string]$NewUpn,
    [securestring]$NewPassword,
    [securestring]$NewTotpSecret,
    [switch]$SetPassword,
    [switch]$SetTotp
)

$ErrorActionPreference = 'Stop'
if (-not $KeyVaultName) {
    $KeyVaultName = az keyvault list -g $ResourceGroup --query "[?starts_with(name, 'xdrlr')].name | [0]" -o tsv
    if (-not $KeyVaultName) { throw "No xdrlr* Key Vault in RG $ResourceGroup" }
}
Write-Host "Rotating secrets in KV: $KeyVaultName" -ForegroundColor Cyan

if ($NewUpn) {
    az keyvault secret set --vault-name $KeyVaultName --name 'defender-upn' --value $NewUpn -o none
    Write-Host "  defender-upn updated" -ForegroundColor Green
}
if ($SetPassword) {
    if (-not $NewPassword) { $NewPassword = Read-Host "New password" -AsSecureString }
    $plain = ConvertFrom-SecureString -SecureString $NewPassword -AsPlainText
    az keyvault secret set --vault-name $KeyVaultName --name 'defender-password' --value $plain -o none
    Remove-Variable plain -ErrorAction SilentlyContinue
    Write-Host "  defender-password updated" -ForegroundColor Green
}
if ($SetTotp) {
    if (-not $NewTotpSecret) { $NewTotpSecret = Read-Host "New TOTP base32 seed" -AsSecureString }
    $plain = ConvertFrom-SecureString -SecureString $NewTotpSecret -AsPlainText
    az keyvault secret set --vault-name $KeyVaultName --name 'defender-totp' --value $plain -o none
    Remove-Variable plain -ErrorAction SilentlyContinue
    Write-Host "  defender-totp updated" -ForegroundColor Green
}

Write-Host "`nForce FA to reload secrets on next cycle:" -ForegroundColor Yellow
$fa = az functionapp list -g $ResourceGroup --query "[?starts_with(name, 'xdrlr')].name | [0]" -o tsv
if ($fa) { Write-Host "  az functionapp restart -g $ResourceGroup -n $fa" -ForegroundColor DarkGray }
