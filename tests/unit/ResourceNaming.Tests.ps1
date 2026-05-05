#Requires -Modules Pester
<#
.SYNOPSIS
    Resource naming convention gates for v0.1.0 GA.

.DESCRIPTION
    Phase J.C.1 (2026-05-04): legacyEnvInName parameter REMOVED. v0.1.0 GA
    is a NEW clean baseline; resource names are env-neutral by design. Env
    travels via the `environment` Azure tag (Well-Architected pattern).

    Resource naming convention (v0.1.0 GA):
      funcName  = <projectPrefix>-fn-suffix
      planName  = <projectPrefix>-plan
      kvName    = <projectPrefix>-kv-suffix
      stName    = <projectPrefix>suffixst (lowercase, hyphens stripped)
      dceName   = <projectPrefix>-dce
      dcrName   = <projectPrefix>-dcr
      aiName    = <projectPrefix>-ai

    Gate categories:
      ResourceNaming.NoLegacyParameter      - legacyEnvInName + envSegment +
                                              stEnvSegment all REMOVED
      ResourceNaming.NameCompositionShape   - resource names follow the
                                              v0.1.0 GA shape above
      ResourceNaming.EnvCarriedByTag        - env signal travels via tag
                                              (env-as-tag Well-Architected)
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
}

Describe 'ResourceNaming.NoLegacyParameter (v0.1.0 GA cleanup)' {

    It 'compiled ARM template does NOT declare legacyEnvInName parameter' {
        $armParams = ($script:Arm.parameters.PSObject.Properties.Name)
        $armParams | Should -Not -Contain 'legacyEnvInName' -Because 'Phase J.C.1: v0.1.0 GA = clean baseline, no prior production to preserve via legacy env-in-name'
    }

    It 'compiled ARM template does NOT declare envSegment variable' {
        $armVars = ($script:Arm.variables.PSObject.Properties.Name)
        $armVars | Should -Not -Contain 'envSegment'
    }

    It 'compiled ARM template does NOT declare stEnvSegment variable' {
        $armVars = ($script:Arm.variables.PSObject.Properties.Name)
        $armVars | Should -Not -Contain 'stEnvSegment'
    }
}

Describe 'ResourceNaming.NameCompositionShape (v0.1.0 GA)' {

    It 'funcName composes as projectPrefix-fn-suffix' {
        $expr = [string]$script:Arm.variables.funcName
        # Single-quoted regex to avoid PowerShell interpolation of $projectPrefix.
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-fn-'', variables\(''suffix''\)\)\]$'
    }

    It 'planName composes as projectPrefix-plan' {
        $expr = [string]$script:Arm.variables.planName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-plan''\)\]$'
    }

    It 'kvName composes as projectPrefix-kv-suffix' {
        $expr = [string]$script:Arm.variables.kvName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-kv-'', variables\(''suffix''\)\)\]$'
    }

    It 'dceName composes as projectPrefix-dce' {
        $expr = [string]$script:Arm.variables.dceName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-dce''\)\]$'
    }

    It 'dcrName composes as projectPrefix-dcr' {
        $expr = [string]$script:Arm.variables.dcrName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-dcr''\)\]$'
    }

    It 'aiName composes as projectPrefix-ai' {
        $expr = [string]$script:Arm.variables.aiName
        $expr | Should -Match '^\[concat\(parameters\(''projectPrefix''\), ''-ai''\)\]$'
    }

    It 'stName uses lowercase, hyphens stripped, length-capped at 24 (Storage account constraints)' {
        $expr = [string]$script:Arm.variables.stName
        $expr | Should -Match 'toLower' -Because 'Storage account names must be lowercase'
        $expr | Should -Match "replace\(.+'-'.+''\)" -Because 'Storage account names disallow hyphens (must replace with empty)'
        $expr | Should -Match 'substring' -Because 'Storage account names must be capped at 24 chars'
    }

    It 'no resource-name variable references envSegment or stEnvSegment' {
        $resourceNameVars = @('funcName', 'planName', 'kvName', 'stName', 'dceName', 'dcrName', 'aiName')
        foreach ($name in $resourceNameVars) {
            $expr = [string]$script:Arm.variables.$name
            $expr | Should -Not -Match 'envSegment' -Because "$name must NOT reference envSegment in v0.1.0 GA"
            $expr | Should -Not -Match 'stEnvSegment' -Because "$name must NOT reference stEnvSegment in v0.1.0 GA"
        }
    }
}

Describe 'ResourceNaming.EnvCarriedByTag (v0.1.0 GA)' {

    It 'commonTag variable includes the environment key' {
        $commonTag = $script:Arm.variables.commonTag
        $commonTag | Should -Not -BeNullOrEmpty
        $tagKeys = $commonTag.PSObject.Properties.Name
        $tagKeys | Should -Contain 'environment' -Because 'env signal MUST travel via tag (Well-Architected env-as-tag), not via resource-name infix'
    }

    It 'commonTag.environment resolves from parameters(env)' {
        $commonTag = $script:Arm.variables.commonTag
        ([string]$commonTag.environment) | Should -Match "parameters\('env'\)" -Because 'environment tag MUST resolve dynamically'
    }
}
