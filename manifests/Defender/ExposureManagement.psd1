# manifests/Defender/ExposureManagement.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'ExposureManagement'
    Operations = @(
@{
            OperationKey = 'MachineSecurityStates'
            Subcategory = 'Attack Surface Reduction'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/tvm/analytics/asrconfiguration/MachineSecurityStates'
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
                asrConfigurationStatesJson = '$.asrConfigurationStates'
                id = '$.id'
                machineName = '$.machineName'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'Asr.MachineSecurityStates'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = $null
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetIdentitySecureScoreMetric'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/metrics/category_identity_secure_score'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                category_x = '$.category'
                dataHistoryJson = '$.dataHistory'
                dataTypesJson = '$.dataTypes'
                description = '$.description'
                hasNoAssets = '$.hasNoAssets'
                hasNoDataHistory = '$.hasNoDataHistory'
                id = '$.id'
                initiativeScoreImpact = '$.initiativeScoreImpact'
                latestCalculatedScoreImpact = '$.latestCalculatedScoreImpact'
                latestCalculatedWeight = '$.latestCalculatedWeight'
                latestCalculationId = '$.latestCalculationId'
                latestCount = '$.latestCount'
                latestScore = '$.latestScore'
                latestTotal = '$.latestTotal'
                latestValue = '$.latestValue'
                name = '$.name'
                recommendationsJson = '$.recommendations'
                recommendationsV2Json = '$.recommendationsV2'
                sentimentType = '$.sentimentType'
                state = '$.state'
                suggestionsJson = '$.suggestions'
                supportGetAssets = '$.supportGetAssets'
                targetValue = '$.targetValue'
                version = '$.version'
                weight = '$.weight'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetIdentitySecureScoreMetric'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetIdentitySecureScoreMetric'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                hasNoAssets = 'boolean'
                hasNoDataHistory = 'boolean'
                initiativeScoreImpact = 'real'
                latestCalculatedScoreImpact = 'real'
                latestCalculatedWeight = 'real'
                latestCount = 'real'
                latestScore = 'real'
                latestTotal = 'real'
                latestValue = 'real'
                supportGetAssets = 'boolean'
                targetValue = 'real'
                version = 'real'
                weight = 'real'
            }
        },
@{
            OperationKey = 'GetRecommendations'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/exposureManagement/recommendations'
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
                totalCount = '$.totalCount'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetRecommendations'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetRecommendations'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetDataSecureScoreMetric'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/metrics/category_data_secure_score'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                category_x = '$.category'
                dataHistoryJson = '$.dataHistory'
                dataTypesJson = '$.dataTypes'
                description = '$.description'
                hasNoAssets = '$.hasNoAssets'
                hasNoDataHistory = '$.hasNoDataHistory'
                id = '$.id'
                initiativeScoreImpact = '$.initiativeScoreImpact'
                latestCalculatedScoreImpact = '$.latestCalculatedScoreImpact'
                latestCalculatedWeight = '$.latestCalculatedWeight'
                latestCalculationId = '$.latestCalculationId'
                latestCount = '$.latestCount'
                latestScore = '$.latestScore'
                latestTotal = '$.latestTotal'
                latestValue = '$.latestValue'
                name = '$.name'
                recommendationsJson = '$.recommendations'
                recommendationsV2Json = '$.recommendationsV2'
                sentimentType = '$.sentimentType'
                state = '$.state'
                suggestionsJson = '$.suggestions'
                supportGetAssets = '$.supportGetAssets'
                targetValue = '$.targetValue'
                version = '$.version'
                weight = '$.weight'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetDataSecureScoreMetric'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetDataSecureScoreMetric'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                hasNoAssets = 'boolean'
                hasNoDataHistory = 'boolean'
                initiativeScoreImpact = 'real'
                latestCalculatedScoreImpact = 'real'
                latestCalculatedWeight = 'real'
                latestCount = 'real'
                latestScore = 'real'
                latestTotal = 'real'
                latestValue = 'real'
                supportGetAssets = 'boolean'
                targetValue = 'real'
                version = 'real'
                weight = 'real'
            }
        },
@{
            OperationKey = 'GetPostureOversightTenants'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/tenants'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('orgId')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                dataCenter = '$.dataCenter'
                featureFlagsJson = '$.featureFlags'
                geoRegion = '$.geoRegion'
                id = '$.id'
                immuneTvmDedicatedClusterUrl = '$.immuneTvmDedicatedClusterUrl'
                isMdcEligible = '$.isMdcEligible'
                lastUpdated = '$.lastUpdated'
                mpsDataCenter = '$.mpsDataCenter'
                mpsSliceId = '$.mpsSliceId'
                orgId = '$.orgId'
                oversightSliceId = '$.oversightSliceId'
                oversightTvmDedicatedClusterUrl = '$.oversightTvmDedicatedClusterUrl'
                tenantId_x = '$.tenantId'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetPostureOversightTenants'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetPostureOversightTenants'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isMdcEligible = 'boolean'
                lastUpdated = 'datetime'
                mpsSliceId = 'long'
                oversightSliceId = 'long'
            }
        },
