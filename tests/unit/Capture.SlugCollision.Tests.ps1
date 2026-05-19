#Requires -Module Pester
# Capture.SlugCollision.Tests.ps1 · Phase α.3 fix proof
#
# 10 slug collisions in defender.psd1 share Slug across SubAreas:
#   TenantContext           (Configuration, MultiTenant)
#   GetIdentitiesAggregatedData (Identity, MultiTenant)
#   GetIdentitiesCount      (Identity, MultiTenant)
#   GetRecommendations      (AttackSimulator, ExposureManagement)
#   GetSecurityCopilotTrial (MultiTenant, PortalServices)
#   ListChangeEvents        (VulnerabilityManagement × 2)
#   ListIdentities          (Identity, MultiTenant)
#   ListPolicies            (AppGovernance, CloudApps)
#   ListRecommendations     (SentinelPrecision, VulnerabilityManagement)
#   RunHuntingQuery         (ExposureManagement, MultiTenant)
#
# Before α.3: all wrote to tests/fixtures/live/<slug>/ · last-writer-wins.
# After α.3: colliding entries write to tests/fixtures/live/<SubArea>_<slug>/.

BeforeAll {
    $script:repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:capturePath  = Join-Path $script:repoRoot 'tools\Capture-EndpointSchemas.ps1'
    $script:manifestPath = Join-Path $script:repoRoot 'manifests\defender.psd1'
}

Describe 'Capture.SlugCollision · pre-scan detection' -Tag 'capture','slug-collision' {

    It 'manifest has exactly 10 slug collisions across SubAreas' {
        $m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:manifestPath)))
        $collisions = $m.Entries | Group-Object Slug | Where-Object { $_.Count -gt 1 }
        @($collisions).Count | Should -Be 10
    }

    It 'Configuration::TenantContext + MultiTenant::TenantContext both exist (architectural collision risk)' {
        $m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $script:manifestPath)))
        $tcEntries = @($m.Entries | Where-Object { $_.Slug -eq 'TenantContext' })
        $tcEntries.Count | Should -Be 2
        ($tcEntries | ForEach-Object SubArea | Sort-Object -Unique) | Should -Be @('Configuration','MultiTenant')
    }
}

Describe 'Capture.SlugCollision · Get-FixtureDirName helper logic (extracted)' -Tag 'capture','slug-collision' {

    BeforeAll {
        # Extract Get-FixtureDirName via scriptblock isolation (avoids running full Capture)
        $captureContent = Get-Content -Raw -LiteralPath $script:capturePath
        $funcMatch = [regex]::Match($captureContent, '(?ms)^function Get-FixtureDirName.*?^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $funcMatch.Success | Should -BeTrue -Because 'Get-FixtureDirName must be defined in Capture-EndpointSchemas.ps1'
        Invoke-Expression $funcMatch.Value
    }

    It 'returns plain Slug when not in collision set' {
        $collisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $entry = [pscustomobject]@{ Slug = 'UniqueSlug'; SubArea = 'Configuration' }
        Get-FixtureDirName -Entry $entry -Collisions $collisions | Should -Be 'UniqueSlug'
    }

    It 'returns SubArea_Slug when slug is in collision set' {
        $collisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$collisions.Add('TenantContext')
        $cfgEntry = [pscustomobject]@{ Slug = 'TenantContext'; SubArea = 'Configuration' }
        $mtEntry  = [pscustomobject]@{ Slug = 'TenantContext'; SubArea = 'MultiTenant' }
        Get-FixtureDirName -Entry $cfgEntry -Collisions $collisions | Should -Be 'Configuration_TenantContext'
        Get-FixtureDirName -Entry $mtEntry  -Collisions $collisions | Should -Be 'MultiTenant_TenantContext'
    }

    It 'sanitizes non-alphanumeric characters in joined name' {
        $collisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$collisions.Add('Foo')
        $entry = [pscustomobject]@{ Slug = 'Foo'; SubArea = 'Sub Area With Spaces' }
        $r = Get-FixtureDirName -Entry $entry -Collisions $collisions
        $r | Should -Match '^Sub-Area-With-Spaces_Foo$|^Sub_Area_With_Spaces_Foo$|^Sub-Area-With-Spaces-Foo$'
    }

    It 'collision check is case-insensitive' {
        $collisions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$collisions.Add('TenantContext')
        $entry = [pscustomobject]@{ Slug = 'tenantcontext'; SubArea = 'Configuration' }
        Get-FixtureDirName -Entry $entry -Collisions $collisions | Should -Be 'Configuration_tenantcontext'
    }
}
