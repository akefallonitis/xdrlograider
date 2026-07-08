#Requires -Version 7.4
# EXIT-GATE · synthetic 2-category dry-run. Proves the foundation delivers TRIVIAL expansion (the north-star: "the only
# thing left is to add categories"): Build-MainTemplate, given TWO category artifacts (the real Operations + a SYNTHETIC
# SPACED 'Cloud Apps'), assembles 2-of-everything generically with ZERO engine edits — 2 workspace tables, 2 DCRs, 2
# scoped Monitoring-Metrics-Publisher role deployments, 2 FA appSettings, and ONE connector card whose dataTypes
# enumerate BOTH tables — with correctly TOKENIZED names (the spaced 'Cloud Apps' -> 'cloudapps' in every ARM resource
# name). Runs the REAL Build-MainTemplate end-to-end against a TEMP schema dir (no committed-artifact pollution ·
# -SkipPackageCard so the committed Package card is never touched).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $bmt = Join-Path $script:repo 'dev-tools\Build-MainTemplate.ps1'
    $realOps = Join-Path $script:repo 'deploy\per-category-schemas\Defender-Operations.json'

    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-exitgate-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    Copy-Item $realOps (Join-Path $script:tmp 'Defender-Operations.json') -Force
    # Synthetic 2nd category derived from Operations: substitute the category token (plural 'Operations' -> 'CloudApps',
    # both cases) so the table becomes Defender_CloudApps_CL · the envelope columns 'Operation'/'OperationKey'/
    # 'OperationId' (singular) are untouched. The filename carries the SPACED category so Resolve-CategoryArtifacts
    # yields Category='Cloud Apps' and Build-MainTemplate must tokenize it to 'cloudapps' for every ARM resource name.
    $synthRaw = (Get-Content $realOps -Raw) -creplace 'Operations', 'CloudApps' -creplace 'operations', 'cloudapps'
    Set-Content -Path (Join-Path $script:tmp 'Defender-Cloud Apps.json') -Value $synthRaw -Encoding UTF8 -NoNewline

    $script:outMt = Join-Path $script:tmp 'mainTemplate.json'
    & pwsh -NoProfile -File $bmt -SchemaDir $script:tmp -OutputPath $script:outMt -SkipPackageCard *> (Join-Path $script:tmp 'build.log')
    $script:buildExit = $LASTEXITCODE
    $script:rawMt = if (Test-Path $script:outMt) { Get-Content $script:outMt -Raw } else { '' }
    $script:tpl   = if ($script:rawMt) { $script:rawMt | ConvertFrom-Json -Depth 60 } else { $null }
    if ($script:tpl) {
        $script:dcrs = @($script:tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
        # PER-CATEGORY MMP role deployments only (name 'xdrlr-role-dcr-<token>-...') — NOT the foundation-level role
        # ('xdrlr-roles-foundation-...') which also references the role GUID but is not per-category.
        $script:roles = @($script:tpl.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'xdrlr-role-dcr-' })
        $fa = $script:tpl.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $script:appSettings = if ($fa) { @($fa.properties.siteConfig.appSettings | Where-Object { $_.name -like 'XDRLR_DCR_*' }) } else { @() }
        $nested = $script:tpl.resources | Where-Object { $_.name -eq '[variables(''nestedDeploymentName'')]' } | Select-Object -First 1
        $card = if ($nested) { $nested.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions' } | Select-Object -First 1 } else { $null }
        $script:cardTables = if ($card) { @($card.properties.connectorUiConfig.dataTypes | ForEach-Object { $_.name }) } else { @() }
    }
}
AfterAll {
    if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'EXIT-GATE · synthetic 2-category dry-run (foundation delivers trivial expansion · zero engine edits)' {
    It 'Build-MainTemplate assembles the 2 categories WITHOUT error (exit 0)' {
        $script:buildExit | Should -Be 0 -Because "build.log: $(if (Test-Path (Join-Path $script:tmp 'build.log')) { (Get-Content (Join-Path $script:tmp 'build.log') -Raw) } else { '<none>' })"
        $script:tpl | Should -Not -BeNullOrEmpty
    }
    It 'emits 2 DCRs (one per category · the per-category telemetry rules)' {
        @($script:dcrs).Count | Should -Be 2
    }
    It 'emits 2 scoped Monitoring-Metrics-Publisher role deployments (cat#2 gets its role · no silent-0-rows)' {
        @($script:roles).Count | Should -Be 2
    }
    It 'wires 2 per-category FA appSettings (XDRLR_DCR_*)' {
        @($script:appSettings).Count | Should -Be 2
    }
    It 'the ONE connector card enumerates BOTH category tables in dataTypes (cat#2 is visible in Sentinel)' {
        @($script:cardTables).Count | Should -Be 2
        $script:cardTables | Should -Contain 'Defender_Operations_CL'
        $script:cardTables | Should -Contain 'Defender_CloudApps_CL'
    }
    It 'the SPACED category is TOKENIZED in every ARM resource name (no raw space · cat#2 ARM-valid)' {
        $script:rawMt | Should -Match 'cloudapps'          # tokenized DCR / role / appSetting names
        $script:rawMt | Should -Not -Match 'dcr-cloud apps' # never the raw spaced form (ARM-invalid · silent 0-rows)
    }
}