@{
            OperationKey = 'ListPostureOversightRecommendations'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/recommendations'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                actionUrl = '$.actionUrl'
                category_x = '$.category'
                compliantAssets = '$.compliantAssets'
                currentState = '$.currentState'
                description = '$.description'
                domainScoreImpact = '$.domainScoreImpact'
                id = '$.id'
                implementationCost = '$.implementationCost'
                implementationStatus = '$.implementationStatus'
                isDisabled = '$.isDisabled'
                isStatic = '$.isStatic'
                lastStateChange = '$.lastStateChange'
                lastStateUpdate = '$.lastStateUpdate'
                lastSynced = '$.lastSynced'
                learnMoreResourcesJson = '$.learnMoreResources'
                maxScore = '$.maxScore'
                mssControlState = '$.mssControlState'
                mssScoreImpact = '$.mssScoreImpact'
                mssTaggedControlsJson = '$.mssTaggedControls'
                notCompliantAssets = '$.notCompliantAssets'
                pointAchieved = '$.pointAchieved'
                product = '$.product'
                relatedInitiativesIdsJson = '$.relatedInitiativesIds'
                relatedMetricsIdsJson = '$.relatedMetricsIds'
                remediation = '$.remediation'
                remediationImpact = '$.remediationImpact'
                score = '$.score'
                severity = '$.severity'
                showOnMainCatalog = '$.showOnMainCatalog'
                source = '$.source'
                title_x = '$.title'
                totalAssets = '$.totalAssets'
                userAffected = '$.userAffected'
                userImpact = '$.userImpact'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListPostureOversightRecommendations'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListPostureOversightRecommendations'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                domainScoreImpact = 'real'
                isDisabled = 'boolean'
                isStatic = 'boolean'
                lastStateChange = 'datetime'
                lastStateUpdate = 'datetime'
                lastSynced = 'datetime'
                maxScore = 'real'
                mssScoreImpact = 'real'
                pointAchieved = 'real'
                score = 'real'
                showOnMainCatalog = 'boolean'
            }
        },
@{
            OperationKey = 'GetPostureOversightInitiative'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/initiatives/{InitiativeId}'
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
                activeMetricIdsJson = '$.activeMetricIds'
                dataHistoryJson = '$.dataHistory'
                description = '$.description'
                id = '$.id'
                isFavorite = '$.isFavorite'
                latestScore = '$.latestScore'
                metricIdsJson = '$.metricIds'
                name = '$.name'
                programsJson = '$.programs'
                recommendationIdsJson = '$.recommendationIds'
                recommendationsV2Json = '$.recommendationsV2'
                suggestionsJson = '$.suggestions'
                supportGetAggregatedAssets = '$.supportGetAggregatedAssets'
                targetValue = '$.targetValue'
                tenantActiveMetricIdsJson = '$.tenantActiveMetricIds'
                threatAnalyticsDataJson = '$.threatAnalyticsData'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetPostureOversightInitiative'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetPostureOversightInitiative'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'ListPostureOversightInitiatives'
                ParentOperationId = 'ExposureManagement.ListPostureOversightInitiatives'
                EntityIdField = 'id'
                ParamName = 'InitiativeId'
                MatchKind = 'PathChildId'
            }
            VolatileHashFields = @('dataHistory')
            ColumnTypes = @{
                isFavorite = 'boolean'
                latestScore = 'real'
                supportGetAggregatedAssets = 'boolean'
                targetValue = 'real'
            }
        },
@{
            OperationKey = 'ListPostureOversightUpdates'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/updates'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
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
                recordsCount = '$.recordsCount'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListPostureOversightUpdates'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListPostureOversightUpdates'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetTvmRiskScore'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/tvm/analytics/riskscore'
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
                assetCount = '$.assetCount'
                assetCountHistoryJson = '$.assetCountHistory'
                risk = '$.risk'
                riskHistoryJson = '$.riskHistory'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetTvmRiskScore'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetTvmRiskScore'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAppsSecureScoreMetric'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/metrics/category_apps_secure_score'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                category_x = '$.category'
                dataHistoryJson = '$.dataHistory'
                dataTypesJson = '$.dataTypes'
                description = '$.description'
                hasNoAssets = '$.hasNoAssets'
                hasNoDataHistory = '$.hasNoDataHistory'
                id = '$.id'
                initiativeScoreImpact = '$.initiativeScoreImpact'
                latestCalculatedScoreImpact = '$.latestCalculatedScoreImpact'
                latestCalculatedWeight = '$.latestCalculatedWeight'
                latestCalculationId = '$.latestCalculationId'
                latestCount = '$.latestCount'
                latestScore = '$.latestScore'
                latestTotal = '$.latestTotal'
                latestValue = '$.latestValue'
                name = '$.name'
                recommendationsJson = '$.recommendations'
                recommendationsV2Json = '$.recommendationsV2'
                sentimentType = '$.sentimentType'
                state = '$.state'
                suggestionsJson = '$.suggestions'
                supportGetAssets = '$.supportGetAssets'
                targetValue = '$.targetValue'
                version = '$.version'
                weight = '$.weight'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetAppsSecureScoreMetric'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetAppsSecureScoreMetric'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                hasNoAssets = 'boolean'
                hasNoDataHistory = 'boolean'
                initiativeScoreImpact = 'real'
                latestCalculatedScoreImpact = 'real'
                latestCalculatedWeight = 'real'
                latestCount = 'real'
                latestScore = 'real'
                latestTotal = 'real'
                latestValue = 'real'
                supportGetAssets = 'boolean'
                targetValue = 'real'
                version = 'real'
                weight = 'real'
            }
        },
