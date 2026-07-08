#Requires -Version 7.4
# Unit test for Onboard-CategorySurgical's what-if safety predicate Test-XdrChangeTouchesFoundation — the 0-KeyVault /
# 0-Web-sites HARD-ASSERT gate. Dot-sources the tool via the XDRLR_ONBOARD_DOTSOURCE_ONLY seam so the PURE predicate is
# testable without az. This gate is security-critical: a false-NEGATIVE would let a foundation mutation through, and the
# false-POSITIVE class (an Unsupported role whose expression merely REFERENCES the FA) regressed the cat-1 re-onboard.

BeforeAll {
    $tool = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'tools' 'Onboard-CategorySurgical.ps1')).Path
    $env:XDRLR_ONBOARD_DOTSOURCE_ONLY = '1'
    try { . $tool -Portal 'Defender' -Category 'X' -ResourceGroup 'rg' } finally { $env:XDRLR_ONBOARD_DOTSOURCE_ONLY = $null }
}

Describe 'Onboard-CategorySurgical · Test-XdrChangeTouchesFoundation (0-KV/0-Web safety gate)' {
    It 'NoChange / Ignore never touch foundation' {
        Test-XdrChangeTouchesFoundation -ChangeType 'NoChange' -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/x' | Should -BeFalse
        Test-XdrChangeTouchesFoundation -ChangeType 'Ignore'   -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/x'       | Should -BeFalse
    }
    It 'a Modify/Create/Delete whose TARGET is KeyVault or Web-sites is FORBIDDEN (fail closed)' {
        Test-XdrChangeTouchesFoundation -ChangeType 'Modify' -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/xdrlr-kv-zocqir' | Should -BeTrue
        Test-XdrChangeTouchesFoundation -ChangeType 'Create' -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/xdrlr-fa-zocqir'       | Should -BeTrue
        Test-XdrChangeTouchesFoundation -ChangeType 'Delete' -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/x/secrets/y'    | Should -BeTrue
    }
    It 'a Modify of the per-category TABLE / DCR is allowed (not foundation)' {
        Test-XdrChangeTouchesFoundation -ChangeType 'Modify' -ResId '/subscriptions/s/resourceGroups/ws/providers/Microsoft.OperationalInsights/workspaces/ws/tables/Defender_ExposureManagement_CL' | Should -BeFalse
        Test-XdrChangeTouchesFoundation -ChangeType 'Modify' -ResId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/xdrlr-dcr-exposuremanagement-zocqir' | Should -BeFalse
    }
    It 'the Unsupported per-DCR roleAssignment is ALLOWED despite its expression referencing the FA (the false-positive that regressed cat-1)' {
        $roleExpr = "[extensionResourceId('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/xdrlr-dcr-exposuremanagement-zocqir', 'Microsoft.Authorization/roleAssignments', guid('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Insights/dataCollectionRules/xdrlr-dcr-exposuremanagement-zocqir', reference('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/xdrlr-fa-zocqir', '2024-11-01', 'full').identity.principalId, 'MMP-DCR-exposuremanagement'))]"
        Test-XdrChangeTouchesFoundation -ChangeType 'Unsupported' -ResId $roleExpr | Should -BeFalse
    }
    It 'an Unsupported change that is NOT the per-DCR role fails CLOSED (unknown opaque → STOP)' {
        Test-XdrChangeTouchesFoundation -ChangeType 'Unsupported' -ResId "[reference('/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/xdrlr-fa-zocqir', '2024-11-01', 'full').siteConfig]" | Should -BeTrue
    }
}

