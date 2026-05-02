#Requires -Modules Pester
<#
.SYNOPSIS
    Y1-only least-privilege gate. Enforces that every role assignment in the
    compiled ARM template (deploy/compiled/mainTemplate.json) is scoped to a
    specific resource (NOT subscription, NOT resource group, NOT broad
    Contributor) and that the principalType is set to ServicePrincipal.

.DESCRIPTION
    Post v0.1.0-beta the connector is Y1-only — FC1/EP1 hosting was dropped
    along with the multi-tier role gating. The ARM template is the single
    source of truth (Bicep was archived to .internal/bicep-reference/).

    Y1 baseline = 7 role assignments:
      - Key Vault Secrets User                    (1)
      - Storage Table Data Contributor            (1)
      - Monitoring Metrics Publisher per DCR      (5; one per DCR sharing the DCE)

    Violations would re-introduce privilege-escalation paths.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:Arm      = Get-Content -LiteralPath $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    $script:RoleAssignments = @($script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
}

Describe 'Least-privilege role-assignment invariants (Y1-only)' {

    It 'declares exactly 7 role assignments (Y1-only baseline)' {
        # 5-DCR shape: KV Secrets User + Storage Table Data Contributor +
        # 5x Monitoring Metrics Publisher (one per DCR) = 7. Strict count
        # gate: any new role assignment requires updating this number.
        $script:RoleAssignments.Count | Should -Be 7 -Because 'Y1-only baseline: KV Secrets User + Storage Table + 5x Monitoring Metrics Publisher (one per DCR) = 7'
    }

    It 'every role assignment uses a SPECIFIC scope (no subscription() or resourceGroup() scopes)' {
        $offenders = @()
        foreach ($r in $script:RoleAssignments) {
            $scope = if ($r.PSObject.Properties.Name -contains 'scope') { [string]$r.scope } else { '' }
            # ARM format: scope must point to a specific resource (Microsoft.X/Y/...)
            if ([string]::IsNullOrEmpty($scope) -or $scope -match 'subscription\(\)' -or $scope -match 'resourceGroup\(\)$') {
                $offenders += $r.name
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "role assignments must be scoped to specific resources, not RG/subscription:`n$(($offenders | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'every role assignment sets principalType: ServicePrincipal (prevents Entra propagation race)' {
        $missing = @()
        foreach ($r in $script:RoleAssignments) {
            $pt = if ($r.properties.PSObject.Properties.Name -contains 'principalType') { [string]$r.properties.principalType } else { '' }
            if ($pt -ne 'ServicePrincipal') {
                $missing += $r.name
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
        $rawTemplate = Get-Content -LiteralPath $script:ArmPath -Raw
        $offenders = @()
        foreach ($id in $broadRoles.Keys) {
            if ($rawTemplate -match $id) {
                $offenders += "$($broadRoles[$id]) ($id)"
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "broad-RBAC roles are forbidden — use specific data-plane roles:`n$(($offenders | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'role definition IDs are referenced via resourceId() (not hardcoded ARM paths)' {
        $missing = @()
        foreach ($r in $script:RoleAssignments) {
            $rd = if ($r.properties.PSObject.Properties.Name -contains 'roleDefinitionId') { [string]$r.properties.roleDefinitionId } else { '' }
            if ($rd -notmatch 'resourceId\(') {
                $missing += $r.name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "role definitions must use resourceId() for portability across clouds:`n$(($missing | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }

    It 'every role assignment uses guid() for deterministic name generation (idempotent re-deploys)' {
        $missing = @()
        foreach ($r in $script:RoleAssignments) {
            if ([string]$r.name -notmatch 'guid\(') {
                $missing += $r.name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "role assignment names must use guid() so re-deploys are idempotent:`n$(($missing | ForEach-Object { '  - ' + $_ }) -join "`n")"
    }
}

Describe 'Y1-only role matrix (canonical role IDs)' {

    It 'grants Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6)' {
        $rawTemplate = Get-Content -LiteralPath $script:ArmPath -Raw
        $rawTemplate | Should -Match '4633458b-17de-408a-b874-0445c86b69e6' -Because 'KV Secrets User canonical role GUID'
    }

    It 'grants Storage Table Data Contributor (0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3)' {
        $rawTemplate = Get-Content -LiteralPath $script:ArmPath -Raw
        $rawTemplate | Should -Match '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    }

    It 'grants Monitoring Metrics Publisher (3913510d-42f4-4e42-8a64-420c390055eb) on every DCR (5 total)' {
        # 5-DCR shape: one role assignment per DCR sharing the DCE. The
        # roleDefinitionId is built via resourceId() that references the
        # variable `monitoringMetricsPublisherRoleId`, so we match either the
        # literal GUID OR the variable reference (the resolved value is
        # identical at deploy time).
        $mmp = @($script:RoleAssignments | Where-Object {
            $rd = [string]$_.properties.roleDefinitionId
            $rd -match '3913510d-42f4-4e42-8a64-420c390055eb' -or
            $rd -match "variables\(\s*'monitoringMetricsPublisherRoleId'\s*\)"
        })
        $mmp.Count | Should -Be 5 -Because 'each of the 5 DCRs needs its own Monitoring Metrics Publisher role'

        # Belt-and-braces: variable must hold the canonical MMP GUID
        $script:Arm.variables.monitoringMetricsPublisherRoleId |
            Should -Be '3913510d-42f4-4e42-8a64-420c390055eb' -Because 'variable must resolve to the canonical Monitoring Metrics Publisher GUID'
    }
}
