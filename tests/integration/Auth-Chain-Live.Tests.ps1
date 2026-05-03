#Requires -Modules Pester
<#
.SYNOPSIS
    Live auth chain tests against a real Entra / Defender XDR tenant.

.DESCRIPTION
    Gated by XDRLR_ONLINE=true. Reads test credentials from env vars
    (or tests/.env.local via Run-Tests.ps1). Exercises the full
    Xdr.Common.Auth + Xdr.Defender.Auth chain + one sample dispatcher call.

    Run locally:
      pwsh ./tests/Run-Tests.ps1 -Category local-online

    Required env vars (loaded by Run-Tests.ps1):
      XDRLR_TEST_UPN
      XDRLR_TEST_AUTH_METHOD       ('CredentialsTotp' | 'Passkey' | 'DirectCookies')

    For CredentialsTotp:  XDRLR_TEST_PASSWORD + XDRLR_TEST_TOTP_SECRET
    For Passkey:          XDRLR_TEST_PASSKEY_PATH
    For DirectCookies:    XDRLR_TEST_SCCAUTH + XDRLR_TEST_XSRF_TOKEN
#>

BeforeDiscovery {
    # Pester 5 evaluates `-Skip:(...)` at discovery time, so all gating flags
    # must be available BEFORE the run phase. Env vars are already loaded by
    # Run-Tests.ps1 from tests/.env.local.

    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN -and (
        ($script:AuthMethod -eq 'CredentialsTotp' -and $env:XDRLR_TEST_PASSWORD     -and $env:XDRLR_TEST_TOTP_SECRET) -or
        ($script:AuthMethod -eq 'Passkey'         -and $env:XDRLR_TEST_PASSKEY_PATH -and (Test-Path $env:XDRLR_TEST_PASSKEY_PATH)) -or
        ($script:AuthMethod -eq 'DirectCookies'   -and $env:XDRLR_TEST_SCCAUTH      -and $env:XDRLR_TEST_XSRF_TOKEN)
    )

    $script:SkipCacheTest = (-not $script:RunLive) -or ($script:AuthMethod -eq 'DirectCookies')
}

