# Architecture J (Plan R++++++++++ AMEND-3): Schema Unification — Sentinel
# Entity Type canonical column coverage regression-locker.
#
# Asserts that every Defender_<Category>_CL workspace table declares at LEAST
# the universal canonical cols (HostMdatpId / AccountUPNSuffix / IpAddress /
# CveId / PolicyId) so cross-table KQL `join` works for operators. Streams
# populate these cols where the source response carries the field; cols are
# nullable per AMEND-3 "apply where possible" rule.
#
# Prevents regression where future stream additions accidentally drop the
# canonical entity cols from per-category tables.

#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ArmPath  = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'
    if (-not (Test-Path $script:ArmPath)) {
        throw "mainTemplate.json not found at $script:ArmPath"
    }
    $script:Arm = Get-Content $script:ArmPath -Raw | ConvertFrom-Json -Depth 50

    # Extract workspace table cols (StrictMode-safe property guards)
    $script:WorkspaceTableCols = @{}
    foreach ($res in $script:Arm.resources) {
        if ($res.type -ne 'Microsoft.Resources/deployments') { continue }
        if (-not $res.PSObject.Properties['properties']) { continue }
        if (-not $res.properties.PSObject.Properties['template']) { continue }
        if (-not $res.properties.template.PSObject.Properties['resources']) { continue }
        foreach ($inner in $res.properties.template.resources) {
            if (-not $inner.PSObject.Properties['type']) { continue }
            if ($inner.type -notmatch 'workspaces/tables$') { continue }
            if (-not $inner.PSObject.Properties['properties']) { continue }
            if (-not $inner.properties.PSObject.Properties['schema']) { continue }
            $name = $inner.properties.schema.name
            if ($name -and $name -match '^Defender_\w+_CL$') {
                $script:WorkspaceTableCols[$name] = @($inner.properties.schema.columns | ForEach-Object { $_.name })
            }
        }
    }

    # Universal canonical entity cols (Architecture J AMEND-3) — present in
    # EVERY Defender_<Category>_CL table to enable cross-table joins.
    # Streams populate them WHERE source carries the field; col nullable.
    $script:UniversalEntityCols = @(
        'HostMdatpId',         # Sentinel Host entity: machineId
        'HostFullName',        # Sentinel Host entity: computerDnsName / FQDN
        'AccountUPNSuffix',    # Sentinel Account entity: domain part of UPN
        'IpAddress',           # Sentinel IP entity
        'CveId',               # Custom CVE entity (TVM cross-ref)
        'PolicyId'             # Custom Policy entity (config cross-ref)
    )

    # Category-specific canonical cols (added to relevant per-category tables)
    $script:CategorySpecificCols = @{
        'Defender_EndpointDeviceManagement_CL' = @('HostName', 'HostDnsDomain', 'HostOSFamily', 'HostAadId', 'MachineGroupId', 'MachineGroupName')
        'Defender_EndpointConfiguration_CL'    = @('Platform', 'PolicyType')
        'Defender_VulnerabilityManagement_CL'  = @('OutbreakId')
        'Defender_ThreatAnalytics_CL'          = @('OutbreakId', 'Url', 'DomainName', 'FileName', 'FileHashType', 'FileHashValue')
        'Defender_IdentityProtection_CL'       = @('AccountName', 'AccountObjectId', 'AccountSid')
        'Defender_ActionCenter_CL'             = @('AlertId', 'AccountName', 'AccountObjectId')
    }
}

Describe 'Architecture J — Universal canonical entity cols across Defender_*_CL tables' {

    It 'every Defender_<Category>_CL table declares all 6 universal canonical entity cols' {
        $missingByTable = @{}
        foreach ($tableName in ($script:WorkspaceTableCols.Keys | Sort-Object)) {
            $missing = @($script:UniversalEntityCols | Where-Object { $_ -notin $script:WorkspaceTableCols[$tableName] })
            if ($missing.Count -gt 0) {
                $missingByTable[$tableName] = $missing -join ','
            }
        }
        if ($missingByTable.Count -gt 0) {
            $reasonLines = @('Architecture J: Universal canonical entity cols missing — operators cannot cross-correlate tables:')
            foreach ($t in $missingByTable.Keys) {
                $reasonLines += ("  ${t} -> missing [$($missingByTable[$t])]")
            }
            $reason = $reasonLines -join [Environment]::NewLine
            $missingByTable.Count | Should -Be 0 -Because $reason
        }
    }

    It 'category-specific canonical cols present on relevant tables' {
        $missingBySpec = @{}
        foreach ($t in $script:CategorySpecificCols.Keys) {
            if (-not $script:WorkspaceTableCols.ContainsKey($t)) {
                $missingBySpec[$t] = "TABLE_NOT_FOUND_IN_ARM"
                continue
            }
            $expected = $script:CategorySpecificCols[$t]
            $present  = $script:WorkspaceTableCols[$t]
            $missing  = @($expected | Where-Object { $_ -notin $present })
            if ($missing.Count -gt 0) {
                $missingBySpec[$t] = ($missing -join ',')
            }
        }
        if ($missingBySpec.Count -gt 0) {
            $reasonLines = @('Architecture J: Category-specific canonical entity cols missing:')
            foreach ($t in $missingBySpec.Keys) {
                $reasonLines += ("  ${t} -> missing [$($missingBySpec[$t])]")
            }
            $reason = $reasonLines -join [Environment]::NewLine
            $missingBySpec.Count | Should -Be 0 -Because $reason
        }
    }
}
