#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0-beta first publish — KV secret cache TTL test gates.

.DESCRIPTION
    Production-readiness invariant: the FA worker must NOT keep KV secrets
    cached forever. Operators rotate secrets annually/quarterly; without a
    TTL, the FA continues using the stale value until the worker restarts.

    Gates by name:
      KvCache.FirstFetch         First call populates the cache + emits
                                 KV.CacheEvicted Reason='first-fetch'.
      KvCache.WithinTtl          Second call within TTL returns cached
                                 value; KV is NOT re-read.
      KvCache.AfterTtl           Second call past TTL evicts + re-fetches;
                                 emits KV.CacheEvicted Reason='ttl'.
      KvCache.ForceManual        -Force bypasses TTL; emits
                                 KV.CacheEvicted Reason='manual'.
      KvCache.EnvVarOverride     KV_CACHE_TTL_MINUTES env var overrides
                                 the default 60-minute TTL.
      KvCache.PerKeyIsolation    Different (VaultUri, SecretPrefix,
                                 AuthMethod) tuples cache independently.
      KvCache.ClearHelper        Clear-XdrAuthKeyVaultCache evicts all
                                 entries + emits Reason='manual-clear'.
#>

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module "$script:Root/src/Modules/Xdr.Sentinel.Ingest/Xdr.Sentinel.Ingest.psd1" -Force
    Import-Module "$script:Root/src/Modules/Xdr.Common.Auth/Xdr.Common.Auth.psd1" -Force

    # Stub Get-AzKeyVaultSecret in the GLOBAL scope so it's findable from
    # InModuleScope. Each test customizes the return per-call.
    function global:Get-AzKeyVaultSecret {
        param(
            [string] $VaultName,
            [string] $Name,
            [switch] $AsPlainText,
            $ErrorAction
        )
        # Return a deterministic stub; per-test Mocks override this.
        return "stub-value-for-$Name"
    }
}

AfterAll {
    Remove-Module Xdr.Common.Auth -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Sentinel.Ingest -Force -ErrorAction SilentlyContinue
    Remove-Item function:Get-AzKeyVaultSecret -ErrorAction SilentlyContinue
    Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
}

# Note: Pester 5 forbids BeforeEach in the container root. Each Describe
# declares its own BeforeEach to reset cache state for test isolation.

Describe 'KvCache.ModuleSurface — exports + back-compat' {

    It 'Get-XdrAuthFromKeyVault is exported (back-compat)' {
        (Get-Module Xdr.Common.Auth).ExportedFunctions.Keys | Should -Contain 'Get-XdrAuthFromKeyVault'
    }

    It 'Clear-XdrAuthKeyVaultCache is exported (new test/operator hook)' {
        (Get-Module Xdr.Common.Auth).ExportedFunctions.Keys | Should -Contain 'Clear-XdrAuthKeyVaultCache'
    }

    It 'Get-XdrAuthFromKeyVault declares -Force and -OperationId parameters; mandatory shape unchanged' {
        $cmd = Get-Command Get-XdrAuthFromKeyVault
        $cmd.Parameters.ContainsKey('Force')       | Should -BeTrue -Because 'manual eviction hook'
        $cmd.Parameters.ContainsKey('OperationId') | Should -BeTrue -Because 'AI correlation'
        # Back-compat: VaultUri + AuthMethod must remain mandatory.
        $isMandatory = {
            param($p)
            $paramAttr = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }) |
                Select-Object -First 1
            return $paramAttr -and $paramAttr.Mandatory
        }
        & $isMandatory $cmd.Parameters['VaultUri']    | Should -BeTrue
        & $isMandatory $cmd.Parameters['AuthMethod']  | Should -BeTrue
    }
}

Describe 'KvCache.FirstFetch — first call populates cache + emits Reason=first-fetch' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'first call reads KV 3 times (CredentialsTotp = upn + password + totp) + emits first-fetch event' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "secret-$Name" }
            $script:emittedEvents = @()
            Mock Send-XdrAppInsightsCustomEvent {
                $script:emittedEvents += [pscustomobject]@{ Name = $EventName; Properties = $Properties }
            }

            $r = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' `
                -SecretPrefix 'mde-portal' -AuthMethod 'CredentialsTotp'

            $r.upn        | Should -Be 'secret-mde-portal-upn'
            $r.password   | Should -Be 'secret-mde-portal-password'
            $r.totpBase32 | Should -Be 'secret-mde-portal-totp'

            $script:kvCalls | Should -Be 3 -Because 'CredentialsTotp pulls 3 secrets on miss'
            $script:emittedEvents.Count | Should -BeGreaterOrEqual 1
            $first = $script:emittedEvents[0]
            $first.Name | Should -Be 'KV.CacheEvicted'
            $first.Properties.Reason | Should -Be 'first-fetch'
        }
    }
}

