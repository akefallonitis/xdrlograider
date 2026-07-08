# Multi-portal Pester dispatch test
# Proves Connect-XdrPortal -Portal X returns a session for ALL 5 portals via mocked HTTP.
#
# Discipline rule 6 (memory feedback_xdr_lograider_skillset.md):
#   Connect-XdrPortal is the SINGLE generic entry point · all 5 handlers register at module load
#   Cookie session (Sccauth) for Defender/Purview · Bearer session (AccessToken) for Entra/Intune/SecCop.

#Requires -Module Pester

BeforeAll {
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    $env:XDRLR_SERVICE_ACCOUNT_UPN = 'svc@xdrtest.local'

    # Import in deterministic order (alphabetical · same as prod profile.ps1)
    $modOrder = @(
        'Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache',
        'Xdr.Common.Auth','Xdr.Common.OAuthBearer',
        'Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Capabilities','Xdr.Common.Runtime',
        'Xdr.Defender.Auth','Xdr.Entra.Auth','Xdr.Intune.Auth','Xdr.Purview.Auth','Xdr.SecurityCopilot.Auth'
    )
    foreach ($m in $modOrder) {
        $psd1 = Join-Path $modulesRoot.Path "$m\$m.psd1"
        Import-Module $psd1 -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'Connect-XdrPortal · 5-portal dispatch' {

    BeforeEach {
        # Mocks · NO real HTTP fired
        Mock -CommandName Get-XdrCredentials -ModuleName Xdr.Common.Auth -MockWith {
            @{ UPN = 'svc@xdrtest.local'; Password = 'p'; TenantId = '00000000-0000-0000-0000-000000000001' }
        }
        Mock -CommandName Get-XdrCachedSession -ModuleName Xdr.Common.Auth -MockWith { $null }
        Mock -CommandName Save-XdrSession -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Lock-XdrSingleFlight -ModuleName Xdr.Common.Auth -MockWith { 'lease-token-aaa' }
        Mock -CommandName Unlock-XdrSingleFlight -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Invalidate-XdrCache -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Test-XdrSessionAlive -ModuleName Xdr.Common.Auth -MockWith { $true }
        Mock -CommandName Track-XdrEvent -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Track-XdrException -ModuleName Xdr.Common.Auth -MockWith { }
    }

    Context 'Defender (cookie path)' {
        It 'returns session with Sccauth' {
            Mock -CommandName Connect-DefenderPortal -ModuleName Xdr.Defender.Auth -MockWith {
                @{ Sccauth = 'fake-sccauth-aaa'; SccauthExpiryUtc = ([DateTime]::UtcNow.AddHours(2)).ToString('o'); UPN = 'svc@xdrtest.local'; Portal = 'Defender' }
            }
            $session = Connect-XdrPortal -Portal 'Defender'
            $session | Should -Not -BeNullOrEmpty
            $session.Sccauth | Should -Be 'fake-sccauth-aaa'
            $session.Portal | Should -Be 'Defender'
        }
    }

    Context 'Entra (bearer path)' {
        It 'returns session with AccessToken via Get-XdrOAuthToken mock' {
            Mock -CommandName Get-XdrOAuthToken -ModuleName Xdr.Entra.Auth -MockWith {
                @{ AccessToken = 'eyJfake.entra.bearer'; ExpiresUtc = ([DateTime]::UtcNow.AddHours(1)).ToString('o'); TokenType = 'Bearer'; Audience = $Audience; UPN = $Credentials.UPN; Portal = 'Entra'; SubPortal = $SubPortal }
            }
            $session = Connect-XdrPortal -Portal 'Entra'
            $session | Should -Not -BeNullOrEmpty
            $session.AccessToken | Should -Be 'eyJfake.entra.bearer'
            $session.Portal | Should -Be 'Entra'
        }
    }

    Context 'Intune (bearer path)' {
        It 'returns session with AccessToken' {
            Mock -CommandName Get-XdrOAuthToken -ModuleName Xdr.Intune.Auth -MockWith {
                @{ AccessToken = 'eyJfake.intune.bearer'; ExpiresUtc = ([DateTime]::UtcNow.AddHours(1)).ToString('o'); TokenType = 'Bearer'; Audience = $Audience; UPN = $Credentials.UPN; Portal = 'Intune'; SubPortal = $SubPortal }
            }
            $session = Connect-XdrPortal -Portal 'Intune'
            $session | Should -Not -BeNullOrEmpty
            $session.AccessToken | Should -Be 'eyJfake.intune.bearer'
            $session.Portal | Should -Be 'Intune'
        }
    }

    Context 'SecurityCopilot (bearer path)' {
        It 'returns session with AccessToken' {
            Mock -CommandName Get-XdrOAuthToken -ModuleName Xdr.SecurityCopilot.Auth -MockWith {
                @{ AccessToken = 'eyJfake.seccop.bearer'; ExpiresUtc = ([DateTime]::UtcNow.AddHours(1)).ToString('o'); TokenType = 'Bearer'; Audience = $Audience; UPN = $Credentials.UPN; Portal = 'SecurityCopilot'; SubPortal = $SubPortal }
            }
            $session = Connect-XdrPortal -Portal 'SecurityCopilot'
            $session | Should -Not -BeNullOrEmpty
            $session.AccessToken | Should -Be 'eyJfake.seccop.bearer'
            $session.Portal | Should -Be 'SecurityCopilot'
        }
    }

    Context 'Purview (cookie path · §35.16 · real cookie-OIDC · auth-verified · not polled in v0.1.0)' {
        It 'returns a Purview cookie session via the shared (host-parameterized) cookie-OIDC chain' {
            $ws = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Mock -CommandName Get-XdrEntraEstsAuth   -ModuleName Xdr.Purview.Auth -MockWith { [pscustomobject]@{ Session = $ws; FinalHtml = '<form action="x">'; KmsiAccepted = $true; TenantIdCandidates = @('t'); Upn = 'svc@xdrtest.local' } }
            Mock -CommandName Submit-XdrAuthFormPost -ModuleName Xdr.Purview.Auth -MockWith { $null }
            Mock -CommandName Get-XdrDefenderSccauth -ModuleName Xdr.Purview.Auth -MockWith { @{ Sccauth = 'scc-purview'; XsrfToken = 'x'; TenantId = 't'; TenantIdSource = 'ests'; AcquiredUtc = ([DateTime]::UtcNow).ToString('o') } }
            Mock -CommandName Get-XdrCookieExpiry    -ModuleName Xdr.Purview.Auth -MockWith { [pscustomobject]@{ ExpiresUtc = ([DateTime]::UtcNow.AddHours(2)); KmsiExpiresUtc = ([DateTime]::UtcNow.AddDays(90)); EarliestExpirySource = 'sccauth' } }
            Mock -CommandName Get-XdrKmsiCookieValue -ModuleName Xdr.Purview.Auth -MockWith { 'kmsi-purview' }
            $session = Connect-XdrPortal -Portal 'Purview'
            $session | Should -Not -BeNullOrEmpty
            $session.Portal | Should -Be 'Purview'
            $session.Sccauth | Should -Be 'scc-purview'
            $session.KmsiCookie | Should -Be 'kmsi-purview'
        }
    }

    Context 'Unknown portal' {
        It 'throws No handler registered' {
            { Connect-XdrPortal -Portal 'BogusPortal' } | Should -Throw '*No handler registered*'
        }
    }

    Context 'All 5 portal handlers registered at module load' {
        It 'PortalHandlers script-scope contains all 5 entries' {
            $handlers = & (Get-Module Xdr.Common.Auth) { $script:PortalHandlers }
            $handlers.Keys.Count | Should -BeGreaterOrEqual 5
            $handlers.ContainsKey('Defender')        | Should -BeTrue
            $handlers.ContainsKey('Entra')           | Should -BeTrue
            $handlers.ContainsKey('Intune')          | Should -BeTrue
            $handlers.ContainsKey('SecurityCopilot') | Should -BeTrue
            $handlers.ContainsKey('Purview')         | Should -BeTrue
        }
    }
}

Describe 'Connect-XdrPortal · session validation gate' {

    BeforeEach {
        Mock -CommandName Get-XdrCredentials -ModuleName Xdr.Common.Auth -MockWith { @{ UPN = 'svc@x.local'; Password = 'p' } }
        Mock -CommandName Get-XdrCachedSession -ModuleName Xdr.Common.Auth -MockWith { $null }
        Mock -CommandName Save-XdrSession -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Lock-XdrSingleFlight -ModuleName Xdr.Common.Auth -MockWith { 'tok' }
        Mock -CommandName Unlock-XdrSingleFlight -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Invalidate-XdrCache -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Test-XdrSessionAlive -ModuleName Xdr.Common.Auth -MockWith { $true }
        Mock -CommandName Track-XdrEvent -ModuleName Xdr.Common.Auth -MockWith { }
        Mock -CommandName Track-XdrException -ModuleName Xdr.Common.Auth -MockWith { }
    }

    It 'accepts session with Sccauth (cookie family)' {
        Register-XdrPortalHandler -Portal 'CookieTest' -Handler { @{ Sccauth = 'x'; SccauthExpiryUtc = ([DateTime]::UtcNow.AddHours(2)).ToString('o') } }
        { Connect-XdrPortal -Portal 'CookieTest' } | Should -Not -Throw
    }

    It 'accepts session with Cookie (legacy alias)' {
        Register-XdrPortalHandler -Portal 'LegacyCookie' -Handler { @{ Cookie = 'old-style' } }
        { Connect-XdrPortal -Portal 'LegacyCookie' } | Should -Not -Throw
    }

    It 'accepts session with AccessToken (bearer family)' {
        Register-XdrPortalHandler -Portal 'BearerTest' -Handler { @{ AccessToken = 'y'; ExpiresUtc = ([DateTime]::UtcNow.AddHours(1)).ToString('o') } }
        { Connect-XdrPortal -Portal 'BearerTest' } | Should -Not -Throw
    }

    It 'rejects session missing both Sccauth/Cookie AND AccessToken' {
        Register-XdrPortalHandler -Portal 'EmptyTest' -Handler { @{ Foo = 'bar' } }
        { Connect-XdrPortal -Portal 'EmptyTest' } | Should -Throw '*missing*'
    }

    It 'rejects null session' {
        Register-XdrPortalHandler -Portal 'NullTest' -Handler { $null }
        { Connect-XdrPortal -Portal 'NullTest' } | Should -Throw '*null session*'
    }
}
