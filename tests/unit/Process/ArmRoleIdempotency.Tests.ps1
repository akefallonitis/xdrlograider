#Requires -Version 7.4
# WS4.1 · ARM role-assignment idempotency pin (the RoleAssignmentExists rollback killer).
# Live-proven failure 2026-06-04: deployment xdrlr-sync-Operations-1780602582 bundled a role grant whose
# guid() name was seeded with the FA NAME (stable) — a recreated FA (new SAMI principal) made ARM try to
# UPDATE the existing assignment's principal → RoleAssignmentExists → the WHOLE deployment (including the
# 136-col schema) rolled back. The fix: every roleAssignment name is guid(scope, parameters('principalId'),
# tag) inside a nested deployment. These pins make a regression RED at the template level.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:tpl = Get-Content (Join-Path $repo 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json -Depth 60
    $script:fnd = Get-Content (Join-Path $repo 'deploy\foundation.json') -Raw | ConvertFrom-Json -Depth 60

    function Get-AllRoleAssignments($node) {
        $found = @()
        if ($null -eq $node) { return $found }
        if ($node -is [System.Collections.IList]) { foreach ($e in $node) { $found += Get-AllRoleAssignments $e }; return $found }
        if ($node -isnot [System.Management.Automation.PSCustomObject]) { return $found }
        if ($node.PSObject.Properties['type'] -and $node.type -eq 'Microsoft.Authorization/roleAssignments') { $found += ,$node }
        foreach ($p in $node.PSObject.Properties) { if ($p.Name -in @('resources','template','properties')) { $found += Get-AllRoleAssignments $p.Value } }
        return $found
    }
    $script:allRolesMain = @(Get-AllRoleAssignments $script:tpl.resources)
    $script:allRolesFnd  = @(Get-AllRoleAssignments $script:fnd.resources)
}

Describe 'WS4.1 · role assignments are principalId-seeded and nested (mainTemplate + foundation)' {
    It 'mainTemplate carries role assignments (the grants exist)' {
        $script:allRolesMain.Count | Should -BeGreaterOrEqual 6
    }
    It 'ZERO roleAssignments at the TOP level of mainTemplate (all nested)' {
        @($script:tpl.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }) | Should -BeNullOrEmpty
    }
    It "every roleAssignment NAME in mainTemplate is seeded with parameters('principalId')" {
        foreach ($ra in $script:allRolesMain) {
            $ra.name | Should -Match "parameters\('principalId'\)" -Because $ra.name
            $ra.name | Should -Not -Match "variables\('functionAppName'\)" -Because 'FA-name seeding is the rollback class'
        }
    }
    It "every roleAssignment NAME in foundation.json is seeded with parameters('principalId')" {
        $script:allRolesFnd.Count | Should -BeGreaterOrEqual 5
        foreach ($ra in $script:allRolesFnd) {
            $ra.name | Should -Match "parameters\('principalId'\)" -Because $ra.name
        }
    }
    It 'every roleAssignment principalId property is the nested parameter (never an inline reference())' {
        foreach ($ra in ($script:allRolesMain + $script:allRolesFnd)) {
            $ra.properties.principalId | Should -Be "[parameters('principalId')]" -Because $ra.name
        }
    }
}

# FH-4 · Validate-ArmCrossReferences Check #11 · per-DCR Monitoring Metrics Publisher COMPLETENESS.
# Every top-level DCR MUST have a scoped MMP role (FA SAMI → that DCR). Without it ingestion 403s and the
# category silently lands 0 rows (cat#2 class). Axis 36 (regen==committed) can't catch a role the generator
# fails to emit — both sides agree-wrong. This is the independent structural invariant + the RED proof that
# the gate actually fires (a missing role is not silently tolerated).
Describe 'FH-4 · per-DCR MMP role completeness (cat#2 silent-0-rows guard · Check #11)' {
    BeforeAll {
        $script:validator = Join-Path $repo 'tools\Validate-ArmCrossReferences.ps1'
        $script:dcrToks = @($script:tpl.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and ([string]$_.name) -match '-dcr-([a-z0-9]+)-' } |
            ForEach-Object { [regex]::Match([string]$_.name, '-dcr-([a-z0-9]+)-').Groups[1].Value })
        $script:roleToks = @($script:tpl.resources |
            Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and ([string]$_.name) -match 'role-dcr-([a-z0-9]+)-' -and (($_ | ConvertTo-Json -Depth 30 -Compress) -match 'monitoringMetricsPublisherRoleId') } |
            ForEach-Object { [regex]::Match([string]$_.name, 'role-dcr-([a-z0-9]+)-').Groups[1].Value })
    }
    It 'every DCR in mainTemplate has a scoped MMP role (1:1 · no silent-0-rows DCR)' {
        $script:dcrToks.Count | Should -BeGreaterThan 0 -Because 'the pilot ships at least the Operations DCR'
        foreach ($t in $script:dcrToks) { $script:roleToks | Should -Contain $t -Because "DCR token '$t' must have a Monitoring Metrics Publisher role" }
    }
    It 'no orphan MMP role targets a missing DCR' {
        foreach ($t in $script:roleToks) { $script:dcrToks | Should -Contain $t -Because "MMP role token '$t' must have a DCR" }
    }
    It 'the gate FAILS when a per-DCR role is stripped (Check #11 fires · RED proof)' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-mt-norole-" + [Guid]::NewGuid().ToString('N') + ".json")
        try {
            $mut = Get-Content (Join-Path $repo 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json -Depth 60
            $mut.resources = @($mut.resources | Where-Object { -not (([string]$_.name) -match 'role-dcr-') })
            $mut | ConvertTo-Json -Depth 60 | Out-File $tmp -Encoding utf8
            $out = & pwsh -NoProfile -File $script:validator -TemplatePath $tmp 2>&1 | Out-String
            $LASTEXITCODE | Should -Not -Be 0 -Because 'a DCR without its MMP role must FAIL the gate'
            $out | Should -Match 'Check #11' -Because 'the per-DCR-role completeness check must be what fires'
        } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    }
}
