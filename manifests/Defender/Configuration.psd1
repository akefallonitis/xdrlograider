# manifests/Defender/Configuration.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'Configuration'
    Operations = @(
@{
            OperationKey = 'GetAssetRules'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/ndr/rulesengine/rules'
            ResponseShape = 'wrapper'
            ItemsContainer = 'rules'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                actionsJson = '$.actions'
                affectedAssetsCount = '$.affectedAssetsCount'
                assetType = '$.assetType'
                classificationValue = '$.classificationValue'
                CreatedBy = '$.createdBy'
                createdByName = '$.createdByName'
                CreationTime = '$.creationTime'
                criticalityLevel = '$.criticalityLevel'
                IsDeleted = '$.isDeleted'
                isDisabled = '$.isDisabled'
                kqlQuery = '$.kqlQuery'
                lastExecutionTime = '$.lastExecutionTime'
                lastUpdatedBy = '$.lastUpdatedBy'
                lastUpdatedByName = '$.lastUpdatedByName'
                LastUpdateTime = '$.lastUpdateTime'
                OrgId = '$.orgId'
                ruleDefinition = '$.ruleDefinition'
                ruleDescription = '$.ruleDescription'
                ruleId = '$.ruleId'
                ruleName = '$.ruleName'
                RuleType = '$.ruleType'
                tenantId_x = '$.tenantId'
                timestamp = '$.timestamp'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetAssetRules'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetAssetRules'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                affectedAssetsCount = 'long'
                CreationTime = 'datetime'
                criticalityLevel = 'long'
                IsDeleted = 'boolean'
                isDisabled = 'boolean'
                lastExecutionTime = 'datetime'
                LastUpdateTime = 'datetime'
                timestamp = 'datetime'
            }
        },
@{
            OperationKey = 'ListThreatIndicators'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/responseApiPortal/ti/indicators'
            ResponseShape = 'bareArray'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                Action = '$.Action'
                Application = '$.Application'
                Category_x = '$.Category'
                CreatedBy = '$.CreatedBy'
                CreatedByDisplayName = '$.CreatedByDisplayName'
                CreatedBySource = '$.CreatedBySource'
                CreationTime = '$.CreationTime'
                Description = '$.Description'
                EducateUrl = '$.EducateUrl'
                GenerateAlert = '$.GenerateAlert'
                IndicatorId = '$.IndicatorId'
                IndicatorType = '$.IndicatorType'
                IndicatorValue = '$.IndicatorValue'
                IoaDefinitionId = '$.IoaDefinitionId'
                IsEnabled = '$.IsEnabled'
                LastUpdateTime = '$.LastUpdateTime'
                OrgId = '$.OrgId'
                Severity = '$.Severity'
                Title_x = '$.Title'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListThreatIndicators'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListThreatIndicators'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                Action = 'long'
                CreationTime = 'datetime'
                IsEnabled = 'boolean'
                LastUpdateTime = 'datetime'
            }
        },
@{
            OperationKey = 'ListWebCategoryPolicies'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/responseApiPortal/webcategory/policies'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                auditCategoryIdsJson = '$.auditCategoryIds'
                blockedCategoryIdsJson = '$.blockedCategoryIds'
                Id = '$.id'
                Name = '$.name'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListWebCategoryPolicies'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListWebCategoryPolicies'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetMdcPreviewFeatures'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mdc'
            Path = '/management/optin'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDC')
            ProjectionMap = @{
                isOptIn = '$.isOptIn'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetMdcPreviewFeatures'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetMdcPreviewFeatures'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isOptIn = 'boolean'
            }
        },
@{
            OperationKey = 'GetMcasPreviewFeatures'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/preview_features/get'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MCAS')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetMcasPreviewFeatures'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetMcasPreviewFeatures'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetDataExportSettings'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/wdatpApi/dataexportsettings'
            ResponseShape = 'wrapper'
            ItemsContainer = 'value'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                designatedTenantId = '$.designatedTenantId'
                eventHubProperties = '$.eventHubProperties'
                Id = '$.id'
                logsJson = '$.logs'
                storageAccountProperties = '$.storageAccountProperties'
                workspacePropertiesJson = '$.workspaceProperties'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetDataExportSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetDataExportSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListCriticalAssetClassifications'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/xspmatlas/assetrules'
            ResponseShape = 'wrapper'
            ItemsContainer = 'rules'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                actionsJson = '$.actions'
                affectedAssetsCount = '$.affectedAssetsCount'
                assetType = '$.assetType'
                classificationValue = '$.classificationValue'
                CreatedBy = '$.createdBy'
                createdByName = '$.createdByName'
                CreationTime = '$.creationTime'
                criticalityLevel = '$.criticalityLevel'
                IsDeleted = '$.isDeleted'
                isDisabled = '$.isDisabled'
                kqlQuery = '$.kqlQuery'
                lastExecutionTime = '$.lastExecutionTime'
                lastUpdatedBy = '$.lastUpdatedBy'
                lastUpdatedByName = '$.lastUpdatedByName'
                LastUpdateTime = '$.lastUpdateTime'
                OrgId = '$.orgId'
                ruleDefinitionJson = '$.ruleDefinition'
                ruleDescription = '$.ruleDescription'
                ruleId = '$.ruleId'
                ruleName = '$.ruleName'
                RuleType = '$.ruleType'
                tenantId_x = '$.tenantId'
                timestamp = '$.timestamp'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListCriticalAssetClassifications'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListCriticalAssetClassifications'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            VolatileHashFields = @('timestamp', 'lastExecutionTime')
            ColumnTypes = @{
                affectedAssetsCount = 'long'
                CreationTime = 'datetime'
                criticalityLevel = 'long'
                IsDeleted = 'boolean'
                isDisabled = 'boolean'
                lastExecutionTime = 'datetime'
                LastUpdateTime = 'datetime'
                timestamp = 'datetime'
            }
        },
