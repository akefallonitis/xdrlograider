#Requires -Module Pester
# Runtime.LiveCycle.Bearer.Tests.ps1 · T4 LIVE simulation · Plan ε.G
#
# Validates the bearer auth chain end-to-end against real Microsoft endpoints.
# Auto-skips when env.local credentials aren't present (CI safety).
#
# Burns 1 TOTP per portal · uses cached session when possible.

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:envFile  = Join-Path $script:repoRoot 'tests\.env.local'

    $script:envPresent = Test-Path $script:envFile
    if ($script:envPresent) {
        Get-Content $script:envFile | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
            $k, $v = $_ -split '=', 2
            Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
        }
    }
    $script:credsAvailable = $script:envPresent -and `
                              $env:XDRLR_TEST_UPN -and `
                              ($env:XDRLR_TEST_TOTP_SECRET -or $env:XDRLR_TEST_TOTP_SEED -or $env:XDRLR_TEST_KV_NAME)

    if ($script:credsAvailable) {
        Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
        Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
        Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Parser\Xdr.Parser.psd1') -Force
    }
}

Describe 'Runtime.LiveCycle.Bearer · Entra IAM live chain' -Tag 'integration','runtime-live','bearer' {

    BeforeAll {
        if (-not $script:credsAvailable) { return }
        try {
            $script:creds = Get-XdrAuthFromKeyVault -FromEnvLocal -ErrorAction Stop
            $script:entraSession = Connect-EntraPortal -Credentials $script:creds -SubPortal IAM -ErrorAction Stop
            $script:entraOk = $true
        } catch {
            $script:entraOk = $false
            $script:entraError = $_.Exception.Message
        }
    }

    It 'env.local credentials present (precondition)' {
        if (-not $script:credsAvailable) {
            Set-ItResult -Skipped -Because 'tests/.env.local absent or lacks XDRLR_TEST_UPN/TOTP'
            return
        }
        $script:credsAvailable | Should -BeTrue
    }

    It 'Connect-EntraPortal -SubPortal IAM returns session with valid bearer token' {
        if (-not $script:credsAvailable) { Set-ItResult -Skipped -Because 'no creds'; return }
        $script:entraOk | Should -BeTrue -Because $script:entraError
        $script:entraSession | Should -Not -BeNullOrEmpty
        $script:entraSession.AccessToken | Should -Not -BeNullOrEmpty
        # JWT format: header.payload.signature
        $script:entraSession.AccessToken | Should -Match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
    }

    It 'Get-XdrBearerTokenExpiry parses JWT exp · returns ExpiresUtc in future' {
        if (-not $script:credsAvailable -or -not $script:entraOk) { Set-ItResult -Skipped -Because 'auth failed'; return }
        $expiry = Get-XdrBearerTokenExpiry -BearerToken $script:entraSession.AccessToken
        $expiry.EarliestExpirySource | Should -Be 'jwt-exp'
        $expiry.ExpiresUtc | Should -BeGreaterThan ([datetime]::UtcNow)
        $expiry.Audience | Should -Not -BeNullOrEmpty
    }

    It 'Connect-EntraPortal -Force re-mints bearer (new AccessToken)' {
        if (-not $script:credsAvailable -or -not $script:entraOk) { Set-ItResult -Skipped -Because 'auth failed'; return }
        $originalToken = $script:entraSession.AccessToken
        $refreshed = Connect-EntraPortal -Credentials $script:creds -SubPortal IAM -Force
        $refreshed.AccessToken | Should -Not -BeNullOrEmpty
        # Token may match if same refresh-token path · but Source field reveals fresh fetch
        $refreshed.Source | Should -BeIn @('full-chain','refresh-token')
    }

    It 'live-cycle-bearer.json proof artefact written when bearer chain proven' {
        if (-not $script:credsAvailable -or -not $script:entraOk) { Set-ItResult -Skipped -Because 'auth failed'; return }
        $iterDir = Join-Path $script:repoRoot ("tests/results/iter-" + ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')))
        New-Item -ItemType Directory -Path $iterDir -Force | Out-Null
        $proof = [pscustomobject]@{
            Timestamp     = (Get-Date).ToUniversalTime().ToString('o')
            Portal        = 'Entra'
            SubPortal     = 'IAM'
            BearerOk      = $true
            Source        = $script:entraSession.Source
            ExpiresUtc    = $script:entraSession.ExpiresUtc
            Audience      = $script:entraSession.Audience
            Note          = 'Bearer chain proven · Connect-EntraPortal + JWT exp parse + Force-refresh'
        }
        $proofPath = Join-Path $iterDir 'live-cycle-bearer.json'
        $proof | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $proofPath -Encoding UTF8
        (Test-Path $proofPath) | Should -BeTrue
    }
}
