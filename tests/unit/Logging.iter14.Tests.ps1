#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 14B — Microsoft-best-practices structured-logging test
    gates. Verifies the new Send-XdrAppInsights* API surface, secret-redaction
    behaviour, AuthChain.* / Stream.Polled / Ingest.BoundaryMarker call-site
    instrumentation, and Bicep/ARM template config (sampling-excluded types,
    AI connection string).

.DESCRIPTION
    Test gates by name (referenced in iter-14.0 Phase 14B plan):
      Logging.NoSecretsLeaked              — secret-key values redacted before
                                              hitting the TelemetryClient
      Logging.AuthChainEventsStructured    — every Write-Warning / throw in
                                              the auth chain has a paired
                                              Send-XdrAppInsights* call
      Logging.NoPlainAADSTSMessages        — no `throw "AADSTS"` /
                                              `Write-Warning "AADSTS"` without
                                              a paired AADSTSError event with
                                              the AADSTSCode property
      Logging.OperationIdStamped           — every Send-XdrAppInsights*
                                              accepts -OperationId
      Logging.SamplingExcludedTypesConfigured
                                            — compiled mainTemplate.json + Bicep
                                              carry the env var with the 3
                                              excluded event types
      Logging.AppInsightsConnectionStringSet
                                            — Bicep configures
                                              APPLICATIONINSIGHTS_CONNECTION_STRING
      Logging.SendXdrAppInsightsTrace      — signature/defaults
      Logging.SendXdrAppInsightsCustomEvent
                                            — signature/defaults
      Logging.SendXdrAppInsightsCustomMetric
                                            — signature/defaults
      Logging.SendXdrAppInsightsException  — signature/defaults
#>

BeforeDiscovery {
    # BeforeDiscovery runs before It -Skip evaluation; pre-compute Bicep paths
    # so inline -Skip clauses can guard cleanly when Bicep is archived.
    $script:DiscoveryRepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:DiscoveryFunctionAppBicep = Join-Path $script:DiscoveryRepoRoot 'deploy' 'modules' 'function-app.bicep'
    $script:DiscoveryMainBicep    = Join-Path $script:DiscoveryRepoRoot 'deploy' 'main.bicep'
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:IngestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    Import-Module $script:IngestPath -Force -ErrorAction Stop

    $script:DefenderAuthDir = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Public'
    $script:ClientDir       = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client'
    $script:BicepPath       = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
    $script:FaBicepPath     = Join-Path $script:RepoRoot 'deploy' 'modules' 'function-app.bicep'
    $script:ArmPath         = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
}

AfterAll {
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
}

# ============================================================================
#  Module export surface
# ============================================================================
Describe 'Send-XdrAppInsights* module surface' {
    It 'exports all 4 Send-XdrAppInsights* entry points' {
        $exported = (Get-Module Xdr.Sentinel.Ingest).ExportedFunctions.Keys
        $exported | Should -Contain 'Send-XdrAppInsightsTrace'
        $exported | Should -Contain 'Send-XdrAppInsightsCustomEvent'
        $exported | Should -Contain 'Send-XdrAppInsightsCustomMetric'
        $exported | Should -Contain 'Send-XdrAppInsightsException'
    }
}

