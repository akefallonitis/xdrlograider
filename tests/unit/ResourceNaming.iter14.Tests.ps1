#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 9 — resource-naming + env-as-tag schema gate. Asserts the
    compiled ARM template declares the `legacyEnvInName` parameter, that resource
    names parameterize on it (no hard-coded env literals), and that every
    connector-local resource carries the canonical commonTags object including
    `environment` + `project` + `managed-by`.

.DESCRIPTION
    Test gates by name (referenced in plan §1.5 LOCKED + Phase 9):
      ResourceNaming.LegacyEnvInName.Param          legacyEnvInName declared, type bool, default true
      ResourceNaming.LegacyEnvInName.Parameterized  resource names use if(parameters('legacyEnvInName'), ...) form;
                                                    no hard-coded `-prod-` / `-dev-` / `-staging-` literals
      ResourceNaming.Tags.PresentEverywhere         every Microsoft.* connector resource has tags property
      ResourceNaming.Tags.Schema                    commonTag carries environment + project + managed-by
      ResourceNaming.NoEnvLeakWhenFalse             when legacyEnvInName=false, no resource name string contains
                                                    `prod` / `staging` / `dev` (text scan of compiled ARM)

    Hidden test gate: the last gate is the "env-neutral" promise — when an
    operator sets legacyEnvInName=false, NO resource name token contains the
    environment literal. That's the architecturally-clean v1.2 Marketplace
    baseline and the contract that Phase 9 LOCKS for downstream phases.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CompiledArm    = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:BicepSource    = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
    $script:BicepModulesDir = Join-Path $script:RepoRoot 'deploy' 'modules'

    if (-not (Test-Path -LiteralPath $script:CompiledArm)) {
        throw "Compiled ARM template not found at $($script:CompiledArm). Run: az bicep build --file ./deploy/main.bicep --outfile ./deploy/compiled/mainTemplate.json"
    }
    $script:ArmJsonRaw = Get-Content -LiteralPath $script:CompiledArm -Raw
    $script:ArmJson    = $script:ArmJsonRaw | ConvertFrom-Json -Depth 50

    # Resource types that MUST carry the commonTags (everything connector-local).
    # Workspace sub-resources (custom tables / Sentinel content) are NOT in this
    # list because tags on workspace sub-resources don't propagate cleanly and
    # the workspace's own tags belong to the customer.
    $script:TaggedResourceTypes = @(
        'Microsoft.Web/sites',
        'Microsoft.Web/serverfarms',
        'Microsoft.KeyVault/vaults',
        'Microsoft.Storage/storageAccounts',
        'Microsoft.Insights/components',
        'Microsoft.Insights/dataCollectionEndpoints',
        'Microsoft.Insights/dataCollectionRules'
    )
}

Describe 'ResourceNaming.LegacyEnvInName.Param' {

    It 'compiled ARM template declares legacyEnvInName parameter' {
        $armParams = ($script:ArmJson.parameters.PSObject.Properties.Name)
        $armParams | Should -Contain 'legacyEnvInName' -Because 'iter-14.0 Phase 9 introduces legacyEnvInName for env-as-tag pattern toggle'
    }

    It 'legacyEnvInName parameter is type bool' {
        $script:ArmJson.parameters.legacyEnvInName.type | Should -Be 'bool'
    }

    It 'legacyEnvInName defaults to true (preserves iter-13.15 names by default — operators upgrade in place)' {
        $script:ArmJson.parameters.legacyEnvInName.defaultValue | Should -Be $true -Because 'default MUST be true so existing iter-13.15 deployments do not get resource recreation on upgrade'
    }

    It 'main.bicep source declares legacyEnvInName parameter' {
        $bicepSource = Get-Content -LiteralPath $script:BicepSource -Raw
        $bicepSource | Should -Match 'param\s+legacyEnvInName\s+bool\s*=\s*true' -Because 'Bicep source must mirror compiled ARM (regenerated via az bicep build)'
    }
}