@{
            OperationKey = 'ListConnectedApps'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/responseApiPortal/apps/all'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                ApplicationSettingsLink = '$.ApplicationSettingsLink'
                DisplayName = '$.DisplayName'
                Enabled = '$.Enabled'
                Id = '$.Id'
                ImageBase64 = '$.ImageBase64'
                ImageType = '$.ImageType'
                ImageUrl = '$.ImageUrl'
                LatestConnectivity = '$.LatestConnectivity'
                MonthlyStatisticsJson = '$.MonthlyStatistics'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListConnectedApps'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListConnectedApps'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                Enabled = 'boolean'
                LatestConnectivity = 'datetime'
            }
        },
@{
            OperationKey = 'GetDisabledAlertServices'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/alertsApiService/workloads/disabled'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetDisabledAlertServices'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetDisabledAlertServices'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListUnifiedConnectors'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/unifiedConnectors/public/connectors'
            ResponseShape = 'bareArray'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                changeDetails = '$.changeDetails'
                Description = '$.description'
                DisplayName = '$.displayName'
                Id = '$.id'
                instancesJson = '$.instances'
                instanceSchemaJson = '$.instanceSchema'
                instancesCount = '$.instancesCount'
                isMultiInstancesSupported = '$.isMultiInstancesSupported'
                isStatic = '$.isStatic'
                kind_x = '$.kind'
                operations = '$.operations'
                prerequisitesJson = '$.prerequisites'
                providerJson = '$.provider'
                requiredPermissionsJson = '$.requiredPermissions'
                statusJson = '$.status'
                supportedByJson = '$.supportedBy'
                supportedCredentialsKindsJson = '$.supportedCredentialsKinds'
                supportedProtectionTypesJson = '$.supportedProtectionTypes'
                tenantId_x = '$.tenantId'
                uiDefinitionJson = '$.uiDefinition'
                version = '$.version'
                versionChangeLogJson = '$.versionChangeLog'
                versionStage = '$.versionStage'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListUnifiedConnectors'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListUnifiedConnectors'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                instancesCount = 'long'
                isMultiInstancesSupported = 'boolean'
                isStatic = 'boolean'
            }
        },
@{
            OperationKey = 'GetGlobalIdentityDisruptionExclusion'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/disrupt/api/exclusions/Identity/global-exclusion'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetGlobalIdentityDisruptionExclusion'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetGlobalIdentityDisruptionExclusion'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListSuppressionRules'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/suppressionRulesService/suppressionRules'
            ResponseShape = 'bareArray'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                Action = '$.Action'
                ActivationDate = '$.ActivationDate'
                AdditionalDetails = '$.AdditionalDetails'
                AlertTitle = '$.AlertTitle'
                BitwiseServiceSources = '$.BitwiseServiceSources'
                ComputerDnsName = '$.ComputerDnsName'
                CreatedBy = '$.CreatedBy'
                CreationTime = '$.CreationTime'
                Description = '$.Description'
                DeserializedRbacGroupIds = '$.DeserializedRbacGroupIds'
                DeserializedScopeConditionsJson = '$.DeserializedScopeConditions'
                FullDeserializedRbacGroupIds = '$.FullDeserializedRbacGroupIds'
                Id = '$.Id'
                IoaDefinitionId = '$.IoaDefinitionId'
                IsEnabled = '$.IsEnabled'
                IsInOptOutPeriod = '$.IsInOptOutPeriod'
                IsReadOnly = '$.IsReadOnly'
                IsSilent = '$.IsSilent'
                IsTestRule = '$.IsTestRule'
                LastActivity = '$.LastActivity'
                MatchingAlertsCount = '$.MatchingAlertsCount'
                OrderIndex = '$.OrderIndex'
                RbacGroupIds = '$.RbacGroupIds'
                RuleConditions = '$.RuleConditions'
                RuleSource = '$.RuleSource'
                RuleTitle = '$.RuleTitle'
                RuleType = '$.RuleType'
                Scope = '$.Scope'
                ScopeConditions = '$.ScopeConditions'
                SenseMachineId = '$.SenseMachineId'
                ThreatFamilyName = '$.ThreatFamilyName'
                UpdateTime = '$.UpdateTime'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListSuppressionRules'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListSuppressionRules'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                Action = 'long'
                ActivationDate = 'datetime'
                BitwiseServiceSources = 'long'
                CreationTime = 'datetime'
                IsEnabled = 'boolean'
                IsInOptOutPeriod = 'boolean'
                IsReadOnly = 'boolean'
                IsSilent = 'boolean'
                IsTestRule = 'boolean'
                MatchingAlertsCount = 'long'
                OrderIndex = 'long'
                RuleSource = 'long'
                Scope = 'long'
                UpdateTime = 'datetime'
            }
        },
