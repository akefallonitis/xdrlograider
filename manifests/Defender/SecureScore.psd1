# manifests/Defender/SecureScore.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'SecureScore'
    Operations = @(
@{
            OperationKey = 'GetTenantProfile'
            Subcategory = 'Secure Score'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoreTenantProfile'
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
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                id = '$.id'
                secureScoreZoneJson = '$.secureScoreZone'
                taggedControlsJson = '$.taggedControls'
                tenantBenchmarksJson = '$.tenantBenchmarks'
            }
            DcrStreamName = 'Custom-Defender_SecureScore_CL'
            WorkspaceTable = 'Defender_SecureScore_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_SECURESCORE'
            Provenance = @{
                OperationId = 'SecureScore.GetTenantProfile'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/secure_score.yml#SecureScore.GetTenantProfile'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetInsights'
            Subcategory = 'Secure Score'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoreInsights'
            ResponseShape = 'wrapper'
            ItemsContainer = 'value'
            Cadence = '06:00:00'
            IngestionMode = 'CURSOR'
            CursorField = 'createdDate'
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'ClientSideHighWater'
                FieldName = 'createdDate'
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                averageScore = '$.averageScore'
                benchmarkJson = '$.benchmark'
                createdDate = '$.createdDate'
                id = '$.id'
                initiative = '$.initiative'
                pillarInsightsJson = '$.pillarInsights'
                tenantCount = '$.tenantCount'
            }
            DcrStreamName = 'Custom-Defender_SecureScore_CL'
            WorkspaceTable = 'Defender_SecureScore_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_SECURESCORE'
            Provenance = @{
                OperationId = 'SecureScore.GetInsights'
                Live = 'references/live/source-mvp-fixtures/GetInsights/response.json'
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/secure_score.yml#SecureScore.GetInsights'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                averageScore = 'real'
                createdDate = 'datetime'
                tenantCount = 'long'
            }
        },
@{
            OperationKey = 'GetSecureScoresV2'
            Subcategory = 'Secure Score'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoresV2'
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
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                activeUserCount = '$.activeUserCount'
                averageComparativeScoresJson = '$.averageComparativeScores'
                azureTenantId = '$.azureTenantId'
                controlScoresJson = '$.controlScores'
                createdDateTime = '$.createdDateTime'
                currentScore = '$.currentScore'
                currentScoreInPercentage = '$.currentScoreInPercentage'
                enabledServicesJson = '$.enabledServices'
                id = '$.id'
                licensedUserCount = '$.licensedUserCount'
                maxScore = '$.maxScore'
                scoreImpactChangeLogsJson = '$.scoreImpactChangeLogs'
                vendorInformationJson = '$.vendorInformation'
            }
            DcrStreamName = 'Custom-Defender_SecureScore_CL'
            WorkspaceTable = 'Defender_SecureScore_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_SECURESCORE'
            Provenance = @{
                OperationId = 'SecureScore.GetSecureScoresV2'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/secure_score.yml#SecureScore.GetSecureScoresV2'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                activeUserCount = 'long'
                createdDateTime = 'datetime'
                currentScore = 'real'
                currentScoreInPercentage = 'real'
                licensedUserCount = 'long'
                maxScore = 'real'
            }
        },
@{
            OperationKey = 'GetControlProfilesV2'
            Subcategory = 'Secure Score'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoreControlProfilesV2'
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
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                actionType = '$.actionType'
                actionUrl = '$.actionUrl'
                azureTenantId = '$.azureTenantId'
                baseControl = '$.baseControl'
                controlCategory = '$.controlCategory'
                controlStateUpdatesJson = '$.controlStateUpdates'
                dateAdded = '$.dateAdded'
                dateRemoved = '$.dateRemoved'
                deprecated = '$.deprecated'
                hasLowAccuracy = '$.hasLowAccuracy'
                id = '$.id'
                implementationCost = '$.implementationCost'
                instanceName = '$.instanceName'
                isCustomControl = '$.isCustomControl'
                isEmergencyControl = '$.isEmergencyControl'
                lastModifiedDateTime = '$.lastModifiedDateTime'
                learnMoreResourcesJson = '$.learnMoreResources'
                licensePrerequisitesJson = '$.licensePrerequisites'
                maxScore = '$.maxScore'
                prerequisitesControlsJson = '$.prerequisitesControls'
                rank = '$.rank'
                relatedControlsJson = '$.relatedControls'
                relatedReportsJson = '$.relatedReports'
                remediation = '$.remediation'
                remediationImpact = '$.remediationImpact'
                service = '$.service'
                threatsJson = '$.threats'
                tier = '$.tier'
                title_x = '$.title'
                userAffected = '$.userAffected'
                userImpact = '$.userImpact'
                vendorInformationJson = '$.vendorInformation'
            }
            DcrStreamName = 'Custom-Defender_SecureScore_CL'
            WorkspaceTable = 'Defender_SecureScore_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_SECURESCORE'
            Provenance = @{
                OperationId = 'SecureScore.GetControlProfilesV2'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/secure_score.yml#SecureScore.GetControlProfilesV2'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                dateAdded = 'datetime'
                deprecated = 'boolean'
                hasLowAccuracy = 'boolean'
                isCustomControl = 'boolean'
                isEmergencyControl = 'boolean'
                maxScore = 'real'
                rank = 'long'
            }
        },
@{
            OperationKey = 'GetSecurityInitiativesV2'
            Subcategory = 'Secure Score'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/secureScore/security/secureScoreSecurityInitiativesV2'
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
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                azureTenantId = '$.azureTenantId'
                category_x = '$.Category'
                DefaultGrouping = '$.DefaultGrouping'
                Description = '$.Description'
                id = '$.id'
                LinksJson = '$.Links'
                Name = '$.Name'
                SubgroupsJson = '$.Subgroups'
                vendorInformationJson = '$.vendorInformation'
            }
            DcrStreamName = 'Custom-Defender_SecureScore_CL'
            WorkspaceTable = 'Defender_SecureScore_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_SECURESCORE'
            Provenance = @{
                OperationId = 'SecureScore.GetSecurityInitiativesV2'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/secure_score.yml#SecureScore.GetSecurityInitiativesV2'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
