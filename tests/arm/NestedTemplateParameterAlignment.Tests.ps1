#Requires -Modules Pester
<#
.SYNOPSIS
    Drift gate between deploy/compiled/mainTemplate.json's nested deployments
    and the templates they invoke.

.DESCRIPTION
    Every `Microsoft.Resources/deployments` resource with `properties.parameters`
    passes a parameter bag to a nested template. If a passed parameter doesn't
    have a matching declaration in the nested template's parameters block, the
    deploy fails at validation time with `InvalidTemplate / The following
    parameters were supplied, but do not correspond to any parameters defined
    in the template`.

    The exact bug class this gate prevents — surfaced 2026-05-01 in production
    deploy — was mainTemplate.json passing `workspaceLocation` to
    sentinelContent.json (via templateLink) when sentinelContent.json declared
    `location` (different name). Caught at Azure Portal review-time, not by the
    existing gates.

    Two cases this gate covers:
    A. Inline-template nested deployments (`properties.template.parameters`)
       — outer params must be subset of inner declared params (keys match).
    B. TemplateLink nested deployments where the URI references a sibling file
       in deploy/compiled/ — fetch the sibling, compare declared parameters.
       (External URIs / mid-deploy artifact paths are skipped — they live
       outside the offline-checkable scope.)
#>

BeforeAll {
    $script:RepoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CompiledRoot  = Join-Path $script:RepoRoot 'deploy' 'compiled'
    $script:ArmPath       = Join-Path $script:CompiledRoot 'mainTemplate.json'

    $script:Arm = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    $script:NestedDeploys = @($script:Arm.resources | Where-Object {
        $_.type -eq 'Microsoft.Resources/deployments'
    })
}

Describe 'NestedTemplate.InlineParameterAlignment' {

    It 'every inline-template nested deployment passes only declared parameters' {
        $violations = @()
        foreach ($n in $script:NestedDeploys) {
            if (-not ($n.properties.PSObject.Properties.Name -contains 'template')) { continue }
            if ($null -eq $n.properties.template) { continue }
            if (-not ($n.properties.template.PSObject.Properties.Name -contains 'parameters')) { continue }
            if ($null -eq $n.properties.template.parameters) { continue }

            $passedParams = @()
            if ($n.properties.PSObject.Properties.Name -contains 'parameters' -and $null -ne $n.properties.parameters) {
                $passedParams = @($n.properties.parameters.PSObject.Properties.Name)
            }
            $declaredParams = @($n.properties.template.parameters.PSObject.Properties.Name)

            foreach ($p in $passedParams) {
                if ($p -notin $declaredParams) {
                    $violations += "$($n.name): outer passes '$p' but inline template declares only [$($declaredParams -join ', ')]"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because "Outer-passed params must match inner template declarations or Azure rejects with InvalidTemplate.`n  $($violations -join "`n  ")"
    }
}

Describe 'NestedTemplate.TemplateLinkSiblingAlignment' {

    It 'every templateLink nested deployment to a sibling deploy/compiled/*.json passes only declared parameters' {
        $violations = @()
        foreach ($n in $script:NestedDeploys) {
            if (-not ($n.properties.PSObject.Properties.Name -contains 'templateLink')) { continue }
            if ($null -eq $n.properties.templateLink) { continue }
            if (-not ($n.properties.templateLink.PSObject.Properties.Name -contains 'uri')) { continue }

            # Match `[uri(deployment().properties.templateLink.uri, '<filename>.json')]`
            # which resolves at deploy-time to a sibling artifact in the same release.
            $uri = $n.properties.templateLink.uri
            if ($uri -notmatch "uri\(deployment\(\)\.properties\.templateLink\.uri,\s*'([^']+\.json)'\)") {
                continue
            }
            $siblingFile = $matches[1]
            $siblingPath = Join-Path $script:CompiledRoot $siblingFile
            if (-not (Test-Path -LiteralPath $siblingPath)) {
                $violations += "$($n.name): templateLink points to '$siblingFile' but file not present in deploy/compiled/"
                continue
            }

            $sibling = Get-Content -LiteralPath $siblingPath -Raw | ConvertFrom-Json -Depth 50
            if (-not ($sibling.PSObject.Properties.Name -contains 'parameters')) { continue }
            if ($null -eq $sibling.parameters) { continue }

            $passedParams = @()
            if ($n.properties.PSObject.Properties.Name -contains 'parameters' -and $null -ne $n.properties.parameters) {
                $passedParams = @($n.properties.parameters.PSObject.Properties.Name)
            }
            $declaredParams = @($sibling.parameters.PSObject.Properties.Name)

            foreach ($p in $passedParams) {
                if ($p -notin $declaredParams) {
                    $violations += "$($n.name) -> ${siblingFile}: outer passes '$p' but sibling declares only [$($declaredParams -join ', ')]"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because "Outer-passed params must match sibling template declarations or Azure rejects with InvalidTemplate.`n  $($violations -join "`n  ")"
    }
}

Describe 'NestedTemplate.ScopeIsInner' {

    It 'every templateLink nested deployment uses expressionEvaluationOptions.scope=inner (so its explicit parameters block actually passes through)' {
        # scope=outer makes parameters() inside the linked template resolve
        # against the PARENT scope, which silently IGNORES the explicit
        # `parameters` block. If the parent doesn't declare matching params,
        # the linked template fails at runtime with cryptic missing-param
        # errors. scope=inner is the only correct choice when a `parameters`
        # block is provided on the deployment.
        # This was the exact bug surfaced 2026-05-01 — sentinelContent-* used
        # scope=outer but mainTemplate.json doesn't declare `workspaceName` /
        # `location` as parameters, so the linked sentinelContent.json couldn't
        # resolve them.
        $violations = @()
        foreach ($n in $script:NestedDeploys) {
            if (-not ($n.properties.PSObject.Properties.Name -contains 'templateLink')) { continue }
            if ($null -eq $n.properties.templateLink) { continue }
            $hasParamsBlock = $n.properties.PSObject.Properties.Name -contains 'parameters' -and $null -ne $n.properties.parameters
            if (-not $hasParamsBlock) { continue }

            $scope = $null
            if ($n.properties.PSObject.Properties.Name -contains 'expressionEvaluationOptions' -and
                $null -ne $n.properties.expressionEvaluationOptions -and
                $n.properties.expressionEvaluationOptions.PSObject.Properties.Name -contains 'scope') {
                $scope = $n.properties.expressionEvaluationOptions.scope
            }
            if ($scope -ne 'inner') {
                $violations += "$($n.name): templateLink with explicit parameters block uses scope='$scope' (must be 'inner')"
            }
        }
        $violations | Should -BeNullOrEmpty -Because "scope=outer silently ignores the explicit parameters block. Violations:`n  $($violations -join "`n  ")"
    }
}

Describe 'NestedTemplate.StorageAccountNameLength' {

    It 'derived stName variable is clamped to <=24 chars (Azure Storage account name limit)' {
        # Azure Storage requires 3-24 lowercase alphanumeric. With max
        # projectPrefix=12 (per @maxLength) + env='staging'=7 + 'st'=2 +
        # suffix=6 = 27 chars — over the limit. Without a substring/clamp the
        # deploy fails with `StorageAccountNameInvalid`.
        $varDef = $script:Arm.variables.stName
        $varDef | Should -Not -BeNullOrEmpty
        # Either uses substring(...) clamp OR is short enough by static
        # construction (no variable expansion can push it over 24).
        ($varDef -match 'substring\(' -or $varDef.Length -lt 24) | Should -BeTrue -Because "stName must be clamped via substring() to <=24 chars or be statically short"
    }
}