@{
            OperationKey = 'ListPostureSecurityEvents'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/securityEvents'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                createdTimestamp = '$.createdTimestamp'
                eventTime = '$.eventTime'
                eventType = '$.eventType'
                id = '$.id'
                isGlobal = '$.isGlobal'
                propertiesJson = '$.properties'
                tenantId_x = '$.tenantId'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListPostureSecurityEvents'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListPostureSecurityEvents'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                createdTimestamp = 'datetime'
                eventTime = 'datetime'
                isGlobal = 'boolean'
            }
        },
@{
            OperationKey = 'ListAttackSurfaceChokepoints'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/xspmatlas/attacksurface/chokepoints/list'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Results'
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
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListAttackSurfaceChokepoints'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListAttackSurfaceChokepoints'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetPostureOversightInitiativesSummarized'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/initiatives/summarized'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
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
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.GetPostureOversightInitiativesSummarized'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.GetPostureOversightInitiativesSummarized'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListAttackSurfaceAttackPaths'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/xspmatlas/attacksurface/attackpaths'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Records'
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
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListAttackSurfaceAttackPaths'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListAttackSurfaceAttackPaths'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListPostureOversightInitiatives'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/initiatives'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                activeMetricIdsJson = '$.activeMetricIds'
                dataHistoryJson = '$.dataHistory'
                description = '$.description'
                id = '$.id'
                isFavorite = '$.isFavorite'
                latestScore = '$.latestScore'
                metricIdsJson = '$.metricIds'
                name = '$.name'
                programsJson = '$.programs'
                recommendationIdsJson = '$.recommendationIds'
                recommendationsV2Json = '$.recommendationsV2'
                suggestionsJson = '$.suggestions'
                supportGetAggregatedAssets = '$.supportGetAggregatedAssets'
                targetValue = '$.targetValue'
                tenantActiveMetricIdsJson = '$.tenantActiveMetricIds'
                threatAnalyticsDataJson = '$.threatAnalyticsData'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListPostureOversightInitiatives'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListPostureOversightInitiatives'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isFavorite = 'boolean'
                latestScore = 'real'
                supportGetAggregatedAssets = 'boolean'
                targetValue = 'real'
            }
        },
@{
            OperationKey = 'ListPostureOversightMetrics'
            Subcategory = 'Exposure Management'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/posture/oversight/metrics'
            ResponseShape = 'wrapper'
            ItemsContainer = 'results'
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('id')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                category_x = '$.category'
                dataHistoryJson = '$.dataHistory'
                dataTypesJson = '$.dataTypes'
                description = '$.description'
                hasNoAssets = '$.hasNoAssets'
                hasNoDataHistory = '$.hasNoDataHistory'
                id = '$.id'
                initiativeScoreImpact = '$.initiativeScoreImpact'
                latestCalculatedScoreImpact = '$.latestCalculatedScoreImpact'
                latestCalculatedWeight = '$.latestCalculatedWeight'
                latestCalculationId = '$.latestCalculationId'
                latestCount = '$.latestCount'
                latestScore = '$.latestScore'
                latestTotal = '$.latestTotal'
                latestValue = '$.latestValue'
                name = '$.name'
                recommendationsJson = '$.recommendations'
                recommendationsV2Json = '$.recommendationsV2'
                releaseNotesJson = '$.releaseNotes'
                sentimentType = '$.sentimentType'
                state = '$.state'
                suggestionsJson = '$.suggestions'
                supportGetAssets = '$.supportGetAssets'
                targetValue = '$.targetValue'
                updateId = '$.updateId'
                version = '$.version'
                weight = '$.weight'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_ExposureManagement_CL'
            WorkspaceTable = 'Defender_ExposureManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_EXPOSUREMANAGEMENT'
            Provenance = @{
                OperationId = 'ExposureManagement.ListPostureOversightMetrics'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/exposure_management.yml#ExposureManagement.ListPostureOversightMetrics'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                hasNoAssets = 'boolean'
                hasNoDataHistory = 'boolean'
                initiativeScoreImpact = 'real'
                latestCalculatedScoreImpact = 'real'
                latestCalculatedWeight = 'real'
                latestCount = 'real'
                latestScore = 'real'
                latestTotal = 'real'
                latestValue = 'real'
                supportGetAssets = 'boolean'
                targetValue = 'real'
                version = 'real'
                weight = 'real'
            }
        }
    )
}