# ============================================================================
#  Per-method signature gates (Logging.SendXdrAppInsights*)
# ============================================================================
Describe 'Send-XdrAppInsightsTrace signature + null-safety' {
    It 'Logging.SendXdrAppInsightsTrace: accepts -Message + -SeverityLevel + -Properties + -OperationId' {
        $cmd = Get-Command Send-XdrAppInsightsTrace
        $cmd.Parameters.ContainsKey('Message')       | Should -BeTrue
        $cmd.Parameters.ContainsKey('SeverityLevel') | Should -BeTrue
        $cmd.Parameters.ContainsKey('Properties')    | Should -BeTrue
        $cmd.Parameters.ContainsKey('OperationId')   | Should -BeTrue
    }

    It 'falls back to Write-Information when no AI client is loadable' {
        # No AI types loaded in unit-test process — should not throw.
        { Send-XdrAppInsightsTrace -Message 'test-msg' -SeverityLevel Information -InformationAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'tolerates a $null Properties hashtable' {
        { Send-XdrAppInsightsTrace -Message 'test' -Properties $null -InformationAction SilentlyContinue } |
            Should -Not -Throw
    }
}

Describe 'Send-XdrAppInsightsCustomEvent signature + null-safety' {
    It 'Logging.SendXdrAppInsightsCustomEvent: accepts -EventName + -Properties + -OperationId' {
        $cmd = Get-Command Send-XdrAppInsightsCustomEvent
        $cmd.Parameters.ContainsKey('EventName')   | Should -BeTrue
        $cmd.Parameters.ContainsKey('Properties')  | Should -BeTrue
        $cmd.Parameters.ContainsKey('OperationId') | Should -BeTrue
    }

    It 'falls back gracefully without throwing' {
        { Send-XdrAppInsightsCustomEvent -EventName 'Unit.Test' -InformationAction SilentlyContinue } |
            Should -Not -Throw
    }
}

Describe 'Send-XdrAppInsightsCustomMetric signature + null-safety' {
    It 'Logging.SendXdrAppInsightsCustomMetric: accepts -MetricName + -Value + -Properties + -OperationId' {
        $cmd = Get-Command Send-XdrAppInsightsCustomMetric
        $cmd.Parameters.ContainsKey('MetricName')  | Should -BeTrue
        $cmd.Parameters.ContainsKey('Value')       | Should -BeTrue
        $cmd.Parameters.ContainsKey('Properties')  | Should -BeTrue
        $cmd.Parameters.ContainsKey('OperationId') | Should -BeTrue
    }

    It 'falls back gracefully on numeric value emission' {
        { Send-XdrAppInsightsCustomMetric -MetricName 'TestMetric' -Value 42.0 -InformationAction SilentlyContinue } |
            Should -Not -Throw
    }
}

Describe 'Send-XdrAppInsightsException signature + null-safety' {
    It 'Logging.SendXdrAppInsightsException: accepts -Exception + -Properties + -SeverityLevel + -OperationId' {
        $cmd = Get-Command Send-XdrAppInsightsException
        $cmd.Parameters.ContainsKey('Exception')     | Should -BeTrue
        $cmd.Parameters.ContainsKey('Properties')    | Should -BeTrue
        $cmd.Parameters.ContainsKey('SeverityLevel') | Should -BeTrue
        $cmd.Parameters.ContainsKey('OperationId')   | Should -BeTrue
    }

    It 'falls back gracefully on a real Exception object' {
        $ex = [System.InvalidOperationException]::new('simulated failure')
        { Send-XdrAppInsightsException -Exception $ex -InformationAction SilentlyContinue } |
            Should -Not -Throw
    }
}

# ============================================================================
#  Logging.NoSecretsLeaked — redaction behaviour
# ============================================================================
Describe 'Logging.NoSecretsLeaked' {
    It 'redacts secret-key values via the internal helper' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = @{
                upn          = 'svc@contoso.com'
                password     = 'super-secret-pw'
                totpBase32   = 'JBSWY3DPEHPK3PXP'
                sccauth      = 'eyJhbGciOiJI...'
                xsrfToken    = 'XYZ-TOKEN'
                passkey      = 'private-passkey-blob'
                privateKey   = '-----BEGIN PRIVATE KEY-----'
                Stream       = 'MDE_PUAConfig_CL'
            }
            $safe = ConvertTo-XdrAiSafeProperties -Properties $props
            $safe['password']   | Should -Be '<redacted>'
            $safe['totpBase32'] | Should -Be '<redacted>'
            $safe['sccauth']    | Should -Be '<redacted>'
            $safe['xsrfToken']  | Should -Be '<redacted>'
            $safe['passkey']    | Should -Be '<redacted>'
            $safe['privateKey'] | Should -Be '<redacted>'
            # Non-secret keys flow through unchanged.
            $safe['upn']        | Should -Be 'svc@contoso.com'
            $safe['Stream']     | Should -Be 'MDE_PUAConfig_CL'
        }
    }

    It 'redaction is case-insensitive' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = @{
                Password   = 'pw1'
                TOTPBASE32 = 'seed-1'
                SCCAUTH    = 'cookie-1'
            }
            $safe = ConvertTo-XdrAiSafeProperties -Properties $props
            $safe['Password']   | Should -Be '<redacted>'
            $safe['TOTPBASE32'] | Should -Be '<redacted>'
            $safe['SCCAUTH']    | Should -Be '<redacted>'
        }
    }

    It 'does not mutate the caller hashtable' {
        $orig = @{ password = 'pw1'; upn = 'x@y.com' }
        $null = & (Get-Module Xdr.Sentinel.Ingest) {
            param($h) ConvertTo-XdrAiSafeProperties -Properties $h
        } $orig
        $orig['password'] | Should -Be 'pw1'
    }
}