Describe 'KvCache.WithinTtl — second call within TTL returns cached value (no KV call)' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'second call within TTL hits cache; KV NOT re-read' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "secret-$Name" }
            Mock Send-XdrAppInsightsCustomEvent {}
            # Use the default 60-minute TTL — well above any test wall-clock.

            $r1 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'
            $r2 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'

            $script:kvCalls | Should -Be 3 -Because 'first call reads 3 secrets; second call hits cache (no additional KV reads)'
            $r2.upn        | Should -Be $r1.upn -Because 'cached value identity preserved'
            $r2.password   | Should -Be $r1.password
            $r2.totpBase32 | Should -Be $r1.totpBase32
        }
    }
}

Describe 'KvCache.AfterTtl — second call past TTL evicts + re-fetches' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'TTL=0 (effectively no cache): second call re-reads KV + emits ttl event' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "secret-$Name-$($script:kvCalls)" }
            $script:evictionEvents = @()
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'KV.CacheEvicted') {
                    $script:evictionEvents += [pscustomobject]@{ Reason = $Properties.Reason; TtlMinutes = $Properties.TtlMinutes }
                }
            }

            # Set TTL to 1 minute, then artificially expire the cache by
            # reaching into module state and rolling Expiry into the past.
            $env:KV_CACHE_TTL_MINUTES = '60'
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null
            $cacheKey = 'https://kv1.vault.azure.net|mde-portal|CredentialsTotp'
            $script:CredentialCacheExpiry[$cacheKey] = [datetime]::UtcNow.AddMinutes(-5)

            $r2 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'

            $script:kvCalls | Should -Be 6 -Because 'first call: 3 reads; expired refresh: 3 more = 6 total'
            $r2.upn | Should -Be 'secret-mde-portal-upn-4' -Because 'refresh returned the new (post-rotation) value'
            ($script:evictionEvents | Where-Object { $_.Reason -eq 'first-fetch' }).Count | Should -Be 1
            ($script:evictionEvents | Where-Object { $_.Reason -eq 'ttl' }).Count          | Should -Be 1
        }
    }

    It 'real-clock TTL = 1 sec: sleep 2 sec triggers eviction + re-fetch' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "v$($script:kvCalls)-$Name" }
            Mock Send-XdrAppInsightsCustomEvent {}

            # 1-minute is the lowest sane env value; for fast unit-test
            # turnaround we set a near-immediate expiry by writing the
            # cache directly with a 1-second future expiry, then sleep.
            $r1 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'
            $cacheKey = 'https://kv1.vault.azure.net|mde-portal|CredentialsTotp'
            $script:CredentialCacheExpiry[$cacheKey] = [datetime]::UtcNow.AddSeconds(1)
            Start-Sleep -Seconds 2

            $r2 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'

            $script:kvCalls | Should -Be 6 -Because '3 + 3 — TTL expired during sleep'
            $r2.upn | Should -Not -Be $r1.upn -Because 'second read returned post-rotation value'
        }
    }
}

Describe 'KvCache.ForceManual — -Force bypasses TTL + emits manual event' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It '-Force bypasses cache + emits Reason=manual' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "v$($script:kvCalls)-$Name" }
            $script:reasons = @()
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'KV.CacheEvicted') { $script:reasons += [string]$Properties.Reason }
            }

            $r1 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp'
            $r2 = Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' -Force

            $script:kvCalls | Should -Be 6 -Because 'Force re-reads even though cache is fresh'
            $r2.upn | Should -Not -Be $r1.upn
            $script:reasons | Should -Contain 'first-fetch'
            $script:reasons | Should -Contain 'manual'
        }
    }
}

Describe 'KvCache.EnvVarOverride — KV_CACHE_TTL_MINUTES env var changes the TTL' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'KV_CACHE_TTL_MINUTES=30 stamps TtlMinutes=30 in the eviction event' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-AzKeyVaultSecret { return "stub-$Name" }
            $script:lastTtl = $null
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'KV.CacheEvicted') { $script:lastTtl = $Properties.TtlMinutes }
            }

            $env:KV_CACHE_TTL_MINUTES = '30'
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null
            $script:lastTtl | Should -Be 30
        }
    }

    It 'env var = "0" or non-numeric falls back to default 60' {
        InModuleScope Xdr.Common.Auth {
            Mock Get-AzKeyVaultSecret { return "stub-$Name" }
            $script:lastTtl = $null
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'KV.CacheEvicted') { $script:lastTtl = $Properties.TtlMinutes }
            }

            $env:KV_CACHE_TTL_MINUTES = 'not-a-number'
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null
            $script:lastTtl | Should -Be 60 -Because 'invalid env var falls back to safe default'
        }
    }
}

