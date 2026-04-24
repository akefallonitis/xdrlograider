#Requires -Modules Pester
<#
.SYNOPSIS
    Asserts the v0.1.0-beta J2 forward-scalable architecture — adding a new
    Microsoft portal (e.g. admin.microsoft.com, entra.microsoft.com) in v0.2.0+
    must be additive-only: no changes required to Xdr.Portal.Auth,
    XdrLogRaider.Ingest, or the timer helper internals.

.DESCRIPTION
    Verifies four invariants that make the connector safe to extend:

      1. Manifest Defaults.Portal = 'security.microsoft.com' applied at load.
         Every entry loaded via Get-MDEEndpointManifest has a Portal field
         regardless of whether the entry declared one.

      2. Invoke-TierPollWithHeartbeat accepts optional -Portal param (defaults
         security.microsoft.com). New portals can reuse the helper with zero
         signature change.

      3. Module dependency graph is strictly acyclic:
             XdrLogRaider.Client -> Xdr.Portal.Auth
             XdrLogRaider.Ingest: no module deps (standalone)
         No cyclic references; safe to add a sibling XdrLogRaider.*.Client
         for other portals without touching Auth/Ingest.

      4. Xdr.Portal.Auth is portal-agnostic — takes -PortalHost on
         Connect-MDEPortal and all request primitives. No hard-coded
         security.microsoft.com in the auth chain except as a default.
#>

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:ClientPsd1   = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client'  'XdrLogRaider.Client.psd1'
    $script:AuthPsd1     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth'      'Xdr.Portal.Auth.psd1'
    $script:IngestPsd1   = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Ingest'  'XdrLogRaider.Ingest.psd1'
    $script:HelperPath   = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client'  'Public' 'Invoke-TierPollWithHeartbeat.ps1'
    $script:ManifestPath = Join-Path $script:RepoRoot 'src' 'Modules' 'XdrLogRaider.Client'  'endpoints.manifest.psd1'
    $script:ConnectPath  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth'      'Public' 'Connect-MDEPortal.ps1'

    Import-Module $script:AuthPsd1   -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1 -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module XdrLogRaider.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Portal.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'J2 invariant 1 — manifest Defaults.Portal applied at load' {

    It 'manifest declares a Defaults.Portal value' {
        $raw = Import-PowerShellDataFile -Path $script:ManifestPath
        $raw.Defaults | Should -Not -BeNullOrEmpty
        $raw.Defaults.Portal | Should -Be 'security.microsoft.com'
    }

    It 'every loaded manifest entry has a Portal field (default applied if missing)' {
        $m = Get-MDEEndpointManifest -Force
        $m.Count | Should -BeGreaterThan 0
        foreach ($stream in $m.Keys) {
            $entry = $m[$stream]
            $entry.ContainsKey('Portal') | Should -BeTrue -Because "entry $stream must have Portal after loader default applied"
            $entry.Portal | Should -Not -BeNullOrEmpty
        }
    }

    It 'v0.1.0-beta every entry resolves to security.microsoft.com (single-portal)' {
        $m = Get-MDEEndpointManifest -Force
        $portals = $m.Values | ForEach-Object { $_.Portal } | Sort-Object -Unique
        $portals | Should -Be @('security.microsoft.com') -Because 'v0.1.0-beta scope is security portal only; v0.2.0 adds others'
    }
}