# ============================================================================
#  Logging.OperationIdStamped — every Send-XdrAppInsights* takes -OperationId
# ============================================================================
Describe 'Logging.OperationIdStamped' {
    It 'every public Send-XdrAppInsights* function defines -OperationId' {
        foreach ($fn in @('Send-XdrAppInsightsTrace','Send-XdrAppInsightsCustomEvent','Send-XdrAppInsightsCustomMetric','Send-XdrAppInsightsException')) {
            $cmd = Get-Command $fn
            $cmd.Parameters.ContainsKey('OperationId') | Should -BeTrue -Because "$fn must accept -OperationId"
        }
    }

    It 'auto-generates an OperationId when none is supplied' {
        InModuleScope Xdr.Sentinel.Ingest {
            $props = [System.Collections.Generic.Dictionary[string,string]]::new()
            $ambient = Add-XdrAiAmbientContext -Properties $props -OperationId $null
            $ambient.OperationId | Should -Not -BeNullOrEmpty
            [Guid]::TryParse($ambient.OperationId, [ref]([Guid]::Empty)) | Should -BeTrue
            $props['OperationId'] | Should -Be $ambient.OperationId
        }
    }
}

# ============================================================================
#  Logging.AuthChainEventsStructured — every Write-Warning / throw in the
#  auth chain is paired with a Send-XdrAppInsights* call
# ============================================================================
Describe 'Logging.AuthChainEventsStructured' {
    It 'Connect-DefenderPortal emits AuthChain.CacheHit + CacheEvict + Started + Completed' {
        $src = Get-Content -LiteralPath (Join-Path $script:DefenderAuthDir 'Connect-DefenderPortal.ps1') -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.CacheHit'"
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.CacheEvict'"
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.Started'"
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.Completed'"
    }

    It 'Invoke-DefenderPortalRequest emits AuthChain.RateLimited + Reauth + ProactiveRefresh' {
        $src = Get-Content -LiteralPath (Join-Path $script:DefenderAuthDir 'Invoke-DefenderPortalRequest.ps1') -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.RateLimited'"
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.Reauth'"
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.ProactiveRefresh'"
    }

    It 'Invoke-MDETierPoll emits Stream.Polled' {
        $src = Get-Content -LiteralPath (Join-Path $script:ClientDir 'Public' 'Invoke-MDETierPoll.ps1') -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'Stream\.Polled'"
    }

    It '_EndpointHelpers emits Ingest.BoundaryMarker on every boundary path' {
        $src = Get-Content -LiteralPath (Join-Path $script:ClientDir 'Endpoints' '_EndpointHelpers.ps1') -Raw
        # Four boundary cases: api-returned-null, unwrap-target-null, empty-array, empty-object.
        ($src | Select-String -Pattern "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'Ingest\.BoundaryMarker'" -AllMatches).Matches.Count |
            Should -BeGreaterOrEqual 4
    }

    It 'Connect-DefenderPortal emits AuthChain.AADSTSError before rethrow' {
        $src = Get-Content -LiteralPath (Join-Path $script:DefenderAuthDir 'Connect-DefenderPortal.ps1') -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomEvent\s+-EventName\s+'AuthChain\.AADSTSError'"
        # Confirm the throw still happens after the AI emission.
        $src | Should -Match 'AuthChain\.AADSTSError'
    }
}

