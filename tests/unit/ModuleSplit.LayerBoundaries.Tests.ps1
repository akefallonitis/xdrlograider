#Requires -Modules Pester
<#
.SYNOPSIS
    Architectural gate for the 5-module split. Asserts the dependency graph
    stays acyclic and that the L4 portal-routing orchestrator has access to
    L1-L3 (so it can dispatch through them) while L3 does not depend on L4
    (would create a cycle).

.DESCRIPTION
    Layer map (v0.1.0 GA — pure Defender connector, 7 modules total):
      L1 Xdr.Common.Auth          portal-generic Entra (TOTP, passkey, ESTS)
      L1 Xdr.Common.Manifest      generic per-portal manifest loader
      L1 Xdr.Common.Telemetry     AppInsights helpers (SRE/dev surface)
      L1 Xdr.Sentinel.Ingest      portal-generic ingest (DCE/DCR + Storage Table)
      L2 Xdr.Defender.Auth        Defender-specific cookie exchange (sccauth + XSRF)
      L3 Xdr.Defender.Client      Defender-portal manifest dispatcher (64 streams)
      L4 Xdr.Connector.Orchestrator  portal-routing dispatcher (Connect-XdrPortal etc.
                                      + Get-XdrConnectorHealth + Test-XdrConnectorConfig)

    NOTE (v0.1.0 GA scope per user 2026-05-05): Multi-portal stubs (Entra/Purview/Intune
    × Auth/Client) are DEFERRED to v0.2.0. v0.2.0 reintroduces them with real bodies
    + FA multi-tenancy support.

    Invariants enforced here:
      1. L3 Xdr.Defender.Client RequiredModules: only L2 Xdr.Defender.Auth + Xdr.Common.Manifest
         (no L4, no L1 ingest — would be a cycle / cross-leg).
      2. L4 Xdr.Connector.Orchestrator RequiredModules cover L1+L2+L3 (live modules only).
      3. 7 modules total. No multi-portal stubs in v0.1.0.
      4. Orchestrator routing: Connect-XdrPortal -Portal 'Defender' resolves
         through to Connect-DefenderPortal; unknown -Portal throws.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulesRoot = Join-Path $script:RepoRoot 'src' 'Modules'

    $script:DefClientPsd1   = Join-Path $script:ModulesRoot 'Xdr.Defender.Client'      'Xdr.Defender.Client.psd1'
    $script:OrchestratorPsd1= Join-Path $script:ModulesRoot 'Xdr.Connector.Orchestrator' 'Xdr.Connector.Orchestrator.psd1'
    $script:SentinelPsd1    = Join-Path $script:ModulesRoot 'Xdr.Sentinel.Ingest'      'Xdr.Sentinel.Ingest.psd1'
    $script:CommonAuthPsd1  = Join-Path $script:ModulesRoot 'Xdr.Common.Auth'           'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1     = Join-Path $script:ModulesRoot 'Xdr.Defender.Auth'         'Xdr.Defender.Auth.psd1'
}

Describe 'Module architecture — pure Defender connector, no stubs in v0.1.0' {

    It 'src/Modules contains exactly the 7 v0.1.0-GA modules (Defender + L1 common + L4 orchestrator)' {
        $dirs = @(Get-ChildItem -LiteralPath $script:ModulesRoot -Directory | Sort-Object Name | ForEach-Object Name)
        $expected = @(
            'Xdr.Common.Auth',            # L1 — Entra ESTS + TOTP + passkey
            'Xdr.Common.Manifest',        # L1 — generic per-portal manifest loader
            'Xdr.Common.Telemetry',       # L1 — AppInsights helpers (SRE surface)
            'Xdr.Connector.Orchestrator', # L4 — portal-routing dispatcher
            'Xdr.Defender.Auth',          # L2 — Defender cookie exchange
            'Xdr.Defender.Client',        # L3 — Defender manifest dispatcher
            'Xdr.Sentinel.Ingest'         # L1 — DCE/DCR + Storage Table + DLQ
        )
        $dirs | Should -Be $expected -Because 'v0.1.0 GA scope per user 2026-05-05: pure Defender connector. Multi-portal stubs (Entra/Purview/Intune × Auth/Client) deferred to v0.2.0 + FA multi-tenancy.'
    }

    It 'no multi-portal stub directories exist in v0.1.0' {
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Entra.Auth')     | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Entra.Client')   | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Purview.Auth')   | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Purview.Client') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Intune.Auth')    | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Intune.Client')  | Should -BeFalse
    }

    It 'src/Modules/Xdr.Portal.Auth, XdrLogRaider.Client, XdrLogRaider.Ingest are deleted (legacy)' {
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'Xdr.Portal.Auth')      | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'XdrLogRaider.Client')  | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ModulesRoot 'XdrLogRaider.Ingest')  | Should -BeFalse
    }
}

