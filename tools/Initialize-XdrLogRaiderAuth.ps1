#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive setup helper: uploads Defender XDR portal auth material to Azure Key Vault
    so the XdrLogRaider Function App can use it.

.DESCRIPTION
    Upload-only. Prompts for the auth method and the required secrets, validates format,
    and writes them to Key Vault. Does NOT call security.microsoft.com or any Graph API —
    the Function App's first poll-* timer (after KV secrets land) is the source of truth
    for "does auth work" via App Insights AuthChain.* customEvents.

    Supported methods:
      - credentials_totp: prompts for UPN, password, TOTP Base32 secret
      - passkey:          prompts for passkey JSON path

    After this script completes, wait ~5-10 minutes then query App Insights:
        customEvents | where name in ('AuthChain.AADSTSError', 'AuthChain.Completed') | order by timestamp desc | take 5
    or check workspace heartbeat:
        MDE_Heartbeat_CL | where StreamsSucceeded > 0 | order by TimeGenerated desc | take 1

.PARAMETER KeyVaultName
    Name of the Key Vault. Output of the deploy wizard includes this.

.PARAMETER Method
    Skip interactive prompt — one of 'credentials_totp' or 'passkey'.

.PARAMETER PasskeyJsonPath
    For -Method passkey only. Path to the passkey JSON file.

.PARAMETER DryRun
    Validate inputs but don't write to Key Vault.

.EXAMPLE
    ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName xdrlr-prod-kv-ab12

.EXAMPLE
    ./tools/Initialize-XdrLogRaiderAuth.ps1 -KeyVaultName xdrlr-prod-kv-ab12 -Method passkey -PasskeyJsonPath ./my-passkey.json

.NOTES
    Requires: Az.Accounts, Az.KeyVault. Install with:
        Install-Module Az.Accounts -Force -Scope CurrentUser
        Install-Module Az.KeyVault -Force -Scope CurrentUser

    Before running this script, gather the auth material per method:
        docs/GETTING-AUTH-MATERIAL.md — step-by-step for TOTP Base32 / Passkey / DirectCookies

.LINK
    docs/GETTING-AUTH-MATERIAL.md

.LINK
    docs/AUTH.md

.LINK
    docs/DEPLOYMENT.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $KeyVaultName,

    [ValidateSet('credentials_totp', 'passkey', 'direct_cookies')]
    [string] $Method,

    [string] $PasskeyJsonPath,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Banner ---

$line = '═' * 67
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   XdrLogRaider — Auth Setup" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

# --- 1. Verify Az modules + session ---

Write-Host "  [1/5] Azure prerequisites" -ForegroundColor Yellow

$required = @('Az.Accounts', 'Az.KeyVault')
foreach ($module in $required) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        throw "Required module '$module' not installed. Run: Install-Module $module -Force -Scope CurrentUser"
    }
    Import-Module $module -Force -ErrorAction Stop
}

try {
    $azContext = Get-AzContext -ErrorAction Stop
    if (-not $azContext) { throw "No Azure context" }
} catch {
    Write-Host "        You're not signed into Azure. Running Connect-AzAccount..." -ForegroundColor Gray
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $azContext = Get-AzContext
}

Write-Host "        Subscription: $($azContext.Subscription.Name) ($($azContext.Subscription.Id))"
Write-Host "        Account:      $($azContext.Account.Id)"

# --- 2. Verify Key Vault access ---

Write-Host ""
Write-Host "  [2/5] Key Vault access" -ForegroundColor Yellow

try {
    $kv = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction Stop
    Write-Host "        Vault:        $($kv.VaultName)"
    Write-Host "        URI:          $($kv.VaultUri)"
} catch {
    throw "Cannot access Key Vault '$KeyVaultName'. Verify: (1) the name is correct, (2) you have Key Vault Secrets Officer or equivalent RBAC role, (3) you're in the right subscription."
}

# --- 3. Choose auth method ---

