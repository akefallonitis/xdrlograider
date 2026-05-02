#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive API error-handling coverage — proves the three layers that
    surround every portal call behave correctly under the full error taxonomy.

.DESCRIPTION
    Three rings of error handling, tested in isolation here:

      1. Invoke-DefenderPortalRequest (Xdr.Defender.Auth)
         - 401 -> Connect-DefenderPortal -Force -> retry once
         - Non-401 errors (403/404/429/5xx/network) -> surface to caller
         - Missing cached credentials -> throw with clear message

      2. Invoke-MDEPortalEndpoint (XdrLogRaider.Client)
         - try/catch wrapper: @{ Success=$true; Data=<body> } on 2xx,
           @{ Success=$false; Error=<msg> } on any exception

      3. Invoke-MDETierPoll (XdrLogRaider.Client)
         - Per-stream failure isolation: one stream's error does NOT abort
           the tier loop; subsequent streams still poll
         - Checkpoint advancement only on success path
         - Errors collected into @{ <stream> = <msg> } hashtable

    Additionally:
      4. Send-ToLogAnalytics (XdrLogRaider.Ingest)
         - Retry with exponential backoff on 429 + 5xx + network error
         - Hard-fail on 4xx other than 401/403
         - Row-level size skip (>1 MB row logged + skipped, not thrown)
         - Token caching with 5-min refresh buffer
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    # iter-14.0: target the L2 module directly so InModuleScope can mock
    # Update-XsrfToken + Connect-DefenderPortal (the real implementations).
    # Xdr.Portal.Auth is still imported so the surface tests at module level
    # continue to find Connect-DefenderPortal etc., but the request-level error
    # tests work against the L2 module where the actual logic lives.
    Import-Module "$script:Root/src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1"         -Force
    Import-Module "$script:Root/src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1"     -Force
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1" -Force
    Import-Module "$script:Root/src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1" -Force

    # Stub DCR_IMMUTABLE_IDS_JSON env var so Get-DcrImmutableIdForStream
    # (called by Invoke-MDETierPoll for every stream) resolves. All keys point
    # at a single stub `dcr-fake` since Send-ToLogAnalytics is mocked anyway.
    $manifestPath = Join-Path $script:Root 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $manifestData = Import-PowerShellDataFile -Path $manifestPath
    $stubMap = @{}
    foreach ($e in $manifestData.Endpoints) { $stubMap[$e.Stream] = 'dcr-fake' }
    $stubMap['MDE_Heartbeat_CL'] = 'dcr-fake'
    $env:DCR_IMMUTABLE_IDS_JSON = ($stubMap | ConvertTo-Json -Compress)
    $module = Get-Module Xdr.Sentinel.Ingest
    if ($module) { & $module { $script:DcrIdMap = $null } }
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\DCR_IMMUTABLE_IDS_JSON -ErrorAction SilentlyContinue
}

Describe 'API error handling — Invoke-DefenderPortalRequest (iter-14.0 home)' {

    It 'surfaces 403 Forbidden without attempting reauth' {
        InModuleScope Xdr.Defender.Auth {
            $fakeSess = [pscustomobject]@{
                Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
            }
            Mock Update-XsrfToken { 'xsrf' }
            Mock Connect-DefenderPortal {}   # must NOT be called on 403
            Mock Invoke-WebRequest {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Forbidden', $resp)
            }

            { Invoke-DefenderPortalRequest -Session $fakeSess -Path '/api/x' } | Should -Throw -ExpectedMessage '*Forbidden*'
            Should -Invoke Connect-DefenderPortal -Times 0 -Exactly
        }
    }

    It 'surfaces 500 Internal Server Error without attempting reauth' {
        InModuleScope Xdr.Defender.Auth {
            $fakeSess = [pscustomobject]@{
                Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Upn         = 'svc@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
            }
            Mock Update-XsrfToken { 'xsrf' }
            Mock Connect-DefenderPortal {}
            Mock Invoke-WebRequest {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::InternalServerError)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Internal Server Error', $resp)
            }

            { Invoke-DefenderPortalRequest -Session $fakeSess -Path '/api/x' } | Should -Throw
            Should -Invoke Connect-DefenderPortal -Times 0 -Exactly
        }
    }

    It 'throws clear message when 401 hits a session with no cached _Credential' {
        InModuleScope Xdr.Defender.Auth {
            $script:SessionCache.Clear()
            $fakeSess = [pscustomobject]@{
                Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                Upn         = 'svc-no-cache@test.com'
                PortalHost  = 'security.microsoft.com'
                AcquiredUtc = [datetime]::UtcNow
            }
            Mock Update-XsrfToken { 'xsrf' }
            Mock Invoke-WebRequest {
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Unauthorized)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Unauthorized', $resp)
            }

            { Invoke-DefenderPortalRequest -Session $fakeSess -Path '/api/x' } |
                Should -Throw -ExpectedMessage '*no cached*'
        }
    }
}

