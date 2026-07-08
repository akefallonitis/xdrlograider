# manifests/Defender/AnalyticsData.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'AnalyticsData'
    Operations = @(
@{
            OperationKey = 'GetTopThreats'
            Subcategory = 'Threat Analytics'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/threatAnalytics/outbreaks/topthreats'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
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
                AlertsCount = '$.AlertsCount'
                CurrentAlertsCountJson = '$.CurrentAlertsCount'
                DevicesCalculationStatus = '$.DevicesCalculationStatus'
                MailboxesCalculationStatus = '$.MailboxesCalculationStatus'
                ThreatExposureCalculationStatus = '$.ThreatExposureCalculationStatus'
                ThreatsExposureJson = '$.ThreatsExposure'
                TotalActiveThreats = '$.TotalActiveThreats'
                TotalThreatRequiresAction = '$.TotalThreatRequiresAction'
            }
            DcrStreamName = 'Custom-Defender_AnalyticsData_CL'
            WorkspaceTable = 'Defender_AnalyticsData_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ANALYTICSDATA'
            Provenance = @{
                OperationId = 'ThreatAnalytics.GetTopThreats'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/threat_analytics.yml#ThreatAnalytics.GetTopThreats'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                TotalActiveThreats = 'long'
                TotalThreatRequiresAction = 'long'
            }
        },
@{
            OperationKey = 'GetEnrichedOutbreakData'
            Subcategory = 'Threat Analytics'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/threatAnalytics/outbreaks/outbreaksEnrichedDataMtp'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Items'
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
                AlertsCountJson = '$.AlertsCount'
                AllCvesAreNotSupported = '$.AllCvesAreNotSupported'
                CreatedOn = '$.CreatedOn'
                CveAndScidNotDefined = '$.CveAndScidNotDefined'
                CveNotDefined = '$.CveNotDefined'
                DisplayName = '$.DisplayName'
                exposedDevices = '$.ExposedDevices'
                ExposureScore = '$.ExposureScore'
                ExposureSeverity = '$.ExposureSeverity'
                id = '$.Id'
                ImpactedEntitiesCountJson = '$.ImpactedEntitiesCount'
                IsTaVNext = '$.IsTaVNext'
                LastUpdatedOn = '$.LastUpdatedOn'
                ReportType = '$.ReportType'
                ScaExposedDevices = '$.ScaExposedDevices'
                ScidNotDefined = '$.ScidNotDefined'
                StartedOn = '$.StartedOn'
                tagsJson = '$.Tags'
                UserStateJson = '$.UserState'
                VaExposedDevices = '$.VaExposedDevices'
            }
            DcrStreamName = 'Custom-Defender_AnalyticsData_CL'
            WorkspaceTable = 'Defender_AnalyticsData_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ANALYTICSDATA'
            Provenance = @{
                OperationId = 'ThreatAnalytics.GetEnrichedOutbreakData'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/threat_analytics.yml#ThreatAnalytics.GetEnrichedOutbreakData'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AllCvesAreNotSupported = 'boolean'
                CreatedOn = 'datetime'
                CveAndScidNotDefined = 'boolean'
                CveNotDefined = 'boolean'
                exposedDevices = 'long'
                ExposureScore = 'long'
                IsTaVNext = 'boolean'
                LastUpdatedOn = 'datetime'
                ScaExposedDevices = 'long'
                ScidNotDefined = 'boolean'
                StartedOn = 'datetime'
                VaExposedDevices = 'long'
            }
        },
@{
            OperationKey = 'ListPortalOutbreaks'
            Subcategory = 'Threat Analytics'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/threatAnalytics/outbreaks'
            ResponseShape = 'bareArray'
            ItemsContainer = $null
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
                CreatedOn = '$.CreatedOn'
                DisplayName = '$.DisplayName'
                id = '$.Id'
                IOAIdsJson = '$.IOAIds'
                IsVNext = '$.IsVNext'
                KeywordsJson = '$.Keywords'
                LastUpdatedOn = '$.LastUpdatedOn'
                LastVisitTime = '$.LastVisitTime'
                MitigationTypesJson = '$.MitigationTypes'
                OutbreakOverviewContent = '$.OutbreakOverviewContent'
                ReferencesJson = '$.References'
                ReportType = '$.ReportType'
                SecureScoreIdsJson = '$.SecureScoreIds'
                severity = '$.Severity'
                StartedOn = '$.StartedOn'
                tagsJson = '$.Tags'
            }
            DcrStreamName = 'Custom-Defender_AnalyticsData_CL'
            WorkspaceTable = 'Defender_AnalyticsData_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ANALYTICSDATA'
            Provenance = @{
                OperationId = 'ThreatAnalytics.ListPortalOutbreaks'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/threat_analytics.yml#ThreatAnalytics.ListPortalOutbreaks'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                CreatedOn = 'datetime'
                IsVNext = 'boolean'
                LastUpdatedOn = 'datetime'
                severity = 'long'
                StartedOn = 'datetime'
            }
        }
    )
}