Write-Host ""
Write-Host "  [3/5] Auth method" -ForegroundColor Yellow

if (-not $Method) {
    Write-Host "        [1] Credentials + TOTP  (auto-refresh, simpler)"
    Write-Host "        [2] Software Passkey    (auto-refresh, phishing-resistant, stronger CA)"
    Write-Host "        [3] Direct Cookies      (testing only — no auto-refresh, 1h lifetime)"
    do {
        $choice = Read-Host -Prompt '        Choice (1/2/3)'
    } while ($choice -notin @('1', '2', '3'))
    $Method = switch ($choice) {
        '1' { 'credentials_totp' }
        '2' { 'passkey' }
        '3' { 'direct_cookies' }
    }
}

Write-Host "        Selected:     $Method"

# --- 4. Collect + validate secrets ---

Write-Host ""
Write-Host "  [4/5] Credentials" -ForegroundColor Yellow

$secretsToUpload = @{}
$secretsToUpload['mde-portal-auth-method'] = $Method

switch ($Method) {
    'credentials_totp' {
        $upn = Read-Host -Prompt '        Service account UPN'
        if ($upn -notmatch '^[^@]+@[^@]+\.[^@]+$') {
            throw "Invalid UPN format: $upn"
        }

        $password = Read-Host -Prompt '        Password' -AsSecureString
        $plainPassword = [System.Net.NetworkCredential]::new('', $password).Password
        if ($plainPassword.Length -eq 0) {
            throw "Password cannot be empty"
        }

        Write-Host ""
        Write-Host "        TOTP Base32 secret (leave blank if tenant doesn't require MFA for this account):"
        $totp = Read-Host -Prompt '        TOTP Base32 secret' -AsSecureString
        $plainTotp = [System.Net.NetworkCredential]::new('', $totp).Password

        $normalizedTotp = ''
        if ($plainTotp -and $plainTotp.Length -gt 0) {
            $normalizedTotp = ($plainTotp -replace '\s', '').ToUpperInvariant().TrimEnd('=')
            if ($normalizedTotp -notmatch '^[A-Z2-7]+$') {
                throw "TOTP secret must be Base32 (A-Z, 2-7). Got invalid characters."
            }
            if ($normalizedTotp.Length -lt 16) {
                throw "TOTP secret too short ($($normalizedTotp.Length) chars). Expected >=16 Base32 characters."
            }
        }

        $secretsToUpload['mde-portal-upn']      = $upn
        $secretsToUpload['mde-portal-password'] = $plainPassword
        if ($normalizedTotp) {
            $secretsToUpload['mde-portal-totp'] = $normalizedTotp
            Write-Host "        Validation:   UPN OK, password OK, TOTP Base32 OK ($($normalizedTotp.Length) chars)"
        } else {
            Write-Host "        Validation:   UPN OK, password OK, no TOTP (MFA not required)" -ForegroundColor Yellow
            Write-Host "        Warning:      If Entra enforces MFA for this account, auth will fail." -ForegroundColor Yellow
        }
    }
    'passkey' {
        if (-not $PasskeyJsonPath) {
            $PasskeyJsonPath = Read-Host -Prompt '        Passkey JSON path'
        }
        if (-not (Test-Path $PasskeyJsonPath)) {
            throw "Passkey JSON file not found: $PasskeyJsonPath"
        }

        $passkeyJson = Get-Content $PasskeyJsonPath -Raw
        try {
            $passkey = $passkeyJson | ConvertFrom-Json
        } catch {
            throw "File is not valid JSON: $PasskeyJsonPath — $_"
        }

        foreach ($field in 'upn', 'credentialId', 'privateKeyPem') {
            if (-not $passkey.$field) {
                throw "Passkey JSON missing required field: $field"
            }
        }
        if ($passkey.privateKeyPem -notmatch '-----BEGIN EC PRIVATE KEY-----') {
            throw "privateKeyPem doesn't look like an EC PEM. Ensure it's an unencrypted ECDSA key."
        }

        $secretsToUpload['mde-portal-passkey'] = $passkeyJson

        Write-Host "        Validation:   schema OK"
        Write-Host "        UPN:          $($passkey.upn)"
        Write-Host "        Credential:   $($passkey.credentialId.Substring(0, [math]::Min(16, $passkey.credentialId.Length)))..."
    }
    'direct_cookies' {
        Write-Host ""
        Write-Host "        DirectCookies is a TEST-ONLY mode — no auto-refresh." -ForegroundColor Yellow
        Write-Host "        sccauth expires in ~1h. Use CredentialsTotp or Passkey for production." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "        How to capture (Chrome/Edge):"
        Write-Host "        1. Sign into https://security.microsoft.com"
        Write-Host "        2. Press F12 → Application tab → Cookies → https://security.microsoft.com"
        Write-Host "        3. Copy the Value column for 'sccauth' and 'XSRF-TOKEN' rows"
        Write-Host ""

        $upn = Read-Host -Prompt '        Service account UPN (for logs only)'

        $sccauth = Read-Host -Prompt '        Paste sccauth value' -AsSecureString
        $plainSccauth = [System.Net.NetworkCredential]::new('', $sccauth).Password
        if ($plainSccauth.Length -lt 20) {
            throw "sccauth looks too short ($($plainSccauth.Length) chars). Expected base64-ish token ~500+ chars."
        }

        $xsrf = Read-Host -Prompt '        Paste XSRF-TOKEN value' -AsSecureString
        $plainXsrf = [System.Net.NetworkCredential]::new('', $xsrf).Password
        if ($plainXsrf.Length -lt 16) {
            throw "XSRF-TOKEN looks too short ($($plainXsrf.Length) chars)."
        }

        $secretsToUpload['mde-portal-upn']     = $upn
        $secretsToUpload['mde-portal-sccauth'] = $plainSccauth
        $secretsToUpload['mde-portal-xsrf']    = $plainXsrf

        Write-Host "        Validation:   UPN OK, sccauth length OK ($($plainSccauth.Length) chars), XSRF length OK ($($plainXsrf.Length) chars)"
    }
}

