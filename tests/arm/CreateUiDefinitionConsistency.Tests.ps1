#Requires -Modules Pester
<#
.SYNOPSIS
    Drift gate between deploy/compiled/createUiDefinition.json (the wizard
    surface operators interact with on the Deploy to Azure flow) and
    deploy/compiled/mainTemplate.json (the ARM template the wizard's outputs
    feed into).

.DESCRIPTION
    The wizard emits a payload of named outputs; the ARM template consumes
    them by parameter name. If a wizard output key has no ARM parameter, ARM
    deployment fails with InvalidTemplate / unrecognized parameter. If a
    dropdown emits a value not in the ARM allowedValues, deployment fails
    with `<value> is not part of allowed value(s)` (the exact bug surfaced
    in v0.1.0-beta first publish - the wizard emitted `consumption-y1` but
    the ARM functionPlanSku parameter only allowed `Y1`/`EP1`/`EP2`).

    Gate categories:
      Outputs.MapToArmParameters         - every createUiDef output key matches an ARM parameter name
      Dropdowns.AllowedValuesAreSubset   - dropdown values are a subset of ARM allowedValues
      Outputs.SubsetOfArmParameters      - non-output ARM params are accounted for (defaults applied)
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:UiPath           = Join-Path $script:RepoRoot 'deploy' 'compiled' 'createUiDefinition.json'
    $script:ArmPath          = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'

    $script:Ui               = Get-Content -LiteralPath $script:UiPath  -Raw | ConvertFrom-Json -Depth 50
    $script:Arm              = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    # Flatten createUiDefinition outputs and dropdown elements for symmetric lookup.
    $script:UiOutputs = @{}
    foreach ($o in $script:Ui.parameters.outputs.PSObject.Properties) {
        $script:UiOutputs[$o.Name] = $o.Value
    }

    # Walk every step + every basics element to find DropDown / OptionsGroup /
    # CheckBox elements with allowedValues. Capture by element name so we can
    # cross-check against the ARM parameter constraint with the same name.
    # Strict-mode-safe property access throughout — some elements (InfoBox,
    # Section, etc.) lack constraints; using PSObject.Properties guards prevents
    # PropertyNotFoundException when other tests have set strict mode.
    $script:UiInputElements = @{}
    $captureUiElement = {
        param($el)
        if ($null -eq $el) { return }
        if (-not ($el.PSObject.Properties.Name -contains 'name')) { return }
        $name = $el.name
        $type = if ($el.PSObject.Properties.Name -contains 'type') { $el.type } else { '' }
        $allowed = $null
        if ($type -in 'Microsoft.Common.DropDown', 'Microsoft.Common.OptionsGroup') {
            if ($el.PSObject.Properties.Name -contains 'constraints' -and
                $null -ne $el.constraints -and
                $el.constraints.PSObject.Properties.Name -contains 'allowedValues' -and
                $null -ne $el.constraints.allowedValues) {
                $allowed = @($el.constraints.allowedValues | ForEach-Object { $_.value })
            }
        }
        $defaultValue = if ($el.PSObject.Properties.Name -contains 'defaultValue') { $el.defaultValue } else { $null }
        $script:UiInputElements[$name] = [pscustomobject]@{
            Name          = $name
            Type          = $type
            AllowedValues = $allowed
            DefaultValue  = $defaultValue
        }
    }

    foreach ($basics in @($script:Ui.parameters.basics)) {
        & $captureUiElement -el $basics
    }
    foreach ($step in @($script:Ui.parameters.steps)) {
        if ($step.PSObject.Properties.Name -contains 'elements') {
            foreach ($el in @($step.elements)) {
                & $captureUiElement -el $el
            }
        }
    }

    # Flatten ARM parameters
    $script:ArmParams = @{}
    foreach ($p in $script:Arm.parameters.PSObject.Properties) {
        $script:ArmParams[$p.Name] = $p.Value
    }

    # Outputs that don't map to a parameter by name (intentional — derived
    # in the wizard from primitives the wizard collects elsewhere). Today
    # there are none — both are required by intent. Document deltas here
    # if introduced.
    $script:OutputDeltas = @()
}

Describe 'Outputs.MapToArmParameters' {

    It 'every createUiDefinition output key matches an ARM parameter name' {
        $unmapped = @()
        foreach ($key in $script:UiOutputs.Keys) {
            if ($key -in $script:OutputDeltas) { continue }
            if (-not $script:ArmParams.ContainsKey($key)) {
                $unmapped += $key
            }
        }
        $unmapped | Should -BeNullOrEmpty -Because "wizard outputs that don't map to ARM parameters cause ARM to reject the deploy with InvalidTemplate. Unmapped outputs: $($unmapped -join ', ')"
    }
}

Describe 'Dropdowns.AllowedValuesAreSubset' {

    It 'every wizard dropdown value is a member of the matching ARM parameter allowedValues' {
        # Strict-mode-safe property access — when other tests have set strict
        # mode and Pester preserves it across files, accessing
        # `$ap.allowedValues` directly on an ARM parameter that lacks the
        # constraint throws PropertyNotFoundException. Use the PSObject
        # Properties collection to check existence first.
        $violations = @()
        foreach ($name in $script:UiInputElements.Keys) {
            $el = $script:UiInputElements[$name]
            if (-not $el.AllowedValues) { continue }
            if (-not $script:ArmParams.ContainsKey($name)) { continue }
            $ap = $script:ArmParams[$name]
            if (-not ($ap.PSObject.Properties.Name -contains 'allowedValues')) { continue }
            if ($null -eq $ap.allowedValues) { continue }
            $armSet = @($ap.allowedValues)
            foreach ($v in $el.AllowedValues) {
                if ($v -notin $armSet) {
                    $violations += "${name}: wizard emits '$v' but ARM allowedValues = [$($armSet -join ', ')]"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because "wizard values outside ARM allowedValues cause `<value> is not part of allowed value(s)` deploy failures. Violations:`n  $($violations -join "`n  ")"
    }
}

Describe 'Outputs.SubsetOfArmParameters' {

    It 'every required ARM parameter (no default + not derived) is supplied by the wizard outputs' {
        # An ARM parameter is REQUIRED if it has no defaultValue. If the wizard
        # doesn't emit an output for it, the deploy fails with `the parameter
        # 'X' has no default value and was not assigned`.
        $missing = @()
        foreach ($name in $script:ArmParams.Keys) {
            $ap = $script:ArmParams[$name]
            $hasDefault = $ap.PSObject.Properties['defaultValue'] -and ($null -ne $ap.defaultValue -or $ap.PSObject.Properties['defaultValue'])
            # The ARM param model treats `"defaultValue": ""` as a default
            # (empty string IS a value). Treat any defaultValue presence as a default.
            if ($ap.PSObject.Properties['defaultValue']) { $hasDefault = $true }
            if (-not $hasDefault -and -not $script:UiOutputs.ContainsKey($name)) {
                $missing += $name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "ARM parameters without defaults must be supplied by the wizard or the deploy fails. Missing wizard outputs for: $($missing -join ', ')"
    }
}

