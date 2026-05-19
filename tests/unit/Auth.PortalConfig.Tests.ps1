#Requires -Module Pester
# Locks $script:PortalConfig + Get-XdrPortalConfig: 10 sub-portal entries across
# 5 portals. Values ported from xdrlograider-prod/references/_auth-chain.md +
# per-portal Xdr.<Portal>.Auth.psm1 config blocks. L-1 live probe is the next
# verification pass — refinements (e.g. CapabilityEndpoint paths) go back into
# this table and re-run the probe.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\Modules\Xdr.Auth\Xdr.Auth.psd1') -Force
}

Describe 'Get-XdrPortalConfig · 5 portals x 10 sub-portal entries' -Tag 'portal-config' {

    It 'is exported from Xdr.Auth' {
        Get-Command -Module Xdr.Auth -Name 'Get-XdrPortalConfig' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'iterates exactly 10 entries when called with no parameters' {
        @(Get-XdrPortalConfig).Count | Should -Be 10
    }

    It 'covers all 5 portals' {
        $portals = (Get-XdrPortalConfig | Select-Object -ExpandProperty Portal) | Sort-Object -Unique
        $portals | Should -Be @('Defender','Entra','Intune','Purview','SecurityCopilot')
    }

    It 'has exactly 1 Active entry at v0.1.0 (Defender)' {
        $active = @(Get-XdrPortalConfig -ActiveOnly)
        $active.Count          | Should -Be 1
        $active[0].Portal      | Should -Be 'Defender'
        $active[0].AuthProfile | Should -Be 'Cookie'
    }

    It 'classifies AuthProfile as Cookie for Defender + Purview' {
        (Get-XdrPortalConfig -Portal Defender).AuthProfile | Should -Be 'Cookie'
        (Get-XdrPortalConfig -Portal Purview).AuthProfile  | Should -Be 'Cookie'
    }

    It 'classifies AuthProfile as Bearer for Entra + Intune + SecurityCopilot' {
        foreach ($sub in 'IAM','PIM','IDGov','IGA','B2C') {
            (Get-XdrPortalConfig -Portal Entra -SubPortal $sub).AuthProfile | Should -Be 'Bearer'
        }
        foreach ($sub in 'Portal','Autopatch') {
            (Get-XdrPortalConfig -Portal Intune -SubPortal $sub).AuthProfile | Should -Be 'Bearer'
        }
        (Get-XdrPortalConfig -Portal SecurityCopilot).AuthProfile | Should -Be 'Bearer'
    }

    It 'every entry has the fields the bearer + cookie + capability chains need' {
        foreach ($e in (Get-XdrPortalConfig)) {
            $e.Host         | Should -Not -BeNullOrEmpty -Because "entry $($e.Key) needs Host"
            $e.ClientId     | Should -Match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -Because "entry $($e.Key) ClientId must be a GUID"
            $e.Scope        | Should -Not -BeNullOrEmpty
            $e.RedirectUri  | Should -Match '^https?://'   # PublicClient uses http://localhost · SPA uses https://portal.azure.com (A-3b)
            $e.CapabilityEndpoint | Should -Not -BeNullOrEmpty
        }
    }

    It 'every Bearer entry uses v1 OAuth · user_impersonation scope (A-3b · Decision D-38)' {
        foreach ($e in (Get-XdrPortalConfig | Where-Object AuthProfile -eq 'Bearer')) {
            $e.Scope       | Should -Be 'user_impersonation' -Because "entry $($e.Key) bearer uses v1 OAuth scope"
            $e.AuthVersion | Should -Be 'v1'                  -Because "entry $($e.Key) bearer uses v1 OAuth endpoint"
            $e.Resource    | Should -Not -BeNullOrEmpty       -Because "entry $($e.Key) bearer needs Resource (URL or AppId)"
            $e.ClientType  | Should -BeIn @('SPA','PublicClient') -Because "entry $($e.Key) bearer needs ClientType for PKCE+Origin contract"
        }
    }

    It 'every Cookie entry has $null ClientType / AuthVersion / Resource (bearer-specific fields)' {
        foreach ($e in (Get-XdrPortalConfig | Where-Object AuthProfile -eq 'Cookie')) {
            $e.ClientType  | Should -BeNullOrEmpty
            $e.AuthVersion | Should -BeNullOrEmpty
            $e.Resource    | Should -BeNullOrEmpty
        }
    }

    It 'Defender ClientId matches the locked Defender XDR public client (cookie · untouched)' {
        (Get-XdrPortalConfig -Portal Defender).ClientId | Should -Be '80ccca67-54bd-44ab-8625-4b79c4dc7775'
    }

    It 'Entra IAM uses Azure Portal SPA client · v1 OAuth · PKCE+Origin (Decision D-35/D-39 · Bug 8 fix)' {
        $iam = Get-XdrPortalConfig -Portal Entra -SubPortal IAM
        $iam.ClientId     | Should -Be 'c44b4083-3bb0-49c1-b47d-974e53cbdf3c'
        $iam.ClientType   | Should -Be 'SPA'
        $iam.Resource     | Should -Be '74658136-14ec-4630-ad9b-26e160ff0fc6'   # ADIbizaUX AppId · nodoc-canonical
        $iam.RedirectUri  | Should -Be 'https://portal.azure.com/signin/index/'
    }

    It 'Entra PIM/IDGov/IGA/B2C use Azure CLI PublicClient (Bug 14 fix · universal pre-consent)' {
        foreach ($sub in 'PIM','IDGov','IGA','B2C') {
            $e = Get-XdrPortalConfig -Portal Entra -SubPortal $sub
            $e.ClientId    | Should -Be '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
            $e.ClientType  | Should -Be 'PublicClient'
            $e.RedirectUri | Should -Be 'http://localhost'
        }
    }

    It 'Intune sub-portals use Azure CLI PublicClient with correct Resource (Bug 15 fix)' {
        $portal = Get-XdrPortalConfig -Portal Intune -SubPortal Portal
        $portal.ClientId    | Should -Be '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        $portal.ClientType  | Should -Be 'PublicClient'
        $portal.Resource    | Should -Be 'https://api.manage.microsoft.com'    # backend API · NOT intune.microsoft.com (UI)
        $portal.RedirectUri | Should -Be 'http://localhost'

        $autopatch = Get-XdrPortalConfig -Portal Intune -SubPortal Autopatch
        $autopatch.ClientId    | Should -Be '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        $autopatch.Resource    | Should -Be 'https://services.autopatch.microsoft.com'
        $autopatch.RedirectUri | Should -Be 'http://localhost'
    }

    It 'SecurityCopilot uses Azure CLI PublicClient with API Resource' {
        $sc = Get-XdrPortalConfig -Portal SecurityCopilot
        $sc.ClientId    | Should -Be '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
        $sc.ClientType  | Should -Be 'PublicClient'
        $sc.Resource    | Should -Be 'https://api.securitycopilot.microsoft.com'
        $sc.RedirectUri | Should -Be 'http://localhost'
    }

    It 'Intune Autopatch carries the x-ms-* ExtraHeaders nodoc requires' {
        $ap = Get-XdrPortalConfig -Portal Intune -SubPortal Autopatch
        $ap.ExtraHeaders.Keys | Should -Contain 'x-ms-client-request-id'
        $ap.ExtraHeaders.Keys | Should -Contain 'x-ms-client-session-id'
        $ap.ExtraHeaders.Keys | Should -Contain 'x-requested-with'
    }

    It 'Intune Portal carries the full 5 x-ms-* / x-requested-with headers (per v3 evidence)' {
        $p = Get-XdrPortalConfig -Portal Intune -SubPortal Portal
        $p.ExtraHeaders.Keys | Should -Contain 'x-ms-client-request-id'
        $p.ExtraHeaders.Keys | Should -Contain 'x-ms-client-session-id'
        $p.ExtraHeaders.Keys | Should -Contain 'x-ms-effective-locale'
        $p.ExtraHeaders.Keys | Should -Contain 'x-ms-extension-flags'
        $p.ExtraHeaders.Keys | Should -Contain 'x-requested-with'
    }

    It 'SecurityCopilot exposes UiHost distinct from API Host (multi-host routing)' {
        $sc = Get-XdrPortalConfig -Portal SecurityCopilot
        $sc.Host   | Should -Be 'api.securitycopilot.microsoft.com'
        $sc.UiHost | Should -Be 'securitycopilot.microsoft.com'
    }

    It 'Intune Portal Resource correctly targets api.manage.microsoft.com backend (NOT UI host)' {
        # A-3b: v1 OAuth split — Resource is the audience (URL); Scope is `user_impersonation`.
        # Bug 15 root cause: prior config used intune.microsoft.com (UI host) as Resource.
        $p = Get-XdrPortalConfig -Portal Intune -SubPortal Portal
        $p.Resource | Should -Be 'https://api.manage.microsoft.com'
        $p.Host     | Should -Be 'intune.microsoft.com'   # UI host stays as Host · Resource is the API audience
    }

    It 'throws on unknown portal or sub-portal (typo guard)' {
        { Get-XdrPortalConfig -Portal Defender -SubPortal Bogus } | Should -Throw -ExpectedMessage '*unknown*'
        { Get-XdrPortalConfig -Portal Entra -SubPortal Bogus }    | Should -Throw -ExpectedMessage '*unknown*'
    }

    It 'returns sorted iteration order for deterministic output' {
        $keys = (Get-XdrPortalConfig | Select-Object -ExpandProperty Key)
        $keys | Should -Be ($keys | Sort-Object)
    }
}
