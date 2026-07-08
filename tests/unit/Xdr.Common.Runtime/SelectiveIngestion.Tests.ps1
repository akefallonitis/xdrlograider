#Requires -Version 7.4
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.5.0' }

# Pester · SSOT §7 SELECTIVE INGESTION · G-Selection gate (increment A · category-level)
#
# WHAT THIS PROVES:
#   The optional XDRLR_ENABLED_CATEGORIES app setting lets an operator restrict which Defender CATEGORIES actively
#   poll+ingest, WITHOUT any code/DCR/table change. It is a THIRD orthogonal per-cycle skip-gate that composes with
#   G-Capability (product-present) and G-Cadence (poll-due). A category polls IFF user-enabled AND product-present
#   AND cadence-due. Backward compatibility is the hard requirement: UNSET/EMPTY => ALL enabled (an existing
#   deployment with no app setting behaves EXACTLY as before).
#
# Two layers, mirroring the LicenseIndependence (behavioural gate) + DispatchSafety/MultiPortalDispatch (AST) tests:
#   (1) BEHAVIOUR · the REAL Get-XdrEnabledCategorySet parser + the dispatch decision it drives, across every
#       edge case (unset/empty/whitespace/commas-only/CSV/case/trim/blanks).
#   (2) WIRING · AST-parse the REAL src/functions/XdrDefenderRefresh/run.ps1 so removing the gate turns this RED.

