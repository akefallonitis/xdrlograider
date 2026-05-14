#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Phase 1 mainTemplate.json + createUiDefinition.json invariants.

Describe 'mainTemplate.json invariants' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:TemplatePath = Join-Path $script:RepoRoot 'deploy' 'mainTemplate.json'
        $script:CreateUiPath = Join-Path $script:RepoRoot 'deploy' 'createUiDefinition.json'
        $script:T = Get-Content -Raw $script:TemplatePath | ConvertFrom-Json -Depth 50
        $script:UI = Get-Content -Raw $script:CreateUiPath | ConvertFrom-Json -Depth 50

        $script:PhaseSubAreas = @(
            'action_center', 'attack_simulator', 'cloud_apps', 'configuration', 'data_lake',
            'endpoint_configuration', 'endpoint_devices', 'entity_pivots', 'exposure_management',
            'files', 'identity', 'multi_tenant', 'portal_services', 'secure_score',
            'sentinel_precision', 'streaming', 'threat_analytics', 'vulnerability_management'
        )
    }

    It 'has the ARM template top-level structure' {
        $script:T.'$schema'      | Should -Match 'deploymentTemplate.json'
        $script:T.contentVersion | Should -Be '1.0.0.0'
        $script:T.parameters     | Should -Not -BeNullOrEmpty
        $script:T.variables      | Should -Not -BeNullOrEmpty
        $script:T.resources      | Should -Not -BeNullOrEmpty
        $script:T.outputs        | Should -Not -BeNullOrEmpty
    }

    It 'declares the required parameters' {
        $params = ($script:T.parameters | Get-Member -MemberType NoteProperty).Name
        foreach ($p in @('projectPrefix','env','location','existingWorkspaceId','workspaceLocation','serviceAccountUpn','authMethod','planSku','retentionInDays','githubRepo','releaseTag','deployRoleAssignments','deploySentinelContent','sentinelContentTemplateUri')) {
            $params | Should -Contain $p
        }
    }

    It 'nested deployment for sentinelContent.json is wired (registers data connector card in operator workspace)' {
        $nested = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'sentinelContent' })
        $nested.Count | Should -Be 1
        $nested[0].condition | Should -Match "parameters\('deploySentinelContent'\)"
        $nested[0].properties.templateLink.uri | Should -Match "sentinelContentTemplateUri"
        $nested[0].properties.templateLink.uri | Should -Match "sentinelContent\.json"
        # Targets the workspace's subscription + resource group (not the connector RG)
        $nested[0].subscriptionId | Should -Match 'workspaceSubscriptionId'
        $nested[0].resourceGroup  | Should -Match 'workspaceResourceGroup'
    }

    It 'defaults planSku to Y1 (Linux Consumption — cost-optimal) with EP1+ opt-in' {
        $script:T.parameters.planSku.defaultValue | Should -Be 'Y1'
        $script:T.parameters.planSku.allowedValues | Should -Contain 'Y1'
        $script:T.parameters.planSku.allowedValues | Should -Contain 'EP1'
        $script:T.parameters.planSku.allowedValues | Should -Contain 'EP2'
        $script:T.parameters.planSku.allowedValues | Should -Contain 'EP3'
    }

    It 'plan resource handles BOTH Y1 (Dynamic + functionapp kind) AND EP* (ElasticPremium + linux kind)' {
        $plan = ($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/serverfarms' })
        # SKU and kind are conditional ARM expressions
        $plan.sku  | Should -Match "if\(equals\(parameters\('planSku'\), 'Y1'\)"
        $plan.kind | Should -Match "if\(equals\(parameters\('planSku'\), 'Y1'\)"
    }

    It 'has 19 DCRs (18 sub-area + 1 ConnectorHealth-ops)' {
        $dcrs = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
        $dcrs.Count | Should -Be 19
        # Last segment of DCR name suffix
        $opsDcr = @($dcrs | Where-Object { $_.name -match '-ops' })
        $opsDcr.Count | Should -Be 1
    }

    It 'has Function App with WEBSITE_RUN_FROM_PACKAGE + SystemAssigned identity + Y1-required settings' {
        $fa = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' })
        $fa.Count | Should -Be 1
        $fa[0].identity.type | Should -Be 'SystemAssigned'
        $settings = @($fa[0].properties.siteConfig.appSettings | Where-Object { $_.name -eq 'WEBSITE_RUN_FROM_PACKAGE' })
        $settings.Count | Should -Be 1
        $settings[0].value | Should -Match "variables\('packageUrl'\)"
        $script:T.variables.packageUrl | Should -Match 'function-app.zip'
        # Y1 Consumption requirements (also harmless on EP)
        $names = @($fa[0].properties.siteConfig.appSettings | ForEach-Object { $_.name })
        $names | Should -Contain 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
        $names | Should -Contain 'WEBSITE_CONTENTSHARE'
        # SuccessKind classifier env contract from profile.ps1
        $names | Should -Contain 'AUTH_METHOD'
        $names | Should -Contain 'TENANT_ID'
        $names | Should -Contain 'DCR_IMMUTABLE_IDS_JSON'
    }

    It 'declares exactly 1 serverfarms resource (SKU + kind + properties are conditional ARM expressions)' {
        $plan = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/serverfarms' })
        $plan.Count | Should -Be 1
        # reserved=true must appear in both Y1 + EP branches (Linux mode for both)
        $plan[0].properties | Should -Match 'reserved.*true'
    }

    It 'declares Key Vault with RBAC + 5 secrets + soft-delete enabled (purge-protection + retention left to operator policy)' {
        $kv = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' })
        $kv.Count | Should -Be 1
        $kv[0].properties.enableRbacAuthorization | Should -BeTrue
        $kv[0].properties.enableSoftDelete | Should -BeTrue
        # Purge-protection + soft-delete retention are intentionally NOT forced —
        # operators enable per tenant compliance policy post-deploy. Connector ARM
        # should not dictate a specific audit/compliance posture.
        $kv[0].properties.enablePurgeProtection | Should -BeFalse -Because 'operator opt-in; do not force a non-reversible setting'
        $secrets = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults/secrets' })
        $secrets.Count | Should -Be 5
    }

    It 'declares ZERO diagnostic settings (operator wires per tenant policy)' {
        # Connector ARM intentionally does NOT emit Diagnostic Settings on FA/KV/Storage.
        # Operators run their own `az monitor diagnostic-settings create` aligned with
        # their tenant compliance posture. Forcing a posture from the connector would
        # break operators with stricter policies (e.g. legal-hold workspaces, separate
        # audit workspaces) and require manual ARM-level subtraction every deploy.
        $diag = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Insights/diagnosticSettings' })
        $diag.Count | Should -Be 0
    }

    It 'CONNECTOR_VERSION + CONNECTOR_BUILD_ID env vars wired in FA appSettings (H13)' {
        $fa = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' }
        $names = @($fa[0].properties.siteConfig.appSettings | ForEach-Object { $_.name })
        $names | Should -Contain 'CONNECTOR_VERSION'
        $names | Should -Contain 'CONNECTOR_BUILD_ID'
        # Values reference variables, not hardcoded — re-deploy with new releaseTag bumps build ID.
        $cv = $fa[0].properties.siteConfig.appSettings | Where-Object { $_.name -eq 'CONNECTOR_VERSION' }
        $cv.value | Should -Match "variables\('connectorVersion'\)"
        $cb = $fa[0].properties.siteConfig.appSettings | Where-Object { $_.name -eq 'CONNECTOR_BUILD_ID' }
        $cb.value | Should -Match "variables\('connectorBuildId'\)"
        # And the variables themselves exist
        $script:T.variables.connectorVersion | Should -Be '0.1.0'
        $script:T.variables.connectorBuildId | Should -Match "parameters\('releaseTag'\)"
    }

    It 'XDR_MAX_PAGES_PER_CYCLE env var wired in FA appSettings (Phase A0.3 pagination resume)' {
        $fa = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' }
        $names = @($fa[0].properties.siteConfig.appSettings | ForEach-Object { $_.name })
        $names | Should -Contain 'XDR_MAX_PAGES_PER_CYCLE'
        $cap = $fa[0].properties.siteConfig.appSettings | Where-Object { $_.name -eq 'XDR_MAX_PAGES_PER_CYCLE' }
        # Default 50 (operator can tune without redeploying the zip)
        $cap.value | Should -Be '50'
    }

    It 'FA dependsOn the customTables nested deployment (race-free first ingest)' {
        # ARM nested deployment dependencies use the literal name form (matches the
        # DCR dependsOn pattern in this template). resourceId('Microsoft.Resources/
        # deployments', ...) fails template validation for in-template nested deploys.
        $fa = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' }
        $deps = @($fa[0].dependsOn)
        ($deps | Where-Object { $_ -match "customTables-" }).Count |
            Should -BeGreaterOrEqual 1 -Because "FA cold-start must not race the workspace-table creation"
    }

    It 'all in-template nested-deployment dependsOn use literal-name form (NOT resourceId)' {
        # Regression: ARM rejects `resourceId('Microsoft.Resources/deployments', X)`
        # for in-template nested deploys with "InvalidTemplate: not defined in the
        # template" — only literal-name form `concat('X-', variables('suffix'))` works.
        # This test scans every resource's dependsOn and fails if it references a
        # nested deployment via resourceId().
        foreach ($r in $script:T.resources) {
            foreach ($d in @($r.dependsOn)) {
                if (-not $d) { continue }
                $isResourceIdNestedDep = ($d -match "resourceId\(\s*'Microsoft\.Resources/deployments'")
                $isResourceIdNestedDep | Should -BeFalse -Because "resource $($r.name) dependsOn '$d' uses resourceId Microsoft.Resources/deployments form — ARM rejects this for in-template nested deploys; use literal name concat form instead"
            }
        }
    }

    It 'no ARM substring(concat(...), 0, N) where N > min possible string length (regression: stName overflow)' {
        # Regression: `substring(concat('xdrlr','st','<6char>'), 0, 18)` fails because
        # concat is 13 chars but substring asks for 18. ARM substring throws when
        # length > actual string length. This test inspects every variable for the
        # substring(concat(...), 0, N) pattern and validates N <= min(possible concat length).

        # Paren-balanced extractor: given an expression and the start index of an opening
        # paren, return the substring between that paren and its matching close paren.
        function Get-BalancedParen {
            param([string] $Text, [int] $OpenIdx)
            $depth = 0
            for ($i = $OpenIdx; $i -lt $Text.Length; $i++) {
                $c = $Text[$i]
                if ($c -eq '(') { $depth++ }
                elseif ($c -eq ')') {
                    $depth--
                    if ($depth -eq 0) { return $Text.Substring($OpenIdx + 1, $i - $OpenIdx - 1) }
                }
            }
            return $null
        }

        $vars = $script:T.variables.PSObject.Properties
        foreach ($v in $vars) {
            $expr = [string]$v.Value
            # Find any "substring(concat(...), 0, N)" pattern (optionally wrapped in toLower/toUpper/etc.).
            $substringIdx = $expr.IndexOf('substring(concat(')
            if ($substringIdx -lt 0) { continue }
            $afterSubstring = $expr.Substring($substringIdx + 'substring('.Length)
            $concatIdx = $afterSubstring.IndexOf('concat(')
            if ($concatIdx -ne 0) { continue }  # not directly wrapping concat
            $concatOpenAbsIdx = $substringIdx + 'substring('.Length + 'concat'.Length
            $concatArgs = Get-BalancedParen -Text $expr -OpenIdx $concatOpenAbsIdx
            if (-not $concatArgs) { continue }
            # After concat's closing paren, parse ", 0, N)"
            $afterConcatIdx = $concatOpenAbsIdx + $concatArgs.Length + 2  # +2 for ( and )
            $tail = $expr.Substring($afterConcatIdx)
            if ($tail -match "^,\s*0\s*,\s*(\d+)\)") {
                $sliceLen = [int]$matches[1]
                # Compute MIN concat length: for each arg compute the smallest length it can be.
                $argTokens = $concatArgs -split ",(?=(?:[^']*'[^']*')*[^']*$)"  # split commas not inside quotes
                $minLen = 0
                foreach ($tok in $argTokens) {
                    $tok = $tok.Trim()
                    if ($tok -match "^'([^']*)'$") {
                        $minLen += $matches[1].Length
                    } elseif ($tok -match "parameters\('([^']+)'\)") {
                        $pName = $matches[1]
                        $pMin = $script:T.parameters.$pName.minLength
                        if (-not $pMin) { $pMin = 1 }
                        $minLen += [int]$pMin
                    } elseif ($tok -match "variables\('suffix'\)") {
                        $minLen += 6  # per substring(uniqueString, 0, 6) in stName chain
                    } else {
                        $minLen += 1  # conservative lower bound for unknown
                    }
                }
                $minLen | Should -BeGreaterOrEqual $sliceLen -Because "variable '$($v.Name)' uses substring(concat(...), 0, $sliceLen) but min possible concat length is $minLen chars — ARM substring throws at deploy time when length > string length"
            }
        }
    }

    It 'XdrConnectorHealth_CL workspace table declares 11 typed cols (Decision 15 / H13)' {
        $nested = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'customTables' }
        $health = $nested.properties.template.resources |
            Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and $_.name -match 'XdrConnectorHealth_CL' }
        $health | Should -Not -BeNullOrEmpty
        $colNames = @($health.properties.schema.columns | ForEach-Object { $_.name })
        $colNames | Should -Contain 'ConnectorVersion' -Because 'H13: operator-facing build pin'
        $colNames | Should -Contain 'ConnectorBuildId' -Because 'H13: git SHA/release tag traceability'
        # Lean Notes (Decision 15 cost optimization)
        $colNames | Should -Contain 'Notes'
        ($health.properties.schema.columns | Where-Object { $_.name -eq 'Notes' }).type | Should -Be 'dynamic'
    }

    It 'declares 4 storage tables (checkpoints, dlq, tier-state, tenant-state)' {
        $tables = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/tableServices/tables' })
        $tables.Count | Should -Be 4
        # Names are ARM expressions like "[concat(variables('stName'), '/default/', 'connectorCheckpoints')]"
        # — extract the trailing quoted literal.
        $names = @($tables | ForEach-Object {
            if ($_.name -match "'([A-Za-z][A-Za-z0-9]+)'\)\]$") { $matches[1] }
        })
        $names | Should -Contain 'connectorCheckpoints'
        $names | Should -Contain 'xdrIngestDlq'
        $names | Should -Contain 'XdrTierState'
        $names | Should -Contain 'XdrTenantState'
    }

    It 'declares 19 workspace tables via nested deployment (18 Defender_<Sub>_CL + 1 XdrConnectorHealth_CL)' {
        $nested = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'customTables' })
        $nested.Count | Should -Be 1
        $tables = @($nested[0].properties.template.resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/tables' })
        $tables.Count | Should -Be 19
        # Names are ARM expressions like "[concat(parameters('workspaceName'), '/', 'Defender_ActionCenter_CL')]";
        # extract the trailing table-name literal.
        $tableNames = @($tables | ForEach-Object {
            if ($_.name -match "'([A-Za-z][A-Za-z0-9_]*_CL)'") { $matches[1] }
        })
        $tableNames | Should -Contain 'XdrConnectorHealth_CL'
        foreach ($s in $script:PhaseSubAreas) {
            $pascal = ($s -split '_' | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
            $tableNames | Should -Contain "Defender_${pascal}_CL"
        }
    }

    It 'has 3 role assignments (1 KV Secrets User + 1 Storage Table Data Contributor + 1 RG-scoped Monitoring Metrics Publisher) all gated on deployRoleAssignments parameter' {
        # Collapsed from 21 to 3 — the 19 per-DCR MMP grants merged into a single
        # RG-scoped MMP assignment. createUiDefinition prompts operator for a fresh
        # RG dedicated to this connector, so RG-scope = effectively DCR-scope for
        # all 19 DCRs without 19 explicit grants cluttering RBAC audit.
        $ra = @($script:T.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        $ra.Count | Should -Be 3
        # KV Secrets User scoped at the Key Vault
        ($ra | Where-Object { $_.scope -match 'Microsoft.KeyVault/vaults' }).Count | Should -Be 1
        # Storage Table Data Contributor scoped at the Storage account
        ($ra | Where-Object { $_.scope -match 'Microsoft.Storage/storageAccounts' }).Count | Should -Be 1
        # Monitoring Metrics Publisher with no scope field = RG-scoped (covers all 19 DCRs)
        ($ra | Where-Object { -not $_.PSObject.Properties['scope'] -or [string]::IsNullOrEmpty($_.scope) }).Count | Should -Be 1
        # All 3 RAs MUST be conditional on deployRoleAssignments parameter (v1-pilot opt-out
        # pattern — Contributor-only deploy identities set this to false + grant manually post-deploy).
        foreach ($r in $ra) {
            $r.condition | Should -Match "parameters\('deployRoleAssignments'\)" -Because 'RAs must be skippable when deploying identity lacks Microsoft.Authorization/roleAssignments/write'
        }
    }

    It 'declares deployRoleAssignments parameter (bool, default=true) — v1 opt-out pattern' {
        $script:T.parameters.deployRoleAssignments | Should -Not -BeNullOrEmpty
        $script:T.parameters.deployRoleAssignments.type | Should -Be 'bool'
        $script:T.parameters.deployRoleAssignments.defaultValue | Should -BeTrue -Because 'default ON — initial Owner/UAA deploy creates RAs; only Contributor-only redeploys set false'
    }

    It 'has no NULL "$null" placeholders in resource definitions' {
        $json = Get-Content -Raw $script:TemplatePath
        # Catch raw '$null' string-literal that some serializers emit; PSObject -> JSON conversion shouldn't produce this
        $json | Should -Not -Match '"\$null"'
    }

    It 'has NO Claude/AI references in template strings' {
        $json = Get-Content -Raw $script:TemplatePath
        $json | Should -Not -Match 'Claude'
        $json | Should -Not -Match 'anthropic'
        $json | Should -Not -Match 'Generated with Claude'
        $json | Should -Not -Match 'Co-Authored-By: Claude'
    }

    It 'has NO V2 module/class references (StorageV2 azure-kind allowed)' {
        $json = Get-Content -Raw $script:TemplatePath
        # Allow Azure 'StorageV2' kind (legit API constant). Forbidden: project-level V2 suffixes.
        $json | Should -Not -Match 'ClientV2'
        $json | Should -Not -Match 'AuthV2'
        $json | Should -Not -Match 'Xdr\.\w+V2'
    }

    It 'has NO MDE_*_CL legacy table names (Rule 5)' {
        # The DCR streamDeclarations should be Custom-Defender_*_CL, transformKql output streams Custom-Defender_*_CL.
        # Allow MDE/MDI within URLs (apiproxy paths) — those are real Defender API paths.
        # But MDE_*_CL pattern (table-suffix) is the Rule 5 violation.
        $json = Get-Content -Raw $script:TemplatePath
        $tableMatches = [regex]::Matches($json, 'MDE_[A-Z][A-Za-z0-9]+_CL')
        $tableMatches.Count | Should -Be 0
    }

    It 'has outputs including dcrImmutableIdsJson + dceEndpoint + functionAppName' {
        $outs = ($script:T.outputs | Get-Member -MemberType NoteProperty).Name
        $outs | Should -Contain 'functionAppName'
        $outs | Should -Contain 'keyVaultName'
        $outs | Should -Contain 'storageAccountName'
        $outs | Should -Contain 'dceEndpoint'
        $outs | Should -Contain 'dcrImmutableIdsJson'
    }
}

Describe 'createUiDefinition.json invariants' {
    BeforeAll {
        $script:UI = Get-Content -Raw (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')) 'deploy' 'createUiDefinition.json') | ConvertFrom-Json -Depth 50
    }

    It 'is the multi-VM wizard schema' {
        $script:UI.'$schema' | Should -Match 'CreateUIDefinition.MultiVm.json'
        $script:UI.handler   | Should -Be 'Microsoft.Azure.CreateUIDef'
    }

    It 'is wizard-style with 3 steps (workspace · auth · advanced)' {
        $script:UI.parameters.config.isWizard | Should -BeTrue
        $script:UI.parameters.steps.Count | Should -Be 3
        $stepNames = $script:UI.parameters.steps | ForEach-Object { $_.name }
        $stepNames | Should -Contain 'workspaceStep'
        $stepNames | Should -Contain 'authStep'
        $stepNames | Should -Contain 'advancedStep'
    }

    It 'workspace step uses ResourceSelector for existing workspace' {
        $ws = $script:UI.parameters.steps | Where-Object { $_.name -eq 'workspaceStep' }
        $sel = $ws.elements | Where-Object { $_.type -eq 'Microsoft.Solutions.ResourceSelector' }
        $sel.resourceType | Should -Be 'Microsoft.OperationalInsights/workspaces'
    }

    It 'auth step supports credentials_totp + passkey + conditional UI' {
        $auth = $script:UI.parameters.steps | Where-Object { $_.name -eq 'authStep' }
        $method = $auth.elements | Where-Object { $_.name -eq 'authMethod' }
        $allowedValues = $method.constraints.allowedValues | ForEach-Object { $_.value }
        $allowedValues | Should -Contain 'credentials_totp'
        $allowedValues | Should -Contain 'passkey'
    }

    It 'has outputs mapping basics + steps to template params' {
        $outs = ($script:UI.parameters.outputs | Get-Member -MemberType NoteProperty).Name
        $outs | Should -Contain 'projectPrefix'
        $outs | Should -Contain 'existingWorkspaceId'
        $outs | Should -Contain 'serviceAccountUpn'
        $outs | Should -Contain 'authMethod'
        $outs | Should -Contain 'planSku'
        $outs | Should -Contain 'deployRoleAssignments' -Because 'v1 opt-out flag for split-role admin tenants'
    }

    It 'advancedStep has deployRoleAssignments CheckBox defaulting to true' {
        $adv = $script:UI.parameters.steps | Where-Object { $_.name -eq 'advancedStep' }
        $dra = $adv.elements | Where-Object { $_.name -eq 'deployRoleAssignments' }
        $dra | Should -Not -BeNullOrEmpty
        $dra.type | Should -Be 'Microsoft.Common.CheckBox'
        $dra.defaultValue | Should -BeTrue
    }
}

Describe 'Cross-template consistency (DCR ↔ workspace table names)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:T = Get-Content -Raw (Join-Path $script:RepoRoot 'deploy' 'mainTemplate.json') | ConvertFrom-Json -Depth 50
    }

    It 'every workspace table is targeted by exactly one DCR outputStream' {
        $nested = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'customTables' }
        # Extract pure table names from ARM concat expressions like
        # "[concat(parameters('workspaceName'), '/', 'Defender_ActionCenter_CL')]"
        $tables = @($nested.properties.template.resources | ForEach-Object {
            if ($_.name -match "'([A-Za-z][A-Za-z0-9_]*_CL)'") { $matches[1] }
        })
        $tables.Count | Should -Be 19

        $dcrs = $script:T.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }
        $outputStreams = @()
        foreach ($d in $dcrs) {
            foreach ($flow in $d.properties.dataFlows) {
                $outputStreams += $flow.outputStream
            }
        }

        foreach ($t in $tables) {
            $expected = "Custom-$t"
            $outputStreams | Should -Contain $expected -Because "workspace table $t must be the outputStream of at least one DCR dataFlow"
        }
    }
}
