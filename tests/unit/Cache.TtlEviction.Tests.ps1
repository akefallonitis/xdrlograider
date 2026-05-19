#Requires -Module Pester
# Cache.TtlEviction.Tests.ps1 · Phase β.3 · cache eviction boundary tests
#
# Validates that 3 module-scope caches evict properly at expiry boundary:
#   1. Xdr.Ingest::Get-MiBearerToken  (~60min JWT exp · 5min refresh window)
#   2. Xdr.Poll::Discover-XdrPortalCapabilities  (24h TTL · ExpiresUtc gate)
#   3. Xdr.Auth::Connect-DefenderPortal cache  (cookie .Expires · 5min refresh)
#
# Cookie cache (#3) already locked by Auth.CookieExpiryWired.Tests.ps1.
# This file covers MI + Capability (the two operator-flagged gaps from audit β.3).

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    # Xdr.Auth must load BEFORE Xdr.Poll · Discover-XdrPortalCapabilities calls Get-XdrPortalConfig (Auth export)
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Ingest\Xdr.Ingest.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Poll\Xdr.Poll.psd1') -Force
}

Describe 'Cache.TtlEviction · Get-MiBearerToken (Xdr.Ingest)' -Tag 'cache-ttl','ingest' {

    BeforeEach {
        # Clear module-scope BearerCache before each test
        InModuleScope Xdr.Ingest { $script:BearerCache = $null }
    }

    It 'cache MISS when BearerCache is null · fetches fresh' {
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            [pscustomobject]@{ Token = 'fresh-token'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(60) }
        }
        $t = Get-MiBearerToken
        $t | Should -Be 'fresh-token'
        Should -Invoke -ModuleName Xdr.Ingest Get-AzAccessToken -Exactly 1
    }

    It 'cache HIT when token has > RefreshBeforeMinutes left · no fresh call' {
        # Seed cache with token expiring 30min from now (well past 5min refresh)
        InModuleScope Xdr.Ingest {
            $script:BearerCache = [pscustomobject]@{
                Token      = 'cached-token'
                ExpiresUtc = ([datetime]::UtcNow).AddMinutes(30)
            }
        }
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            [pscustomobject]@{ Token = 'should-not-be-used'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(60) }
        }
        $t = Get-MiBearerToken
        $t | Should -Be 'cached-token'
        Should -Invoke -ModuleName Xdr.Ingest Get-AzAccessToken -Exactly 0
    }

    It 'cache EVICT when token expires within RefreshBeforeMinutes window · fetches fresh' {
        # Seed cache with token expiring 2min from now (inside 5min refresh window)
        InModuleScope Xdr.Ingest {
            $script:BearerCache = [pscustomobject]@{
                Token      = 'near-expiry'
                ExpiresUtc = ([datetime]::UtcNow).AddMinutes(2)
            }
        }
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            [pscustomobject]@{ Token = 'refreshed-token'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(60) }
        }
        $t = Get-MiBearerToken
        $t | Should -Be 'refreshed-token'
        Should -Invoke -ModuleName Xdr.Ingest Get-AzAccessToken -Exactly 1
    }

    It 'cache EVICT when -Force regardless of expiry · fetches fresh' {
        InModuleScope Xdr.Ingest {
            $script:BearerCache = [pscustomobject]@{
                Token      = 'still-valid'
                ExpiresUtc = ([datetime]::UtcNow).AddMinutes(45)
            }
        }
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            [pscustomobject]@{ Token = 'forced-refresh'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(60) }
        }
        $t = Get-MiBearerToken -Force
        $t | Should -Be 'forced-refresh'
        Should -Invoke -ModuleName Xdr.Ingest Get-AzAccessToken -Exactly 1
    }

    It 'custom RefreshBeforeMinutes=10 evicts at 8min remaining · fetches fresh' {
        InModuleScope Xdr.Ingest {
            $script:BearerCache = [pscustomobject]@{
                Token      = 'eight-min-left'
                ExpiresUtc = ([datetime]::UtcNow).AddMinutes(8)
            }
        }
        Mock -ModuleName Xdr.Ingest Get-AzAccessToken {
            [pscustomobject]@{ Token = 'fresh-by-window'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(60) }
        }
        $t = Get-MiBearerToken -RefreshBeforeMinutes 10
        $t | Should -Be 'fresh-by-window'
        Should -Invoke -ModuleName Xdr.Ingest Get-AzAccessToken -Exactly 1
    }
}

Describe 'Cache.TtlEviction · Discover-XdrPortalCapabilities (Xdr.Poll · R-C 24h TTL)' -Tag 'cache-ttl','poll','r-c' {

    BeforeEach {
        Clear-XdrCapabilityCache
    }

    It 'cache MISS when tenant not in cache · builds fresh snapshot' {
        $snap = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        $snap | Should -Not -BeNullOrEmpty
        $snap.TenantId | Should -Be 'tenant-A'
        $snap.ExpiresUtc | Should -BeGreaterThan ([datetime]::UtcNow.AddHours(23.9))
    }

    It 'cache HIT when same tenant queried within TTL · returns same snapshot' {
        $s1 = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        Start-Sleep -Milliseconds 50
        $s2 = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        # ExpiresUtc identical → same cached object
        $s2.ExpiresUtc | Should -Be $s1.ExpiresUtc
        $s2.CapturedUtc | Should -Be $s1.CapturedUtc
    }

    It 'cache EVICT when -Force · rebuilds snapshot (new ExpiresUtc)' {
        $s1 = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        Start-Sleep -Milliseconds 50
        $s2 = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24 -Force
        $s2.CapturedUtc | Should -BeGreaterThan $s1.CapturedUtc
    }

    It 'cache EVICT after TTL expires · rebuilds snapshot' {
        # Seed cache with expired snapshot
        InModuleScope Xdr.Poll {
            $script:CapabilityCache['tenant-A'] = @{
                TenantId    = 'tenant-A'
                CapturedUtc = [datetime]::UtcNow.AddHours(-25)
                ExpiresUtc  = [datetime]::UtcNow.AddHours(-1)  # expired 1h ago
                Portals     = @{}
            }
        }
        $s = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        # New ExpiresUtc is in the future
        $s.ExpiresUtc | Should -BeGreaterThan ([datetime]::UtcNow)
    }

    It 'separate tenants get separate cache slots' {
        $a = Discover-XdrPortalCapabilities -TenantId 'tenant-A' -TtlHours 24
        $b = Discover-XdrPortalCapabilities -TenantId 'tenant-B' -TtlHours 24
        $a.TenantId | Should -Be 'tenant-A'
        $b.TenantId | Should -Be 'tenant-B'
    }
}

Describe 'Cache.TtlEviction · capability cache survives Test-XdrEndpointAllowedByCapabilities calls' -Tag 'cache-ttl','poll','r-c' {

    BeforeEach { Clear-XdrCapabilityCache }

    It 'multiple Test-* calls do not invalidate snapshot' {
        $snap1 = Discover-XdrPortalCapabilities -TenantId 'tenant-X' -TtlHours 24
        $entry = @{ RequiresProducts = @('Defender for Endpoint') }
        $null = Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $snap1
        $null = Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $snap1
        $snap2 = Discover-XdrPortalCapabilities -TenantId 'tenant-X' -TtlHours 24
        $snap2.CapturedUtc | Should -Be $snap1.CapturedUtc
    }
}