BeforeDiscovery {
    $repoRoot    = (Resolve-Path "$PSScriptRoot/../../..").Path
    $modulesRoot = Join-Path $repoRoot 'src/Modules'
    foreach ($mod in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Cache','Xdr.Common.Lease','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Auth','Xdr.Common.Runtime')) {
        $psd1 = Join-Path $modulesRoot "$mod/$mod.psd1"
        $psm1 = Join-Path $modulesRoot "$mod/$mod.psm1"
        $loadPath = if (Test-Path $psd1) { $psd1 } elseif (Test-Path $psm1) { $psm1 } else { $null }
        if ($loadPath) { try { Import-Module $loadPath -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
}

BeforeAll {
    $repoRoot    = (Resolve-Path "$PSScriptRoot/../../..").Path
    $modulesRoot = Join-Path $repoRoot 'src/Modules'
    foreach ($mod in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Storage','Xdr.Common.Cache','Xdr.Common.Lease','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Auth','Xdr.Common.Runtime')) {
        $psd1 = Join-Path $modulesRoot "$mod/$mod.psd1"
        $psm1 = Join-Path $modulesRoot "$mod/$mod.psm1"
        $loadPath = if (Test-Path $psd1) { $psd1 } elseif (Test-Path $psm1) { $psm1 } else { $null }
        if ($loadPath) { try { Import-Module $loadPath -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }

    # The production G-Selection decision, mirroring run.ps1 EXACTLY — parse through the REAL Get-XdrEnabledCategorySet
    # and decide through the REAL Test-XdrCategoryEnabled (NO re-implementation of the decision, so a logic change in the
    # shipped function turns these red):
    #   $enabledCategories = Get-XdrEnabledCategorySet -Raw $env:XDRLR_ENABLED_CATEGORIES
    #   if ($enabledCategories -and -not (Test-XdrCategoryEnabled -EnabledCategories $enabledCategories -Category $catName)) { ...skip... ; continue }
    # A category is DISPATCHED iff NOT (selection-active AND not-enabled). This wrapper returns that same boolean.
    function Test-CategoryDispatched {
        param([AllowNull()][string] $Raw, [AllowNull()][AllowEmptyString()][string] $Category)
        $set = Get-XdrEnabledCategorySet -Raw $Raw
        if ($set -and -not (Test-XdrCategoryEnabled -EnabledCategories $set -Category $Category)) { return $false }
        return $true
    }
}

Describe 'SSOT §7 · Get-XdrEnabledCategorySet · parse semantics' {
    It 'is exported by the Runtime module' {
        Get-Command Get-XdrEnabledCategorySet -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    Context 'ALL-enabled sentinels (=> $null · backward-compatible)' {
        It 'returns $null for <label>' -TestCases @(
            @{ Raw = $null;          label = 'unset/null' }
            @{ Raw = '';             label = 'empty string' }
            @{ Raw = '   ';          label = 'whitespace only' }
            @{ Raw = ',';            label = 'a bare comma' }
            @{ Raw = ' , , ';        label = 'commas + whitespace only' }
        ) {
            param($Raw)
            Get-XdrEnabledCategorySet -Raw $Raw | Should -BeNullOrEmpty
        }
    }

    Context 'explicit CSV => a case-insensitive allow-set' {
        It 'parses two categories' {
            $set = Get-XdrEnabledCategorySet -Raw 'Configuration,Operations'
            $set | Should -Not -BeNullOrEmpty
            $set.Count | Should -Be 2
            $set.Contains('Configuration') | Should -BeTrue
            $set.Contains('Operations')    | Should -BeTrue
        }
        It 'membership is case-insensitive (portal/app-setting casing drift must not silently disable a category)' {
            $set = Get-XdrEnabledCategorySet -Raw 'configuration'
            $set.Contains('Configuration') | Should -BeTrue
            $set.Contains('CONFIGURATION') | Should -BeTrue
        }
        It 'trims surrounding whitespace on each entry' {
            $set = Get-XdrEnabledCategorySet -Raw '  Configuration , Operations  '
            $set.Count | Should -Be 2
            $set.Contains('Configuration') | Should -BeTrue
            $set.Contains('Operations')    | Should -BeTrue
        }
        It 'drops blank entries between commas (no empty-string member)' {
            $set = Get-XdrEnabledCategorySet -Raw 'Configuration,,Operations,'
            $set.Count | Should -Be 2
            $set.Contains('') | Should -BeFalse
        }
    }
}

Describe 'SSOT §7 · Test-XdrCategoryEnabled · the selection decision SoT (run.ps1 branches on this)' {
    It 'is exported by the Runtime module' {
        Get-Command Test-XdrCategoryEnabled -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'no selection ($null set) => enabled for any category (backward-compatible)' {
        Test-XdrCategoryEnabled -EnabledCategories $null -Category 'Configuration' | Should -BeTrue
        Test-XdrCategoryEnabled -EnabledCategories $null -Category ''              | Should -BeTrue
    }
    Context 'with an active selection {Configuration, Operations}' {
        BeforeAll { $script:Sel = Get-XdrEnabledCategorySet -Raw 'Configuration,Operations' }
        It 'ENABLED when the set contains the category' {
            Test-XdrCategoryEnabled -EnabledCategories $script:Sel -Category 'Configuration' | Should -BeTrue
        }
        It 'ENABLED case-insensitively (the set comparer is honored)' {
            Test-XdrCategoryEnabled -EnabledCategories $script:Sel -Category 'operations' | Should -BeTrue
        }
        It 'DISABLED when the set does not contain the category' {
            Test-XdrCategoryEnabled -EnabledCategories $script:Sel -Category 'SecureScore' | Should -BeFalse
        }
        It 'DISABLED for an empty category name (the StrictMode-safe '''' path when a manifest lacks .Category · no throw)' {
            { Test-XdrCategoryEnabled -EnabledCategories $script:Sel -Category '' } | Should -Not -Throw
            Test-XdrCategoryEnabled -EnabledCategories $script:Sel -Category '' | Should -BeFalse
        }
    }
    It 'a selection of only non-existent / LABEL-style names disables every real category (deselect-by-typo footgun · documented)' {
        # 'Analytics & Data' is the display LABEL; the manifest .Category key is 'AnalyticsData'. A CSV of labels/typos
        # matches no real category → all are skipped. This pins the intended (case-insensitive-but-exact-key) behavior.
        $bogus = Get-XdrEnabledCategorySet -Raw 'Nope,Analytics & Data'
        Test-XdrCategoryEnabled -EnabledCategories $bogus -Category 'AnalyticsData' | Should -BeFalse
        Test-XdrCategoryEnabled -EnabledCategories $bogus -Category 'Configuration' | Should -BeFalse
    }
}

Describe 'SSOT §7 · G-Selection dispatch decision (the boolean run.ps1 branches on)' {
    It 'UNSET => every category dispatches (all enabled · backward-compatible)' {
        Test-CategoryDispatched -Raw $null -Category 'Configuration' | Should -BeTrue
        Test-CategoryDispatched -Raw ''    -Category 'SecureScore'   | Should -BeTrue
    }
    It 'explicit subset => selected categories dispatch, unselected are skipped' {
        $raw = 'Configuration,Operations'
        Test-CategoryDispatched -Raw $raw -Category 'Configuration' | Should -BeTrue
        Test-CategoryDispatched -Raw $raw -Category 'Operations'    | Should -BeTrue
        Test-CategoryDispatched -Raw $raw -Category 'SecureScore'   | Should -BeFalse
        Test-CategoryDispatched -Raw $raw -Category 'Identity'      | Should -BeFalse
    }
    It 'case/whitespace drift in the setting still dispatches the intended category' {
        Test-CategoryDispatched -Raw '  operations ' -Category 'Operations' | Should -BeTrue
    }
}

Describe 'SSOT §7 · deploy wiring · createUiDefinition to mainTemplate parameter mapping' {
    BeforeAll {
        $repo = (Resolve-Path "$PSScriptRoot/../../..").Path
        $script:CreateUi = Get-Content (Join-Path $repo 'deploy/createUiDefinition.json') -Raw | ConvertFrom-Json
        $script:MainTpl  = Get-Content (Join-Path $repo 'deploy/mainTemplate.json') -Raw | ConvertFrom-Json
        $script:ManDir   = Join-Path $repo 'manifests/Defender'
    }

    It 'createUiDefinition EMITS enabledCategories in outputs (else the portal selection is silently discarded)' {
        # The exact blocker the adversarial review caught: a DropDown with no matching output is a silent no-op.
        @($script:CreateUi.parameters.outputs.PSObject.Properties.Name) | Should -Contain 'enabledCategories'
    }

    It 'the enabledCategories output binds to the ingestionConfig multiselect step' {
        [string]$script:CreateUi.parameters.outputs.enabledCategories | Should -Match "steps\('ingestionConfig'\)\.enabledCategories"
    }

    It 'mainTemplate declares the enabledCategories array parameter the output feeds' {
        $p = $script:MainTpl.parameters.enabledCategories
        $p | Should -Not -BeNullOrEmpty
        $p.type | Should -Be 'array'
    }

    It 'EVERY createUiDefinition output maps to a mainTemplate parameter of the same name (no dead UI wiring)' {
        $params = @($script:MainTpl.parameters.PSObject.Properties.Name)
        foreach ($o in @($script:CreateUi.parameters.outputs.PSObject.Properties.Name)) {
            if ($o -eq 'location') { continue }   # location() is an intrinsic, not a template parameter
            $params | Should -Contain $o -Because "createUiDefinition output '$o' must map to a mainTemplate parameter or it is silently dropped"
        }
    }

    It 'the multiselect allowedValues exactly equal the shipped manifest category keys (drift guard as the surface grows)' {
        $step = @($script:CreateUi.parameters.steps | Where-Object { $_.name -eq 'ingestionConfig' })[0]
        $dd   = @($step.elements | Where-Object { $_.name -eq 'enabledCategories' })[0]
        $uiVals  = @($dd.constraints.allowedValues.value) | Sort-Object
        $manVals = @(Get-ChildItem $script:ManDir -Filter *.psd1 | ForEach-Object {
            $m = Select-String -LiteralPath $_.FullName -Pattern "^\s*Category\s*=\s*'([^']+)'" | Select-Object -First 1
            if ($m) { $m.Matches[0].Groups[1].Value }
        }) | Sort-Object
        $uiVals | Should -Be $manVals -Because 'a new manifest category must be added to the createUiDefinition multiselect to be selectable'
    }
}

Describe 'SSOT §7 · G-Selection is wired into the REAL dispatcher (AST · removing it turns this RED)' {
    BeforeAll {
        $script:RunPs1 = Join-Path (Resolve-Path "$PSScriptRoot/../../..").Path 'src/functions/XdrDefenderRefresh/run.ps1'
        $errs = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunPs1, [ref]$null, [ref]$errs)
        $script:ParseErrors = $errs
        $script:Src = Get-Content -LiteralPath $script:RunPs1 -Raw
    }

    It 'run.ps1 parses with zero errors' {
        $script:ParseErrors | Should -BeNullOrEmpty
    }

    It 'reads the XDRLR_ENABLED_CATEGORIES app setting' {
        $script:Src | Should -Match 'XDRLR_ENABLED_CATEGORIES'
    }

    It 'parses the setting through Get-XdrEnabledCategorySet (the tested helper · not an ad-hoc inline split)' {
        $calls = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Get-XdrEnabledCategorySet'
            }, $true)
        @($calls).Count | Should -BeGreaterThan 0
    }

    It 'delegates the decision to the tested Test-XdrCategoryEnabled (not a re-implemented inline .Contains())' {
        $calls = $script:Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Test-XdrCategoryEnabled'
            }, $true)
        @($calls).Count | Should -BeGreaterThan 0
    }

    It 'inverts the decision with -not (guards against a logic inversion silently disabling selection)' {
        # A missing/removed -not would flip the gate to skip ENABLED categories and poll DISABLED ones.
        $script:Src | Should -Match '-not\s*\(\s*Test-XdrCategoryEnabled'
    }

    It 'reads Category via the StrictMode-safe indexer (a manifest missing .Category must not throw / abort enumeration)' {
        $script:Src | Should -Match "catBlock\['Category'\]"
    }

    It 'emits Entry.Selection.Skipped and then continues (observable skip · mirrors the sibling gates)' {
        # The skip must both record telemetry AND `continue` past the category — assert they occur together.
        $script:Src | Should -Match "Entry\.Selection\.Skipped[\s\S]{0,600}continue"
    }
}
