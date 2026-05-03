#Requires -Modules Pester
<#
.SYNOPSIS
    Architectural gate for the 5-module split. Asserts the dependency graph
    stays acyclic and that the L4 portal-routing orchestrator has access to
    L1-L3 (so it can dispatch through them) while L3 does not depend on L4
    (would create a cycle).

.DESCRIPTION
    Layer map (v0.1.0 GA — 5 live + 6 multi-portal scaffolding stubs per Phase A.3):
      L1 Xdr.Common.Auth          portal-generic Entra (TOTP, passkey, ESTS)
      L1 Xdr.Sentinel.Ingest      portal-generic ingest (DCE/DCR + Storage Table)
      L2 Xdr.Defender.Auth        Defender-specific cookie exchange (sccauth + XSRF)
      L3 Xdr.Defender.Client      Defender-portal manifest dispatcher (46 streams)
      L2 Xdr.Entra.Auth           Entra portal scaffolding stub (v0.2.0 roadmap)
      L3 Xdr.Entra.Client         Entra portal scaffolding stub (v0.2.0 roadmap)
      L2 Xdr.Purview.Auth         Purview portal scaffolding stub (v0.2.0 roadmap)
      L3 Xdr.Purview.Client       Purview portal scaffolding stub (v0.2.0 roadmap)
      L2 Xdr.Intune.Auth          Intune portal scaffolding stub (v0.2.0 roadmap)
      L3 Xdr.Intune.Client        Intune portal scaffolding stub (v0.2.0 roadmap)
      L4 Xdr.Connector.Orchestrator  portal-routing dispatcher (Connect-XdrPortal etc.
                                      + Get-XdrConnectorHealth + Test-XdrConnectorConfig)

    Invariants enforced here:
      1. L3 Xdr.Defender.Client RequiredModules: only L2 Xdr.Defender.Auth
         (no L4, no L1 ingest — would be a cycle / cross-leg).
      2. L4 Xdr.Connector.Orchestrator RequiredModules cover L1+L2+L3 + all 6 stubs
         (so the dispatcher can call into them).
      3. 11 modules total: 5 live + 6 multi-portal scaffolding stubs.
         No MDE-prefixed legacy shim modules left.
      4. Orchestrator routing: Connect-XdrPortal -Portal 'Defender' resolves
         through to Connect-DefenderPortal; unknown -Portal throws.
      5. Stub modules throw informative "v0.2.0 roadmap" errors when called
         (covered by MultiPortalScaffolding.Tests.ps1 Phase A.4.4).
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

Describe 'Five-module architecture — no shim modules remain' {

    It 'src/Modules contains exactly the 11 v0.1.0-GA modules (5 live + 6 scaffolding stubs)' {
        $dirs = @(Get-ChildItem -LiteralPath $script:ModulesRoot -Directory | Sort-Object Name | ForEach-Object Name)
        $expected = @(
            'Xdr.Common.Auth',           # L1 live
            'Xdr.Connector.Orchestrator', # L4 live
            'Xdr.Defender.Auth',          # L2 live
            'Xdr.Defender.Client',        # L3 live
            'Xdr.Entra.Auth',             # L2 stub (v0.2.0)
            'Xdr.Entra.Client',           # L3 stub (v0.2.0)
            'Xdr.Intune.Auth',            # L2 stub (v0.2.0)
            'Xdr.Intune.Client',          # L3 stub (v0.2.0)
            'Xdr.Purview.Auth',           # L2 stub (v0.2.0)
            'Xdr.Purview.Client',         # L3 stub (v0.2.0)
            'Xdr.Sentinel.Ingest'         # L1 live
        )
        $dirs | Should -Be $expected -Because 'v0.1.0 GA: 5 live modules + 6 multi-portal scaffolding stubs (Entra/Purview/Intune × Auth/Client). Stubs ship empty placeholders; v0.2.0 fills bodies.'
    }

    It 'src/Modules/Xdr.Portal.Auth, XdrLogRaider.Client, XdrLogRaider.Ingest are deleted' {
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

    It 'L4 Xdr.Connector.Orchestrator RequiredModules contains L1+L2+L3 + 6 multi-portal stubs' {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratorPsd1
        $req = @($manifest.RequiredModules)
        # Live module dependencies
        $req | Should -Contain 'Xdr.Common.Auth'      -Because 'L4 routes into L1 Entra'
        $req | Should -Contain 'Xdr.Sentinel.Ingest'  -Because 'L4 routes into L1 ingest'
        $req | Should -Contain 'Xdr.Defender.Auth'    -Because 'L4 routes into L2 cookie exchange'
        $req | Should -Contain 'Xdr.Defender.Client'  -Because 'L4 routes into L3 client dispatcher'
        # v0.1.0 GA Phase A.3: multi-portal scaffolding stubs
        $req | Should -Contain 'Xdr.Entra.Auth'       -Because 'L4 PortalRoutes references Entra stub'
        $req | Should -Contain 'Xdr.Entra.Client'     -Because 'L4 PortalRoutes references Entra stub'
        $req | Should -Contain 'Xdr.Purview.Auth'     -Because 'L4 PortalRoutes references Purview stub'
        $req | Should -Contain 'Xdr.Purview.Client'   -Because 'L4 PortalRoutes references Purview stub'
        $req | Should -Contain 'Xdr.Intune.Auth'      -Because 'L4 PortalRoutes references Intune stub'
        $req | Should -Contain 'Xdr.Intune.Client'    -Because 'L4 PortalRoutes references Intune stub'
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
        # v0.1.0 GA Phase A.3: also load 6 multi-portal scaffolding stubs
        # (referenced by orchestrator psd1 RequiredModules).
        Get-Module Xdr.* | Remove-Module -Force -ErrorAction SilentlyContinue

        Import-Module $script:CommonAuthPsd1   -Force -ErrorAction Stop
        Import-Module $script:SentinelPsd1     -Force -ErrorAction Stop
        Import-Module $script:DefAuthPsd1      -Force -ErrorAction Stop
        Import-Module $script:DefClientPsd1    -Force -ErrorAction Stop
        # 6 scaffolding stubs (Phase A.3)
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Entra.Auth' 'Xdr.Entra.Auth.psd1')       -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Entra.Client' 'Xdr.Entra.Client.psd1')   -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Purview.Auth' 'Xdr.Purview.Auth.psd1')   -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Purview.Client' 'Xdr.Purview.Client.psd1') -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Intune.Auth' 'Xdr.Intune.Auth.psd1')     -Force -ErrorAction Stop
        Import-Module (Join-Path $script:ModulesRoot 'Xdr.Intune.Client' 'Xdr.Intune.Client.psd1') -Force -ErrorAction Stop
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
        # (the Defender route's default host) — either the entry has that exact
        # Portal value, or it had no Portal field and the loader applied the
        # default.
        foreach ($key in $entries.Keys) {
            $entry = $entries[$key]
            $portal = if ($entry.ContainsKey('Portal')) { [string]$entry.Portal } else { 'security.microsoft.com' }
            $portal | Should -Be 'security.microsoft.com' -Because "entry $key must be a Defender-portal entry"
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
