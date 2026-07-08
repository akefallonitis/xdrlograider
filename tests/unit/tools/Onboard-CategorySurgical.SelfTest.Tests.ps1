#Requires -Version 7.4
# GM-2 · surgical-output self-test for tools/Onboard-CategorySurgical.ps1. The surgical onboard is the SECOND deploy
# writer (beside dev-tools/Build-MainTemplate.ps1). It historically HARDCODED transformKql='source' at the DCR dataFlow;
# GM-2 makes it CARRY the artifact's transformKql via the shared Parser.Get-XdrArtifactTransformKql (single-source with
# Build-MainTemplate's Get-StreamInfo). This test drives the REAL tool offline (-EmitTemplateOnly · zero Azure) with a
# synthetic artifact whose transformKql is a NON-identity probe, and asserts the emitted DCR dataFlow carries it — i.e.
# proves the hardcode is gone end-to-end through the tool, not by re-implementing the assembly.

Describe 'GM-2 · Onboard-CategorySurgical carries the artifact transformKql (surgical output · -EmitTemplateOnly)' {
    BeforeAll {
        $script:tool = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'tools' 'Onboard-CategorySurgical.ps1')).Path
        $script:raw  = Get-Content -LiteralPath $script:tool -Raw
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('xdrlr-gm2-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null

        # A synthetic per-category artifact with a NON-identity transformKql probe. Only the 4 field-paths the assembler
        # consumes are present (table name/columns · stream columns · dataFlows[0].transformKql).
        $script:probe = 'source | extend _gm2probe = toint(Severity)'
        $artifact = [ordered]@{
            TableResource = [ordered]@{ properties = [ordered]@{ schema = [ordered]@{
                name = 'Defender_Gm2Probe_CL'
                columns = @(
                    [ordered]@{ name = 'TimeGenerated'; type = 'datetime' }
                    [ordered]@{ name = 'RawJson';       type = 'string'   }
                )
            } } }
            DcrResource = [ordered]@{ properties = [ordered]@{
                streamDeclarations = [ordered]@{ 'Custom-Defender_Gm2Probe_CL' = [ordered]@{ columns = @(
                    [ordered]@{ name = 'TimeGenerated'; type = 'datetime' }
                    [ordered]@{ name = 'RawJson';       type = 'string'   }
                ) } }
                dataFlows = @(
                    [ordered]@{
                        streams      = @('Custom-Defender_Gm2Probe_CL')
                        destinations = @('xdrlrWorkspace')
                        transformKql = $script:probe
                        outputStream = 'Custom-Defender_Gm2Probe_CL'
                    }
                )
            } }
        }
        $script:artifactPath = Join-Path $script:work 'Defender-Gm2Probe.json'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($script:artifactPath, ($artifact | ConvertTo-Json -Depth 30), $utf8)

        # -EmitTemplateOnly returns BEFORE reading the params file, but the existence check still runs → a minimal one.
        $script:paramsPath = Join-Path $script:work 'params.json'
        [IO.File]::WriteAllText($script:paramsPath, '{"parameters":{"workspaceResourceId":{"value":"/subscriptions/x/resourceGroups/ws-rg/providers/Microsoft.OperationalInsights/workspaces/ws"},"deploymentNameSuffix":{"value":"abc123"},"location":{"value":"eastus"}}}', $utf8)
    }
    AfterAll {
        if ($script:work -and (Test-Path $script:work)) { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parses with zero errors' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }

    It 'emits a DCR whose dataFlow transformKql == the artifact probe (carried · not hardcoded source)' {
        $out = & $script:tool -Portal 'Defender' -Category 'Gm2Probe' -ResourceGroup 'test-rg' `
            -SchemaArtifactPath $script:artifactPath -ParametersFile $script:paramsPath -EmitTemplateOnly
        $emitted = @($out) | Where-Object { $_ -is [string] -and $_ -match '\.json$' } | Select-Object -Last 1
        $emitted | Should -Not -BeNullOrEmpty
        Test-Path $emitted | Should -BeTrue
        try {
            $tpl = Get-Content $emitted -Raw | ConvertFrom-Json -Depth 60
            $dcr = @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })[0]
            $dcr | Should -Not -BeNullOrEmpty
            @($dcr.properties.dataFlows)[0].transformKql | Should -BeExactly $script:probe
        } finally {
            if ($emitted -and (Test-Path $emitted)) { Remove-Item $emitted -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'the DCR dependsOn references only IN-TEMPLATE resources — never the external DCE (ARM InvalidTemplate guard)' {
        # The DCE is a foundation resource NOT defined in the surgical template. ARM dependsOn accepts only in-template
        # targets, so a dependsOn on the external DCE -> InvalidTemplate at deploy (what-if misses it · live-validate
        # caught it 2026-06-16). The DCE must be bound ONLY via the dataCollectionEndpointId property.
        $out = & $script:tool -Portal 'Defender' -Category 'Gm2Probe' -ResourceGroup 'test-rg' `
            -SchemaArtifactPath $script:artifactPath -ParametersFile $script:paramsPath -EmitTemplateOnly
        $emitted = @($out) | Where-Object { $_ -is [string] -and $_ -match '\.json$' } | Select-Object -Last 1
        try {
            $tpl = Get-Content $emitted -Raw | ConvertFrom-Json -Depth 60
            $dcr = @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })[0]
            @($dcr.dependsOn) | Where-Object { $_ -match 'dataCollectionEndpoints' } | Should -BeNullOrEmpty
            $dcr.properties.dataCollectionEndpointId | Should -Match 'dataCollectionEndpoints'   # still bound as a property
        } finally {
            if ($emitted -and (Test-Path $emitted)) { Remove-Item $emitted -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'the per-DCR role is NOT in the ARM template (ensured POST-DEPLOY via idempotent az · avoids RoleAssignmentExists 409)' {
        # An ARM roleAssignment PUT 409s when the (FA-SAMI, role, DCR) tuple already has an assignment under ANY name —
        # true for every re-onboard (a deterministic guid only collides by luck · cat-1 matched, Operations did not).
        # So the surgical template must contain NO roleAssignment / role nested deployment; the role is ensured
        # post-deploy via az check-then-create (tuple-idempotent). Guard both: template clean + source does the ensure.
        $out = & $script:tool -Portal 'Defender' -Category 'Gm2Probe' -ResourceGroup 'test-rg' `
            -SchemaArtifactPath $script:artifactPath -ParametersFile $script:paramsPath -EmitTemplateOnly
        $emitted = @($out) | Where-Object { $_ -is [string] -and $_ -match '\.json$' } | Select-Object -Last 1
        try {
            $tpl = Get-Content $emitted -Raw | ConvertFrom-Json -Depth 60
            @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }) | Should -BeNullOrEmpty       # no top-level role
            @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and ($_.name -match 'role-dcr') }) | Should -BeNullOrEmpty  # no role nested
        } finally {
            if ($emitted -and (Test-Path $emitted)) { Remove-Item $emitted -Force -ErrorAction SilentlyContinue }
        }
        $script:raw | Should -Match 'az role assignment create'        # ensured post-deploy
        $script:raw | Should -Match 'Monitoring Metrics Publisher'
        $script:raw | Should -Match 'az role assignment list'          # check-then-create (idempotent)
    }

    It 'static · the dataFlow assigns the carried $transformKql variable, never a literal source hardcode' {
        $script:raw | Should -Match 'transformKql = \$transformKql'
        $script:raw | Should -Not -Match "transformKql = 'source'"
        $script:raw | Should -Match 'Get-XdrArtifactTransformKql -DcrResource \$artifact\.DcrResource'
    }
}

Describe 'recreate-on-drift WIRING · DROP-then-recreate-fresh applies the new schema · purge is OPTIONAL (soft-restore phantom disproven live 2026-06-20)' {
    BeforeAll {
        $script:tool2 = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'tools' 'Onboard-CategorySurgical.ps1')).Path
        $script:src2  = Get-Content -LiteralPath $script:tool2 -Raw
        # comment-stripped view: negative/ordering checks run against CODE only (the docstring legitimately names the path)
        $script:code2 = (($script:src2 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
    It 'declares the -PurgeNonEmptyOnDrift switch (OPTIONAL cosmetic pre-clean · companion to -RecreateTableOnSchemaDrift)' {
        $script:src2 | Should -Match '\[switch\]\s*\$PurgeNonEmptyOnDrift'
    }
    It 'on a NON-EMPTY drifted table WITHOUT the purge flag · drops+recreates (the soft-restore fail-closed guard is GONE · the new schema applies · live-proven)' {
        # The old fail-closed soft-restore throw is REMOVED — a populated drop+recreate lands the new schema (proven
        # 2026-06-20: 50-col SecureScore_CL recreated to 65-col, no soft-restore). The no-purge branch logs + proceeds.
        $script:code2 | Should -Not -Match 'would SOFT-RESTORE the old data'
        $script:code2 | Should -Match '\$rowCnt -gt 0 -and -not \$PurgeNonEmptyOnDrift'
    }
    It 'the table DROP is UNCONDITIONAL — it runs whether or not the optional purge ran (no row-count gate blocks the recreate)' {
        # both the no-purge branch and the optional-purge branch fall through to the same unconditional delete
        $ifIdx   = $script:code2.IndexOf('$rowCnt -gt 0 -and -not $PurgeNonEmptyOnDrift')
        $dropIdx = $script:code2.IndexOf('workspace table delete')
        ($ifIdx -ge 0 -and $dropIdx -gt $ifIdx) | Should -BeTrue
    }
    It 'WITH the switch · submits an OPTIONAL pre-clean PURGE via native Invoke-RestMethod (no az.cmd JSON mangle) BEFORE the drop' {
        $script:code2 | Should -Match 'Invoke-RestMethod -Method Post -Uri \$purgeUri'
        $script:code2 | Should -Match '/purge\?api-version='
        $script:code2 | Should -Match '\$purged = \$false'
        $pollIdx = $script:code2.IndexOf('$purged = $false')
        $dropIdx = $script:code2.IndexOf('workspace table delete')
        ($pollIdx -ge 0 -and $dropIdx -gt $pollIdx) | Should -BeTrue   # the optional purge runs before the table delete
    }
    It 'the OPTIONAL purge is NON-BLOCKING · an incomplete purge WARNS and proceeds to the drop (never throws · the schema applies regardless)' {
        $script:code2 | Should -Not -Match 'purge did not COMPLETE.*NOT proceeding'
        $script:code2 | Should -Match 'PROCEEDING to drop\+recreate anyway'
    }
    It 'the purge body filters TimeGenerated to cover ALL rows (empties the whole table)' {
        $script:code2 | Should -Match "column = 'TimeGenerated'; operator = '>'"
    }
    It 'parses with zero errors (post -PurgeNonEmptyOnDrift edit)' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool2, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }
}
