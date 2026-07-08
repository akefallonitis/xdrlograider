# manifests/Defender/AttackSimulation.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'AttackSimulation'
    Operations = @(
@{
            OperationKey = 'ListGlobalPayloads'
            Subcategory = 'AttackSimulator'
            Method = 'GET'
            SubPortal = 'astgws'
            Path = '/AttackSimulator/api/v1/GlobalPayloads'
            ResponseShape = 'wrapper'
            ItemsContainer = 'value'
            Cadence = '01:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'cursor'
                ParamLocation = 'query'
                CursorMode = 'nextLink'
                CursorPath = '$[''odata.nextLink'']'
                LoopGuard = 1000
            }
            RequiresProducts = @('MDO')
            ProjectionMap = @{
                etag_x = '$._etag'
                attackType = '$.attackType'
                complexity = '$.complexity'
                createdBy = '$.createdBy'
                createdTime = '$.createdTime'
                description = '$.description'
                id = '$.id'
                isAutomated = '$.isAutomated'
                isControversial = '$.isControversial'
                isCurrentEvent = '$.isCurrentEvent'
                language = '$.language'
                lastModifiedBy = '$.lastModifiedBy'
                lastModifiedTime = '$.lastModifiedTime'
                missedPercentage = '$.missedPercentage'
                name = '$.name'
                payloadBrand = '$.payloadBrand'
                payloadDetail = '$.payloadDetail'
                payloadIndustry = '$.payloadIndustry'
                payloadStatistics = '$.payloadStatistics'
                payloadTagsJson = '$.payloadTags'
                payloadTheme = '$.payloadTheme'
                platform = '$.platform'
                predictedCompromiseRate = '$.predictedCompromiseRate'
                source = '$.source'
                status = '$.status'
                technique = '$.technique'
                tenantFlightingIds = '$.tenantFlightingIds'
                tenantsImpacted = '$.tenantsImpacted'
            }
            DcrStreamName = 'Custom-Defender_AttackSimulation_CL'
            WorkspaceTable = 'Defender_AttackSimulation_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ATTACKSIMULATION'
            Provenance = @{
                OperationId = 'AttackSimulator.ListGlobalPayloads'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/attack_simulator.yml#AttackSimulator.ListGlobalPayloads'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetRecommendations'
            Subcategory = 'AttackSimulator'
            Method = 'GET'
            SubPortal = 'astgws'
            Path = '/AttackSimulator/api/v1/Recommendations'
            ResponseShape = 'wrapper'
            ItemsContainer = 'value'
            Cadence = '01:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'cursor'
                ParamLocation = 'query'
                CursorMode = 'nextLink'
                CursorPath = '$[''odata.nextLink'']'
                LoopGuard = 1000
            }
            RequiresProducts = @('MDO')
            ProjectionMap = @{
                id = '$.id'
                payloadId = '$.payloadId'
                payloadName = '$.payloadName'
                recommendationType = '$.recommendationType'
                technique = '$.technique'
            }
            DcrStreamName = 'Custom-Defender_AttackSimulation_CL'
            WorkspaceTable = 'Defender_AttackSimulation_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ATTACKSIMULATION'
            Provenance = @{
                OperationId = 'AttackSimulator.GetRecommendations'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/attack_simulator.yml#AttackSimulator.GetRecommendations'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListSimulations'
            Subcategory = 'AttackSimulator'
            Method = 'GET'
            SubPortal = 'astgws'
            Path = '/AttackSimulator/api/v1/Simulations'
            ResponseShape = 'wrapper'
            ItemsContainer = 'value'
            Cadence = '01:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'cursor'
                ParamLocation = 'query'
                CursorMode = 'nextLink'
                CursorPath = '$[''odata.nextLink'']'
                LoopGuard = 1000
            }
            RequiresProducts = @('MDO')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_AttackSimulation_CL'
            WorkspaceTable = 'Defender_AttackSimulation_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ATTACKSIMULATION'
            Provenance = @{
                OperationId = 'AttackSimulator.ListSimulations'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/attack_simulator.yml#AttackSimulator.ListSimulations'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetCampaignSettings'
            Subcategory = 'AttackSimulator'
            Method = 'GET'
            SubPortal = 'astgws'
            Path = '/AttackSimulator/api/v1/campaignSettings'
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
            RequiresProducts = @('MDO')
            ProjectionMap = @{
                eTag = '$.eTag'
                organizationInsightsSettingsJson = '$.organizationInsightsSettings'
                repeatOffenderSettingsJson = '$.repeatOffenderSettings'
                trainingDedupSettingsJson = '$.trainingDedupSettings'
                trainingNotificationSettings = '$.trainingNotificationSettings'
                userReminderSettingsJson = '$.userReminderSettings'
                userSusceptibilitySettingsJson = '$.userSusceptibilitySettings'
            }
            DcrStreamName = 'Custom-Defender_AttackSimulation_CL'
            WorkspaceTable = 'Defender_AttackSimulation_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ATTACKSIMULATION'
            Provenance = @{
                OperationId = 'AttackSimulator.GetCampaignSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/attack_simulator.yml#AttackSimulator.GetCampaignSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
