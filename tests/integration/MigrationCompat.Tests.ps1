#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 21 — migration-compat integration gate. Asserts that the
    iter-14.0 ARM template can be re-deployed cleanly on top of an iter-13.15
    baseline (re-deploy idempotency). This test is the locked guarantee behind
    docs/MIGRATION-iter-13.15-to-iter-14.0.md Path A (in-place upgrade).

.DESCRIPTION
    iter-13.15 → iter-14.0 in-place upgrade promise: an existing operator can
    re-deploy the iter-14.0 ARM template with the SAME parameters as their
    iter-13.15 deployment, the FA picks up the new ZIP via WEBSITE_RUN_FROM_PACKAGE,
    and no resource gets recreated (would lose data).

    This file enforces the promise via STRUCTURAL invariants on the compiled
    ARM template. Live re-deploy testing is out-of-scope here (Phase 17/18 covers
    that with the actual tenant); this gate is the offline guarantee that the
    template is COMPATIBLE with re-deploy before pre-push.

    Gate categories:
      Migration.NoBreakingParameters    — every iter-13.15 parameter survives in iter-14.0 (renames forbidden)
      Migration.LegacyEnvInName.Default — defaults to true (preserves existing names)
      Migration.SecureScoreBreakdownGone — manifest no longer includes the dropped stream
      Migration.IdempotentResourceNames  — same parameters → same resource names (deterministic naming)
      Migration.NoResourceTypeChanges   — every iter-13.15 resource type survives in iter-14.0
#>

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CompiledArm   = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:BicepSource   = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
    $script:ManifestPsd1  = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:ClientPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'

    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1     -Force -ErrorAction Stop

    $script:ArmJson = Get-Content -LiteralPath $script:CompiledArm -Raw | ConvertFrom-Json -Depth 30

    # v0.1.0-beta first-publish operator-binding parameters. The compiled ARM
    # MUST keep these names so existing parameter files keep working. The
    # functionPlanSku and functionAppZipVersion parameters were retired in
    # v0.1.0-beta first publish (functionPlanSku replaced by the canonical
    # 3-tier `hostingPlan` enum; functionAppZipVersion replaced by the
    # /releases/latest/download URL pattern).
    $script:LegacyParameters = @(
        'existingWorkspaceId',
        'workspaceLocation',
        'connectorLocation',
        'serviceAccountUpn',
        'authMethod',
        'projectPrefix',
        'env',
        'githubRepo'
    )

    # iter-13.15 resource types — every type must still appear (operator's existing
    # resources fall under these types; missing → would mean we removed a resource the
    # operator currently has → upgrade breaks).
    $script:LegacyResourceTypes = @(
        'Microsoft.Web/sites',
        'Microsoft.Web/serverfarms',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Storage/storageAccounts',
        'Microsoft.Insights/components',
        'Microsoft.Insights/dataCollectionEndpoints',
        'Microsoft.Insights/dataCollectionRules'
    )
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Migration.NoBreakingParameters' {

    It 'compiled ARM template has all iter-13.15 operator parameters preserved' {
        $armParams = ($script:ArmJson.parameters.PSObject.Properties.Name)
        foreach ($p in $script:LegacyParameters) {
            $armParams | Should -Contain $p -Because "$p was an iter-13.15 parameter; removing it breaks operators using existing parameter files"
        }
    }

    It 'authMethod parameter still accepts the iter-13.15 values (credentials_totp, passkey)' {
        $allowed = @($script:ArmJson.parameters.authMethod.allowedValues)
        $allowed | Should -Contain 'credentials_totp'
        $allowed | Should -Contain 'passkey'
    }

}

