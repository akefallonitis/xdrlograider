#Requires -Module Pester
# Pure-function coverage for Xdr.Poll helpers · no live HTTP required.
# Exercises Test-ApiproxyPathPrefix + Test-AuthChainHtmlResponse + Test-XdrEndpointAllowedByCapabilities + Clear-XdrCapabilityCache.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Poll/Xdr.Poll.psd1') -Force
}

Describe 'Test-ApiproxyPathPrefix (Gate O validator)' -Tag 'poll-pure' {
    It 'accepts /apiproxy/mtp/... (Defender XDR canonical)' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/mtp/sccManagement/mgmt/TenantContext' | Should -BeTrue
    }
    It 'accepts /apiproxy/admin/... (PortalServices admin surface · nodoc portal_services.yml)' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/admin/Beta/abc-123/InvokeCommand' | Should -BeTrue
    }
    It 'accepts /apiproxy/securityplatform/... (DataLake)' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/securityplatform/lake/databases' | Should -BeTrue
    }
    It 'rejects path without /apiproxy/ prefix' {
        Test-ApiproxyPathPrefix -Path '/api/foo/bar' | Should -BeFalse
    }
    It 'rejects /apiproxy/UNKNOWN-SERVICE/ (not in $script:ValidApiproxyServices)' {
        Test-ApiproxyPathPrefix -Path '/apiproxy/fake-service-name/anything' | Should -BeFalse
    }
}

Describe 'Test-AuthChainHtmlResponse (Reinforcement-B stage-aware classifier)' -Tag 'poll-pure' {
    It 'returns "not-html" for plain JSON content' {
        Test-AuthChainHtmlResponse -Stage 'PortalRequest' -ContentSnippet '{"OrgId":"abc"}' | Should -Be 'not-html'
    }
    It 'returns "expected" for HTML at Authorize stage (login SPA)' {
        Test-AuthChainHtmlResponse -Stage 'Authorize' -ContentSnippet '<!DOCTYPE html><html></html>' | Should -Be 'expected'
    }
    It 'returns "expected" for HTML at KmsiInterrupt stage' {
        Test-AuthChainHtmlResponse -Stage 'KmsiInterrupt' -ContentSnippet '<html>KMSI walker</html>' | Should -Be 'expected'
    }
    It 'returns "broken" for HTML at PortalRequest stage (Reinforcement-B trigger)' {
        Test-AuthChainHtmlResponse -Stage 'PortalRequest' -ContentSnippet '<!DOCTYPE html>' | Should -Be 'broken'
    }
    It 'returns "broken" for HTML at Apiproxy data stage' {
        Test-AuthChainHtmlResponse -Stage 'Apiproxy' -ContentSnippet '<html><body>SPA shell</body></html>' | Should -Be 'broken'
    }
    It 'returns "broken" for HTML at BearerPortalApi stage' {
        Test-AuthChainHtmlResponse -Stage 'BearerPortalApi' -ContentSnippet '<!DOCTYPE html><body></body></html>' | Should -Be 'broken'
    }
    It 'returns "not-html" for empty content snippet' {
        Test-AuthChainHtmlResponse -Stage 'Apiproxy' -ContentSnippet '' | Should -Be 'not-html'
    }
    It 'tolerates leading whitespace before <!DOCTYPE' {
        Test-AuthChainHtmlResponse -Stage 'Apiproxy' -ContentSnippet "   `n  <!DOCTYPE html>" | Should -Be 'broken'
    }
}

Describe 'Test-XdrEndpointAllowedByCapabilities (v0.1.0 BYPASS · v0.2.0 will restore intersection logic)' -Tag 'poll-pure' {
    # Π11 · v0.1.0 BYPASS: function returns $true unconditionally because Discover-XdrPortalCapabilities
    # is a stub (ProductsAvailable=@()) · the real intersection filter would reject all 410 entries
    # with non-empty RequiresProducts (CloudApps · Identity · MDE-licensed sub-areas). Until v0.2.0
    # implements real capability discovery, bypass lets all endpoints attempt naturally · API itself
    # returns 401/403/404 if license-blocked · DLQ catches errors · production tenants' license
    # matrix reveals itself through real API responses.
    It 'v0.1.0 BYPASS · empty RequiresProducts always allowed' {
        $entry = @{ RequiresProducts = @() }
        $caps  = @{ Portals = @{ Defender = @{ ProductsAvailable = @('IsMdatpActive') } } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $caps | Should -BeTrue
    }
    It 'v0.1.0 BYPASS · intersecting RequiresProducts still allowed' {
        $entry = @{ RequiresProducts = @('IsMdatpActive','IsSentinelActive') }
        $caps  = @{ Portals = @{ Defender = @{ ProductsAvailable = @('IsMdatpActive') } } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $caps | Should -BeTrue
    }
    It 'v0.1.0 BYPASS · non-intersecting RequiresProducts ALSO allowed (v0.2.0 will reject)' {
        # Originally asserted $false (license-gated reject). v0.1.0 bypass returns $true.
        # API will naturally reject with 401/403/404 at runtime · DLQ catches errors.
        $entry = @{ RequiresProducts = @('IsDlpActive') }
        $caps  = @{ Portals = @{ Defender = @{ ProductsAvailable = @('IsMdatpActive') } } }
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $caps | Should -BeTrue
    }
    It 'v0.1.0 BYPASS · empty CapabilitySnapshot.ProductsAvailable does NOT block all entries (this is the bug bypass exists to prevent)' {
        # Without bypass: stub Discover returns ProductsAvailable=@() · original filter would have
        # rejected EVERY entry with non-empty RequiresProducts (410/519 entries · operator surprise).
        $entry = @{ RequiresProducts = @('IsMdatpActive') }
        $caps  = @{ Portals = @{ Defender = @{ ProductsAvailable = @() } } }   # stub-empty
        Test-XdrEndpointAllowedByCapabilities -ManifestEntry $entry -CapabilitySnapshot $caps | Should -BeTrue
    }
}

Describe 'Clear-XdrCapabilityCache (test seam)' -Tag 'poll-pure' {
    It 'runs to completion without error' {
        { Clear-XdrCapabilityCache } | Should -Not -Throw
    }
}

Describe 'AuthChainBrokenException class (Reinforcement-B exception type)' -Tag 'poll-pure' {
    It 'is defined within Xdr.Poll module source (psm1)' {
        $psm1 = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'src/Modules/Xdr.Poll/Xdr.Poll.psm1')
        $psm1 | Should -Match 'class\s+AuthChainBrokenException\s*:\s*System\.Exception'
    }
    It 'declares Stage and StatusCode properties' {
        $psm1 = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'src/Modules/Xdr.Poll/Xdr.Poll.psm1')
        $psm1 | Should -Match '\[string\]\$Stage'
        $psm1 | Should -Match '\[int\]\$StatusCode'
    }
}
