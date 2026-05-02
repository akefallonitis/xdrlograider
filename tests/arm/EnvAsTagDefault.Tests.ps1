#Requires -Modules Pester
<#
.SYNOPSIS
    Bug-class gate: legacyEnvInName must default to false. Env signal is
    carried by the `environment` Azure tag (Well-Architected env-as-tag
    pattern) — NOT by an env infix in resource names.

.DESCRIPTION
    User directive 2026-04-30: "prod etc should be tags". Resource names like
    `xdrlr-prod-dcr-2` leak the environment into the name. Per Azure Well-
    Architected, env should be carried by tag (`tags.environment = 'prod'`),
    not by the resource name.

    This gate locks the parameter default for both compiled artifacts so a
    future regression (someone flips it back to true) is caught at PR review.
    Operators on legacy `xdrlr-prod-*` deploys must explicitly opt-in to
    legacyEnvInName=true at deploy time for in-place upgrades.

    Scope of assertions:
      - main.bicep source declares `param legacyEnvInName bool = false`
      - mainTemplate.json compiled parameter defaultValue = false
      - the `environment` tag is on the commonTag dictionary (carries env
        regardless of legacyEnvInName setting; this part is the "tag carries
        the env signal even when the resource name doesn't" half of the gate)
#>

BeforeDiscovery {
    # BeforeDiscovery runs before the It -Skip evaluation, so any path used in
    # an inline -Skip clause must be computed here (BeforeAll-set vars are
    # NOT visible at discovery time). The compiled ARM is the single source
    # of truth in v0.1.0-beta; Bicep is archived to .internal/bicep-reference/.
    $script:DiscoveryRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:DiscoveryBicepSrc = Join-Path $script:DiscoveryRepoRoot 'deploy' 'main.bicep'
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:BicepSrc = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
    if (-not (Test-Path -LiteralPath $script:ArmPath)) {
        throw "Compiled ARM template not found at $($script:ArmPath). Hand-authored ARM is the single source of truth in v0.1.0-beta."
    }
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
}

Describe 'EnvAsTagDefault.legacyEnvInName' {

    It 'compiled ARM template declares legacyEnvInName parameter' {
        $armParams = ($script:Arm.parameters.PSObject.Properties.Name)
        $armParams | Should -Contain 'legacyEnvInName' -Because 'parameter must remain (operators can opt back into legacy form)'
    }

    It 'compiled ARM legacyEnvInName.defaultValue is FALSE (env-as-tag default per Well-Architected)' {
        $script:Arm.parameters.legacyEnvInName.defaultValue |
            Should -Be $false -Because 'env signal MUST be carried via the `environment` tag, not via resource-name infix. Operators upgrading from pre-v0.2.0 deploys must explicitly opt into legacyEnvInName=true.'
    }

    It 'main.bicep source mirrors the false default' -Skip:(-not (Test-Path -LiteralPath $script:DiscoveryBicepSrc)) {
        # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
        # single source of truth). Skip cleanly when not present.
        $bicep = Get-Content -LiteralPath $script:BicepSrc -Raw
        $bicep | Should -Match 'param\s+legacyEnvInName\s+bool\s*=\s*false' -Because 'Bicep source must mirror the compiled ARM'
    }
}

Describe 'EnvAsTagDefault.EnvironmentTagCarriesSignal' {
    # The "env-as-tag" half: even when legacyEnvInName=false strips the env
    # infix from resource names, the `environment` Azure tag still carries the
    # env signal so operators can filter/group resources by environment.

    It 'commonTag variable includes the environment key' {
        $commonTag = $script:Arm.variables.commonTag
        $commonTag | Should -Not -BeNullOrEmpty -Because 'commonTag dictionary must exist'
        $tagKeys = $commonTag.PSObject.Properties.Name
        $tagKeys | Should -Contain 'environment' -Because 'commonTag MUST include `environment` so the env signal travels via tag (Azure Well-Architected env-as-tag pattern)'
    }

    It 'commonTag.environment value resolves from parameters(env), not a hard-coded literal' {
        $commonTag = $script:Arm.variables.commonTag
        ([string]$commonTag.environment) |
            Should -Match "parameters\('env'\)" -Because 'environment tag value must be `parameters(env)` so the env signal travels via tag regardless of legacyEnvInName'
    }
}
