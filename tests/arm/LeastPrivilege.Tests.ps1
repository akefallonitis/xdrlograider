#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.15 plan-independent least-privilege gate. Enforces that every role
    assignment in deploy/modules/role-assignments.bicep is scoped to a specific
    resource (NOT subscription, NOT resource group, NOT broad Contributor) and
    that the principalType is set to ServicePrincipal.

.DESCRIPTION
    These invariants apply to ALL hosting plans. Companion gate to
    HostingPlanMatrix.Tests.ps1 which covers tier-specific differences.

    Violations would re-introduce privilege-escalation paths or Entra
    propagation race conditions.
#>

BeforeAll {
    $script:RepoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RoleBicep = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'role-assignments.bicep') -Raw

    # Find every role-assignment resource declaration. Bicep resources have
    # nested {} so we can't easily regex the whole block; instead, locate each
    # `resource <name> 'Microsoft.Authorization/roleAssignments@...'` header
    # and capture the body via balanced-brace walking.
    $script:RoleResources = [System.Collections.Generic.List[pscustomobject]]::new()
    # Pattern: every Bicep resource has `= {` after the type literal. For
    # conditional resources, that's `= if (cond) {`. The `= ` is REQUIRED in
    # both cases (not part of the optional `if (...)` group).
    $headerPattern = "resource\s+(\w+)\s+'Microsoft\.Authorization/roleAssignments@[\d\-]+'\s+=\s+(?:if\s*\([^)]+\)\s+)?\{"
    foreach ($headerMatch in [regex]::Matches($script:RoleBicep, $headerPattern)) {
        $name = $headerMatch.Groups[1].Value
        # Walk the brace balance forward from the opening { of this header.
        $start = $headerMatch.Index + $headerMatch.Length - 1   # position of opening {
        $depth = 1
        $i = $start + 1
        while ($i -lt $script:RoleBicep.Length -and $depth -gt 0) {
            $ch = $script:RoleBicep[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') { $depth-- }
            $i++
        }
        $body = $script:RoleBicep.Substring($start + 1, $i - $start - 2)
        $declarationContext = $script:RoleBicep.Substring($headerMatch.Index, $i - $headerMatch.Index)
        $script:RoleResources.Add([pscustomobject]@{
            Name                = $name
            Body                = $body
            DeclarationContext  = $declarationContext
        })
    }
}

Describe 'Least-privilege role-assignment invariants (plan-independent)' {

    It 'discovers at least 5 role assignments (Y1 baseline) and at most 6 (FC1/EP1)' {
        # Y1 = 5 roles (KV + Table + DCR + Blob + Queue)
        # FC1/EP1 = 6 roles (above + File SMB Share)
        $script:RoleResources.Count | Should -BeGreaterOrEqual 5 -Because 'iter-13.15 SAMI has at minimum: KV Secrets User + Storage Table Data Contributor + Monitoring Metrics Publisher + Storage Blob Data Owner + Storage Queue Data Contributor'
        $script:RoleResources.Count | Should -BeLessOrEqual 6 -Because 'never exceed 6 roles — anything else is privilege creep'
    }

    It 'every role assignment uses a SPECIFIC scope (no subscription() or resourceGroup() scopes)' {
        $offenders = @()
        foreach ($m in $script:RoleResources) {
            # Look for either an explicit scope: line OR fallback to resourceGroup() / subscription()
            if ($m.Body -match 'scope:\s*(subscription\(\)|resourceGroup\(\))') {
                $offenders += $m.Name
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "role assignments must be scoped to specific resources, not RG/subscription:`n$(($offenders | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'every role assignment sets principalType: ServicePrincipal (prevents Entra propagation race)' {
        $missing = @()
        foreach ($m in $script:RoleResources) {
            if ($m.Body -notmatch "principalType:\s*'ServicePrincipal'") {
                $missing += $m.Name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "principalType must be ServicePrincipal — without it, deploys race against Entra propagation:`n$(($missing | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'no role assignment uses a "Contributor" (broad) role — only specific-purpose RBAC roles' {
        # The known canonical broad roles to forbid:
        $broadRoles = @{
            'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
            '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Owner'
            'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
            '17d1049b-9a84-46fb-8f53-869881c3d3ab' = 'Storage Account Contributor'
        }
        $offenders = @()
        foreach ($id in $broadRoles.Keys) {
            if ($script:RoleBicep -match $id) {
                $offenders += "$($broadRoles[$id]) ($id)"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "broad-RBAC roles are forbidden — use specific data-plane roles:`n$(($offenders | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'role definition IDs are referenced via resourceId() (not hardcoded ARM paths)' {
        $missing = @()
        foreach ($m in $script:RoleResources) {
            if ($m.Body -notmatch "resourceId\('Microsoft\.Authorization/roleDefinitions',\s*\w+RoleId\)") {
                $missing += $m.Name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "role definitions must use resourceId() for portability across clouds:`n$(($missing | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'every role assignment uses guid() for deterministic name generation (idempotent re-deploys)' {
        $missing = @()
        foreach ($m in $script:RoleResources) {
            if ($m.DeclarationContext -notmatch 'name:\s*guid\(') {
                $missing += $m.Name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "role assignment names must use guid() so re-deploys are idempotent:`n$(($missing | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }
}

Describe 'Forward-compat sanity gates' {

    It 'role-assignments.bicep accepts the useFullManagedIdentity bool parameter' {
        $script:RoleBicep | Should -Match 'param useFullManagedIdentity bool' -Because 'tier-driven role gating is core to iter-13.15'
    }

    It 'main.bicep passes useFullManagedIdentity through to role-assignments module' {
        $mainBicep = Get-Content (Join-Path $script:RepoRoot 'deploy' 'main.bicep') -Raw
        $mainBicep | Should -Match "module roles 'modules/role-assignments\.bicep'(?s).*useFullManagedIdentity:" -Because 'main must wire the derived param through to the module'
    }

    It 'role assignment count is exactly 6 in source (5 unconditional + 1 conditional on useFullManagedIdentity)' {
        # Strict count gate: any new role assignment requires updating this number AND adding a test in HostingPlanMatrix.Tests.ps1.
        $script:RoleResources.Count | Should -Be 6 -Because 'iter-13.15 baseline is exactly 6 role assignments (the 6th is conditional on useFullManagedIdentity)'
    }
}