Describe 'ResourceNaming.LegacyEnvInName.Parameterized' {

    It 'resource-name variables use if(parameters(legacyEnvInName), ...) conditional form' {
        # The compiled ARM uses an envSegment variable that flips to '<env>-' when
        # legacyEnvInName=true and '' when false. No name expression should embed
        # the env value via direct concat without going through the conditional.
        $variables = $script:ArmJson.variables
        $variables.PSObject.Properties.Name | Should -Contain 'envSegment' -Because 'Phase 9 introduces envSegment as the conditional gate'
        $envSegmentExpr = [string]$variables.envSegment
        $envSegmentExpr | Should -Match "if\(parameters\('legacyEnvInName'\)" -Because "envSegment must use if() on the parameter to drive the toggle"
    }

    It 'connector resource names compose via envSegment (not raw env)' {
        $variables = $script:ArmJson.variables
        # funcName + planName + kvName + dceName + dcrName + aiName all must reference envSegment
        foreach ($name in 'funcName', 'planName', 'kvName', 'dceName', 'dcrName', 'aiName') {
            $expr = [string]$variables.$name
            $expr | Should -Match 'envSegment' -Because "$name must compose through envSegment so legacyEnvInName toggles cleanly"
        }
        # stName uses stEnvSegment (no trailing dash variant for storage accounts)
        $stExpr = [string]$variables.stName
        $stExpr | Should -Match 'stEnvSegment' -Because 'stName must compose through stEnvSegment (storage accounts disallow hyphens)'
    }

    It 'no resource-name variable embeds a hard-coded env literal (prod / dev / staging)' {
        # Read the compiled ARM as raw text and check the variables block for any
        # hard-coded environment literal. The ONLY allowed env reference in name
        # expressions is via parameters('env') indirection.
        $variables = $script:ArmJson.variables
        foreach ($name in 'funcName', 'planName', 'kvName', 'dceName', 'dcrName', 'aiName', 'stName') {
            $expr = [string]$variables.$name
            $expr | Should -Not -Match "[-']prod[-']" -Because "$name must not hard-code 'prod'"
            $expr | Should -Not -Match "[-']dev[-']"  -Because "$name must not hard-code 'dev'"
            $expr | Should -Not -Match "[-']staging[-']" -Because "$name must not hard-code 'staging'"
        }
    }
}

Describe 'ResourceNaming.Tags.PresentEverywhere' {

    BeforeAll {
        # Walk every connector-local resource (top-level array, NOT nested
        # workspace sub-resources). For each, assert tags is present.
        $script:TopLevelResources = @($script:ArmJson.resources)
    }

    It 'every connector-local Microsoft.* resource declares a tags property' {
        foreach ($r in $script:TopLevelResources) {
            $type = [string]$r.type
            if ($script:TaggedResourceTypes -contains $type) {
                $r.PSObject.Properties['tags'] | Should -Not -BeNullOrEmpty -Because "$type resource '$($r.name)' must carry commonTags so the environment tag is queryable"
            }
        }
    }

    It 'commonTag variable is defined' {
        $script:ArmJson.variables.PSObject.Properties.Name | Should -Contain 'commonTag' -Because 'commonTag is the canonical reusable tag dictionary'
    }
}

Describe 'ResourceNaming.Tags.Schema' {

    BeforeAll {
        $script:CommonTag = $script:ArmJson.variables.commonTag
    }

    It 'commonTag includes environment key (carries env signal regardless of legacyEnvInName)' {
        $tagKeys = $script:CommonTag.PSObject.Properties.Name
        $tagKeys | Should -Contain 'environment' -Because 'environment is the canonical Azure tag the v1.2 Marketplace baseline relies on for env filtering'
        ([string]$script:CommonTag.environment) | Should -Match "parameters\('env'\)" -Because 'environment value must be parameters(env), not a hard-coded literal'
    }

    It 'commonTag includes project key' {
        $tagKeys = $script:CommonTag.PSObject.Properties.Name
        $tagKeys | Should -Contain 'project' -Because 'project tag enables operators to find ALL XdrLogRaider resources via tag query'
    }

    It 'commonTag includes managed-by key (canonical Azure provenance tag)' {
        # Both kebab-case ('managed-by') and Pascal/legacy ('managedBy') are
        # acceptable so long as at least one provenance tag is present. iter-14.0
        # Phase 9 introduces 'managed-by'. Legacy 'managedBy' may co-exist
        # for backward-compat with any pre-Phase-9 tooling.
        $tagKeys = $script:CommonTag.PSObject.Properties.Name
        ($tagKeys -contains 'managed-by') -or ($tagKeys -contains 'managedBy') | Should -BeTrue -Because 'at least one managed-by/managedBy provenance tag MUST be present'
    }
}

