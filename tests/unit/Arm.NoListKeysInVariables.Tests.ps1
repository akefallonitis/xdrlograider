#Requires -Module Pester
# ARM hardening · NoListKeysInVariables.
#
# Rule: listKeys() / listSecrets() / list*() ARM functions MUST NOT appear inside
# the `variables{}` block. Putting them there means the secret-bearing string is
# exposed in deployment-history outputs, ARM template logs, and any operator who
# can `az deployment show` the resource group.
#
# Safe placements: directly inside resource property assignments (siteConfig.appSettings,
# DCR properties.dataCollectionEndpointId, etc.). ARM resolves them at deploy time
# only · they don't materialise in audit logs at those positions.
#
# Reference: Azure security best practice · 'Never use listKeys() in variables'.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Arm      = Get-Content (Join-Path $script:RepoRoot 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json
}

Describe 'deploy/mainTemplate.json · variables{} block hardening' -Tag 'arm-hardening' {

    It 'has a variables{} block' {
        $script:Arm.variables | Should -Not -BeNullOrEmpty
    }

    It 'NO variable uses listKeys() (would leak storage key into deployment history)' {
        $varsJson = $script:Arm.variables | ConvertTo-Json -Depth 20 -Compress
        $varsJson | Should -Not -Match 'listKeys\s*\('
    }

    It 'NO variable uses listSecrets() (would leak ML/Cog credentials into deployment history)' {
        $varsJson = $script:Arm.variables | ConvertTo-Json -Depth 20 -Compress
        $varsJson | Should -Not -Match 'listSecrets\s*\('
    }

    It 'NO variable uses generic list*() helper that could fetch credentials at variable-eval time' {
        $varsJson = $script:Arm.variables | ConvertTo-Json -Depth 20 -Compress
        # Match list<Word>(  · use $rxMatches not $matches (the latter is a PowerShell automatic variable)
        $rxMatches = [regex]::Matches($varsJson, '\blist[A-Z][A-Za-z0-9]*\s*\(')
        $unsafe = @($rxMatches | Where-Object { $_.Value -notmatch '^list(Available|Callback|Skus|Sku|Versions|UsageRights|EligibleResourceTypes)' })
        $unsafeNames = @($unsafe | ForEach-Object { $_.Value })
        $unsafe.Count | Should -Be 0 -Because "Found list*() in variables{}: $($unsafeNames -join ', ')"
    }

    It 'NO variable evaluates an ARM expression that begins with reference() to a sensitive resource type' {
        # reference() in variables can extract runtime properties (e.g. fqdn, principalId) which
        # might be acceptable; but reference of KV/Storage/etc. for property extraction risks
        # logging deployment input. Soft-warn pattern.
        $varsJson = $script:Arm.variables | ConvertTo-Json -Depth 20 -Compress
        # Detect reference(... Microsoft.KeyVault ...) in variables (would leak vault metadata)
        $varsJson | Should -Not -Match 'reference\s*\([^)]*Microsoft\.KeyVault'
    }
}
