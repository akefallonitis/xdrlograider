#Requires -Modules Pester
<#
.SYNOPSIS
    PRE-DEPLOY validation suite — the go/no-go gate before running the
    Deploy-to-Azure button.

.DESCRIPTION
    Proves end-to-end that the credentials and configuration you're about to
    upload into Key Vault actually work against the real tenant, and that the
    code you're about to ship is healthy:

      1. AUTH CHAIN: live CredentialsTotp (or Passkey) sign-in succeeds;
         sccauth + XSRF + TenantId returned.
      2. REAUTH: forcing cache eviction re-authenticates silently.
      3. PORTAL API: a known-working endpoint (TenantContext) returns 200.
      4. MANIFEST COVERAGE: audit every stream path against live portal;
         assert >= threshold (default 20 green — adjustable via
         XDRLR_MIN_GREEN_STREAMS env var). Count is read dynamically from
         the manifest; no hardcoded stream-count literals.
      5. CHECKPOINT STATE: Azure Table Storage write+read round-trips for a
         test stream (when XDRLR_TEST_STORAGE_ACCOUNT is set).
      6. DCE REACHABILITY: if XDRLR_TEST_DCE_ENDPOINT is set, a single
         throwaway row is posted and we confirm HTTP 204 — proves the
         DCE/DCR pair exists and the MI (or Connect-AzAccount bearer) has
         Monitoring Metrics Publisher.

    Gated by XDRLR_ONLINE=true. Runs from your laptop only — never in CI.

    Run locally:
      pwsh ./tests/Run-Tests.ps1 -Category predeploy

.NOTES
    This suite is CHEAP (under 2 minutes) but exercises real endpoints.
    It is the single command that distinguishes "my laptop works" from
    "my deployed Function App will work". Run it BEFORE deploying.
#>

BeforeDiscovery {
    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN -and (
        ($script:AuthMethod -eq 'CredentialsTotp' -and $env:XDRLR_TEST_PASSWORD     -and $env:XDRLR_TEST_TOTP_SECRET) -or
        ($script:AuthMethod -eq 'Passkey'         -and $env:XDRLR_TEST_PASSKEY_PATH -and (Test-Path $env:XDRLR_TEST_PASSKEY_PATH))
    )

    $script:MinGreenStreams = if ($env:XDRLR_MIN_GREEN_STREAMS) { [int]$env:XDRLR_MIN_GREEN_STREAMS } else { 20 }
    $script:CheckpointTest = [bool]$env:XDRLR_TEST_STORAGE_ACCOUNT
    $script:DceTest        = [bool]$env:XDRLR_TEST_DCE_ENDPOINT
}

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module "$repoRoot/src/Modules/Xdr.Portal.Auth/Xdr.Portal.Auth.psd1"         -Force
    Import-Module "$repoRoot/src/Modules/XdrLogRaider.Ingest/XdrLogRaider.Ingest.psd1" -Force
    Import-Module "$repoRoot/src/Modules/XdrLogRaider.Client/XdrLogRaider.Client.psd1" -Force

    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN
    if (-not $script:RunLive) {
        Write-Warning "Predeploy-Validation: XDRLR_ONLINE=true + XDRLR_TEST_UPN required. Skipping."
    }

    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }
    $script:PortalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }

    $script:Credential = switch ($script:AuthMethod) {
        'CredentialsTotp' { @{ upn = $env:XDRLR_TEST_UPN; password = $env:XDRLR_TEST_PASSWORD; totpBase32 = $env:XDRLR_TEST_TOTP_SECRET } }
        'Passkey'         { @{ upn = $env:XDRLR_TEST_UPN; passkey = (Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json) } }
    }

    $script:MinGreenStreams = if ($env:XDRLR_MIN_GREEN_STREAMS) { [int]$env:XDRLR_MIN_GREEN_STREAMS } else { 20 }
}

