#Requires -Module Pester
# Locks the contracts between deploy/createUiDefinition.json + deploy/mainTemplate.json
# (operator wizard must map 1:1 to ARM parameters) and the module-load integrity of
# profile.ps1 against the bundled FA zip layout.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Arm      = Get-Content (Join-Path $script:RepoRoot 'deploy\mainTemplate.json') -Raw | ConvertFrom-Json
    $script:Ui       = Get-Content (Join-Path $script:RepoRoot 'deploy\createUiDefinition.json') -Raw | ConvertFrom-Json
}

Describe 'createUiDefinition to mainTemplate parameter alignment' -Tag 'deploy-shape' {

    It 'every UI output maps to a mainTemplate parameter (no orphan outputs)' {
        $armParams = @($script:Arm.parameters.PSObject.Properties.Name)
        $uiOutputs = @($script:Ui.parameters.outputs.PSObject.Properties.Name)
        # 'location' is an ARM standard supplied by the portal; not declared explicitly
        $missing = $uiOutputs | Where-Object { $_ -ne 'location' -and $_ -notin $armParams }
        $missing | Should -BeNullOrEmpty -Because "UI output(s) [$($missing -join ', ')] have no corresponding ARM parameter"
    }

    It 'every required (no-default) ARM parameter is supplied by the UI' {
        $uiOutputs = @($script:Ui.parameters.outputs.PSObject.Properties.Name)
        $armParams = $script:Arm.parameters.PSObject.Properties
        $missing = foreach ($p in $armParams) {
            if (-not ($p.Value.PSObject.Properties.Name -contains 'defaultValue') -and $p.Name -notin $uiOutputs) {
                $p.Name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "Required ARM parameter(s) [$($missing -join ', ')] have no UI input"
    }

    It 'all secure parameters in ARM correspond to UI PasswordBox inputs (no plain TextBox for secrets)' {
        $secureArmParams = $script:Arm.parameters.PSObject.Properties |
            Where-Object { $_.Value.type -eq 'securestring' } | ForEach-Object Name
        $passwordSteps = @()
        foreach ($step in $script:Ui.parameters.steps) {
            foreach ($el in $step.elements) {
                if ($el.type -eq 'Microsoft.Common.PasswordBox') { $passwordSteps += $el.name }
            }
        }
        # Map ARM secureParam <-> UI output element (output value '[steps(x).element]')
        foreach ($secure in $secureArmParams) {
            $uiOutputValue = $script:Ui.parameters.outputs.$secure
            $uiOutputValue | Should -Match 'steps\(' -Because "secure ARM param '$secure' must be sourced from a steps() expression, not a basics() TextBox"
            $elementName = if ($uiOutputValue -match "steps\([^)]+\)\.(\w+)") { $Matches[1] } else { $null }
            $elementName | Should -BeIn $passwordSteps -Because "secure ARM param '$secure' is bound to UI element '$elementName' which is NOT a PasswordBox"
        }
    }
}

Describe 'mainTemplate.json invariants' -Tag 'deploy-shape' {

    It 'φ.B · has 2 DCR resources (1 health DCR + 1 per-sub-area copy block · 1+19=20 DCRs at deploy)' {
        # ARM declarations: 2 resources entries · the second uses copy to spawn 19
        $dcrResources = @($script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
        $dcrResources.Count | Should -Be 2 -Because 'Plan §3 P6 · 1 health DCR + 1 copy-block producing 19 per-sub-area DCRs'
        # The second resource MUST have copy block with count=length(defenderSubAreas)
        $copyDcr = $dcrResources | Where-Object { $_.PSObject.Properties['copy'] -and $_.copy }
        $copyDcr | Should -Not -BeNullOrEmpty -Because 'per-sub-area DCR must be ARM copy block'
        ([string]$copyDcr.copy.count) | Should -Match 'defenderSubAreas' -Because 'copy count must reference defenderSubAreas variable'
    }

    It 'φ.B · defenderSubAreas variable has 19 sub-areas matching manifest' {
        $subAreas = @($script:Arm.variables.defenderSubAreas)
        $subAreas.Count | Should -Be 19 -Because 'Plan §3 sub-area inventory · 19 nodoc YAMLs'
        # All 5 operator-flagged categories must be present in the right sub-area
        $subAreas | Should -Contain 'ExposureManagement'   # ASR lives here
        $subAreas | Should -Contain 'Configuration'        # SuppressionRules lives here
        $subAreas | Should -Contain 'EndpointDevices'      # DeviceTimeline lives here
        $subAreas | Should -Contain 'EndpointConfiguration' # CustomCollectionRules lives here
        $subAreas | Should -Contain 'CloudApps'             # largest sub-area
    }

    It 'φ.B · health DCR declares Custom-XdrConnectorHealth_CL stream' {
        $healthDcr = $script:Arm.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and -not $_.PSObject.Properties['copy'] }
        @($healthDcr.properties.streamDeclarations.PSObject.Properties.Name) | Should -Contain 'Custom-XdrConnectorHealth_CL'
    }

    It 'φ.B · per-sub-area DCRs use parametric stream name Custom-Defender_(SubArea)_CL via copyIndex' {
        $copyDcr = $script:Arm.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and $_.PSObject.Properties['copy'] }
        $streamDecl = $copyDcr.properties.streamDeclarations
        # The stream key is an ARM expression like [concat('Custom-Defender_', variables('defenderSubAreas')[copyIndex()], '_CL')]
        $streamKeys = @($streamDecl.PSObject.Properties.Name)
        $streamKeys.Count | Should -Be 1 -Because 'each per-sub-area DCR has exactly 1 stream'
        $streamKeys[0] | Should -Match 'defenderSubAreas' -Because 'stream name must be built from defenderSubAreas variable'
        $streamKeys[0] | Should -Match 'Custom-Defender_' -Because 'must produce Custom-Defender_<SubArea>_CL'
    }

    It 'φ.B · per-sub-area DCRs declare ProjectionMap+RawJson columns (R-A schema · via defenderRowSchema variable)' {
        $copyDcr = $script:Arm.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and $_.PSObject.Properties['copy'] }
        # Inspect defenderRowSchema variable (the SHARED schema referenced by all 19 stream decls)
        $rowSchema = @($script:Arm.variables.defenderRowSchema)
        $colNames = @($rowSchema.name)
        $colNames | Should -Contain 'ProjectedData'    # R-A primary
        $colNames | Should -Contain 'RawJson'          # R-A companion
        $colNames | Should -Contain 'Portal'
        $colNames | Should -Contain 'IngestionMode'
        $colNames | Should -Contain 'SubArea'          # always Defender for v0.1.0
        $colNames | Should -Contain 'Slug'
    }

    It 'φ.B · health DCR Custom-XdrConnectorHealth_CL stream declares Reinforcement-B/C columns' {
        $healthDcr = $script:Arm.resources |
            Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and -not $_.PSObject.Properties['copy'] }
        $cols = @($healthDcr.properties.streamDeclarations.'Custom-XdrConnectorHealth_CL'.columns.name)
        $cols | Should -Contain 'ReauthCount'
        $cols | Should -Contain 'SkippedThisCycle'
        $cols | Should -Contain 'Capabilities'
        $cols | Should -Contain 'Portal'
        $cols | Should -Contain 'CircuitOpen'
        # Π11.4g · OpenCircuits surfaces open sub-areas in heartbeat row (operator visibility · no AI grep)
        $cols | Should -Contain 'OpenCircuits'
    }

    It 'ARM provisions 4 Storage Tables (XdrCheckpoint + XdrIngestDlq + XdrTierState + XdrTenantCapabilities)' {
        $tables = @($script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/tableServices/tables' })
        # Names are ARM-template expressions like "[concat(variables('storageName'), '/default/XdrCheckpoint')]"
        # — extract the literal trailing table identifier via regex
        $names  = $tables | ForEach-Object {
            if ($_.name -match "/(\w+)'\)\]?$") { $Matches[1] } else { ($_.name -split '/')[-1] }
        }
        $names | Should -Contain 'XdrCheckpoint'
        $names | Should -Contain 'XdrIngestDlq'
        $names | Should -Contain 'XdrTierState'
        $names | Should -Contain 'XdrTenantCapabilities'
    }

    It 'FA appSettings expose DCE_ENDPOINT + DCR_IMMUTABLE_ID + DCR_IMMUTABLE_ID_MAP + KEYVAULT_NAME + MANIFEST_PATH' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' }
        $names = @($fa.properties.siteConfig.appSettings | ForEach-Object Name)
        $names | Should -Contain 'DCE_ENDPOINT'
        $names | Should -Contain 'DCR_IMMUTABLE_ID'        # health DCR (kept for backwards compat · used for heartbeats)
        $names | Should -Contain 'DCR_IMMUTABLE_ID_MAP'    # φ.B · per-sub-area map (JSON array · stream router reads this)
        $names | Should -Contain 'KEYVAULT_NAME'
        $names | Should -Contain 'MANIFEST_PATH'
        $names | Should -Contain 'CONNECTOR_VERSION'
        $names | Should -Contain 'WEBSITE_RUN_FROM_PACKAGE'
    }

    It 'FA has SystemAssigned identity (SAMI required for KV + DCR)' {
        $fa = $script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' }
        $fa.identity.type | Should -Be 'SystemAssigned'
    }

    It 'packageUrl auto-latest · uses releases/latest/download/ when releaseTag=latest · D-2026-05-18k · φ.1' {
        # FA WEBSITE_RUN_FROM_PACKAGE must auto-pull newest release on cold-restart when operator
        # leaves releaseTag at default 'latest'. GitHub provides /releases/latest/download/<asset>
        # as an auto-redirect URL to the most recent release · /releases/download/latest/<asset>
        # is a literal path that 404s. ARM if() conditional switches based on releaseTag value.
        $packageUrlExpr = [string]$script:Arm.variables.packageUrl
        $packageUrlExpr | Should -Not -BeNullOrEmpty
        $packageUrlExpr | Should -Match "if\(equals\(parameters\('releaseTag'\)" -Because 'must use if/equals conditional on releaseTag'
        $packageUrlExpr | Should -Match 'releases/latest/download/' -Because "must include GitHub auto-latest URL branch (when releaseTag='latest')"
        $packageUrlExpr | Should -Match "releases/download/'" -Because 'must include tag-pinned URL branch for reproducible deploys'
        $packageUrlExpr | Should -Match 'function-app\.zip' -Because 'must terminate in the FA zip asset name'
    }

    It 'has 6 role-assignment resource declarations (KV Secrets User + MMP-health + MMP-perSubArea-copy + Storage Table Data Contributor + Π11 Storage Blob Data Owner + Storage Queue Data Contributor for identity-based AzureWebJobsStorage), gated by deployRoleAssignments param' {
        $ras = @($script:Arm.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        # φ.B · 4 + Π11 NOD-1 · 2 new (Storage Blob Data Owner + Storage Queue Data Contributor for identity-based AzureWebJobsStorage)
        $ras.Count | Should -Be 6
        $ras | ForEach-Object { $_.condition | Should -Be "[parameters('deployRoleAssignments')]" }
        # HB-1 (Phase ε.A): Storage Table Data Contributor on storage account
        $storageRole = $ras | Where-Object { ($_.scope -match "Microsoft.Storage/storageAccounts") -and ($_.properties.roleDefinitionId -match 'storageTableDataContributorRoleId') }
        $storageRole | Should -Not -BeNullOrEmpty
        $script:Arm.variables.storageTableDataContributorRoleId | Should -Be '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
        # Π11 NOD-1 · Storage Blob Data Owner (for AzureWebJobsStorage__credential=managedidentity)
        $blobRole = $ras | Where-Object { $_.properties.roleDefinitionId -match 'storageBlobDataOwnerRoleId' }
        $blobRole | Should -Not -BeNullOrEmpty -Because 'Π11 NOD-1 · identity-based AzureWebJobsStorage requires Storage Blob Data Owner on SA'
        $script:Arm.variables.storageBlobDataOwnerRoleId | Should -Be 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
        # Π11 NOD-1 · Storage Queue Data Contributor (for AzureWebJobsStorage durable queues)
        $queueRole = $ras | Where-Object { $_.properties.roleDefinitionId -match 'storageQueueDataContributorRoleId' }
        $queueRole | Should -Not -BeNullOrEmpty -Because 'Π11 NOD-1 · identity-based AzureWebJobsStorage requires Storage Queue Data Contributor on SA'
        $script:Arm.variables.storageQueueDataContributorRoleId | Should -Be '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
        # φ.B · MMP role assignment via copy for per-sub-area DCRs
        $mmpCopy = $ras | Where-Object { $_.PSObject.Properties['copy'] -and $_.copy }
        $mmpCopy | Should -Not -BeNullOrEmpty -Because 'φ.B · MMP role on 19 per-sub-area DCRs via ARM copy loop'
        ([string]$mmpCopy.copy.count) | Should -Match 'defenderSubAreas'
    }
}