Describe 'J2 invariant 2 — Invoke-TierPollWithHeartbeat helper accepts optional -Portal' {

    BeforeAll {
        $tokens = $null; $errs = $null
        $script:HelperAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:HelperPath, [ref]$tokens, [ref]$errs)
    }

    It 'parses without errors' {
        $script:HelperAst | Should -Not -BeNullOrEmpty
    }

    It 'param block includes -Portal' {
        $params = $script:HelperAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $portal = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'Portal' } | Select-Object -First 1
        $portal | Should -Not -BeNullOrEmpty -Because 'helper must accept -Portal so v0.2.0+ timers pass non-default portals'
    }

    It 'Portal param default is security.microsoft.com' {
        $params = $script:HelperAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $portal = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'Portal' } | Select-Object -First 1
        $portal.DefaultValue | Should -Not -BeNullOrEmpty
        $portal.DefaultValue.Extent.Text | Should -Match 'security\.microsoft\.com'
    }

    It 'Portal param is not Mandatory (stays zero-config for v0.1.0)' {
        $params = $script:HelperAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $portal = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'Portal' } | Select-Object -First 1
        $mandatoryAttr = $portal.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -ieq 'Mandatory' } |
            Select-Object -First 1
        if ($mandatoryAttr) {
            $mandatoryAttr.Argument.Extent.Text | Should -Not -Match 'true'
        }
    }
}

Describe 'J2 invariant 3 — strictly acyclic module dependency graph' {

    It 'XdrLogRaider.Client declares RequiredModules = Xdr.Portal.Auth' {
        $manifest = Import-PowerShellDataFile -Path $script:ClientPsd1
        $req = @($manifest.RequiredModules)
        $req | Should -Contain 'Xdr.Portal.Auth' -Because 'client depends on auth'
    }

    It 'XdrLogRaider.Ingest has no RequiredModules (portal-agnostic leaf)' {
        $manifest = Import-PowerShellDataFile -Path $script:IngestPsd1
        # Ingest may either omit RequiredModules entirely or declare an empty array
        # Accept both; what we reject is any forward-dependency on Client or Auth.
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'XdrLogRaider.Client'
            $req | Should -Not -Contain 'Xdr.Portal.Auth'
        }
    }

    It 'Xdr.Portal.Auth has no RequiredModules (root of the graph)' {
        $manifest = Import-PowerShellDataFile -Path $script:AuthPsd1
        # Must be a pure leaf with respect to the connector modules — no cyclic
        # or forward deps. May declare Az.* at runtime but those are ambient.
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'XdrLogRaider.Client'
            $req | Should -Not -Contain 'XdrLogRaider.Ingest'
        }
    }
}

Describe 'J2 invariant 4 — Xdr.Portal.Auth is portal-agnostic' {

    It 'Connect-MDEPortal accepts -PortalHost param (not hardcoded security.microsoft.com)' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ConnectPath, [ref]$tokens, [ref]$errs)
        $params = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $portalHost = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'PortalHost' } | Select-Object -First 1
        $portalHost | Should -Not -BeNullOrEmpty -Because 'Connect-MDEPortal must take PortalHost param so v0.2.0 portals reuse the auth chain'
    }

    It 'Invoke-MDEPortalRequest uses $portalHost variable not literal string' {
        $reqPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Portal.Auth' 'Public' 'Invoke-MDEPortalRequest.ps1'
        $src = Get-Content $reqPath -Raw
        $src | Should -Match '\$uri\s*=\s*"https://\$portalHost' -Because 'URI must be built from $portalHost variable, not a hardcoded security.microsoft.com'
        # Absence of hardcoded literal in URI construction:
        $uriLines = $src -split "`n" | Where-Object { $_ -match 'https://' }
        ($uriLines | Where-Object { $_ -match 'https://security\.microsoft\.com/[^"]' }) | Should -BeNullOrEmpty -Because 'no literal security.microsoft.com in URI construction paths'
    }
}

Describe 'J2 invariant 5 — adding a new portal in v0.2.0 requires only additive changes' {

    It 'Get-MDEEndpointManifest filter-by-Portal works' {
        $m = Get-MDEEndpointManifest -Force
        $security = $m.Values | Where-Object { $_.Portal -eq 'security.microsoft.com' }
        @($security).Count | Should -Be $m.Count -Because 'v0.1.0-beta: 100% security-portal'

        # Simulate v0.2.0 filter-by-Portal — no entries yet for admin, should be 0
        $admin = $m.Values | Where-Object { $_.Portal -eq 'admin.microsoft.com' }
        @($admin).Count | Should -Be 0 -Because 'no admin-portal entries yet; forward-scalable path is empty-but-valid'
    }
}