# --- 5. Upload to Key Vault ---

Write-Host ""
Write-Host "  [5/5] Upload to Key Vault" -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "        DRY RUN — skipping upload. Would upload:" -ForegroundColor Magenta
    foreach ($name in $secretsToUpload.Keys) {
        Write-Host "          - $name" -ForegroundColor Magenta
    }
} else {
    foreach ($name in $secretsToUpload.Keys) {
        $value = $secretsToUpload[$name]
        # Required: Set-AzKeyVaultSecret needs [SecureString]; we came from
        # interactive Read-Host (already secure) or from a file the user provided.
        # The plaintext exists only on the stack inside this loop; zeroed on GC.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Required for KV upload; value is user-provided and only in-scope for one iteration.')]
        $secureValue = ConvertTo-SecureString $value -AsPlainText -Force
        try {
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -SecretValue $secureValue -ErrorAction Stop | Out-Null
            Write-Host "        Uploaded:     $name" -ForegroundColor Green
        } catch {
            throw "Failed to upload secret '$name' — $_"
        }
        Remove-Variable -Name value, secureValue -ErrorAction SilentlyContinue
    }
}

# --- Success ---

Write-Host ""
Write-Host "  ✓ Done." -ForegroundColor Green
Write-Host ""
Write-Host "  Within 5-10 minutes the Function App's heartbeat timer + first poll fire." -ForegroundColor Gray
Write-Host "  The Sentinel **Data Connectors** blade flips the **XdrLogRaider** card to" -ForegroundColor Gray
Write-Host "  **Connected** when MDE_Heartbeat_CL has a row with StreamsSucceeded > 0." -ForegroundColor Gray
Write-Host ""
Write-Host "  If the card stays Disconnected past 15 min, see docs/TROUBLESHOOTING.md." -ForegroundColor Gray
Write-Host ""