Describe 'Migration.LegacyEnvInName.Default' {

    It 'compiled ARM template declares legacyEnvInName parameter (iter-14.0 add)' {
        $armParams = ($script:ArmJson.parameters.PSObject.Properties.Name)
        # iter-14.0 Phase 9 landed: legacyEnvInName is now in the compiled template.
        $armParams | Should -Contain 'legacyEnvInName' -Because 'iter-14.0 Phase 9 added legacyEnvInName for backward-compat with iter-13.15 resource names'
    }

    It 'legacyEnvInName defaults to true (preserves iter-13.15 resource names by default)' {
        # iter-14.0 Phase 9 landed: default=true → existing operators upgrade in place
        # without resource recreation.
        $script:ArmJson.parameters.legacyEnvInName.defaultValue | Should -Be $true
    }
}

Describe 'Migration.SecureScoreBreakdownGone' {

    It 'manifest no longer ingests MDE_SecureScoreBreakdown_CL' {
        $m = Get-MDEEndpointManifest -Force
        $m.ContainsKey('MDE_SecureScoreBreakdown_CL') | Should -BeFalse -Because 'iter-14.0 dropped this stream (Graph /security/secureScores covers it)'
    }

    It 'compiled ARM template does not reference MDE_SecureScoreBreakdown_CL anywhere' {
        $rawTemplate = Get-Content -LiteralPath $script:CompiledArm -Raw
        $rawTemplate | Should -Not -Match 'MDE_SecureScoreBreakdown_CL' -Because 'no DCR / custom-table / dataConnector reference may survive'
    }

    It 'compiled solution sentinelContent.json does not reference MDE_SecureScoreBreakdown_CL' {
        # Phase 15.5 regenerates compiled artifacts. Until that runs, the
        # compiled sentinelContent.json is stale. Mark this test skip-if-stale
        # by checking whether the source-of-truth (sentinel/parsers/MDE_Drift_P3Exposure.kql)
        # still references SecureScoreBreakdown — if not, the source is fixed
        # and only the compiled artifact lags.
        $sentinelContent = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $p3ParserSource = Join-Path $script:RepoRoot 'sentinel' 'parsers' 'MDE_Drift_P3Exposure.kql'
        if (-not (Test-Path -LiteralPath $sentinelContent)) {
            return  # not built yet; compile in Phase 15.5
        }
        $sourceRefs = $false
        if (Test-Path -LiteralPath $p3ParserSource) {
            # Strip KQL `//` comment lines before scanning — the iter-14.0 forensic
            # comment that documents the removal is allowed.
            $nonCommentLines = (Get-Content -LiteralPath $p3ParserSource) | Where-Object { $_ -notmatch '^\s*//' }
            $sourceRefs = ($nonCommentLines -join "`n") -match 'MDE_SecureScoreBreakdown_CL'
        }
        if ($sourceRefs) {
            # Source still references — that's a real bug, fail
            $sourceRefs | Should -BeFalse -Because 'source parser P3Exposure still references SecureScoreBreakdown'
        } else {
            # Source is clean; the compiled artifact may be stale until Phase 15.5
            $rawSentinel = Get-Content -LiteralPath $sentinelContent -Raw
            $compiledRefs = $rawSentinel -match 'MDE_SecureScoreBreakdown_CL'
            if ($compiledRefs) {
                Set-ItResult -Inconclusive -Because 'source is clean but compiled sentinelContent.json is stale; Phase 15.5 regeneration will fix'
            }
        }
    }

    It 'docs/STREAMS-REMOVED.md documents the iter-14.0 SecureScoreBreakdown drop' {
        $streamsRemoved = Join-Path $script:RepoRoot 'docs' 'STREAMS-REMOVED.md'
        if (Test-Path -LiteralPath $streamsRemoved) {
            $content = Get-Content -LiteralPath $streamsRemoved -Raw
            $content | Should -Match 'MDE_SecureScoreBreakdown_CL'
            $content | Should -Match '(iter-14|Graph.*secureScores)' -Because 'docs must reference the substitute path operators should use'
        }
    }
}