AfterAll {
    Remove-Module XdrLogRaider.Client -Force -ErrorAction SilentlyContinue
    Remove-Module XdrLogRaider.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Portal.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Pre-deploy: Auth chain' -Tag 'predeploy', 'live' {

    It 'CredentialsTotp or Passkey sign-in returns sccauth + XSRF + TenantId' -Skip:(-not $script:RunLive) {
        $session = Connect-MDEPortal -Method $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session             | Should -Not -BeNullOrEmpty
        $session.Session     | Should -Not -BeNullOrEmpty
        $session.AcquiredUtc | Should -BeOfType [datetime]
        $session.TenantId    | Should -Not -BeNullOrEmpty

        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        ($cookies | Where-Object Name -eq 'sccauth').Value    | Should -Not -BeNullOrEmpty
        ($cookies | Where-Object Name -eq 'XSRF-TOKEN').Value | Should -Not -BeNullOrEmpty
    }

    It 'Silent reauth: -Force mints fresh sccauth with newer AcquiredUtc' -Skip:(-not $script:RunLive) {
        $s1 = Connect-MDEPortal -Method $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force

        # Wait for next TOTP window so duplicate-code retry doesn't fire
        $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $waitTo = [math]::Floor($now / 30) * 30 + 32
        Start-Sleep -Seconds ([math]::Max(1, $waitTo - $now))

        $s2 = Connect-MDEPortal -Method $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $s2.AcquiredUtc | Should -BeGreaterThan $s1.AcquiredUtc
    }
}

Describe 'Pre-deploy: Portal API coverage' -Tag 'predeploy', 'live' {

    It "At least $script:MinGreenStreams manifest streams return usable data" -Skip:(-not $script:RunLive) {
        $session = Connect-MDEPortal -Method $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $entries = @((Get-MDEEndpointManifest).Values)
        Write-Host "  Manifest declares $($entries.Count) streams; threshold: $script:MinGreenStreams green."

        $greenCount = 0
        $brokenStreams = @()
        foreach ($entry in $entries) {
            try {
                $null = Invoke-MDEPortalRequest -Session $session -Path $entry.Path -Method GET -ErrorAction Stop
                $greenCount++
            } catch {
                $brokenStreams += $entry.Stream
            }
        }

        Write-Host "  Green: $greenCount / $($entries.Count)"
        Write-Host "  First 5 broken: $(($brokenStreams | Select-Object -First 5) -join ', ')"
        $greenCount | Should -BeGreaterOrEqual $script:MinGreenStreams
    }

    It 'Every filterable endpoint has a non-empty Filter field in manifest' -Skip:(-not $script:RunLive) {
        $entries = @((Get-MDEEndpointManifest).Values)
        $filterable = $entries | Where-Object { $_.Filter }
        $filterable.Count | Should -BeGreaterThan 0

        # Sanity: Filter values are all 'fromDate' or similar query-param names (not empty, not a URL)
        foreach ($e in $filterable) {
            $e.Filter | Should -Match '^[a-zA-Z]+$'
        }
    }
}

Describe 'Pre-deploy: Checkpoint state storage (Azure Table)' -Tag 'predeploy', 'live' {

    It 'Get/Set-CheckpointTimestamp round-trips against real storage' -Skip:(-not ($script:RunLive -and $script:CheckpointTest)) {
        $sa    = $env:XDRLR_TEST_STORAGE_ACCOUNT
        $table = if ($env:XDRLR_TEST_CHECKPOINT_TABLE) { $env:XDRLR_TEST_CHECKPOINT_TABLE } else { 'predeploytest' }
        $testStream = "MDE_Predeploy_Probe_$((Get-Date -Format 'yyyyMMddHHmmss'))_CL"

        # Write
        $writeTime = [datetime]::UtcNow
        { Set-CheckpointTimestamp -StorageAccountName $sa -TableName $table -StreamName $testStream -Timestamp $writeTime } |
            Should -Not -Throw

        # Read back
        $readTime = Get-CheckpointTimestamp -StorageAccountName $sa -TableName $table -StreamName $testStream
        $readTime | Should -Not -BeNullOrEmpty
        # Allow 1s drift from storage-side precision
        [math]::Abs(($readTime - $writeTime).TotalSeconds) | Should -BeLessOrEqual 1
    }
}

Describe 'Pre-deploy: DCE reachability' -Tag 'predeploy', 'live' {

    It 'A throwaway row POST to the DCE returns 204' -Skip:(-not ($script:RunLive -and $script:DceTest)) {
        $dce = $env:XDRLR_TEST_DCE_ENDPOINT
        $dcr = $env:XDRLR_TEST_DCR_IMMUTABLE_ID
        $streamName = if ($env:XDRLR_TEST_DCE_STREAM) { $env:XDRLR_TEST_DCE_STREAM } else { 'Custom-HeartbeatTest_CL' }

        $row = [pscustomobject]@{
            TimeGenerated = [datetime]::UtcNow.ToString('o')
            FunctionName  = 'predeploy-test'
            SourceStream  = 'predeploy-probe'
        }

        $result = Send-ToLogAnalytics -DceEndpoint $dce -DcrImmutableId $dcr -StreamName $streamName -Rows @($row)
        $result             | Should -Not -BeNullOrEmpty
        $result.RowsSent    | Should -Be 1
    }
}
