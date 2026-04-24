#Requires -Modules Pester

BeforeAll {
    $script:DeployDir = Join-Path $PSScriptRoot '..' '..' 'deploy'
    $script:MainTemplatePath  = Join-Path $script:DeployDir 'compiled' 'mainTemplate.json'
    $script:UiDefinitionPath  = Join-Path $script:DeployDir 'compiled' 'createUiDefinition.json'
    $script:BicepMainPath     = Join-Path $script:DeployDir 'main.bicep'
}

Describe 'ARM template files — presence' {
    It 'mainTemplate.json exists' {
        Test-Path $script:MainTemplatePath | Should -BeTrue
    }

    It 'createUiDefinition.json exists' {
        Test-Path $script:UiDefinitionPath | Should -BeTrue
    }

    It 'main.bicep source exists' {
        Test-Path $script:BicepMainPath | Should -BeTrue
    }
}

Describe 'mainTemplate.json — schema + structure' {
    BeforeAll {
        $script:MainTemplate = Get-Content $script:MainTemplatePath -Raw | ConvertFrom-Json
    }

    It 'has a valid ARM $schema' {
        $script:MainTemplate.'$schema' | Should -Match 'schema\.management\.azure\.com.*deploymentTemplate'
    }

    It 'has required top-level keys' {
        foreach ($key in 'contentVersion', 'parameters', 'variables', 'resources', 'outputs') {
            $script:MainTemplate.PSObject.Properties[$key] | Should -Not -BeNullOrEmpty
        }
    }

    It 'declares projectPrefix parameter with valid constraints' {
        $p = $script:MainTemplate.parameters.projectPrefix
        $p | Should -Not -BeNullOrEmpty
        $p.type | Should -Be 'string'
        $p.minLength | Should -Be 3
        $p.maxLength | Should -Be 12
    }

    It 'declares authMethod parameter with validation' {
        $p = $script:MainTemplate.parameters.authMethod
        $p | Should -Not -BeNullOrEmpty
        $p.allowedValues | Should -Contain 'passkey'
        $p.allowedValues | Should -Contain 'credentials_totp'
    }

    It 'declares serviceAccountUpn parameter' {
        $script:MainTemplate.parameters.serviceAccountUpn | Should -Not -BeNullOrEmpty
    }

    It 'declares deploySentinelContent bool parameter (default true)' {
        $p = $script:MainTemplate.parameters.deploySentinelContent
        $p | Should -Not -BeNullOrEmpty
        $p.type | Should -Be 'bool'
        $p.defaultValue | Should -Be $true
    }

    It 'declares optional secure params for wizard secret upload (servicePassword, totpSeed, passkeyJson)' {
        foreach ($name in 'servicePassword', 'totpSeed', 'passkeyJson') {
            $p = $script:MainTemplate.parameters.$name
            $p | Should -Not -BeNullOrEmpty -Because "secure param '$name' must be declared so wizard can write directly to KV"
            $p.type | Should -Be 'securestring'
            $p.defaultValue | Should -Be ''
        }
    }

    It 'sentinelContent nested deploy is conditional on deploySentinelContent param' {
        $sentinel = $script:MainTemplate.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'sentinelContent'
        } | Select-Object -First 1
        $sentinel | Should -Not -BeNullOrEmpty
        $sentinel.condition | Should -Match "parameters\('deploySentinelContent'\)"
    }

    It 'creates KV secrets for auth method + UPN unconditionally' {
        $secrets = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults/secrets' })
        $secretNames = $secrets | ForEach-Object { $_.name }
        $secretNames | Where-Object { $_ -match 'mde-portal-auth-method' } | Should -Not -BeNullOrEmpty
        $secretNames | Where-Object { $_ -match 'mde-portal-upn' }         | Should -Not -BeNullOrEmpty
    }

    It 'creates conditional KV secrets for password + totp + passkey (only when wizard provided value)' {
        $secrets = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults/secrets' })
        foreach ($leaf in 'mde-portal-password', 'mde-portal-totp', 'mde-portal-passkey') {
            $s = $secrets | Where-Object { $_.name -match $leaf } | Select-Object -First 1
            $s | Should -Not -BeNullOrEmpty -Because "wizard secret-write resource for '$leaf' must exist"
            $s.PSObject.Properties['condition'] | Should -Not -BeNullOrEmpty -Because "'$leaf' write must be conditional so empty wizard input is a no-op"
        }
    }

    It 'existingWorkspaceId is REQUIRED (no default value)' {
        $p = $script:MainTemplate.parameters.existingWorkspaceId
        $p | Should -Not -BeNullOrEmpty
        $p.PSObject.Properties['defaultValue'] | Should -BeNullOrEmpty
        $p.minLength | Should -Be 1
    }

    It 'workspaceLocation is REQUIRED' {
        $p = $script:MainTemplate.parameters.workspaceLocation
        $p | Should -Not -BeNullOrEmpty
        $p.minLength | Should -Be 1
    }

    It 'has NO workspace-creation resource (workspace must pre-exist)' {
        $types = $script:MainTemplate.resources | ForEach-Object { $_.type }
        $types | Should -Not -Contain 'Microsoft.OperationalInsights/workspaces'
    }

    It 'creates core connector resource types' {
        $types = $script:MainTemplate.resources | ForEach-Object { $_.type } | Sort-Object -Unique
        $types | Should -Contain 'Microsoft.Storage/storageAccounts'
        $types | Should -Contain 'Microsoft.KeyVault/vaults'
        $types | Should -Contain 'Microsoft.Web/sites'
        $types | Should -Contain 'Microsoft.Web/serverfarms'
        $types | Should -Contain 'Microsoft.Insights/components'
        $types | Should -Contain 'Microsoft.Insights/dataCollectionEndpoints'
        $types | Should -Contain 'Microsoft.Insights/dataCollectionRules'
        $types | Should -Contain 'Microsoft.Authorization/roleAssignments'
        $types | Should -Contain 'Microsoft.Resources/deployments'
    }

    It 'Function App has SystemAssigned managed identity' {
        $funcApp = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' } | Select-Object -First 1
        $funcApp.identity.type | Should -Be 'SystemAssigned'
    }

    It 'creates exactly 3 role assignments for the MI (KV Secrets User, Storage Table Contributor, Monitoring Metrics Publisher)' {
        $roleAssignments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        $roleAssignments.Count | Should -Be 3
    }

    It 'has a nested deployment for cross-RG custom tables (54)' {
        $nestedDeployments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })
        $nestedDeployments.Count | Should -BeGreaterOrEqual 2  # customTables + sentinelContent
        $customTablesDeploy = $nestedDeployments | Where-Object { $_.name -match 'customTables' }
        $customTablesDeploy | Should -Not -BeNullOrEmpty
        $customTablesDeploy.subscriptionId | Should -Not -BeNullOrEmpty  # cross-subscription capable
        $customTablesDeploy.resourceGroup  | Should -Not -BeNullOrEmpty  # cross-RG
    }

    It 'has a nested deployment for cross-RG Sentinel content' {
        $sentinelDeploy = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'sentinelContent' }
        $sentinelDeploy | Should -Not -BeNullOrEmpty
        $sentinelDeploy.properties.templateLink.uri | Should -Match 'sentinelContent\.json'
    }

    It 'DCE + DCR use workspaceLocation (not connectorLocation)' {
        $dce = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionEndpoints' } | Select-Object -First 1
        $dcr = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules'    } | Select-Object -First 1
        $dce.location | Should -Be "[parameters('workspaceLocation')]"
        $dcr.location | Should -Be "[parameters('workspaceLocation')]"
    }

    It 'DCE does NOT have a `kind` property (the AMA-era label)' {
        $dce = $script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionEndpoints' } | Select-Object -First 1
        $dce.PSObject.Properties['kind'] | Should -BeNullOrEmpty
    }

    It 'outputs keyVaultName, dceEndpoint, dcrImmutableId, workspace context' {
        $script:MainTemplate.outputs.keyVaultName      | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dceEndpoint       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dcrImmutableId    | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceId       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceRg       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceLocation | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.postDeployCommand | Should -Not -BeNullOrEmpty
    }
}

