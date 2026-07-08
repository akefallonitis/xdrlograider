#Requires -Version 7.4
# F1.4 (operator 2026-06-14 · multi-portal is v0.1.0, not deferred) · THE PORTAL REGISTRY — the keystone that makes
# "add a portal = data, not engine edits." Before this, New-XdrRequestUrl had a 5-name `switch ($portal)` →
# https://<portal>.microsoft.com/apiproxy with `default { throw "Unknown Portal" }`, and the /apiproxy grammar is
# Defender-only (Graph-proxy / SharePoint _api / SecurityCopilot pod-host portals violate it). The registry is ONE
# data structure {BaseUrl, UrlGrammar, AuthMode, PartitionPrefix} keyed by Portal name; New-XdrRequestUrl resolves
# base+grammar through it. Defender's row = the current literals ⇒ the pilot URL is BYTE-IDENTICAL (regen/replay
# stable). Onboarding a portal = a registry row + its catalogue DATA. ADDITIVE · zero pilot behavior change.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
}

Describe 'F1.4 · Portal Registry · the transport URL base/grammar is DATA-driven' {
    It 'PILOT BYTE-IDENTICAL · Defender resolves the exact proven /apiproxy URL (registry Defender row = the literals)' {
        $e = @{ Portal = 'Defender'; SubPortal = 'mtp'; Path = '/actionCenter/actioncenterui/history-actions'
                Pagination = @{ PageIndexQuery = 'pageIndex'; PageSizeQuery = 'pageSize'; PageSize = 50; PageIndexStart = 1 } }
        $u = New-XdrRequestUrl -Entry $e -Window @{} -Page 1
        $u | Should -BeLike 'https://security.microsoft.com/apiproxy/mtp/actionCenter/actioncenterui/history-actions*'
    }
    It 'every registered portal resolves a config row from the registry (the 5 polled portals + AuthMode)' {
        InModuleScope Xdr.Common.Runtime {
            $expectAuth = @{ Defender = 'Cookie'; Purview = 'Cookie'; Entra = 'Bearer'; Intune = 'Bearer'; SecurityCopilot = 'Bearer' }
            foreach ($p in $expectAuth.Keys) {
                $cfg = Get-XdrPortalConfig -Portal $p
                $cfg.BaseUrl  | Should -Match '^https://'
                $cfg.AuthMode | Should -Be $expectAuth[$p] -Because "registry must carry $p's auth mode"
                $cfg.PartitionPrefix | Should -Not -BeNullOrEmpty
            }
        }
    }
    It 'UrlGrammar GENERALIZES beyond /apiproxy (DirectHost → no apiproxy segment · the SPO/pod/Graph class)' {
        InModuleScope Xdr.Common.Runtime {
            (Get-XdrPortalBaseUrl -Config @{ BaseUrl = 'https://security.microsoft.com'; UrlGrammar = 'ApiProxy' })   | Should -Be 'https://security.microsoft.com/apiproxy'
            (Get-XdrPortalBaseUrl -Config @{ BaseUrl = 'https://x-admin.sharepoint.com'; UrlGrammar = 'DirectHost' }) | Should -Be 'https://x-admin.sharepoint.com'
        }
    }
    It 'an UNREGISTERED portal throws the onboard-by-DATA contract (not a silent default)' {
        InModuleScope Xdr.Common.Runtime {
            { Get-XdrPortalConfig -Portal 'NoSuchPortal' } | Should -Throw -ExpectedMessage '*Portal Registry*'
        }
    }
    It 'a NEW registered portal of a non-apiproxy grammar builds its URL with NO engine edit (proves data-only add)' {
        InModuleScope Xdr.Common.Runtime {
            # simulate onboarding a SharePoint-admin-style portal as DATA: add a registry row, build a URL
            $script:XdrPortalRegistry['TestSpo'] = @{ BaseUrl = 'https://contoso-admin.sharepoint.com'; UrlGrammar = 'DirectHost'; AuthMode = 'Bearer'; PartitionPrefix = 'TestSpo' }
            try {
                $cfg = Get-XdrPortalConfig -Portal 'TestSpo'
                (Get-XdrPortalBaseUrl -Config $cfg) | Should -Be 'https://contoso-admin.sharepoint.com'
            } finally { $script:XdrPortalRegistry.Remove('TestSpo') }
        }
    }
}
