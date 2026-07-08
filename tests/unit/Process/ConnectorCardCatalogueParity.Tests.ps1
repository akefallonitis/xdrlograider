#Requires -Version 7.4
# WS-card-sync · Task D · the in-repo connector card MUST NOT drift from the deployable shipped-category surface.
#
# The live Sentinel card froze at the initial 6-category deploy while the repo advanced to 10 (the drift this round
# fixes). This gate is the IN-REPO half of the anti-drift invariant: it proves the COMMITTED card's dataTypes ==
# the repo's authoritative DEPLOYABLE shipped-category set, so the card can never silently fall behind (or run ahead
# of) the onboarded categories within the repo. The LIVE-vs-repo half (does the deployed card match the repo card)
# is a §4.B / D12 postdeploy concern (tools/Confirm-PostDeploy.ps1 · Verify-DeployedConnector.ps1), NOT an offline test.
#
# "Deployable shipped category" = a category that has BOTH a committed manifest (manifests/Defender/<Cat>.psd1) AND a
# committed per-category-schema (deploy/per-category-schemas/Defender-<Cat>.json) — i.e. an actual Log Analytics
# table + DCR get deployed for it, so it legitimately belongs in the connector card's dataTypes. This is the same set
# Build-MainTemplate enumerates the card from (New-XdrConnectorCardContent over the assembled per-category plan). Note
# the catalogue's Operations[].Shipped flag is a SUPERSET signal (an op can be Shipped in the catalogue before its
# category has a manifest/schema/table); the CARD tracks the deployable surface, not the raw catalogue ship-flag, so
# this test derives the expected set from the manifest∩schema set (the deployable truth), with a cross-check below.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Parser -Force -DisableNameChecking

    # ── the DEPLOYABLE shipped-category table set, derived from the committed manifests (authoritative) ──
    $manifestDir = Join-Path $script:repo 'manifests\Defender'
    $script:manifestTables = @(Get-ChildItem $manifestDir -Filter '*.psd1' -ErrorAction SilentlyContinue | ForEach-Object {
        $mf  = Import-PowerShellDataFile $_.FullName
        $tok = Get-XdrCategoryToken -Category ([string]$mf.Category)
        "Defender_${tok}_CL"
    } | Sort-Object -Unique)

    # ── the per-category-schema table set (each = one deployed table/DCR) ──
    $schemaDir = Join-Path $script:repo 'deploy\per-category-schemas'
    $script:schemaTables = @(Get-ChildItem $schemaDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*-nested-deployment.json' } |
        ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 60).TableResource.properties.schema.name } |
        Sort-Object -Unique)

    # ── the ARM-embedded connector card (deploy/mainTemplate.json · the deployed card) ──
    $mt = Get-Content (Join-Path $script:repo 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json -Depth 60
    $nested = $mt.resources | Where-Object { $_.PSObject.Properties['name'] -and ([string]$_.name) -eq "[variables('nestedDeploymentName')]" } | Select-Object -First 1
    $cardArm = $nested.properties.template.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/dataConnectorDefinitions' } | Select-Object -First 1
    $script:armCardTables = @($cardArm.properties.connectorUiConfig.dataTypes | ForEach-Object { $_.name } | Sort-Object -Unique)

    # ── the Content Hub solution card (Package/... · the PUBLISHED card) ──
    $pkgUi = (Get-Content (Join-Path $script:repo 'Package\dataConnectors\XdrLogRaiderDataConnectorDefinition.json') -Raw | ConvertFrom-Json -Depth 60).properties.connectorUiConfig
    $script:pkgCardTables = @($pkgUi.dataTypes | ForEach-Object { $_.name } | Sort-Object -Unique)

    # ── the catalogue's raw shipped-category set (the SUPERSET signal · for the cross-check) ──
    $catPath = Join-Path $script:repo 'references\inventory\nodoc-defender-xdr\catalogue.json'
    $script:catalogueShippedTables = @()
    if (Test-Path $catPath) {
        $cat = Get-Content $catPath -Raw | ConvertFrom-Json -Depth 60
        $script:catalogueShippedTables = @($cat.Operations | Where-Object { $_.Shipped } |
            ForEach-Object { 'Defender_' + (Get-XdrCategoryToken -Category ([string]$_.Category)) + '_CL' } |
            Sort-Object -Unique)
    }
}

Describe 'Task D · connector card dataTypes == the repo deployable shipped-category set (no in-repo drift)' {
    It 'the repo HAS a deployable shipped-category set (sanity · manifests present)' {
        $script:manifestTables.Count | Should -BeGreaterThan 0
    }
    It 'manifest set == per-category-schema set (every manifested category has a schema and vice-versa)' {
        $onlyManifest = @($script:manifestTables | Where-Object { $_ -notin $script:schemaTables })
        $onlySchema   = @($script:schemaTables   | Where-Object { $_ -notin $script:manifestTables })
        $onlyManifest | Should -BeNullOrEmpty -Because "manifested category with no per-category-schema (no table deployed): $($onlyManifest -join ', ')"
        $onlySchema   | Should -BeNullOrEmpty -Because "per-category-schema with no manifest (orphan table): $($onlySchema -join ', ')"
    }
    It 'the ARM card dataTypes EQUALS the deployable shipped-category set (exact · no drift either way)' {
        $missingFromCard = @($script:manifestTables | Where-Object { $_ -notin $script:armCardTables })
        $extraInCard     = @($script:armCardTables  | Where-Object { $_ -notin $script:manifestTables })
        $missingFromCard | Should -BeNullOrEmpty -Because "deployable category absent from the card (card froze behind onboarding · the 6->10 drift class): $($missingFromCard -join ', ')"
        $extraInCard     | Should -BeNullOrEmpty -Because "card lists a table with no deployable backing (manifest+schema): $($extraInCard -join ', ')"
    }
    It 'the Content Hub (Package) card dataTypes EQUALS the deployable shipped-category set (published card in sync too)' {
        $missingFromPkg = @($script:manifestTables | Where-Object { $_ -notin $script:pkgCardTables })
        $extraInPkg     = @($script:pkgCardTables  | Where-Object { $_ -notin $script:manifestTables })
        $missingFromPkg | Should -BeNullOrEmpty -Because "deployable category absent from the PUBLISHED card: $($missingFromPkg -join ', ')"
        $extraInPkg     | Should -BeNullOrEmpty -Because "published card lists a table with no deployable backing: $($extraInPkg -join ', ')"
    }
    It 'the ARM card and the Package card carry the IDENTICAL dataTypes set (the two cards never diverge)' {
        $script:armCardTables | Should -Be $script:pkgCardTables
    }
    It 'every card category is a SUBSET of the catalogue Shipped set (the card never ships a non-catalogued table)' {
        # The catalogue Shipped set is a SUPERSET (a category can be catalogue-Shipped before it has a manifest/schema/
        # table · e.g. Vulnerability Management at this snapshot). The card must be WITHIN it — i.e. the card never
        # invents a table that the catalogue does not consider shippable. (The reverse — catalogue-Shipped categories
        # without a deployable surface — is a catalogue/onboarding gap tracked outside this card-sync gate.)
        if ($script:catalogueShippedTables.Count -eq 0) {
            Set-ItResult -Skipped -Because 'catalogue.json (internal layer) not present on this clone'
            return
        }
        $cardNotInCatalogue = @($script:armCardTables | Where-Object { $_ -notin $script:catalogueShippedTables })
        $cardNotInCatalogue | Should -BeNullOrEmpty -Because "the card lists a table whose category is not Shipped in the catalogue: $($cardNotInCatalogue -join ', ')"
    }
}
