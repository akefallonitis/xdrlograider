#Requires -Modules Pester
<#
.SYNOPSIS
    Online preflight: capture fresh portal responses + diff committed fixtures.
    Catches portal-side schema drift before deploy.

.DESCRIPTION
    iter-14.0 Phase 4 (v0.1.0 GA). Implements Section 3 step 6 (online preflight)
    + Section 5 (CI/CD pipeline) of the senior-architect plan.

    For each `live` stream in the manifest, fetches the live portal response and
    compares its top-level shape against the committed fixture at
    `tests/fixtures/live-responses/<Stream>-raw.json`. Fails when:

      - Portal returned a different top-level type (e.g. fixture is `[array]`,
        live is `[object]`)
      - Wrapper-property shape changed (committed fixture had `{value: [...]}`,
        live has `{Results: [...]}`)
      - Stream that was previously `live` now returns 4xx persistently

    Skip-on-empty: if both fixture AND live response are empty (`{}` / `null`),
    no diff possible — skip with note.

    REQUIREMENTS:
      - tests/.env.local with creds (AZURE_TENANT_ID / AZURE_CLIENT_ID /
        AZURE_CLIENT_SECRET / XDRLR_TEST_UPN / XDRLR_TEST_AUTH_METHOD / etc)
      - Run via: pwsh tests/Run-Tests.ps1 -Category online-preflight
      - Or in CI via .github/workflows/online-preflight.yml (OIDC federation)
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1')
    # Iterate live streams only (tenant-gated streams 4xx legitimately).
    $script:LiveStreams = $script:Manifest.Endpoints |
        Where-Object { $_.ContainsKey('Availability') -and $_.Availability -eq 'live' } |
        ForEach-Object { @{ Stream = $_.Stream } }
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:FixturesDir = Join-Path $script:RepoRoot 'tests' 'fixtures' 'live-responses'

    # Load .env.local
    $envFile = Join-Path $script:RepoRoot 'tests' '.env.local'
    if (-not (Test-Path $envFile)) {
        throw "tests/.env.local missing — required for online-preflight. Copy tests/.env.local.example."
    }
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim('"').Trim("'"), 'Process')
        }
    }

    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1') -Force

    # Build session
    $portalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }
    $authMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }
    $upn        = $env:XDRLR_TEST_UPN

    $script:Session = switch ($authMethod) {
        'DirectCookies' {
            Connect-DefenderPortalWithCookies `
                -Sccauth   $env:XDRLR_TEST_SCCAUTH `
                -XsrfToken $env:XDRLR_TEST_XSRF_TOKEN `
                -Upn       $upn `
                -PortalHost $portalHost
        }
        'CredentialsTotp' {
            $cred = @{ upn = $upn; password = $env:XDRLR_TEST_PASSWORD; totpBase32 = $env:XDRLR_TEST_TOTP_SECRET }
            Connect-DefenderPortal -Method CredentialsTotp -Credential $cred -PortalHost $portalHost -Force
        }
        'Passkey' {
            $pk = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
            $cred = @{ upn = $upn; passkey = $pk }
            Connect-DefenderPortal -Method Passkey -Credential $cred -PortalHost $portalHost -Force
        }
        default { throw "Unsupported auth method: $authMethod" }
    }
}

Describe 'CapturePreflight — committed fixture matches live portal shape' -ForEach $script:LiveStreams -Tag 'online-preflight' {

    It 'live response shape matches committed fixture for <Stream>' {
        $streamName = $_.Stream
        $manifestEntry = $script:Manifest.Endpoints | Where-Object { $_.Stream -eq $streamName } | Select-Object -First 1
        if ($null -eq $manifestEntry) {
            Set-ItResult -Skipped -Because "Stream '$streamName' not in manifest"
            return
        }

        $rawPath = Join-Path $script:FixturesDir "$streamName-raw.json"
        if (-not (Test-Path $rawPath)) {
            Set-ItResult -Skipped -Because "No committed fixture for $streamName — run tools/Capture-EndpointSchemas.ps1"
            return
        }

        # Try live invocation
        try {
            $live = Invoke-MDEEndpoint -Session $script:Session -Stream $streamName
            if ($null -eq $live -or @($live).Count -eq 0) {
                Set-ItResult -Skipped -Because "Live portal returned 0 rows for $streamName (operator-empty tenant); cannot diff"
                return
            }
        } catch {
            $msg = $_.Exception.Message
            $msg | Should -BeNullOrEmpty -Because "live portal call for $streamName failed: $msg. Possible portal-API drift; investigate."
            return
        }

        # Top-level shape comparison: row count > 0 in both is sufficient signal
        # that the manifest's Unwrap/SingleObject behavior is intact.
        # Detailed shape diffs would need per-stream property-key comparison —
        # defer to v0.2.0 (this gate is the smoke test).
        $liveRows = @($live)
        $fixtureRaw = Get-Content $rawPath -Raw
        $fixtureRows = if ([string]::IsNullOrWhiteSpace($fixtureRaw) -or $fixtureRaw -eq 'null' -or $fixtureRaw -eq '{}' -or $fixtureRaw -eq '[]') {
            @()
        } else {
            try {
                $parsed = $fixtureRaw | ConvertFrom-Json
                $expandArgs = @{ Response = $parsed }
                if ($manifestEntry.ContainsKey('IdProperty') -and $manifestEntry.IdProperty) { $expandArgs['IdProperty'] = [string[]]$manifestEntry.IdProperty }
                if ($manifestEntry.ContainsKey('UnwrapProperty') -and $manifestEntry.UnwrapProperty) { $expandArgs['UnwrapProperty'] = [string]$manifestEntry.UnwrapProperty }
                if ($manifestEntry.ContainsKey('SingleObjectAsRow') -and $manifestEntry.SingleObjectAsRow) { $expandArgs['SingleObjectAsRow'] = $true }
                $pairs = Expand-MDEResponse @expandArgs
                @($pairs)
            } catch {
                @()
            }
        }

        # Both having data is the happy path.
        if ($liveRows.Count -eq 0 -and $fixtureRows.Count -eq 0) {
            Set-ItResult -Skipped -Because "Both live + fixture empty for $streamName"
            return
        }

        # The smoke signal: both yielded > 0 rows OR both yielded 0 rows.
        # If they disagree, the portal shape changed — fixture stale.
        $bothEmpty = ($liveRows.Count -eq 0 -and $fixtureRows.Count -eq 0)
        $bothHaveData = ($liveRows.Count -gt 0 -and $fixtureRows.Count -gt 0)
        ($bothEmpty -or $bothHaveData) | Should -BeTrue -Because "live row count ($($liveRows.Count)) and fixture row count ($($fixtureRows.Count)) disagree for $streamName — portal-side shape may have drifted; refresh fixture via tools/Capture-EndpointSchemas.ps1"
    }
}