Describe 'Onboard-CategorySurgical · Test-XdrTableColumnDrift (recreate-on-drift guard · in-place LA table modify is unreliable)' {
    It 'flags a type-change (RETYPE) — the string→boolean class that dropped Operations typed cols (2026-06-17)' {
        $target = @([pscustomobject]@{ name = 'IsSuspended'; type = 'boolean' })
        $live   = @([pscustomobject]@{ name = 'IsSuspended'; type = 'string' })
        $d = @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live)
        $d.Count | Should -Be 1
        $d[0]    | Should -Match '^RETYPE IsSuspended'
    }
    It 'flags a newly-ADDED target column missing from the live table (in-place add → stale ingestion schema)' {
        $target = @([pscustomobject]@{ name = 'OrgId'; type = 'string' }, [pscustomobject]@{ name = 'NewCol'; type = 'string' })
        $live   = @([pscustomobject]@{ name = 'OrgId'; type = 'string' })
        $d = @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live)
        $d.Count | Should -Be 1
        $d[0]    | Should -Match '^ADD NewCol'
    }
    It 'returns EMPTY when the live schema already matches the target (no recreate needed)' {
        $cols = @([pscustomobject]@{ name = 'OrgId'; type = 'string' }, [pscustomobject]@{ name = 'AccountMode'; type = 'long' })
        @(Test-XdrTableColumnDrift -TargetCols $cols -LiveCols $cols).Count | Should -Be 0
    }
    It 'normalizes ARM↔KQL type names (artifact boolean == getschema bool · dateTime == datetime · int == long) — no false drift' {
        # Target = artifact/ARM names; Live = the EFFECTIVE getschema (KQL) names — the realistic post-recreate match.
        $target = @([pscustomobject]@{ name = 'EventTime'; type = 'dateTime' }, [pscustomobject]@{ name = 'IsX'; type = 'boolean' }, [pscustomobject]@{ name = 'Cnt'; type = 'int' })
        $live   = @([pscustomobject]@{ name = 'EventTime'; type = 'datetime' }, [pscustomobject]@{ name = 'IsX'; type = 'bool' }, [pscustomobject]@{ name = 'Cnt'; type = 'long' })
        @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live).Count | Should -Be 0
    }
    It 'flags artifact boolean vs EFFECTIVE getschema string as RETYPE (the exact in-place-modify failure)' {
        # The live bug: declared=boolean but getschema(effective)=string → the guard MUST flag it (else no recreate).
        $target = @([pscustomobject]@{ name = 'IsSuspended'; type = 'boolean' })
        $live   = @([pscustomobject]@{ name = 'IsSuspended'; type = 'string' })
        $d = @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live)
        $d.Count | Should -Be 1
        $d[0]    | Should -Match 'RETYPE IsSuspended \(string->bool\)'
    }
    It 'IGNORES extra LA-managed live columns (TimeGenerated/TenantId/Type) — drift is one-directional (target not-subset-of live)' {
        $target = @([pscustomobject]@{ name = 'OrgId'; type = 'string' })
        $live   = @([pscustomobject]@{ name = 'OrgId'; type = 'string' }, [pscustomobject]@{ name = 'TimeGenerated'; type = 'dateTime' }, [pscustomobject]@{ name = 'TenantId'; type = 'string' })
        @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live).Count | Should -Be 0
    }
    It 'flags BOTH a retype and an add together (the live Operations case · boolean retypes + added *Json cols)' {
        $target = @([pscustomobject]@{ name = 'IsSuspended'; type = 'boolean' }, [pscustomobject]@{ name = 'AccountMode'; type = 'long' }, [pscustomobject]@{ name = 'IrmMtpPermissionsJson'; type = 'string' })
        $live   = @([pscustomobject]@{ name = 'IsSuspended'; type = 'string' }, [pscustomobject]@{ name = 'AccountMode'; type = 'long' })
        $d = @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols $live)
        $d.Count | Should -Be 2
        ($d -join '|') | Should -Match 'RETYPE IsSuspended'
        ($d -join '|') | Should -Match 'ADD IrmMtpPermissionsJson'
    }
    It 'empty live cols → every target col is drift (pure-function behavior · the tool guards table-exists before calling)' {
        $target = @([pscustomobject]@{ name = 'A'; type = 'string' }, [pscustomobject]@{ name = 'B'; type = 'long' })
        @(Test-XdrTableColumnDrift -TargetCols $target -LiveCols @()).Count | Should -Be 2
    }
}

Describe 'Onboard-CategorySurgical · Get-XdrCanonicalColType (ARM↔KQL getschema type normalization)' {
    It 'maps ARM boolean → KQL bool (the divergence that hid the live drift)' { Get-XdrCanonicalColType 'boolean' | Should -Be 'bool' }
    It 'passes KQL bool through unchanged' { Get-XdrCanonicalColType 'bool' | Should -Be 'bool' }
    It 'folds int / int32 / int64 → long (LA stores int32 as long · harmless widening)' {
        Get-XdrCanonicalColType 'int'   | Should -Be 'long'
        Get-XdrCanonicalColType 'int32' | Should -Be 'long'
        Get-XdrCanonicalColType 'int64' | Should -Be 'long'
    }
    It 'normalizes dateTime case → datetime' { Get-XdrCanonicalColType 'dateTime' | Should -Be 'datetime' }
    It 'passes real / string / long through (lower-invariant)' {
        Get-XdrCanonicalColType 'Real'   | Should -Be 'real'
        Get-XdrCanonicalColType 'string' | Should -Be 'string'
        Get-XdrCanonicalColType 'long'   | Should -Be 'long'
    }
}