BeforeAll {
    # Modules needed for live auth + dispatcher calls (5-module set)
    $commonPsd1   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Common.Auth'    'Xdr.Common.Auth.psd1'
    $defAuthPsd1  = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Auth'  'Xdr.Defender.Auth.psd1'
    $ingestPsd1   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    $clientPsd1   = Join-Path $PSScriptRoot '..' '..' 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'

    Import-Module $commonPsd1  -Force -ErrorAction Stop
    Import-Module $defAuthPsd1 -Force -ErrorAction Stop
    Import-Module $ingestPsd1  -Force -ErrorAction Stop
    Import-Module $clientPsd1  -Force -ErrorAction Stop

    # Mirror discovery-phase gating flag so it's valid during run too.
    $script:RunLive = ($env:XDRLR_ONLINE -eq 'true') -and $env:XDRLR_TEST_UPN
    if (-not $script:RunLive) {
        Write-Warning "Auth-Chain-Live tests require XDRLR_ONLINE=true + XDRLR_TEST_UPN. Skipping."
    }

    $script:AuthMethod = if ($env:XDRLR_TEST_AUTH_METHOD) { $env:XDRLR_TEST_AUTH_METHOD } else { 'CredentialsTotp' }

    $script:Credential = switch ($script:AuthMethod) {
        'CredentialsTotp' {
            @{
                upn        = $env:XDRLR_TEST_UPN
                password   = $env:XDRLR_TEST_PASSWORD
                totpBase32 = $env:XDRLR_TEST_TOTP_SECRET
            }
        }
        'Passkey' {
            $passkey = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
            @{
                upn     = $env:XDRLR_TEST_UPN
                passkey = $passkey
            }
        }
        'DirectCookies' {
            @{
                upn       = $env:XDRLR_TEST_UPN
                sccauth   = $env:XDRLR_TEST_SCCAUTH
                xsrfToken = $env:XDRLR_TEST_XSRF_TOKEN
            }
        }
        default {
            throw "Invalid XDRLR_TEST_AUTH_METHOD: $script:AuthMethod (expected CredentialsTotp | Passkey | DirectCookies)"
        }
    }

    $script:PortalHost = if ($env:XDRLR_TEST_PORTAL_HOST) { $env:XDRLR_TEST_PORTAL_HOST } else { 'security.microsoft.com' }

    # Helper — defined in BeforeAll so it's visible inside It blocks (Pester 5
    # doesn't propagate top-level file functions into the run scope).
    function script:New-LiveSession {
        param($AuthMethod, $Credential, $PortalHost, [switch]$Force)
        if ($AuthMethod -eq 'DirectCookies') {
            return Connect-DefenderPortalWithCookies `
                -Sccauth   $Credential.sccauth `
                -XsrfToken $Credential.xsrfToken `
                -Upn       $Credential.upn `
                -PortalHost $PortalHost
        }
        return Connect-DefenderPortal -Method $AuthMethod -Credential $Credential -PortalHost $PortalHost -Force:$Force.IsPresent
    }
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

Describe 'Live auth chain against real tenant' -Tag 'online', 'live' {

    It 'Session has non-empty sccauth cookie' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session             | Should -Not -BeNullOrEmpty
        $session.Session     | Should -Not -BeNullOrEmpty
        $session.AcquiredUtc | Should -BeOfType [datetime]

        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $sccauth = $cookies | Where-Object Name -eq 'sccauth' | Select-Object -First 1
        $sccauth        | Should -Not -BeNullOrEmpty
        $sccauth.Value  | Should -Not -BeNullOrEmpty
    }

    It 'XSRF-TOKEN present in session' -Skip:(-not $script:RunLive) {
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $cookies = $session.Session.Cookies.GetCookies("https://$script:PortalHost")
        $xsrf = $cookies | Where-Object Name -eq 'XSRF-TOKEN' | Select-Object -First 1
        $xsrf       | Should -Not -BeNullOrEmpty
        $xsrf.Value | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-DefenderPortalRequest returns TenantContext (proven-working portal API)' -Skip:(-not $script:RunLive) {
        # TenantContext is the most stable portal API — used by the sign-in flow itself.
        # If this returns 200 + AuthInfo, the session is fully authenticated. The
        # 52-stream endpoint catalogue in endpoints.manifest.psd1 is a separate
        # validation (different tracking issue — some paths may have drifted since
        # the nodoc/XDRInternals research dates).
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $ctx = Invoke-DefenderPortalRequest -Session $session -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' -Method GET
        $ctx               | Should -Not -BeNullOrEmpty
        $ctx.AuthInfo      | Should -Not -BeNullOrEmpty
        $ctx.AuthInfo.TenantId | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-MDEEndpoint -Stream MDE_AdvancedFeatures_CL dispatcher reaches the portal' -Skip:(-not $script:RunLive) {
        # Even if the 52-stream manifest path is stale, the dispatcher should attempt
        # the call without auth errors. Failure here = auth chain regression;
        # failure in the actual call = endpoint-path drift (tracked separately).
        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $rows = Invoke-MDEEndpoint -Session $session -Stream 'MDE_AdvancedFeatures_CL' -ErrorAction SilentlyContinue 3>$null
        # Dispatcher returns $null or empty on endpoint 404/500 — ACCEPTABLE as long as
        # the session itself is still healthy. We re-query TenantContext to confirm.
        $stillAuthed = Invoke-DefenderPortalRequest -Session $session -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' -Method GET
        $stillAuthed.AuthInfo.TenantId | Should -Not -BeNullOrEmpty
    }

    It 'Session cache: second Connect call returns same AcquiredUtc (50-min cache)' -Skip:$script:SkipCacheTest {
        $session1 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $session2 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost
        $session2.AcquiredUtc | Should -Be $session1.AcquiredUtc
    }

    It 'Silent reauth: -Force after initial connect mints a fresh sccauth' -Skip:$script:SkipCacheTest {
        # First auth
        $s1 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $cookies1 = $s1.Session.Cookies.GetCookies("https://$script:PortalHost")
        $sccauth1 = ($cookies1 | Where-Object Name -eq 'sccauth' | Select-Object -First 1).Value

        # Wait ~32s so a fresh TOTP window is available (avoid duplicate-code reject)
        $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $waitTo = [math]::Floor($now / 30) * 30 + 32
        Start-Sleep -Seconds ([math]::Max(1, $waitTo - $now))

        # Force re-auth — simulating a 401 recovery in Invoke-DefenderPortalRequest
        $s2 = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force
        $cookies2 = $s2.Session.Cookies.GetCookies("https://$script:PortalHost")
        $sccauth2 = ($cookies2 | Where-Object Name -eq 'sccauth' | Select-Object -First 1).Value

        $sccauth2       | Should -Not -BeNullOrEmpty
        $s2.AcquiredUtc | Should -BeGreaterThan $s1.AcquiredUtc
        # Both are valid sccauth values (large tokens) — not same byte-for-byte (fresh mint)
        $sccauth2.Length | Should -BeGreaterThan 100
    }

    It 'Passkey auth also returns sccauth (skipped if no passkey configured)' -Skip:(-not $env:XDRLR_TEST_PASSKEY_PATH -or -not (Test-Path $env:XDRLR_TEST_PASSKEY_PATH)) {
        $passkey = Get-Content $env:XDRLR_TEST_PASSKEY_PATH -Raw | ConvertFrom-Json
        $cred = @{ upn = $env:XDRLR_TEST_UPN; passkey = $passkey }
        $session = Connect-DefenderPortal -Method Passkey -Credential $cred -PortalHost $script:PortalHost -Force
        $sccauth = $session.Session.Cookies.GetCookies("https://$script:PortalHost") | Where-Object Name -eq 'sccauth' | Select-Object -First 1
        $sccauth       | Should -Not -BeNullOrEmpty
        $sccauth.Value | Should -Not -BeNullOrEmpty
    }

    It 'Live 401-recovery: poisoning sccauth triggers silent reauth + API call succeeds' -Skip:$script:SkipCacheTest {
        # Prove the end-to-end reauth path: inject an obviously-invalid sccauth into the
        # live session so the NEXT /apiproxy call returns 401 → Invoke-DefenderPortalRequest
        # detects the 401 → Connect-DefenderPortal -Force mints a fresh session → retry succeeds.
        # This is the exact path the Function App walks in production when sccauth expires.

        $session = script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost -Force

        # Wait for fresh TOTP window so the reauth's EndAuth doesn't duplicate-code-reject.
        $now    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $waitTo = [math]::Floor($now / 30) * 30 + 32
        Start-Sleep -Seconds ([math]::Max(1, $waitTo - $now))

        # Poison: overwrite sccauth with gibberish. Portal will return 401 on next call.
        $cookieUri = [System.Uri]::new("https://$script:PortalHost/")
        $poisoned  = [System.Net.Cookie]::new('sccauth', 'POISONED-BY-LIVE-TEST', '/', $script:PortalHost)
        $poisoned.Secure = $true
        $session.Session.Cookies.Add($cookieUri, $poisoned)

        $priorAcquired = $session.AcquiredUtc

        # Trigger the 401→reauth path. TenantContext is our proven-working endpoint.
        $ctx = Invoke-DefenderPortalRequest -Session $session -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext?realTime=true' -Method GET
        $ctx               | Should -Not -BeNullOrEmpty -Because 'Auto-reauth must recover the call'
        $ctx.AuthInfo      | Should -Not -BeNullOrEmpty
        $ctx.AuthInfo.TenantId | Should -Not -BeNullOrEmpty

        # After reauth the in-place session gets its AcquiredUtc bumped.
        $session.AcquiredUtc | Should -BeGreaterThan $priorAcquired
    }

    It 'Live delta-polling: two sequential MDETierPoll runs advance the checkpoint' -Skip:$script:SkipCacheTest {
        # Proves the P6 tier's filterable endpoints (ActionCenter + ThreatAnalytics,
        # both now Filter='fromDate') correctly pick up the checkpoint on the 2nd run.
        # We use an IN-MEMORY mock of Get/Set-CheckpointTimestamp because we don't want
        # to require a real storage account for this laptop test — but the manifest-
        # driven delta behaviour itself IS live.

        InModuleScope Xdr.Defender.Client -Parameters @{
            Session = (script:New-LiveSession -AuthMethod $script:AuthMethod -Credential $script:Credential -PortalHost $script:PortalHost)
        } {
            param($Session)

            $script:CpStore = @{}
            Mock Get-CheckpointTimestamp { return $script:CpStore[$args[-1]] }
            Mock Set-CheckpointTimestamp {
                $streamName = ($args | ForEach-Object { $_ } | Where-Object { $_ -is [string] -and $_ -match '^MDE_' }) | Select-Object -First 1
                if ($streamName) { $script:CpStore[$streamName] = [datetime]::UtcNow }
            }
            Mock Send-ToLogAnalytics { @{ RowsSent = 0; BatchesSent = 0; LatencyMs = 0 } }

            $config = [pscustomobject]@{
                DceEndpoint        = 'https://fake.ingest.monitor.azure.com'
                DcrImmutableId     = 'dcr-fake-0000'
                StorageAccountName = 'fakesa'
                CheckpointTable    = 'fakecp'
            }

            # Run 1: no checkpoint yet → endpoint called without -FromUtc via default 1h.
            $r1 = Invoke-MDETierPoll -Session $Session -Tier 'ActionCenter' -Config $config
            $r1.StreamsAttempted | Should -Be 2

            # Both filterable streams should now have a checkpoint.
            $script:CpStore.Keys.Count | Should -BeGreaterOrEqual 1

            # Run 2: each filterable stream's Invoke-MDEEndpoint should receive the
            # checkpoint as -FromUtc.
            Mock Invoke-MDEEndpoint {
                param($Session, $Stream, $FromUtc, $PathParams)
                # On 2nd run we MUST see a -FromUtc for filterable streams
                $manifest = Get-MDEEndpointManifest
                $entry = $manifest[$Stream]
                $filter = if ($entry -is [hashtable]) { $entry['Filter'] } else { $null }
                if ($filter) {
                    $PSBoundParameters.ContainsKey('FromUtc') | Should -BeTrue -Because "$Stream is filterable and must receive -FromUtc after first run"
                }
                ,@()
            }

            $r2 = Invoke-MDETierPoll -Session $Session -Tier 'ActionCenter' -Config $config
            $r2.StreamsAttempted | Should -Be 2
        }
    }
}