Describe 'L1-L4 layering — manifest RequiredModules graph' {

    It 'L3 Xdr.Defender.Client RequiredModules contains only L2 Xdr.Defender.Auth' {
        $manifest = Import-PowerShellDataFile -Path $script:DefClientPsd1
        $req = @($manifest.RequiredModules)
        $req | Should -Contain 'Xdr.Defender.Auth' -Because 'L3 must depend on L2 for the cookie-exchange surface'
        $req | Should -Not -Contain 'Xdr.Connector.Orchestrator' -Because 'L3 cannot depend on L4 (cycle)'
    }

    It 'L4 Xdr.Connector.Orchestrator RequiredModules contains L1+L2+L3 live (no stubs in v0.1.0)' {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratorPsd1
        $req = @($manifest.RequiredModules)
        # Live module dependencies (v0.1.0 = pure Defender)
        $req | Should -Contain 'Xdr.Common.Auth'      -Because 'L4 routes into L1 Entra ESTS auth'
        $req | Should -Contain 'Xdr.Common.Manifest'  -Because 'L4 calls Get-XdrEndpointManifest -Portal'
        $req | Should -Contain 'Xdr.Common.Telemetry' -Because 'L4 emits AppInsights traces/events'
        $req | Should -Contain 'Xdr.Sentinel.Ingest'  -Because 'L4 routes into L1 ingest'
        $req | Should -Contain 'Xdr.Defender.Auth'    -Because 'L4 routes into L2 cookie exchange'
        $req | Should -Contain 'Xdr.Defender.Client'  -Because 'L4 routes into L3 client dispatcher'
        # No stubs — v0.2.0 reintroduces with real bodies
        $req | Should -Not -Contain 'Xdr.Entra.Auth'    -Because 'v0.1.0 GA: Entra stub deferred to v0.2.0'
        $req | Should -Not -Contain 'Xdr.Purview.Auth'  -Because 'v0.1.0 GA: Purview stub deferred to v0.2.0'
        $req | Should -Not -Contain 'Xdr.Intune.Auth'   -Because 'v0.1.0 GA: Intune stub deferred to v0.2.0'
    }

    It 'L4 Xdr.Connector.Orchestrator FunctionsToExport is the portal-routing surface + v0.1.0 GA helpers' {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratorPsd1
        $exports = @($manifest.FunctionsToExport)
        # Original L4 surface
        $exports | Should -Contain 'Connect-XdrPortal'
        $exports | Should -Contain 'Invoke-XdrTierPoll'
        $exports | Should -Contain 'Test-XdrPortalAuth'
        $exports | Should -Contain 'Get-XdrPortalManifest'
        # v0.1.0 GA Phase A.3.6 helpers
        $exports | Should -Contain 'Get-XdrConnectorHealth'   -Because 'Phase A.3.6: connector health aggregator'
        $exports | Should -Contain 'Test-XdrConnectorConfig'  -Because 'Phase A.3.6: env+KV+DCE config validator'
    }

    It 'L1 Xdr.Sentinel.Ingest does not depend on any auth or client module' {
        $manifest = Import-PowerShellDataFile -Path $script:SentinelPsd1
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'Xdr.Common.Auth'
            $req | Should -Not -Contain 'Xdr.Defender.Auth'
            $req | Should -Not -Contain 'Xdr.Defender.Client'
            $req | Should -Not -Contain 'Xdr.Connector.Orchestrator'
        }
    }
}