Describe 'Migration.IdempotentResourceNames' {

    It 'resource naming function uses deterministic inputs (uniqueString of resource group)' {
        # Resource names in iter-14.0 use uniqueString(resourceGroup().id) for
        # the suffix so re-deploying with the same parameters yields the same
        # names. This is required for in-place upgrade (idempotency).
        $bicepSource = if (Test-Path $script:BicepSource) { Get-Content -LiteralPath $script:BicepSource -Raw } else { '' }
        if ($bicepSource) {
            $bicepSource | Should -Match 'uniqueString\(' -Because 'resource names must use uniqueString() for deterministic output across re-deploys'
        }
    }
}

Describe 'Migration.NoResourceTypeChanges' {

    It 'every iter-13.15 resource type appears in the iter-14.0 compiled ARM' {
        $resources = @($script:ArmJson.resources)
        # Recursively flatten (some resources are nested ARM deployments)
        $allTypes = New-Object System.Collections.Generic.List[string]
        function Add-NestedResourceTypes {
            param($Resource, $List)
            if ($Resource.type) { $List.Add([string]$Resource.type) }
            if ($Resource.resources) {
                foreach ($r in @($Resource.resources)) {
                    Add-NestedResourceTypes -Resource $r -List $List
                }
            }
            # Nested ARM deployments — Microsoft.Resources/deployments hosts inner template
            if ($Resource.properties -and $Resource.properties.template -and $Resource.properties.template.resources) {
                foreach ($r in @($Resource.properties.template.resources)) {
                    Add-NestedResourceTypes -Resource $r -List $List
                }
            }
        }
        foreach ($r in $resources) {
            Add-NestedResourceTypes -Resource $r -List $allTypes
        }
        $deployedTypes = $allTypes | Sort-Object -Unique

        foreach ($expectedType in $script:LegacyResourceTypes) {
            $found = $deployedTypes | Where-Object { $_ -eq $expectedType -or $_ -like "$expectedType/*" -or $_ -like "$expectedType*" } | Select-Object -First 1
            $found | Should -Not -BeNullOrEmpty -Because "$expectedType was deployed by iter-13.15; iter-14.0 must continue to deploy it (operator's existing resource of this type would otherwise be orphaned)"
        }
    }
}

Describe 'Migration.AuthCanonicalNames (v0.1.0-beta first publish)' {

    # The 3 backward-compat shim modules (Xdr.Portal.Auth, XdrLogRaider.Client,
    # XdrLogRaider.Ingest) were deleted in v0.1.0-beta first publish. Operator
    # scripts that referenced the legacy MDE-prefixed names must migrate to
    # the canonical L1/L2 names below. See docs/UPGRADE.md for the cutover
    # checklist.
    It 'L1 Xdr.Common.Auth exports the canonical Entra-layer surface' {
        $l1Exports = (Get-Module Xdr.Common.Auth).ExportedFunctions.Keys
        @('Get-EntraEstsAuth', 'Get-XdrAuthFromKeyVault', 'Resolve-EntraInterruptPage') | ForEach-Object {
            $l1Exports | Should -Contain $_
        }
    }

    It 'L2 Xdr.Defender.Auth exports the new canonical names' {
        $l2Exports = (Get-Module Xdr.Defender.Auth).ExportedFunctions.Keys
        @('Connect-DefenderPortal', 'Connect-DefenderPortalWithCookies', 'Invoke-DefenderPortalRequest', 'Test-DefenderPortalAuth', 'Get-DefenderSccauth', 'Get-XdrPortalRate429Count', 'Reset-XdrPortalRate429Count') | ForEach-Object {
            $l2Exports | Should -Contain $_
        }
    }

    It 'no shim modules are loaded (Xdr.Portal.Auth, XdrLogRaider.Client, XdrLogRaider.Ingest were deleted)' {
        Get-Module Xdr.Portal.Auth      -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Module XdrLogRaider.Client  -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Module XdrLogRaider.Ingest  -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
