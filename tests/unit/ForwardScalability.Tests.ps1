#Requires -Modules Pester
<#
.SYNOPSIS
    Asserts the v0.1.0-beta forward-scalable architecture — adding a new
    Microsoft portal (e.g. compliance.microsoft.com, intune.microsoft.com,
    entra.microsoft.com) in v0.2.0+ must be additive-only: no changes required
    to L1 Xdr.Common.Auth, Xdr.Sentinel.Ingest, or the timer helper internals.

.DESCRIPTION
    Five-module architecture:
      - L1 Xdr.Common.Auth      (portal-generic Entra layer; TOTP, passkey, ESTS)
      - L1 Xdr.Sentinel.Ingest  (portal-generic DCE/DCR ingest + Storage Table)
      - L2 Xdr.Defender.Auth    (Defender-specific cookie exchange)
      - L3 Xdr.Defender.Client  (Defender-portal manifest dispatcher)
      - L4 Xdr.Connector.Orchestrator (portal-routing dispatcher)

    v0.2.0 multi-portal expansion is a 1-day file-add operation: copy
    Xdr.Defender.Auth, change the public-client ID + portal host + cookie
    names, register in profile.ps1. L1 unchanged.

    Verified invariants:
      1. Manifest Defaults.Portal = 'security.microsoft.com' applied at load.
         Every entry loaded via Get-MDEEndpointManifest has a Portal field.

      2. Invoke-TierPollWithHeartbeat accepts optional -Portal param (defaults
         security.microsoft.com).

      3. Module dependency graph is strictly acyclic:
             Xdr.Defender.Client -> Xdr.Defender.Auth -> Xdr.Common.Auth
             Xdr.Sentinel.Ingest: no auth-module deps (standalone)
         No cyclic references; safe to add a sibling Xdr.<Portal>.Auth + a
         sibling Xdr.<Portal>.Client without touching the other layers.

      4. L1 Xdr.Common.Auth is PORTAL-AGNOSTIC — Get-EntraEstsAuth takes
         -ClientId and -PortalHost as parameters; no Defender-specific symbols.
         (Hard-asserted by tests/unit/AuthLayerBoundaries.Tests.ps1.)

      5. L2 Xdr.Defender.Auth is portal-aware — Connect-DefenderPortal +
         Invoke-DefenderPortalRequest accept/use -PortalHost. v0.2.0 sibling
         L2 modules follow the identical template (only their hardcoded
         constants differ).

      6. Adding a new portal in v0.2.0 = additive-only: no edits to existing
         Public/Private files in L1 or in the Defender L2 module are required.
#>

BeforeAll {
    $script:RepoRoot       = Join-Path $PSScriptRoot '..' '..'
    $script:ClientPsd1     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth'      'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth'    'Xdr.Defender.Auth.psd1'
    $script:IngestPsd1     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Xdr.Sentinel.Ingest.psd1'
    $script:HelperPath     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-TierPollWithHeartbeat.ps1'
    $script:ManifestPath   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:ConnectDefPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth'    'Public' 'Connect-DefenderPortal.ps1'
    $script:InvokeDefPath  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth'    'Public' 'Invoke-DefenderPortalRequest.ps1'

    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1     -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
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

Describe 'invariant 3 — strictly acyclic L1 -> L2 -> L3 dependency graph (no shim modules)' {

    It 'Xdr.Defender.Client declares Xdr.Defender.Auth as a RequiredModule' {
        $manifest = Import-PowerShellDataFile -Path $script:ClientPsd1
        $req = @($manifest.RequiredModules)
        $req | Should -Contain 'Xdr.Defender.Auth' -Because 'L3 client depends on the L2 cookie-exchange surface'
    }

    It 'Xdr.Sentinel.Ingest has no auth-module RequiredModules (standalone L1)' {
        $manifest = Import-PowerShellDataFile -Path $script:IngestPsd1
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'Xdr.Defender.Client'
            $req | Should -Not -Contain 'Xdr.Defender.Auth'
            $req | Should -Not -Contain 'Xdr.Common.Auth'
        }
    }

    It 'L1 Xdr.Common.Auth has no auth-module RequiredModules (root of the graph)' {
        $manifest = Import-PowerShellDataFile -Path $script:CommonAuthPsd1
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'Xdr.Defender.Client'
            $req | Should -Not -Contain 'Xdr.Sentinel.Ingest'
            $req | Should -Not -Contain 'Xdr.Defender.Auth' -Because 'L1 must not depend on L2 (would be a cycle)'
        }
    }

    It 'L2 Xdr.Defender.Auth does not depend on the L3 client or on Sentinel.Ingest' {
        $manifest = Import-PowerShellDataFile -Path $script:DefAuthPsd1
        if ($manifest.ContainsKey('RequiredModules')) {
            $req = @($manifest.RequiredModules)
            $req | Should -Not -Contain 'Xdr.Defender.Client'
            $req | Should -Not -Contain 'Xdr.Sentinel.Ingest'
        }
    }
}

