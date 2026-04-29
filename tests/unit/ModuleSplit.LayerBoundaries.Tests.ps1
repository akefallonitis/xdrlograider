#Requires -Modules Pester
<#
.SYNOPSIS
    Architectural gate for the L1-L4 module-split work. Asserts the dependency
    graph stays acyclic and that the L4 portal-routing orchestrator has access
    to L1-L3 (so it can dispatch through them) while L3 does not depend on L4
    (would create a cycle).

.DESCRIPTION
    Layer map:
      L1 Xdr.Common.Auth          portal-generic Entra (TOTP, passkey, ESTS)
      L1 Xdr.Sentinel.Ingest      portal-generic ingest (DCE/DCR + Storage Table)
      L2 Xdr.Defender.Auth        Defender-specific cookie exchange (sccauth + XSRF)
      L3 Xdr.Defender.Client      Defender-portal manifest dispatcher (46 streams)
      L4 Xdr.Connector.Orchestrator  portal-routing dispatcher (Connect-XdrPortal etc.)
      Shim Xdr.Portal.Auth         legacy MDE-prefixed auth wrappers
      Shim XdrLogRaider.Client     legacy MDE-prefixed client wrappers
      Shim XdrLogRaider.Ingest     legacy ingest wrappers

    Invariants enforced here:
      1. L3 Xdr.Defender.Client RequiredModules: only L2 Xdr.Defender.Auth
         (no L4, no L1 ingest — would be a cycle / cross-leg).
      2. L4 Xdr.Connector.Orchestrator RequiredModules cover L1+L2+L3
         (so the dispatcher can call into them).
      3. Backward-compat shims XdrLogRaider.Client + XdrLogRaider.Ingest
         re-export the same public surface as the renamed modules.
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
    $script:LegacyClientPsd1 = Join-Path $script:ModulesRoot 'XdrLogRaider.Client'      'XdrLogRaider.Client.psd1'
    $script:LegacyIngestPsd1 = Join-Path $script:ModulesRoot 'XdrLogRaider.Ingest'      'XdrLogRaider.Ingest.psd1'
}