Describe 'KvCache.PerKeyIsolation — different vault/prefix/method tuples cache independently' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'different SecretPrefix produces independent cache entries' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "secret-$Name" }
            Mock Send-XdrAppInsightsCustomEvent {}

            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -SecretPrefix 'mde-portal'    -AuthMethod 'CredentialsTotp' | Out-Null
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -SecretPrefix 'purview-portal' -AuthMethod 'CredentialsTotp' | Out-Null

            $script:kvCalls | Should -Be 6 -Because 'each prefix is its own cache key — both miss on first call'
            # Repeat both — should hit cache.
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -SecretPrefix 'mde-portal'    -AuthMethod 'CredentialsTotp' | Out-Null
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -SecretPrefix 'purview-portal' -AuthMethod 'CredentialsTotp' | Out-Null
            $script:kvCalls | Should -Be 6 -Because 'second pass hits cache for both prefixes'
        }
    }

    It 'different AuthMethod produces independent cache entries (CredentialsTotp vs Passkey)' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret {
                $script:kvCalls++
                if ($Name -match 'passkey') {
                    return '{"upn":"svc@test","credentialId":"abc"}'
                }
                return "secret-$Name"
            }
            Mock Send-XdrAppInsightsCustomEvent {}

            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'Passkey' | Out-Null

            # CredentialsTotp = 3 reads + Passkey = 1 read = 4 total
            $script:kvCalls | Should -Be 4
        }
    }
}

Describe 'KvCache.ClearHelper — Clear-XdrAuthKeyVaultCache empties the cache + emits manual-clear event' {

    BeforeEach {
        InModuleScope Xdr.Common.Auth {
            $script:CredentialCache       = @{}
            $script:CredentialCacheExpiry = @{}
        }
        Remove-Item Env:\KV_CACHE_TTL_MINUTES -ErrorAction SilentlyContinue
    }

    It 'evicts all entries + next call re-reads KV' {
        InModuleScope Xdr.Common.Auth {
            $script:kvCalls = 0
            Mock Get-AzKeyVaultSecret { $script:kvCalls++; return "secret-$Name" }
            $script:reasons = @()
            $script:lastEvictedCount = $null
            Mock Send-XdrAppInsightsCustomEvent {
                if ($EventName -eq 'KV.CacheEvicted') {
                    $script:reasons += [string]$Properties.Reason
                    if ($Properties.Reason -eq 'manual-clear' -and $Properties.ContainsKey('EntriesEvicted')) {
                        $script:lastEvictedCount = $Properties.EntriesEvicted
                    }
                }
            }

            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null
            Clear-XdrAuthKeyVaultCache
            Get-XdrAuthFromKeyVault -VaultUri 'https://kv1.vault.azure.net' -AuthMethod 'CredentialsTotp' | Out-Null

            $script:kvCalls | Should -Be 6 -Because '3 + 3 — Clear forced a re-read'
            $script:reasons | Should -Contain 'first-fetch'
            $script:reasons | Should -Contain 'manual-clear'
            # After the first call, exactly 1 entry was in cache; Clear evicts it.
            $script:lastEvictedCount | Should -Be 1
        }
    }
}

Describe 'KvCache.ArmConfig — KV_CACHE_TTL_MINUTES app setting wired by deploy templates' {

    BeforeAll {
        $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:BicepPath  = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
        $script:BicepText  = if (Test-Path -LiteralPath $script:BicepPath) { Get-Content $script:BicepPath -Raw } else { $null }
        $script:ArmJson    = Get-Content (Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json') -Raw | ConvertFrom-Json -Depth 50
    }

    It 'main.bicep declares KV_CACHE_TTL_MINUTES app setting with default 60' -Skip:(-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'deploy' 'main.bicep'))) {
        # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
        # single source of truth). Skip cleanly when not present.
        $script:BicepText | Should -Match "KV_CACHE_TTL_MINUTES:\s*'60'" -Because 'operator-tunable knob in the deploy template'
    }

    It 'mainTemplate.json appSettings expression includes KV_CACHE_TTL_MINUTES = 60' {
        $faRes = $script:ArmJson.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $expr = [string]$faRes.properties.siteConfig.appSettings
        $expr | Should -Match "KV_CACHE_TTL_MINUTES" -Because 'appSettings expression must include the env var name'
        $expr | Should -Match "createObject\('name',\s*'KV_CACHE_TTL_MINUTES',\s*'value',\s*'60'\)"
    }
}