Describe 'createUiDefinition.json — schema + structure' {
    BeforeAll {
        $script:UiDef = Get-Content $script:UiDefinitionPath -Raw | ConvertFrom-Json
    }

    It 'has correct handler' {
        $script:UiDef.handler | Should -Be 'Microsoft.Azure.CreateUIDef'
    }

    It 'has schema property' {
        $script:UiDef.'$schema' | Should -Match 'schema\.management\.azure\.com.*CreateUIDefinition'
    }

    It 'declares basics elements' {
        $script:UiDef.parameters.basics | Should -Not -BeNullOrEmpty
    }

    It 'has authentication step' {
        $authStep = $script:UiDef.parameters.steps | Where-Object name -eq 'authSettings'
        $authStep | Should -Not -BeNullOrEmpty
    }

    It 'outputs match mainTemplate parameters' {
        $outputs = $script:UiDef.parameters.outputs.PSObject.Properties.Name
        foreach ($requiredOutput in 'projectPrefix', 'serviceAccountUpn', 'authMethod', 'existingWorkspaceId', 'workspaceLocation') {
            $outputs | Should -Contain $requiredOutput
        }
    }

    It 'has workspaceSettings step with a ResourceSelector for the Log Analytics workspace' {
        # v0.1.0-beta UI simplification: the workspace picker is now a
        # Microsoft.Solutions.ResourceSelector (dropdown of existing
        # workspaces) instead of a manual TextBox, and the region auto-fills
        # from the selected workspace.location (with optional override).
        $wsStep = $script:UiDef.parameters.steps | Where-Object name -eq 'workspaceSettings'
        $wsStep | Should -Not -BeNullOrEmpty

        $wsPicker = $wsStep.elements | Where-Object name -eq 'existingWorkspace'
        $wsPicker | Should -Not -BeNullOrEmpty -Because 'workspace picker element must exist'
        $wsPicker.type | Should -Be 'Microsoft.Solutions.ResourceSelector'
        $wsPicker.resourceType | Should -Be 'Microsoft.OperationalInsights/workspaces'

        # Output must still provide the canonical workspace ID + location
        # (derived from the picker) to the mainTemplate.
        $outputs = $script:UiDef.parameters.outputs
        $outputs.existingWorkspaceId | Should -Match 'existingWorkspace\.id'
        $outputs.workspaceLocation   | Should -Match 'existingWorkspace\.location'
    }
}

