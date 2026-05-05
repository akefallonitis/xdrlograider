#Requires -Modules Pester
<#
.SYNOPSIS
    ARM template invariant: variables MUST NOT contain listKeys() / list*() /
    reference() function calls. Azure rejects deploys with InvalidTemplate when
    these deployment-time-resolving functions appear at the variables-section
    parse-time scope.

.DESCRIPTION
    Per Microsoft ARM rule (https://learn.microsoft.com/azure/azure-resource-manager/templates/variables):

        Within the variables section, you can't use any of the reference,
        list*, listKeys, listAccountSas, ... functions. These functions get
        their values from the runtime state of a resource, and can't be
        executed before the deployment exists.

    Pre-fix root cause: the FC1/EP1 hosting plan tier-fix introduced three
    variables that each embedded a listKeys() call:
       sharedKeyConnString
       azureWebJobsStorageSettings_Y1
       websiteContentSettings_SharedKey
    Azure deploy validator rejected the template at parse time with
    InvalidTemplate even before the deployment got to PreflightValidation.

    The fix: move the shared-key connection string construction OUT of the
    variables section and INTO the resource property where it lives at
    deploy-time scope. listKeys() resolves correctly there because ARM
    evaluates resource properties after the dependency graph completes.

    This gate also catches the symmetric reference() bug — the same ARM rule
    rejects reference() in variables. We have one test per function family so
    a regression names the exact violation class.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:Arm      = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50
}

Describe 'ArmTemplate.NoListKeysInVariables' {
    It 'no variable contains listKeys() call (ARM rejects this with InvalidTemplate)' {
        $violations = @()
        foreach ($v in $script:Arm.variables.PSObject.Properties) {
            $val = $v.Value
            $valStr = if ($val -is [string]) { $val } else { ($val | ConvertTo-Json -Depth 50 -Compress) }
            if ($valStr -match 'listKeys\(' -or $valStr -match 'list[A-Z]\w+\(' -or $valStr -match '\[reference\(') {
                $violations += "variables.$($v.Name) contains a listKeys()/list*()/reference() call which ARM rejects (variables resolve at parse time; these functions resolve at deploy time)"
            }
        }
        $violations | Should -BeNullOrEmpty -Because "ARM templates: variables cannot use listKeys/list*/reference functions. Move them to resource properties."
    }
}

Describe 'ArmTemplate.NoReferenceInVariables' {
    # Same gate but specifically for reference() — same rule
    It 'no variable contains reference() call' {
        $violations = @()
        foreach ($v in $script:Arm.variables.PSObject.Properties) {
            $val = $v.Value
            $valStr = if ($val -is [string]) { $val } else { ($val | ConvertTo-Json -Depth 50 -Compress) }
            if ($valStr -match '\[reference\(' -or $valStr -match ',\s*reference\(') {
                $violations += "variables.$($v.Name) contains a reference() call"
            }
        }
        $violations | Should -BeNullOrEmpty
    }
}