Describe 'ResourceNaming.NoEnvLeakWhenFalse' {
    # Hidden test gate (plan §1.5 LOCKED): when legacyEnvInName=false, an operator
    # gets env-neutral resource names. Simulate by reading the compiled ARM text
    # with the parameter substituted and confirming no resource name string
    # contains a `prod`/`staging`/`dev` literal.
    #
    # We test this by instantiating the envSegment variable expression with
    # legacyEnvInName=false and confirming the resulting resource names lack
    # any env literal. Since we can't fully evaluate ARM expressions offline,
    # we read the SOURCE expressions and verify they reduce to '' when
    # legacyEnvInName=false.

    It 'envSegment evaluates to empty string when legacyEnvInName=false' {
        # The expression should be: if(parameters('legacyEnvInName'), <env-form>, <no-env-form>)
        # The "no-env" branch must be the empty string ''.
        $envSegmentExpr = [string]$script:ArmJson.variables.envSegment
        # Match the if() with a final '' literal as the false branch.
        # Allow either single-quoted '' or escaped form.
        $envSegmentExpr | Should -Match "if\(parameters\('legacyEnvInName'\),.*?,\s*''" -Because 'envSegment false-branch MUST be empty string for env-neutral names'
    }

    It 'stEnvSegment evaluates to empty string when legacyEnvInName=false' {
        $stEnvSegmentExpr = [string]$script:ArmJson.variables.stEnvSegment
        $stEnvSegmentExpr | Should -Match "if\(parameters\('legacyEnvInName'\),.*?,\s*''" -Because 'stEnvSegment false-branch MUST be empty string'
    }

    It 'no resource-name variable bakes in a literal env value (Phase 9 contract)' {
        # If the variable expression matches "'prod'" or similar with no surrounding
        # if(), the env is hard-coded. The only allowed embed is via parameters('env')
        # OR parameters('env') threaded through an if(parameters('legacyEnvInName'), ...)
        # conditional.
        $vars = $script:ArmJson.variables
        foreach ($name in 'funcName', 'planName', 'kvName', 'dceName', 'dcrName', 'aiName', 'stName') {
            $expr = [string]$vars.$name
            # No bare 'prod' / 'dev' / 'staging' string literal should appear.
            # Allow them only inside parameters('env') reference (which they don't).
            $expr | Should -Not -Match "'prod'"      -Because "$name must not contain literal 'prod'"
            $expr | Should -Not -Match "'dev'"       -Because "$name must not contain literal 'dev'"
            $expr | Should -Not -Match "'staging'"   -Because "$name must not contain literal 'staging'"
        }
    }
}

Describe 'ResourceNaming.LegacyDefault.IdenticalToIter1315' {
    # The DEFAULT (legacyEnvInName=true) MUST produce IDENTICAL resource names
    # to iter-13.15 so existing operators upgrade in place without recreation.
    # iter-13.15 names: xdrlr-prod-fn-<suffix>, xdrlr-prod-plan, xdrlr-prod-kv-<suffix>,
    # xdrlrprodst<suffix>, xdrlr-prod-dce, xdrlr-prod-dcr, xdrlr-prod-ai

    It 'when legacyEnvInName=true and env=prod, funcName composes to projectPrefix-env-fn-suffix form' {
        # Reduce the funcName expression: concat(projectPrefix, '-', envSegment, 'fn-', suffix)
        # When envSegment='prod-': xdrlr-prod-fn-<suffixToken>. Confirm via expression text.
        $funcNameExpr = [string]$script:ArmJson.variables.funcName
        # The expression must contain envSegment AND 'fn-'
        $funcNameExpr | Should -Match "envSegment"
        $funcNameExpr | Should -Match "fn-" -Because 'funcName format must be projectPrefix-envSegment-fn-<suffixToken>'
    }

    It 'when legacyEnvInName=true and env=prod, stName composes to xdrlrprodst form' {
        # stName expression: toLower(replace(concat(projectPrefix, stEnvSegment, 'st', suffix), '-', ''))
        # When stEnvSegment='prod': xdrlrprodst<suffixToken>. Confirm structure.
        $stNameExpr = [string]$script:ArmJson.variables.stName
        $stNameExpr | Should -Match "toLower\(" -Because 'stName MUST be toLower-wrapped'
        $stNameExpr | Should -Match "stEnvSegment" -Because 'stName MUST compose through stEnvSegment'
        $stNameExpr | Should -Match "'st'" -Because 'stName MUST contain the st infix literal'
    }
}
