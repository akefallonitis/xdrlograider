# Probe-MsalPortalAuth.ps1 — research probe: can we acquire a Bearer token
# programmatically for a Bearer-only portal (intune-autopatch as test case) using
# ROPC (Resource Owner Password Credentials)? ROPC fails on MFA-required users, so
# this probe TELLS US whether the SA can be used for ROPC or whether we need
# MSAL device-code/interactive flow.

#Requires -Version 7.0
[CmdletBinding()] param()

$envFile = "$PSScriptRoot\..\..\xdrlograider\tests\.env.local"
Get-Content $envFile | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object {
    $k,$v = $_ -split '=', 2; Set-Item -Path "env:$k" -Value $v
}

$tenantId = $env:AZURE_TENANT_ID
$upn      = $env:XDRLR_TEST_UPN
$password = $env:XDRLR_TEST_PASSWORD

# Candidate scopes / resources to probe — each is a Bearer-protected API
$scopes = @(
    @{ Name='services.autopatch.microsoft.com';      Resource='https://services.autopatch.microsoft.com' }
    @{ Name='main.iam.ad.ext.azure.com';             Resource='74658136-14ec-4630-ad9b-26e160ff0fc6' }    # ARM-related; common public client
    @{ Name='admin.cloud.microsoft (M365 admin)';    Resource='https://admin.microsoft.com' }
    @{ Name='api.securitycopilot.microsoft.com';     Resource='https://api.securitycopilot.microsoft.com' }
    @{ Name='Microsoft Graph (control)';             Resource='https://graph.microsoft.com' }
)

# Public clients to try (Microsoft well-known)
$clients = @(
    @{ Name='Azure-CLI';        ClientId='04b07795-8ddb-461a-bbee-02f9e1bf7b46' }   # Allowed for ROPC by default
    @{ Name='Microsoft-Graph-PS'; ClientId='14d82eec-204b-4c2f-b7e8-296a70dab67e' }
)

foreach ($cli in $clients) {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "ClientId: $($cli.Name) ($($cli.ClientId))" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    foreach ($s in $scopes) {
        $body = @{
            client_id  = $cli.ClientId
            scope      = "$($s.Resource)/.default offline_access openid profile"
            username   = $upn
            password   = $password
            grant_type = 'password'
        }
        $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        # Use Invoke-WebRequest with -SkipHttpErrorCheck so we can read the 400 body
        $resp = Invoke-WebRequest -Uri $tokenUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -UseBasicParsing -ErrorAction SilentlyContinue
        if ($resp.StatusCode -in 200,201) {
            try {
                $j = $resp.Content | ConvertFrom-Json
                Write-Host "  [$($s.Name)]: ROPC SUCCESS — token_len=$($j.access_token.Length)" -ForegroundColor Green
            } catch { Write-Host "  [$($s.Name)]: 200 but JSON parse failed" -ForegroundColor Yellow }
        } else {
            $body2 = [string]$resp.Content
            if ($body2.Length -gt 350) { $body2 = $body2.Substring(0, 350) + '...' }
            try {
                $j = $resp.Content | ConvertFrom-Json
                $errCode = $j.error
                $errDesc = $j.error_description -replace "\r?\n", ' '
                if ($errDesc.Length -gt 220) { $errDesc = $errDesc.Substring(0, 220) + '...' }
                $verdict = if ($errDesc -match 'AADSTS500011|AADSTS65001') { 'NO-CONSENT' } elseif ($errDesc -match 'AADSTS50079|AADSTS50076|AADSTS50158|AADSTS50076') { 'MFA-REQUIRED' } elseif ($errDesc -match 'AADSTS70011|AADSTS65002|AADSTS900144') { 'INVALID-SCOPE/CLIENT' } elseif ($errDesc -match 'AADSTS50059|AADSTS50034|AADSTS50056|AADSTS50126') { 'BAD-CREDS' } elseif ($errDesc -match 'AADSTS7000218') { 'NEEDS-CLIENT-SECRET' } else { 'OTHER' }
                Write-Host "  [$($s.Name)]: $verdict — $errCode — $errDesc" -ForegroundColor Yellow
            } catch {
                Write-Host "  [$($s.Name)]: HTTP $($resp.StatusCode) — $body2" -ForegroundColor Yellow
            }
        }
    }
}