Describe 'Bicep source — files present' {
    It 'main.bicep is non-empty' {
        (Get-Content $script:BicepMainPath -Raw).Length | Should -BeGreaterThan 500
    }

    It 'has modular submodules (no log-analytics.bicep — workspace is external)' {
        $modulesDir = Join-Path $script:DeployDir 'modules'
        $modules = Get-ChildItem -Path $modulesDir -Filter '*.bicep'
        $modules.Count | Should -BeGreaterOrEqual 6  # storage, key-vault, app-insights, function-app, dce-dcr, custom-tables, role-assignments, data-connector
        $moduleNames = $modules | ForEach-Object { $_.BaseName }
        $moduleNames | Should -Not -Contain 'log-analytics'  # deleted in v1.0
    }

    It 'main.bicep requires existingWorkspaceId + workspaceLocation (no defaults)' {
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "param existingWorkspaceId string\b"
        $bicep | Should -Match "param workspaceLocation string\b"
        $bicep | Should -Match "@minLength\(1\)"   # Both required params carry minLength(1)
    }

    It 'main.bicep wires Sentinel Solution module (sentinelSolution) before sentinelContent' {
        # v0.1.0-beta iteration 5: connector now appears in the Sentinel Data
        # Connectors blade like Microsoft Defender XDR / MDE / Office 365 do —
        # via a Sentinel Solution package + StaticUI dataConnector. Lock that
        # main.bicep wires the module under the canonical name.
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "module sentinelSolution 'modules/data-connector\.bicep'"
        $bicep | Should -Match "name: 'solution-\$\{uniq\}'"
    }

    It 'main.bicep uses cross-RG scope for custom-tables module' {
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "scope:\s*resourceGroup\(workspaceSubscriptionId,\s*workspaceResourceGroup\)"
    }
}