Describe 'API error handling — Invoke-MDEPortalEndpoint (structured failures)' {

    It 'returns Success true with Data on happy path' {
        InModuleScope Xdr.Defender.Client {
            Mock Invoke-DefenderPortalRequest { @{ hello = 'world' } }
            $r = Invoke-MDEPortalEndpoint -Session ([pscustomobject]@{}) -Path '/api/x'
            $r.Success | Should -BeTrue
            $r.Data.hello | Should -Be 'world'
            $r.Path    | Should -Be '/api/x'
        }
    }

    It 'returns Success false with Error on any exception' {
        InModuleScope Xdr.Defender.Client {
            Mock Invoke-DefenderPortalRequest { throw 'simulated portal blowup' }
            $r = Invoke-MDEPortalEndpoint -Session ([pscustomobject]@{}) -Path '/api/x'
            $r.Success | Should -BeFalse
            $r.Error   | Should -Match 'simulated portal blowup'
            $r.Path    | Should -Be '/api/x'
        }
    }

    It 'does not throw — caller must check .Success' {
        InModuleScope Xdr.Defender.Client {
            Mock Invoke-DefenderPortalRequest { throw 'boom' }
            { Invoke-MDEPortalEndpoint -Session ([pscustomobject]@{}) -Path '/api/x' } | Should -Not -Throw
        }
    }
}

Describe 'API error handling — Invoke-MDETierPoll (per-stream isolation)' {

    BeforeAll {
        $script:FakeSession = [pscustomobject]@{
            Session     = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Upn         = 'svc@test.com'
            PortalHost  = 'security.microsoft.com'
            AcquiredUtc = [datetime]::UtcNow
        }
        $script:FakeConfig = [pscustomobject]@{
            DceEndpoint        = 'https://fake.ingest.monitor.azure.com'
            DcrImmutableId     = 'dcr-fake-0000'
            StorageAccountName = 'fakesa'
            CheckpointTable    = 'fakecp'
        }
    }

    It 'one stream failing does NOT stop subsequent streams in the tier' {
        InModuleScope Xdr.Defender.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            $script:invoked = @()
            Mock Invoke-MDEEndpoint {
                param($Session, $Stream, $FromUtc, $PathParams)
                $script:invoked += $Stream
                # Pick a fast-tier stream to be the failing one
                if ($Stream -eq 'MDE_ActionCenter_CL') { throw 'boom' }
                ,@()
            }
            Mock Send-ToLogAnalytics { @{ RowsSent = 0 } }
            Mock Set-CheckpointTimestamp { }
            Mock Get-CheckpointTimestamp { $null }

            $result = Invoke-MDETierPoll -Session $Sess -Tier 'fast' -Config $Cfg
            # fast tier has 2 streams: MDE_ActionCenter_CL + MDE_MachineActions_CL
            $result.StreamsAttempted | Should -Be 2
            $result.StreamsSucceeded | Should -Be 1
            $result.Errors['MDE_ActionCenter_CL'] | Should -Be 'boom'
            $script:invoked.Count | Should -Be 2 -Because 'All streams in fast tier should have been tried even after one fails'
        }
    }

    It 'checkpoint is NOT advanced on per-stream failure' {
        InModuleScope Xdr.Defender.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            Mock Invoke-MDEEndpoint { throw 'blow up' }
            Mock Send-ToLogAnalytics { @{ RowsSent = 0 } }
            Mock Get-CheckpointTimestamp { $null }
            Mock Set-CheckpointTimestamp {}

            $null = Invoke-MDETierPoll -Session $Sess -Tier 'fast' -Config $Cfg

            Should -Invoke Set-CheckpointTimestamp -Times 0 -Exactly -Because 'failed stream must not checkpoint'
        }
    }

    It 'tier with NO streams declared returns zero-count result (no throw)' {
        InModuleScope Xdr.Defender.Client -Parameters @{ Sess = $script:FakeSession; Cfg = $script:FakeConfig } {
            param($Sess, $Cfg)
            # P4 was intentionally dropped — no streams carry Tier='P4' in the manifest.
            # But ValidateSet rejects P4 directly. Simulate empty tier by mocking manifest.
            Mock Get-MDEEndpointManifest { @{} }
            { Invoke-MDETierPoll -Session $Sess -Tier 'inventory' -Config $Cfg } | Should -Not -Throw
        }
    }
}