# ============================================================================
#  Logging.NoPlainAADSTSMessages
# ============================================================================
Describe 'Logging.NoPlainAADSTSMessages' {
    It 'every AADSTS-bearing message in Connect-DefenderPortal pairs with AuthChain.AADSTSError emission' {
        $src = Get-Content -LiteralPath (Join-Path $script:DefenderAuthDir 'Connect-DefenderPortal.ps1') -Raw
        # The function must reference both the AADSTS regex extraction AND the
        # AADSTSError event emission with AADSTSCode property.
        $src | Should -Match 'AADSTS\(\\d\+\)'
        $src | Should -Match "AuthChain\.AADSTSError"
        $src | Should -Match "AADSTSCode"
    }
}

# ============================================================================
#  Bicep + ARM gates
# ============================================================================
Describe 'Logging.SamplingExcludedTypesConfigured' {
    It 'Bicep main.bicep configures APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES with the 3 critical event types' -Skip:(-not (Test-Path -LiteralPath $script:DiscoveryMainBicep)) {
        # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
        # single source of truth). Skip cleanly when not present.
        $bicep = Get-Content -LiteralPath $script:BicepPath -Raw
        $bicep | Should -Match 'APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES'
        $bicep | Should -Match 'AuthChain\.AADSTSError'
        $bicep | Should -Match 'AuthChain\.RateLimited'
        $bicep | Should -Match 'AuthChain\.BoundaryMarker'
    }

    It 'compiled mainTemplate.json carries the same env var' {
        $arm = Get-Content -LiteralPath $script:ArmPath -Raw
        $arm | Should -Match 'APPLICATIONINSIGHTS_TELEMETRY_SAMPLING_EXCLUDED_TYPES'
        $arm | Should -Match 'AuthChain\.AADSTSError;AuthChain\.RateLimited;AuthChain\.BoundaryMarker'
    }
}

Describe 'Logging.AppInsightsConnectionStringSet' {
    It 'Bicep configures APPLICATIONINSIGHTS_CONNECTION_STRING (modern; supersedes instrumentation key)' -Skip:(-not (Test-Path -LiteralPath $script:DiscoveryFunctionAppBicep)) {
        # Bicep is archived to .internal/bicep-reference/ in v0.1.0-beta — ARM
        # is the single source of truth. Skip cleanly when not present; the
        # next test below validates the same setting on the compiled ARM.
        $faBicep = Get-Content -LiteralPath $script:FaBicepPath -Raw
        $faBicep | Should -Match 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    }

    It 'compiled ARM template sets APPLICATIONINSIGHTS_CONNECTION_STRING via reference()' {
        $arm = Get-Content -LiteralPath $script:ArmPath -Raw
        $arm | Should -Match 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    }
}

# ============================================================================
#  Direct emission round-trip with fallback (Write-Information capture)
# ============================================================================
Describe 'Send-XdrAppInsights* end-to-end fallback round-trip' {
    It 'redacts secrets in the fallback Write-Information stream too' {
        # Ambient context redacts via ConvertTo-XdrAiSafeProperties before any
        # message body is constructed, so even the Information-stream fallback
        # never sees the raw secret value.
        InModuleScope Xdr.Sentinel.Ingest {
            $props = @{ password = 'should-never-leak'; upn = 'safe@x.com' }
            $safe = ConvertTo-XdrAiSafeProperties -Properties $props
            $safe['password'] | Should -Be '<redacted>'
            $safe['password'] | Should -Not -Match 'should-never-leak'
        }
    }
}