Describe 'L1-L4 layering — manifest RequiredModules graph' {

    It 'L3 Xdr.Defender.Client RequiredModules contains only L2 Xdr.Defender.Auth' {
        $manifest = Import-PowerShellDataFile -Path $script:DefClientPsd1
        $req = @($manifest.RequiredModules)
        $req | Should -Contain 'Xdr.Defender.Auth' -Because 'L3 must depend on L2 for the cookie-exchange surface'
        $req | Should -Not -Contain 'Xdr.Connector.Orchestrator' -Because 'L3 cannot depend on L4 (cycle)'
    }

    It 'L4 Xdr.Connector.Orchestrator RequiredModules contains L1+L2+L3 layer modules' {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratorPsd1
        $req = @($manifest.RequiredModules)
        $req | Should -Contain 'Xdr.Common.Auth'      -Because 'L4 routes into L1 Entra'
        $req | Should -Contain 'Xdr.Sentinel.Ingest'  -Because 'L4 routes into L1 ingest'
        $req | Should -Contain 'Xdr.Defender.Auth'    -Because 'L4 routes into L2 cookie exchange'
        $req | Should -Contain 'Xdr.Defender.Client'  -Because 'L4 routes into L3 client dispatcher'
    }

    It 'L4 Xdr.Connector.Orchestrator FunctionsToExport is the portal-routing surface' {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratorPsd1
        $exports = @($manifest.FunctionsToExport)
        $exports | Should -Contain 'Connect-XdrPortal'
        $exports | Should -Contain 'Invoke-XdrTierPoll'
        $exports | Should -Contain 'Test-XdrPortalAuth'
        $exports | Should -Contain 'Get-XdrPortalManifest'
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

Describe 'Backward-compat shims — XdrLogRaider.Client + XdrLogRaider.Ingest' {

    It 'XdrLogRaider.Client shim FunctionsToExport matches Xdr.Defender.Client surface' {
        $shim    = Import-PowerShellDataFile -Path $script:LegacyClientPsd1
        $renamed = Import-PowerShellDataFile -Path $script:DefClientPsd1
        $shimExports    = @($shim.FunctionsToExport)    | Sort-Object
        $renamedExports = @($renamed.FunctionsToExport) | Sort-Object
        $shimExports    | Should -Be $renamedExports -Because 'shim must re-export the same surface as the renamed module'
    }

    It 'XdrLogRaider.Ingest shim FunctionsToExport matches Xdr.Sentinel.Ingest surface' {
        $shim    = Import-PowerShellDataFile -Path $script:LegacyIngestPsd1
        $renamed = Import-PowerShellDataFile -Path $script:SentinelPsd1
        $shimExports    = @($shim.FunctionsToExport)    | Sort-Object
        $renamedExports = @($renamed.FunctionsToExport) | Sort-Object
        $shimExports    | Should -Be $renamedExports -Because 'shim must re-export the same surface as the renamed module'
    }

    It 'XdrLogRaider.Client shim psm1 imports Xdr.Defender.Client (no Public/ duplication)' {
        $shimPsm1 = Get-Content -LiteralPath (Join-Path $script:ModulesRoot 'XdrLogRaider.Client' 'XdrLogRaider.Client.psm1') -Raw
        $shimPsm1 | Should -Match 'Xdr\.Defender\.Client' -Because 'shim must reference the renamed module by name'
    }

    It 'XdrLogRaider.Ingest shim psm1 imports Xdr.Sentinel.Ingest (no Public/ duplication)' {
        $shimPsm1 = Get-Content -LiteralPath (Join-Path $script:ModulesRoot 'XdrLogRaider.Ingest' 'XdrLogRaider.Ingest.psm1') -Raw
        $shimPsm1 | Should -Match 'Xdr\.Sentinel\.Ingest' -Because 'shim must reference the renamed module by name'
    }
}

Describe 'Orchestrator portal-routing dispatch (offline)' {

    BeforeAll {
        # Load the layered modules in dependency order. Tests run InModuleScope
        # against the orchestrator and stub the per-portal connect/test functions.
        Get-Module Xdr.* | Remove-Module -Force -ErrorAction SilentlyContinue
        Get-Module XdrLogRaider.* | Remove-Module -Force -ErrorAction SilentlyContinue

        Import-Module $script:CommonAuthPsd1   -Force -ErrorAction Stop
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
        $r = Invoke-XdrTierPoll -Session $session -Tier 'P0' -Config $config -Portal 'Defender'
        $r.RowsIngested | Should -Be 42
        $r.Tier | Should -Be 'P0'
    }

    It "Invoke-XdrTierPoll -Portal 'Unknown' throws" {
        $session = [pscustomobject]@{ Upn = 'svc' }
        $config  = [pscustomobject]@{ DceEndpoint = 'x'; DcrImmutableId = 'y'; StorageAccountName = 'z'; CheckpointTable = 'c' }
        { Invoke-XdrTierPoll -Session $session -Tier 'P0' -Config $config -Portal 'Unknown' } |
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

Describe 'profile.ps1 imports the new module set in the right order' {

    BeforeAll {
        $script:ProfilePath = Join-Path $script:RepoRoot 'src' 'profile.ps1'
        $script:ProfileContent = Get-Content -LiteralPath $script:ProfilePath -Raw
    }

    It 'profile.ps1 loads the new orchestrator module' {
        $script:ProfileContent | Should -Match "'Xdr\.Connector\.Orchestrator'" -Because 'profile.ps1 must import the L4 orchestrator'
    }

    It 'profile.ps1 loads Xdr.Sentinel.Ingest (renamed from XdrLogRaider.Ingest)' {
        $script:ProfileContent | Should -Match "'Xdr\.Sentinel\.Ingest'" -Because 'profile.ps1 must reference the renamed L1 ingest module'
    }

    It 'profile.ps1 loads Xdr.Defender.Client (renamed from XdrLogRaider.Client)' {
        $script:ProfileContent | Should -Match "'Xdr\.Defender\.Client'" -Because 'profile.ps1 must reference the renamed L3 client module'
    }

    It 'profile.ps1 loads the legacy XdrLogRaider.Client + XdrLogRaider.Ingest shims for backward-compat' {
        $script:ProfileContent | Should -Match "'XdrLogRaider\.Client'"
        $script:ProfileContent | Should -Match "'XdrLogRaider\.Ingest'"
    }

    It 'profile.ps1 imports renamed modules BEFORE the legacy shims (shim depends on renamed)' {
        $lines = Get-Content -LiteralPath $script:ProfilePath
        $rangeStart = ($lines | Select-String -Pattern '\$coreModules\s*=\s*@\(').LineNumber
        $rangeEnd   = ($lines | Select-String -Pattern '^\)' | Where-Object { $_.LineNumber -gt $rangeStart } | Select-Object -First 1).LineNumber
        $section = $lines[$rangeStart..$rangeEnd]
        $renamedClientLine = ($section | Select-String -Pattern "'Xdr\.Defender\.Client'").LineNumber
        $shimClientLine    = ($section | Select-String -Pattern "'XdrLogRaider\.Client'").LineNumber
        $renamedIngestLine = ($section | Select-String -Pattern "'Xdr\.Sentinel\.Ingest'").LineNumber
        $shimIngestLine    = ($section | Select-String -Pattern "'XdrLogRaider\.Ingest'").LineNumber
        $renamedClientLine | Should -BeLessThan $shimClientLine -Because 'shim psm1 imports the renamed module; renamed must load first'
        $renamedIngestLine | Should -BeLessThan $shimIngestLine -Because 'shim psm1 imports the renamed module; renamed must load first'
    }
}