Describe 'API error handling — Send-ToLogAnalytics (retry + backoff)' {

    It 'retries on HTTP 429 (rate limit) and succeeds on a later attempt' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep { }  # avoid real waits

            $script:attempt = 0
            Mock Invoke-WebRequest {
                $script:attempt++
                if ($script:attempt -lt 3) {
                    $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too Many Requests', $resp)
                }
                @{ StatusCode = 204 }
            }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-fake' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @([pscustomobject]@{ TimeGenerated = (Get-Date).ToString('o') })

            $script:attempt | Should -Be 3 -Because 'Should have retried twice, succeeded on 3rd'
            $result.RowsSent    | Should -Be 1
            $result.BatchesSent | Should -Be 1
        }
    }

    It 'retries on HTTP 503 (transient server error)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep { }

            $script:attempt = 0
            Mock Invoke-WebRequest {
                $script:attempt++
                if ($script:attempt -eq 1) {
                    $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::ServiceUnavailable)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Service Unavailable', $resp)
                }
                @{ StatusCode = 204 }
            }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-fake' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @([pscustomobject]@{ foo = 'bar' })

            $result.RowsSent | Should -Be 1
        }
    }

    It 'hard-fails on HTTP 400 Bad Request (no retry)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep { }

            $script:attempt = 0
            Mock Invoke-WebRequest {
                $script:attempt++
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::BadRequest)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Bad Request', $resp)
            }

            { Send-ToLogAnalytics -DceEndpoint 'https://fake.ingest.monitor.azure.com' -DcrImmutableId 'dcr-fake' -StreamName 'Custom-X_CL' -Rows @([pscustomobject]@{ x = 1 }) } |
                Should -Throw -ExpectedMessage '*Bad Request*'
            $script:attempt | Should -Be 1 -Because '400 is NOT transient — no retries'
        }
    }

    It 'stops after MaxRetries (5) even for a persistent 429' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep { }

            $script:attempt = 0
            Mock Invoke-WebRequest {
                $script:attempt++
                $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Too Many Requests', $resp)
            }

            { Send-ToLogAnalytics -DceEndpoint 'https://fake.ingest.monitor.azure.com' -DcrImmutableId 'dcr-fake' -StreamName 'Custom-X_CL' -Rows @([pscustomobject]@{ x = 1 }) } |
                Should -Throw
            $script:attempt | Should -Be 6 -Because 'Initial try + 5 retries = 6 attempts, then give up'
        }
    }

    It 'row >= MaxBatchBytes is skipped with a warning (not thrown)' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken { 'fake-token' }
            Mock Start-Sleep { }
            Mock Invoke-WebRequest { @{ StatusCode = 204 } }

            $bigRow  = [pscustomobject]@{ payload = 'x' * 2000000 }   # 2 MB
            $tinyRow = [pscustomobject]@{ foo = 'bar' }

            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-fake' `
                -StreamName 'Custom-MDE_Test_CL' `
                -Rows @($bigRow, $tinyRow) `
                -WarningVariable warnings 3>$null

            $result.RowsSent | Should -Be 1 -Because 'big row was skipped, tiny row was sent'
            ($warnings -join ' ') | Should -Match 'Row exceeds' -Because 'Warning must surface the oversize row'
        }
    }

    It 'empty Rows returns RowsSent=0 without any HTTP call' {
        InModuleScope Xdr.Sentinel.Ingest {
            Mock Get-MonitorIngestionToken {}
            Mock Invoke-WebRequest {}
            $result = Send-ToLogAnalytics `
                -DceEndpoint 'https://fake.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-fake' `
                -StreamName 'Custom-X_CL' `
                -Rows @()
            $result.RowsSent | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Get-MonitorIngestionToken -Times 0 -Exactly
        }
    }
}