Describe 'Sentinel Solution shape — connector visible in Data Connectors blade' {
    # v0.1.0-beta iteration 5: the connector now appears in Sentinel → Data
    # Connectors alongside Microsoft Defender XDR / MDE / Office 365 — same
    # resource shape Microsoft uses for first-party connectors. The compiled
    # mainTemplate must contain a 'solution-*' nested deployment with the 4
    # canonical resources: contentPackages + Solution metadata + StaticUI
    # dataConnector + DataConnector metadata.
    BeforeAll {
        $script:SolutionDeploy = $script:MainTemplate.resources |
            Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'solution-' } |
            Select-Object -First 1
    }

    It 'mainTemplate.json contains solution-* nested deploy (cross-RG into workspace)' {
        $script:SolutionDeploy | Should -Not -BeNullOrEmpty -Because 'connector won''t appear in Data Connectors blade without it'
        $script:SolutionDeploy.subscriptionId | Should -Not -BeNullOrEmpty -Because 'must be cross-subscription capable'
        $script:SolutionDeploy.resourceGroup  | Should -Not -BeNullOrEmpty -Because 'must scope into the workspace RG'
    }

    It 'solution-* deploy has NO condition (always deploys regardless of deploySentinelContent)' {
        # The Solution package + connector card should always be present; only
        # rules/hunting/workbooks are gated by deploySentinelContent.
        $script:SolutionDeploy.PSObject.Properties['condition'] | Should -BeNullOrEmpty
    }

    It 'solution-* dependsOn customTables (tables exist before connector references them)' {
        $deps = @($script:SolutionDeploy.dependsOn)
        ($deps -join '|') | Should -Match 'customTables-' -Because 'connector dataTypes reference tables that must exist'
    }

    It 'inner template emits 3 canonical resources: contentPackages + StaticUI dataConnector + DataConnector metadata (NO redundant Solution metadata)' {
        # Per AbnormalSecurity 2026-02-17 reference (contentSchemaVersion 3.0.0):
        # newer Sentinel solutions use ONLY contentPackages as the Solution wrapper.
        # Adding a separate metadata kind=Solution triggers Sentinel's `Invalid data
        # model - solutions expect contentId to match parentId` because that
        # metadata's parentId is a full resourceId while contentId is the slug —
        # they can never match by string.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        @($inner | Where-Object { $_.type -match 'contentPackages$' }).Count                                                       | Should -BeGreaterOrEqual 1
        @($inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'Solution' }).Count                       | Should -Be 0 -Because 'metadata kind=Solution causes Sentinel API rejection in cross-RG nested deploys'
        @($inner | Where-Object { $_.type -match 'dataConnectors$' -and $_.kind -eq 'StaticUI' }).Count                            | Should -BeGreaterOrEqual 1
        @($inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'DataConnector' }).Count                  | Should -BeGreaterOrEqual 1
    }

    It 'Solution package contentKind = Solution and the inner template defines XdrLogRaider' {
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $pkg   = $inner | Where-Object { $_.type -match 'contentPackages$' } | Select-Object -First 1
        $pkg.properties.contentKind | Should -Be 'Solution'
        $pkg.properties.version     | Should -Not -BeNullOrEmpty
        # displayName is an ARM expression that resolves at deploy time. Walk
        # the inner template variables to confirm the resolved name is correct.
        $vars = $script:SolutionDeploy.properties.template.variables
        $vars.solutionName | Should -Be 'XdrLogRaider'
        $vars.solutionId   | Should -Be 'community.xdrlograider'
    }

    It 'StaticUI dataConnector has connectivityCriterias (Sentinel uses this for Connected status)' {
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $dc    = $inner | Where-Object { $_.type -match 'dataConnectors$' } | Select-Object -First 1
        $dc.properties.connectorUiConfig.connectivityCriterias | Should -Not -BeNullOrEmpty
        $dc.properties.connectorUiConfig.dataTypes             | Should -Not -BeNullOrEmpty
    }

    It 'DataConnector metadata back-links to dataConnector via parentId' {
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $meta  = $inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'DataConnector' } | Select-Object -First 1
        $meta.properties.parentId | Should -Match 'dataConnectors'
    }

    It 'inner template does NOT contain a metadata kind=Solution resource (intentional per AbnormalSecurity 2026-02-17)' {
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $solMeta = @($inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'Solution' })
        $solMeta.Count | Should -Be 0 -Because 'metadata kind=Solution is redundant when contentPackages exists; including it triggers Sentinel parentId/contentId mismatch rejection'
    }

    It 'every Solution resource has a location field (contentPackages + metadata + dataConnectors)' {
        # Microsoft Sentinel content resources require Azure region. Missing
        # location triggers Marketplace/Content Hub indexing failures and may
        # cause silent UI rendering issues. Iteration 8 added location to all 4.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $solRes = $inner | Where-Object {
            $_.type -in 'Microsoft.OperationalInsights/workspaces/providers/contentPackages',
                        'Microsoft.OperationalInsights/workspaces/providers/metadata',
                        'Microsoft.OperationalInsights/workspaces/providers/dataConnectors'
        }
        # Iter 11: dropped metadata-Solution per AbnormalSecurity reference, so count is 3 (contentPackages + dataConnectors + DataConnector metadata)
        @($solRes).Count | Should -BeGreaterOrEqual 3
        $missingLoc = @($solRes | Where-Object { -not $_.PSObject.Properties['location'] -or -not $_.location })
        $missingLoc.Count | Should -Be 0 -Because 'every Sentinel Solution resource must carry location for Content Hub indexing'
    }

    It 'contentPackages has dependencies block with criteria array' {
        # The dependencies block tells Content Hub about prerequisite content
        # packages. Even an empty criteria array is a valid declaration that
        # the Solution has no external dependencies.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $cp = $inner | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/contentPackages' } | Select-Object -First 1
        $cp.properties.PSObject.Properties['dependencies'] | Should -Not -BeNullOrEmpty
        $cp.properties.dependencies.PSObject.Properties['criteria'] | Should -Not -BeNullOrEmpty
    }

    It 'contentPackages has all 6 required Sentinel content schema 3.0.0 properties' {
        # Microsoft.SecurityInsights API rejects PUT with
        #   `properties.contentSchemaVersion is required` BadRequestException.
        # Pinned required set per reference solutions
        # (Solutions/Akamai Security Events/Package/mainTemplate.json):
        #   contentSchemaVersion, kind, version, displayName, contentKind, contentId.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $cp    = $inner | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/contentPackages' } | Select-Object -First 1
        $cp | Should -Not -BeNullOrEmpty
        foreach ($f in 'contentSchemaVersion', 'kind', 'version', 'displayName', 'contentKind', 'contentId') {
            $cp.properties.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty -Because "contentPackages.$f is required by Sentinel content schema; missing field causes deploy to fail"
        }
        $cp.properties.contentSchemaVersion | Should -Match '^\d+\.\d+\.\d+$' -Because 'contentSchemaVersion should be semver (3.0.0 is the modern Sentinel content schema)'
        $cp.properties.kind                 | Should -Be 'Solution'
        $cp.properties.contentKind          | Should -Be 'Solution'
    }

    It 'inner template uses resourceId() (NOT extensionResourceId) for hierarchical workspaces/providers types' {
        # Iteration 6 deploy blocker: bicep `solutionPackage.id` compiled to
        # extensionResourceId(workspaceScope, type, 2 names) but ARM requires
        # 3 names for Microsoft.OperationalInsights/workspaces/providers/<X>
        # types. Result: "Unable to evaluate template language function
        # 'extensionResourceId': the type ... requires '3' resource name
        # argument(s)" at template validation. Lock the canonical form.
        $body = $script:SolutionDeploy.properties.template | ConvertTo-Json -Depth 50 -Compress
        $bad  = [regex]::Matches($body, 'extensionResourceId\([^)]*workspaces/providers/')
        $bad.Count | Should -Be 0 -Because "extensionResourceId() with hierarchical workspaces/providers/ types breaks at deploy validation; use resourceId('Microsoft.OperationalInsights/workspaces/providers/<resource>', workspaceName, 'Microsoft.SecurityInsights', <name>)"
    }
}