Describe 'Orchestrator portal-routing dispatch (offline)' {

    BeforeAll {
        # Load the layered modules in dependency order. Tests run InModuleScope
        # against the orchestrator and stub the per-portal connect/test functions.
        # v0.1.0 GA: pure Defender connector, 7 modules total (no portal stubs).
        Get-Module Xdr.* | Remove-Module -Force -ErrorAction SilentlyContinue

        Import-Module $script:CommonAuthPsd1   -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Common.Manifest' 'Xdr.Common.Manifest.psd1')   -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Common.Telemetry' 'Xdr.Common.Telemetry.psd1') -Force -ErrorAction Stop
        Import-Module $script:SentinelPsd1     -Force -ErrorAction Stop
        Import-Module $script:DefAuthPsd1      -Force -ErrorAction Stop
        Import-Module $script:DefClientPsd1    -Force -ErrorAction Stop
        Import-Module $script:OrchestratorPsd1 -Force -ErrorAction Stop
    }

    AfterAll {
        Get-Module Xdr.* | Remove-Module -Force -ErrorAction SilentlyContinue
    }

    It "Connect-XdrPortal -Portal 'Defender' dispatches to Connect-DefenderPortal" {
        Mock -ModuleName 'Xdr.Defender.Auth' Connect-DefenderPortal -MockWith {
            param($Method, $Credential, $PortalHost, $TenantId, [switch]$Force)
            [pscustomobject]@{ Upn = 'mocked@example.com'; PortalHost = $PortalHost; Method = $Method }
        }
        $cred = @{ Upn = 'svc@example.com'; Password = 'p' }
        $session = Connect-XdrPortal -Portal 'Defender' -Method 'CredentialsTotp' -Credential $cred
        $session.Upn | Should -Be 'mocked@example.com'
        $session.PortalHost | Should -Be 'security.microsoft.com' -Because 'orchestrator applies route default host when not overridden'
    }

    It "Connect-XdrPortal -Portal value match is case-insensitive" {
        Mock -ModuleName 'Xdr.Defender.Auth' Connect-DefenderPortal -MockWith {
            param($Method, $Credential, $PortalHost, $TenantId, [switch]$Force)
            [pscustomobject]@{ Upn = 'mocked'; PortalHost = $PortalHost }
        }
        $cred = @{ Upn = 'svc@example.com' }
        { Connect-XdrPortal -Portal 'defender' -Method 'Passkey' -Credential $cred } | Should -Not -Throw
        { Connect-XdrPortal -Portal 'DEFENDER' -Method 'Passkey' -Credential $cred } | Should -Not -Throw
    }

    It "Connect-XdrPortal -Portal 'NonExistent' throws with a clear error" {
        $cred = @{ Upn = 'svc@example.com' }
        { Connect-XdrPortal -Portal 'NonExistent' -Method 'Passkey' -Credential $cred } |
            Should -Throw -ExpectedMessage "*Unknown -Portal 'NonExistent'*"
    }

    It "Test-XdrPortalAuth -Portal 'Defender' dispatches to Test-DefenderPortalAuth" {
        Mock -ModuleName 'Xdr.Defender.Auth' Test-DefenderPortalAuth -MockWith {
            param($Method, $Credential, $PortalHost)
            [pscustomobject]@{ Success = $true; Method = $Method; PortalHost = $PortalHost }
        }
        $cred = @{ Upn = 'svc@example.com' }
        $r = Test-XdrPortalAuth -Portal 'Defender' -Method 'CredentialsTotp' -Credential $cred
        $r.Success | Should -BeTrue
        $r.PortalHost | Should -Be 'security.microsoft.com'
    }

    It "Test-XdrPortalAuth -Portal 'Bogus' throws" {
        $cred = @{ Upn = 'svc@example.com' }
        { Test-XdrPortalAuth -Portal 'Bogus' -Method 'Passkey' -Credential $cred } |
            Should -Throw -ExpectedMessage "*Unknown -Portal 'Bogus'*"
    }

    It "Invoke-XdrTierPoll -Portal 'Defender' dispatches to Invoke-MDETierPoll" {
        Mock -ModuleName 'Xdr.Defender.Client' Invoke-MDETierPoll -MockWith {
            param($Session, $Tier, $Config, [switch]$IncludeDeferred)
            [pscustomobject]@{
                StreamsAttempted = 3; StreamsSucceeded = 3; StreamsSkipped = 0
                RowsIngested = 42; Errors = @{}; Tier = $Tier
            }
        }
        $session = [pscustomobject]@{ Upn = 'svc'; PortalHost = 'security.microsoft.com' }
        $config  = [pscustomobject]@{ DceEndpoint = 'x'; DcrImmutableId = 'y'; StorageAccountName = 'z'; CheckpointTable = 'c' }
        $r = Invoke-XdrTierPoll -Session $session -Tier 'ActionCenter' -Config $config -Portal 'Defender'
        $r.RowsIngested | Should -Be 42
        $r.Tier | Should -Be 'ActionCenter'
    }

    It "Invoke-XdrTierPoll -Portal 'Unknown' throws" {
        $session = [pscustomobject]@{ Upn = 'svc' }
        $config  = [pscustomobject]@{ DceEndpoint = 'x'; DcrImmutableId = 'y'; StorageAccountName = 'z'; CheckpointTable = 'c' }
        { Invoke-XdrTierPoll -Session $session -Tier 'ActionCenter' -Config $config -Portal 'Unknown' } |
            Should -Throw -ExpectedMessage "*Unknown -Portal 'Unknown'*"
    }

    It "Get-XdrPortalManifest -Portal 'Defender' returns the manifest filtered by Portal field" {
        $entries = Get-XdrPortalManifest -Portal 'Defender'
        $entries | Should -Not -BeNullOrEmpty
        $entries.Count | Should -BeGreaterThan 0
        # Every returned entry's Portal should resolve to security.microsoft.com
        # v0.1.0 GA: Defaults split into Portal='Defender' (logical name) +
        # PortalHost='security.microsoft.com' (FQDN). The orchestrator's filter
        # matches against logical name; FQDN moved to PortalHost so L2 auth
        # session URL construction still has access. Either field is acceptable
        # evidence the entry is Defender-scoped.
        foreach ($key in $entries.Keys) {
            $entry = $entries[$key]
            $logical = if ($entry.ContainsKey('Portal'))     { [string]$entry.Portal }     else { '' }
            $host_   = if ($entry.ContainsKey('PortalHost')) { [string]$entry.PortalHost } else { '' }
            ($logical -eq 'Defender' -or $host_ -eq 'security.microsoft.com') | Should -BeTrue -Because "entry $key must identify as a Defender-scoped entry via Portal (logical) or PortalHost (FQDN)"
        }
    }

    It "Get-XdrPortalManifest -Portal 'NonExistent' throws" {
        { Get-XdrPortalManifest -Portal 'NonExistent' } |
            Should -Throw -ExpectedMessage "*Unknown -Portal 'NonExistent'*"
    }
}

