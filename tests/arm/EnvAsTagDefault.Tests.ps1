#Requires -Modules Pester
<#
.SYNOPSIS
    Env-as-tag pattern gate. Resource names MUST NOT contain env infix; env
    signal travels via the `environment` Azure tag (Well-Architected pattern).

.DESCRIPTION
    Phase J.C.1 (2026-05-04): legacyEnvInName parameter REMOVED. v0.1.0 GA is
    a NEW clean baseline — no prior production to preserve. Resource names are
    always env-neutral; env carried by tag.

    Scope:
      - mainTemplate.json declares NO legacyEnvInName parameter
      - mainTemplate.json declares NO envSegment / stEnvSegment variables
      - resource-name variables (funcName, planName, kvName, stName, dceName,
        dcrName, aiName) compose WITHOUT env infix
      - commonTag dictionary still carries `environment = parameters('env')`
        so operators filter/group by environment via tags
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    if (-not (Test-Path -LiteralPath $script:ArmPath)) {
        throw "Compiled ARM template not found at $($script:ArmPath)."
    }
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
}

Describe 'EnvAsTag.NoLegacyParameter (v0.1.0 GA)' {

    It 'compiled ARM template does NOT declare legacyEnvInName parameter (Phase J.C.1 cleanup)' {
        $armParams = ($script:Arm.parameters.PSObject.Properties.Name)
        $armParams | Should -Not -Contain 'legacyEnvInName' -Because 'v0.1.0 GA is a clean baseline; no prior production to preserve via legacy env-in-name behavior. Removed in Phase J.C.1.'
    }

    It 'compiled ARM template does NOT declare envSegment variable' {
        $armVars = ($script:Arm.variables.PSObject.Properties.Name)
        $armVars | Should -Not -Contain 'envSegment' -Because 'envSegment was the legacyEnvInName conditional gate; both removed in Phase J.C.1'
    }

    It 'compiled ARM template does NOT declare stEnvSegment variable' {
        $armVars = ($script:Arm.variables.PSObject.Properties.Name)
        $armVars | Should -Not -Contain 'stEnvSegment' -Because 'stEnvSegment was the storage-account variant of envSegment; removed in Phase J.C.1'
    }
}

Describe 'EnvAsTag.NoEnvInResourceNames (v0.1.0 GA)' {

    It 'funcName has no env infix' {
        $expr = [string]$script:Arm.variables.funcName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-fn-'', variables\(''suffix''\)\)\]$' -Because 'funcName MUST be projectPrefix-fn-suffix only'
    }

    It 'planName has no env infix' {
        $expr = [string]$script:Arm.variables.planName
        $expr | Should -Not -Match 'envSegment' -Because 'planName must compose without env infix in v0.1.0 GA'
    }

    It 'kvName has no env infix' {
        $expr = [string]$script:Arm.variables.kvName
        $expr | Should -Not -Match 'envSegment' -Because 'kvName must compose without env infix in v0.1.0 GA'
    }

    It 'dceName has no env infix' {
        $expr = [string]$script:Arm.variables.dceName
        $expr | Should -Not -Match 'envSegment' -Because 'dceName must compose without env infix in v0.1.0 GA'
    }

    It 'dcrName has no env infix' {
        $expr = [string]$script:Arm.variables.dcrName
        $expr | Should -Not -Match 'envSegment' -Because 'dcrName must compose without env infix in v0.1.0 GA'
    }

    It 'aiName has no env infix' {
        $expr = [string]$script:Arm.variables.aiName
        $expr | Should -Not -Match 'envSegment' -Because 'aiName must compose without env infix in v0.1.0 GA'
    }

    It 'stName has no env infix' {
        $expr = [string]$script:Arm.variables.stName
        $expr | Should -Not -Match 'stEnvSegment' -Because 'stName must compose without env infix in v0.1.0 GA'
    }
}

Describe 'EnvAsTag.EnvironmentTagCarriesSignal (v0.1.0 GA)' {
    # Env signal still travels via the `environment` Azure tag — operators
    # filter/group resources by environment via tag, not by name.

    It 'commonTag variable includes the environment key' {
        $commonTag = $script:Arm.variables.commonTag
        $commonTag | Should -Not -BeNullOrEmpty -Because 'commonTag dictionary must exist'
        $tagKeys = $commonTag.PSObject.Properties.Name
        $tagKeys | Should -Contain 'environment' -Because 'commonTag MUST include `environment` so the env signal travels via tag (Azure Well-Architected env-as-tag pattern)'
    }

    It 'commonTag.environment value resolves from parameters(env), not a hard-coded literal' {
        $commonTag = $script:Arm.variables.commonTag
        ([string]$commonTag.environment) | Should -Match "parameters\('env'\)" -Because 'environment tag MUST resolve from the env parameter, not a literal'
    }
}