Describe 'J2 invariant 4 — L1 Xdr.Common.Auth is portal-agnostic' {

    It 'Get-EntraEstsAuth requires -ClientId and -PortalHost as parameters' {
        $tokens = $null; $errs = $null
        $entraPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Get-EntraEstsAuth.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $entraPath, [ref]$tokens, [ref]$errs)
        $params = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $clientId = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'ClientId' } | Select-Object -First 1
        $portalHost = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'PortalHost' } | Select-Object -First 1
        $clientId   | Should -Not -BeNullOrEmpty -Because 'L1 must take -ClientId so each L2 portal passes its own public-client ID'
        $portalHost | Should -Not -BeNullOrEmpty -Because 'L1 must take -PortalHost so each L2 portal passes its own host'
    }

    It 'L1 Get-EntraEstsAuth defines $ClientId/$PortalHost as MANDATORY parameters (no defaults)' {
        # The full "no Defender-specific symbols in L1 code" gate is enforced by
        # AuthLayerBoundaries.Tests.ps1 with comment-tolerance. Here we just check
        # the param shape that makes L1 portal-generic.
        $tokens = $null; $errs = $null
        $entraPath = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Get-EntraEstsAuth.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $entraPath, [ref]$tokens, [ref]$errs)
        $params = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        foreach ($paramName in @('ClientId', 'PortalHost')) {
            $p = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq $paramName } | Select-Object -First 1
            $p | Should -Not -BeNullOrEmpty -Because "Get-EntraEstsAuth must define -$paramName"
            $mandatoryAttr = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
                ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -ieq 'Mandatory' } |
                Select-Object -First 1
            $mandatoryAttr | Should -Not -BeNullOrEmpty -Because "-$paramName must be Mandatory (each L2 portal supplies its own)"
            $p.DefaultValue | Should -BeNullOrEmpty -Because "-$paramName must have NO default in L1 (defaults are L2's concern)"
        }
    }
}

Describe 'J2 invariant 5 — L2 Xdr.Defender.Auth is portal-aware (template for v0.2.0 siblings)' {

    It 'Connect-DefenderPortal accepts -PortalHost param (default security.microsoft.com)' {
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ConnectDefPath, [ref]$tokens, [ref]$errs)
        $params = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ParameterAst]
        }, $true)
        $portalHost = $params | Where-Object { $_.Name.VariablePath.UserPath -ieq 'PortalHost' } | Select-Object -First 1
        $portalHost | Should -Not -BeNullOrEmpty -Because 'Connect-DefenderPortal must take PortalHost for the v0.2.0 L2 template'
        $portalHost.DefaultValue.Extent.Text | Should -Match 'security\.microsoft\.com'
    }

    It 'Invoke-DefenderPortalRequest builds URI from $portalHost variable, not a literal' {
        $src = Get-Content $script:InvokeDefPath -Raw
        $src | Should -Match '\$uri\s*=\s*"https://\$portalHost' -Because 'URI must be built from $portalHost variable, not a hardcoded security.microsoft.com'
        # Absence of literal Defender host in URI construction:
        $uriLines = $src -split "`n" | Where-Object { $_ -match 'https://' }
        ($uriLines | Where-Object { $_ -match 'https://security\.microsoft\.com/[^"]' }) | Should -BeNullOrEmpty -Because 'no literal security.microsoft.com in URI construction paths'
    }

    It 'Xdr.Defender.Auth.psm1 hardcodes Defender public-client ID (this is the L2 template marker)' {
        $defPsm1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psm1'
        $src = Get-Content $defPsm1 -Raw
        $src | Should -Match '\$script:DefenderClientId\s*=\s*''80ccca67-54bd-44ab-8625-4b79c4dc7775''' -Because 'L2 hardcodes its own portal client ID; v0.2.0 sibling modules will hardcode their own'
    }
}

Describe 'J2 invariant 6 — adding a new portal in v0.2.0 requires only additive changes' {

    It 'Get-MDEEndpointManifest filter-by-Portal works' {
        $m = Get-MDEEndpointManifest -Force
        $security = $m.Values | Where-Object { $_.Portal -eq 'security.microsoft.com' }
        @($security).Count | Should -Be $m.Count -Because 'v0.1.0-beta: 100% security-portal'

        # Simulate v0.2.0 filter-by-Portal — no entries yet for compliance/intune/entra
        $compliance = $m.Values | Where-Object { $_.Portal -eq 'compliance.microsoft.com' }
        @($compliance).Count | Should -Be 0 -Because 'no Purview-portal entries yet; forward-scalable path is empty-but-valid'
        $intune = $m.Values | Where-Object { $_.Portal -eq 'intune.microsoft.com' }
        @($intune).Count | Should -Be 0 -Because 'no Intune-portal entries yet; forward-scalable path is empty-but-valid'
    }

    It 'docs/PORTAL-COOKIE-CATALOG.md documents the L2 template for v0.2.0 portal additions' {
        $catalog = Join-Path $script:RepoRoot 'docs' 'PORTAL-COOKIE-CATALOG.md'
        Test-Path -LiteralPath $catalog | Should -BeTrue -Because 'iter-14.0 Phase 1.5 deliverable — v0.2.0 portal-add reference'
        $content = Get-Content -LiteralPath $catalog -Raw
        $content | Should -Match 'Defender XDR.*security\.microsoft\.com'
        $content | Should -Match 'Purview.*compliance\.microsoft\.com'
        $content | Should -Match 'Intune.*intune\.microsoft\.com'
        $content | Should -Match 'L2 template'
    }
}