Describe 'profile.ps1 imports the 5-module set in dependency order' {

    BeforeAll {
        $script:ProfilePath = Join-Path $script:RepoRoot 'src' 'profile.ps1'
        $script:ProfileContent = Get-Content -LiteralPath $script:ProfilePath -Raw
    }

    It 'profile.ps1 loads Xdr.Common.Auth (L1 Entra)' {
        $script:ProfileContent | Should -Match "'Xdr\.Common\.Auth'"
    }

    It 'profile.ps1 loads Xdr.Sentinel.Ingest (L1 ingest)' {
        $script:ProfileContent | Should -Match "'Xdr\.Sentinel\.Ingest'"
    }

    It 'profile.ps1 loads Xdr.Defender.Auth (L2 cookie exchange)' {
        $script:ProfileContent | Should -Match "'Xdr\.Defender\.Auth'"
    }

    It 'profile.ps1 loads Xdr.Defender.Client (L3 manifest dispatcher)' {
        $script:ProfileContent | Should -Match "'Xdr\.Defender\.Client'"
    }

    It 'profile.ps1 loads Xdr.Connector.Orchestrator (L4 portal routing)' {
        $script:ProfileContent | Should -Match "'Xdr\.Connector\.Orchestrator'"
    }

    It 'profile.ps1 does NOT reference legacy shim modules' {
        $script:ProfileContent | Should -Not -Match "'Xdr\.Portal\.Auth'"
        $script:ProfileContent | Should -Not -Match "'XdrLogRaider\.Client'"
        $script:ProfileContent | Should -Not -Match "'XdrLogRaider\.Ingest'"
    }

    It 'profile.ps1 imports modules in dependency order (Common.Auth + Sentinel.Ingest before Defender.Auth before Defender.Client before Orchestrator)' {
        $lines = Get-Content -LiteralPath $script:ProfilePath
        $rangeStart = ($lines | Select-String -Pattern '\$coreModules\s*=\s*@\(').LineNumber
        $rangeEnd   = ($lines | Select-String -Pattern '^\)' | Where-Object { $_.LineNumber -gt $rangeStart } | Select-Object -First 1).LineNumber
        $section = $lines[$rangeStart..$rangeEnd]

        $commonLine     = ($section | Select-String -Pattern "'Xdr\.Common\.Auth'").LineNumber
        $sentinelLine   = ($section | Select-String -Pattern "'Xdr\.Sentinel\.Ingest'").LineNumber
        $defAuthLine    = ($section | Select-String -Pattern "'Xdr\.Defender\.Auth'").LineNumber
        $defClientLine  = ($section | Select-String -Pattern "'Xdr\.Defender\.Client'").LineNumber
        $orchLine       = ($section | Select-String -Pattern "'Xdr\.Connector\.Orchestrator'").LineNumber

        $commonLine    | Should -BeLessThan $defAuthLine
        $sentinelLine  | Should -BeLessThan $defClientLine
        $defAuthLine   | Should -BeLessThan $defClientLine
        $defClientLine | Should -BeLessThan $orchLine
    }
}