@{
            OperationKey = 'GetAutoIrProperties'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/autoIr/ui/properties'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                AutomatedIrPuaAsSuspicious = '$.AutomatedIrPuaAsSuspicious'
                IsAutomatedIrContainDeviceEnabled = '$.IsAutomatedIrContainDeviceEnabled'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetAutoIrProperties'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetAutoIrProperties'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AutomatedIrPuaAsSuspicious = 'boolean'
                IsAutomatedIrContainDeviceEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetSentinelOnboardedState'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/sentinelOnboarding/sentinel/workspaces/isOnboarded'
            ResponseShape = 'scalar'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                Value = '$'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetSentinelOnboardedState'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetSentinelOnboardedState'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetTopWebContentFilteringCategories'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/webThreatProtection/WebContentFiltering/Reports/TopParentCategories'
            ResponseShape = 'wrapper'
            ItemsContainer = 'TopParentCategories'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                ActivityDeltaPercentage = '$.ActivityDeltaPercentage'
                IsDeltaPercentageValid = '$.IsDeltaPercentageValid'
                Name = '$.Name'
                TotalAccessRequests = '$.TotalAccessRequests'
                TotalBlockedCount = '$.TotalBlockedCount'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetTopWebContentFilteringCategories'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetTopWebContentFilteringCategories'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                ActivityDeltaPercentage = 'long'
                IsDeltaPercentageValid = 'boolean'
                TotalAccessRequests = 'long'
                TotalBlockedCount = 'long'
            }
        },
@{
            OperationKey = 'GetIntuneOnboardingStatus'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/responseApiPortal/onboarding/intune/status'
            ResponseShape = 'scalar'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                Value = '$'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetIntuneOnboardingStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetIntuneOnboardingStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListIncidentNotificationSettings'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/papin/api/cloud/public/internal/IncidentNotificationSettingsV2'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                AlertSeverities = '$.AlertSeverities'
                AllRbacGroups = '$.AllRbacGroups'
                CreatedBy = '$.CreatedBy'
                CreationTime = '$.CreationTime'
                Description = '$.Description'
                FormatOptions = '$.FormatOptions'
                IncidentNotificationsSettingId = '$.IncidentNotificationsSettingId'
                IsReadOnly = '$.IsReadOnly'
                LastUpdateTime = '$.LastUpdateTime'
                Name = '$.Name'
                RbacGroupIdsJson = '$.RbacGroupIds'
                RecipientsJson = '$.Recipients'
                RulesJson = '$.Rules'
                RulesReadOnly = '$.RulesReadOnly'
                ScopesJson = '$.Scopes'
                SendOncePerIncident = '$.SendOncePerIncident'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.ListIncidentNotificationSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.ListIncidentNotificationSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AlertSeverities = 'long'
                AllRbacGroups = 'boolean'
                CreationTime = 'datetime'
                FormatOptions = 'long'
                IncidentNotificationsSettingId = 'long'
                IsReadOnly = 'boolean'
                LastUpdateTime = 'datetime'
                RulesReadOnly = 'boolean'
                SendOncePerIncident = 'boolean'
            }
        },
@{
            OperationKey = 'GetUserSettings'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/settings/GetUserSettings'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                CommunicationsAndMedia = '$.CommunicationsAndMedia'
                FinancialServices = '$.FinancialServices'
                GeoRegion = '$.GeoRegion'
                ManufacturingAndResources = '$.ManufacturingAndResources'
                MaxEndpoints = '$.MaxEndpoints'
                MinEndpoints = '$.MinEndpoints'
                PublicSector = '$.PublicSector'
                RetailConsumerProductsAndService = '$.RetailConsumerProductsAndService'
                RetentionPolicy = '$.RetentionPolicy'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetUserSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetUserSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                MaxEndpoints = 'long'
                MinEndpoints = 'long'
                RetentionPolicy = 'long'
            }
        },
@{
            OperationKey = 'GetUnifiedRbacWorkload'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/urbacConfiguration/gw/unifiedrbac/configuration/tenantinfo'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetUnifiedRbacWorkload'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetUnifiedRbacWorkload'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAlertSharingStatus'
            Subcategory = 'Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/wdatpInternalApi/compliance/alertSharing/status'
            ResponseShape = 'scalar'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                Value = '$'
            }
            DcrStreamName = 'Custom-Defender_Configuration_CL'
            WorkspaceTable = 'Defender_Configuration_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CONFIGURATION'
            Provenance = @{
                OperationId = 'Configuration.GetAlertSharingStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/configuration.yml#Configuration.GetAlertSharingStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