Describe 'profile.ps1 module load integrity against bundled layout' -Tag 'fa-cold-start' {

    BeforeAll {
        $script:ProfilePath = Join-Path $script:RepoRoot 'src\profile.ps1'
        $script:ProfileText = Get-Content $script:ProfilePath -Raw
    }

    It 'imports all 5 Xdr.* modules and only those (Common.Telemetry + Auth + Poll + Ingest + Parser)' {
        # Extract the foreach module list literal
        $m = [regex]::Match($script:ProfileText, "foreach\s*\(\s*\`$name\s+in\s+([^)]+)\)")
        $m.Success | Should -BeTrue
        $imported = $m.Groups[1].Value -replace "[\'\`"]", '' -split ',' | ForEach-Object { $_.Trim() }
        $imported | Should -Contain 'Xdr.Common.Telemetry'
        $imported | Should -Contain 'Xdr.Auth'
        $imported | Should -Contain 'Xdr.Poll'
        $imported | Should -Contain 'Xdr.Ingest'
        $imported | Should -Contain 'Xdr.Parser'
        @($imported).Count | Should -Be 5
    }

    It 'looks for modules under Modules folder name name.psd1 path (matches FA zip layout)' {
        $script:ProfileText | Should -Match 'Modules' -Because 'profile.ps1 must reference the Modules/ dir'
        $script:ProfileText | Should -Match '\$name\.psd1'
    }

    It 'retries Connect-AzAccount on transient IMDS failure (cold-start safety)' {
        $script:ProfileText | Should -Match '\$i\s+-le\s+3'
    }
}
