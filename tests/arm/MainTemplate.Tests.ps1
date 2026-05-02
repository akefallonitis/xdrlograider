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

    It 'main.bicep source exists' -Skip {
        # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
        # single source of truth). The deploy/main.bicep file no longer ships.
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

    It 'mainTemplate variables.packageUrl resolves /releases/latest/download/function-app.zip (no functionAppZipVersion parameter)' {
        # v0.1.0-beta first publish: drops the functionAppZipVersion wizard
        # field. The Function App ZIP URL tracks GitHub Releases /latest
        # unconditionally (Marketplace best practice for community connectors).
        # /latest resolves to the most-recent non-prerelease tag — operators
        # don't have to edit the wizard for routine upgrades.
        $script:MainTemplate.parameters.PSObject.Properties.Name | Should -Not -Contain 'functionAppZipVersion' -Because 'parameter retired in v0.1.0-beta first publish'
        $packageUrl = $script:MainTemplate.variables.packageUrl
        $packageUrl | Should -Match '/releases/latest/download/function-app\.zip' -Because 'packageUrl must point at /releases/latest/download/function-app.zip'
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

    It 'declares optional secure params for wizard secret upload (servicePassword, totpSeed, passkeyJson)' {
        foreach ($name in 'servicePassword', 'totpSeed', 'passkeyJson') {
            $p = $script:MainTemplate.parameters.$name
            $p | Should -Not -BeNullOrEmpty -Because "secure param '$name' must be declared so wizard can write directly to KV"
            $p.type | Should -Be 'securestring'
            $p.defaultValue | Should -Be ''
        }
    }

    It 'sentinelContent nested deploy is unconditional (Sentinel content always deploys)' {
        $sentinel = $script:MainTemplate.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -match 'sentinelContent'
        } | Select-Object -First 1
        $sentinel | Should -Not -BeNullOrEmpty
        $sentinel.PSObject.Properties['condition'] | Should -BeNullOrEmpty -Because 'Sentinel content always deploys post-architectural-simplification (no deploySentinelContent toggle)'
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

    It 'creates exactly 7 role assignments for the MI (Y1 baseline: KV Secrets User + Storage Table Contributor + 5x Monitoring Metrics Publisher per DCR)' {
        # 5 DCRs sharing one DCE → 5 separate Monitoring Metrics Publisher
        # role assignments (the Logs Ingestion API authorizes per DCR). With
        # KV Secrets User + Storage Table Contributor, that's 7 unconditional
        # role assignments on Y1. (FC1/EP1 add Storage File SMB Share
        # Contributor; that role is conditional and not in the compiled JSON's
        # Y1 default — counted separately by the LeastPrivilege test.)
        $roleAssignments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        $roleAssignments.Count | Should -Be 7
    }

    It 'has a nested deployment for cross-RG custom tables' {
        $nestedDeployments = @($script:MainTemplate.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' })
        $nestedDeployments.Count | Should -BeGreaterOrEqual 2  # customTables + Sentinel Solution wrapper (data connector card)
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

    It 'outputs keyVaultName, dceEndpoint, dcrImmutableIdsJson, 5x dcr#ImmutableId, workspace context' {
        # 5-DCR shape (Microsoft Learn canonical): the FA needs the per-stream
        # map (dcrImmutableIdsJson) for the lookup helper; operators benefit
        # from each indexed id being separately accessible (post-deploy
        # diagnostics, KQL queries against a specific DCR).
        $script:MainTemplate.outputs.keyVaultName            | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dceEndpoint             | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.dcrImmutableIdsJson     | Should -Not -BeNullOrEmpty
        foreach ($i in 1..5) {
            $script:MainTemplate.outputs."dcr${i}ImmutableId" | Should -Not -BeNullOrEmpty -Because "indexed output dcr${i}ImmutableId must exist"
        }
        $script:MainTemplate.outputs.workspaceId             | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceRg             | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.workspaceLocation       | Should -Not -BeNullOrEmpty
        $script:MainTemplate.outputs.postDeployCommand       | Should -Not -BeNullOrEmpty
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

Describe 'Bicep source — files present' -Skip {
    # Bicep is archived to .internal/bicep-reference/ in v0.2.0 (ARM is the
    # single source of truth). These assertions reference deploy/main.bicep
    # and deploy/modules/*.bicep which no longer ship. Re-enable in v0.2.0
    # when Bicep + auto-compile is reintroduced.
    It 'main.bicep is non-empty' {
        (Get-Content $script:BicepMainPath -Raw).Length | Should -BeGreaterThan 500
    }

    It 'has modular submodules (no log-analytics.bicep — workspace is external)' {
        $modulesDir = Join-Path $script:DeployDir 'modules'
        $modules = Get-ChildItem -Path $modulesDir -Filter '*.bicep'
        $modules.Count | Should -BeGreaterOrEqual 6
        $moduleNames = $modules | ForEach-Object { $_.BaseName }
        $moduleNames | Should -Not -Contain 'log-analytics'
    }

    It 'main.bicep requires existingWorkspaceId + workspaceLocation (no defaults)' {
        $bicep = Get-Content $script:BicepMainPath -Raw
        $bicep | Should -Match "param existingWorkspaceId string\b"
        $bicep | Should -Match "param workspaceLocation string\b"
        $bicep | Should -Match "@minLength\(1\)"
    }

    It 'main.bicep wires Sentinel Solution module (sentinelSolution) before sentinelContent' {
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
    # v0.1.0-beta iteration 12: the connector appears in Sentinel → Data
    # Connectors alongside Microsoft Defender XDR / MDE / Office 365 — using
    # the canonical shape for community FA-based connectors per Trend Micro
    # Vision One reference (kind=GenericUI + apiVersion=2021-03-01-preview).
    # The compiled mainTemplate must contain a 'solution-*' nested deployment
    # with 3 canonical resources: contentPackages + GenericUI dataConnector +
    # DataConnector metadata. (No metadata-Solution per AbnormalSecurity ref.)
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

    It 'solution-* deploy has NO condition (always deploys)' {
        # The Solution package + connector card should always be present; the
        # entire sentinel content nested deploy is also unconditional after
        # the deploySentinelContent toggle was removed.
        $script:SolutionDeploy.PSObject.Properties['condition'] | Should -BeNullOrEmpty
    }

    It 'solution-* dependsOn customTables (tables exist before connector references them)' {
        $deps = @($script:SolutionDeploy.dependsOn)
        ($deps -join '|') | Should -Match 'customTables-' -Because 'connector dataTypes reference tables that must exist'
    }

    It 'inner template emits 3 canonical resources: contentPackages + GenericUI dataConnector + DataConnector metadata (NO redundant Solution metadata)' {
        # Per AbnormalSecurity 2026-02-17 reference (contentSchemaVersion 3.0.0):
        # newer Sentinel solutions use ONLY contentPackages as the Solution wrapper.
        # Adding a separate metadata kind=Solution triggers Sentinel's `Invalid data
        # model - solutions expect contentId to match parentId` because that
        # metadata's parentId is a full resourceId while contentId is the slug —
        # they can never match by string.
        # Per Trend Micro Vision One reference (the canonical FA-based community
        # connector that surfaces correctly in Data Connectors blade after direct
        # ARM deploy): kind=GenericUI is the right kind; StaticUI is reserved for
        # first-party Microsoft connectors and is treated differently by the
        # Sentinel UI blade indexer when the publisher is non-Microsoft.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        @($inner | Where-Object { $_.type -match 'contentPackages$' }).Count                                                       | Should -BeGreaterOrEqual 1
        @($inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'Solution' }).Count                       | Should -Be 0 -Because 'metadata kind=Solution causes Sentinel API rejection in cross-RG nested deploys'
        @($inner | Where-Object { $_.type -match 'dataConnectors$' -and $_.kind -eq 'GenericUI' }).Count                           | Should -BeGreaterOrEqual 1 -Because 'GenericUI is the canonical kind for community FA-based connectors per Trend Micro reference'
        @($inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'DataConnector' }).Count                  | Should -BeGreaterOrEqual 1
    }

    It 'dataConnector apiVersion is 2021-03-01-preview (canonical FA-community version per Trend Micro reference)' {
        # Trend Micro Vision One — the production reference for FA-push community
        # connectors that surface in Sentinel → Data Connectors after direct ARM
        # deploy — uses 2021-03-01-preview. Newer 2023-04-01-preview is documented
        # for first-party MS solutions; mixing it with a non-MS publisher caused
        # iter 11 connector card to stay hidden.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $dc    = $inner | Where-Object { $_.type -match 'dataConnectors$' } | Select-Object -First 1
        $dc.apiVersion | Should -Be '2021-03-01-preview' -Because 'Trend Micro reference uses this apiVersion for FA-community connectors'
    }

    It 'dataConnector metadata.parentId uses extensionResourceId() form (Sentinel UI indexer chains correctly)' {
        # The hierarchical resourceId() form
        # ('Microsoft.OperationalInsights/workspaces/providers/dataConnectors')
        # produces a different canonical resource ID string than the extension
        # form ('Microsoft.SecurityInsights/dataConnectors'). The Sentinel UI
        # blade indexer expects the latter when chaining metadata back-links.
        $inner = @($script:SolutionDeploy.properties.template.resources)
        $meta  = $inner | Where-Object { $_.type -match 'metadata$' -and $_.properties.kind -eq 'DataConnector' } | Select-Object -First 1
        $meta.properties.parentId | Should -Match 'extensionResourceId\('                              -Because 'Trend Micro reference uses extensionResourceId, not hierarchical resourceId'
        $meta.properties.parentId | Should -Match "Microsoft\.SecurityInsights/dataConnectors"          -Because 'extension form targets Microsoft.SecurityInsights/dataConnectors, not OI workspaces/providers/dataConnectors'
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

    It 'GenericUI dataConnector has connectivityCriterias (Sentinel uses this for Connected status)' {
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

    It '5 DCRs partition 47 streams 4x10 + 1x7 (canonical Microsoft Learn shape)' {
        # 47 streams > 10-flow-per-DCR cap → split across 5 DCRs sharing 1 DCE.
        # Each DCR's dataFlows array has one flow per stream with explicit
        # outputStream + transformKql='source' (Microsoft Learn
        # data-collection-rule-structure canonical pattern).
        # 47 = 46 data + 1 operational (Heartbeat). AuthTestResult retired in
        # v0.1.0-beta first publish (auth chain → App Insights customEvents).
        @($script:Dcrs).Count | Should -Be 5 -Because '47 streams > 10-flow cap per DCR; canonical split is 5 DCRs sharing 1 DCE'
        $declCounts = @()
        $allStreams = @()
        foreach ($dcr in $script:Dcrs) {
            $declCount = @($dcr.properties.streamDeclarations.PSObject.Properties.Name).Count
            $declCounts += $declCount
            foreach ($df in $dcr.properties.dataFlows) {
                $allStreams += @($df.streams)
            }
        }
        $sortedCounts = @($declCounts | Sort-Object)
        $sortedCounts | Should -Be @(7, 10, 10, 10, 10) -Because 'partition 4x10 + 1x7 (alphabetical, see deploy/modules/dce-dcr.bicep)'
        @($allStreams | Sort-Object -Unique).Count | Should -Be 47 -Because 'every declared stream must appear in exactly one dataFlow'
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

    It 'every dataFlow has outputStream set to its single stream (Microsoft Learn canonical shape)' {
        # 5-DCR shape: every dataFlow is single-stream with explicit
        # outputStream='Custom-X' + transformKql='source'. Azure rejects
        # multi-stream dataFlows that lack outputStream with InvalidTransformOutput.
        # See deploy/modules/dce-dcr.bicep + tests/arm/DcrShape.Tests.ps1.
        foreach ($dcr in $script:Dcrs) {
            for ($i = 0; $i -lt @($dcr.properties.dataFlows).Count; $i++) {
                $df = $dcr.properties.dataFlows[$i]
                @($df.streams).Count | Should -Be 1 -Because 'canonical pattern is single-stream per dataFlow'
                $df.PSObject.Properties['outputStream'] | Should -Not -BeNullOrEmpty -Because 'outputStream MUST be set to avoid InvalidTransformOutput'
                $df.outputStream | Should -Be $df.streams[0] -Because 'outputStream must match the single stream'
                $df.transformKql | Should -Be 'source' -Because 'identity transform per Microsoft canonical sample'
            }
        }
    }
}

Describe 'DCR streams — completeness' {
    BeforeAll {
        # Source = compiled mainTemplate.json (Bicep was archived to
        # .internal/bicep-reference/ in v0.1.0-beta — ARM is the single
        # source of truth). Stream declarations live inside each
        # Microsoft.Insights/dataCollectionRules resource under
        # `properties.streamDeclarations.<key>`.
        $script:RawTemplate = Get-Content $script:MainTemplatePath -Raw
        $tpl = $script:RawTemplate | ConvertFrom-Json
        $dcrs = @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
        $script:DcrStreamKeys = @()
        foreach ($dcr in $dcrs) {
            $sd = $dcr.properties.streamDeclarations
            if ($null -ne $sd) {
                foreach ($k in $sd.PSObject.Properties.Name) {
                    $script:DcrStreamKeys += $k
                }
            }
        }
        $script:DcrStreamKeys = $script:DcrStreamKeys | Sort-Object -Unique
    }

    It 'DCR includes 46 MDE_*_CL data stream declarations + 1 operational table' {
        # 46 active+deprecated data streams + 1 operational (Heartbeat). The
        # legacy MDE_AuthTestResult_CL stream was retired in v0.1.0-beta first
        # publish — auth chain diagnostics moved to App Insights customEvents
        # (AuthChain.* event names) instead of a dedicated workspace table.
        $mdeStreams = $script:DcrStreamKeys | Where-Object { $_ -match '^Custom-MDE_\w+_CL$' }
        @($mdeStreams).Count | Should -BeGreaterOrEqual 47 -Because '46 data streams + Heartbeat = 47 total stream declarations'
    }

    It 'DCR has NO dropped streams (v1.0.0 P4 + v1.0.2 + v0.1.0-beta.1 removals)' {
        # Negative gate: scan the raw ARM JSON for any reference (column or key)
        # to a known-removed stream. Source is the same compiled template above.
        # v1.0.0 early drops
        $script:RawTemplate | Should -Not -Match 'MDE_AirDecisions'
        $script:RawTemplate | Should -Not -Match 'MDE_InvestigationPackage'
        # v1.0.2 NO_PUBLIC_API removals
        $script:RawTemplate | Should -Not -Match 'MDE_AsrRulesConfig_CL'
        $script:RawTemplate | Should -Not -Match 'MDE_AntiRansomwareConfig_CL'
        $script:RawTemplate | Should -Not -Match 'MDE_ControlledFolderAccess_CL'
        $script:RawTemplate | Should -Not -Match 'MDE_NetworkProtectionConfig_CL'
        $script:RawTemplate | Should -Not -Match 'MDE_ApprovalAssignments_CL'
        # v0.1.0-beta.1 write-endpoint removals
        $script:RawTemplate | Should -Not -Match 'MDE_CriticalAssets_CL'
        $script:RawTemplate | Should -Not -Match 'MDE_DeviceCriticality_CL'
    }
}