Describe 'DCR — Azure service-quota gates' {
    # Microsoft.Insights/dataCollectionRules has hard service quotas that the
    # JSON schema and ARM-TTK do not catch. Hitting these manifests at preflight
    # (PreflightValidationCheckFailed) — too late. v0.1.0-beta originally
    # generated 47 dataFlows (one per stream) and tripped 'DataFlows item count
    # should be 10 or less'. These tests guard against regression.
    BeforeAll {
        $script:Dcrs = @($script:MainTemplate.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
    }

    It 'every DCR has dataFlows count <= 10 (Azure hard limit)' {
        $script:Dcrs.Count | Should -BeGreaterOrEqual 1
        foreach ($dcr in $script:Dcrs) {
            $flowCount = @($dcr.properties.dataFlows).Count
            $flowCount | Should -BeLessOrEqual 10 -Because "DCR '$($dcr.name)' has $flowCount dataFlows; Azure rejects >10 at preflight"
        }
    }

    It 'every dataFlow has streams count <= 20 (Azure hard limit per dataFlow)' {
        # Tripped after the first consolidation attempt (1 flow × 47 streams).
        # Azure rejects with InvalidDataFlow / 'Streams item count should be 20 or less'.
        foreach ($dcr in $script:Dcrs) {
            for ($i = 0; $i -lt @($dcr.properties.dataFlows).Count; $i++) {
                $flow = $dcr.properties.dataFlows[$i]
                $sCount = @($flow.streams).Count
                $sCount | Should -BeLessOrEqual 20 -Because "DCR '$($dcr.name)' dataFlow[$i] has $sCount streams; Azure caps at 20 per dataFlow"
            }
        }
    }

    It 'every DCR has destinations count <= 10' {
        foreach ($dcr in $script:Dcrs) {
            $destCount = 0
            foreach ($destProp in $dcr.properties.destinations.PSObject.Properties) {
                if ($destProp.Value -is [array]) { $destCount += @($destProp.Value).Count }
                elseif ($destProp.Value)         { $destCount += 1 }
            }
            $destCount | Should -BeLessOrEqual 10 -Because "DCR '$($dcr.name)' has $destCount destinations; Azure limit is 10"
        }
    }

    It 'every streamDeclaration is referenced in at least one dataFlow.streams' {
        foreach ($dcr in $script:Dcrs) {
            $declared = @($dcr.properties.streamDeclarations.PSObject.Properties.Name)
            $referenced = @()
            foreach ($df in $dcr.properties.dataFlows) {
                $referenced += @($df.streams)
            }
            $orphans = @($declared | Where-Object { $_ -notin $referenced })
            $orphans.Count | Should -Be 0 -Because "DCR '$($dcr.name)' has orphan streamDeclarations not referenced in dataFlows: $($orphans -join ', ')"
        }
    }

    It 'main DCR splits 47 streams across 3 tier-grouped dataFlows (post-quota-fix shape)' {
        # Final quota-compliant shape after the v0.1.0-beta deploy fixes:
        #   - dataFlows.Count = 3 (Azure limit 10)
        #   - max streams in any single dataFlow = 19 (Azure limit 20)
        #   - sum of streams across all dataFlows >= 47 (every declared stream routed)
        # Locks the canonical shape so future edits don't accidentally
        # re-explode (>10 flows) or re-collapse (>20 streams in any flow).
        $mainDcr = $script:Dcrs | Where-Object { @($_.properties.streamDeclarations.PSObject.Properties.Name).Count -ge 47 } | Select-Object -First 1
        $mainDcr | Should -Not -BeNullOrEmpty
        @($mainDcr.properties.dataFlows).Count | Should -Be 3 -Because 'tier-grouped split: P0 / P1+P2+P3 / P5+P6+P7+ops'
        $totalStreams = 0
        foreach ($df in $mainDcr.properties.dataFlows) { $totalStreams += @($df.streams).Count }
        $totalStreams | Should -BeGreaterOrEqual 47 -Because 'every declared stream must appear in some dataFlow'
    }

    It 'no dataFlow combines multiple streams with a transformKql (Microsoft DCR rule)' {
        # Microsoft DCR docs: "If you use a transformation, the data flow
        # should only use a single stream." First DCR PUT in v0.1.0-beta
        # tripped this with InvalidPayload. Lock the rule.
        foreach ($dcr in $script:Dcrs) {
            for ($i = 0; $i -lt @($dcr.properties.dataFlows).Count; $i++) {
                $df = $dcr.properties.dataFlows[$i]
                $hasTransform = ($df.PSObject.Properties['transformKql'] -and $df.transformKql)
                $multiStream  = (@($df.streams).Count -gt 1)
                ($hasTransform -and $multiStream) | Should -BeFalse -Because "DCR '$($dcr.name)' dataFlow[$i] has $(@($df.streams).Count) streams + transformKql — Azure rejects this combo"
            }
        }
    }

    It 'DCR dependsOn includes the customTables cross-RG nested deploy' {
        # The DCR API does a synchronous "tables exist?" check at PUT time. If
        # the DCR resource is not dependsOn'd on the cross-RG customTables-*
        # nested deploy, ARM runs them in parallel and DCR creation races —
        # fails with InvalidOutputTable. Caught us in the second deploy attempt.
        $template = $script:MainTemplate
        $dcrRes = $template.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' } | Select-Object -First 1
        $dcrRes | Should -Not -BeNullOrEmpty
        $dcrRes.dependsOn | Should -Not -BeNullOrEmpty
        $hasTablesDep = $false
        foreach ($d in $dcrRes.dependsOn) {
            if ($d -match 'customTables|tables-') { $hasTablesDep = $true; break }
        }
        $hasTablesDep | Should -BeTrue -Because 'DCR must dependsOn customTables-* nested deploy or it races the table creation'
    }

    It 'every dataFlow omits per-stream outputStream (default routing to like-named tables)' {
        # When outputStream is omitted, each Custom-X stream routes by name to
        # workspace table X. Setting outputStream on a multi-stream dataFlow
        # would collapse all streams into ONE table — that would be a bug.
        $mainDcr = $script:Dcrs | Where-Object { @($_.properties.streamDeclarations.PSObject.Properties.Name).Count -ge 47 } | Select-Object -First 1
        foreach ($df in $mainDcr.properties.dataFlows) {
            if (@($df.streams).Count -gt 1) {
                $df.PSObject.Properties['outputStream'] | Should -BeNullOrEmpty -Because 'multi-stream dataFlow with outputStream collapses all streams into a single output table'
            }
        }
    }
}

Describe 'DCR streams — completeness' {
    It 'DCR includes 45 MDE_*_CL data stream declarations + 2 operational tables (v0.1.0-beta.1)' {
        # v0.1.0-beta.1: 45 = 15 P0 + 7 P1 + 4 P2 + 8 P3 + 5 P5 + 2 P6 + 4 P7
        # v0.1.0-beta.1 removals (2 WRITE endpoints per XDRInternals):
        #   MDE_CriticalAssets_CL, MDE_DeviceCriticality_CL.
        # Earlier v1.0.2 removals (NO_PUBLIC_API):
        #   MDE_AsrRulesConfig_CL, MDE_AntiRansomwareConfig_CL,
        #   MDE_ControlledFolderAccess_CL, MDE_NetworkProtectionConfig_CL,
        #   MDE_ApprovalAssignments_CL.
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        $streams = [regex]::Matches($dceDcrBicep, "'(MDE_\w+_CL)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $streams.Count | Should -BeGreaterOrEqual 47  # 45 data streams + Heartbeat + AuthTestResult
    }

    It 'DCR has NO dropped streams (v1.0.0 P4 + v1.0.2 + v0.1.0-beta.1 removals)' {
        $dceDcrBicep = Get-Content (Join-Path $script:DeployDir 'modules' 'dce-dcr.bicep') -Raw
        # v1.0.0 early drops
        $dceDcrBicep | Should -Not -Match 'MDE_AirDecisions'
        $dceDcrBicep | Should -Not -Match 'MDE_InvestigationPackage'
        $dceDcrBicep | Should -Not -Match 'MDE_DeviceTimeline'
        # v1.0.2 NO_PUBLIC_API removals
        $dceDcrBicep | Should -Not -Match 'MDE_AsrRulesConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_AntiRansomwareConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_ControlledFolderAccess_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_NetworkProtectionConfig_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_ApprovalAssignments_CL'
        # v0.1.0-beta.1 write-endpoint removals
        $dceDcrBicep | Should -Not -Match 'MDE_CriticalAssets_CL'
        $dceDcrBicep | Should -Not -Match 'MDE_DeviceCriticality_CL'
    }
}
