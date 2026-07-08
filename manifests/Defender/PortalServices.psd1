# manifests/Defender/PortalServices.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'PortalServices'
    Operations = @(
@{
            OperationKey = 'GetOptimizeRecommendations'
            Subcategory = 'Portal Services'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/optimize/OptimizeRecommendation'
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
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_PortalServices_CL'
            WorkspaceTable = 'Defender_PortalServices_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_PORTALSERVICES'
            Provenance = @{
                OperationId = 'PortalServices.GetOptimizeRecommendations'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/portal_services.yml#PortalServices.GetOptimizeRecommendations'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'CheckAppGovernanceOnboarding'
            Subcategory = 'Portal Services'
            Method = 'GET'
            SubPortal = 'm365appprotection'
            Path = '/mapg-glsservice/compliance/istenantonboarded'
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
            RequiresProducts = @('MAPG')
            ProjectionMap = @{
                odatacontext_x = '$.@odata.context'
                forestName = '$.forestName'
                hasConsentToExportData = '$.hasConsentToExportData'
                id = '$.id'
                isFirstLoginForCurrentUser = '$.isFirstLoginForCurrentUser'
                isRegionSupported = '$.isRegionSupported'
                isTenantOnboarded = '$.isTenantOnboarded'
                tenantId_x = '$.tenantId'
                toggleStatus = '$.toggleStatus'
            }
            DcrStreamName = 'Custom-Defender_PortalServices_CL'
            WorkspaceTable = 'Defender_PortalServices_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_PORTALSERVICES'
            Provenance = @{
                OperationId = 'PortalServices.CheckAppGovernanceOnboarding'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/portal_services.yml#PortalServices.CheckAppGovernanceOnboarding'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            VolatileHashFields = @('id')
        },
@{
            OperationKey = 'GetMachineHealthStatus'
            Subcategory = 'Portal Services'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/mdepDnH/reports/machineHealth/healthStatus'
            ResponseShape = 'wrapper'
            ItemsContainer = 'data'
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
                date_x = '$.date'
                valuesJson = '$.values'
            }
            DcrStreamName = 'Custom-Defender_PortalServices_CL'
            WorkspaceTable = 'Defender_PortalServices_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_PORTALSERVICES'
            Provenance = @{
                OperationId = 'PortalServices.GetMachineHealthStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/portal_services.yml#PortalServices.GetMachineHealthStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAttackSimUserCoverage'
            Subcategory = 'Portal Services'
            Method = 'GET'
            SubPortal = 'astgws'
            Path = '/AttackSimulator/api/v1/AdvanceReporting/chart/UserCoverage'
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
            RequiresProducts = @('MDO')
            ProjectionMap = @{
                coveredCount = '$.coveredCount'
                totalUserCount = '$.totalUserCount'
            }
            DcrStreamName = 'Custom-Defender_PortalServices_CL'
            WorkspaceTable = 'Defender_PortalServices_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_PORTALSERVICES'
            Provenance = @{
                OperationId = 'PortalServices.GetAttackSimUserCoverage'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/portal_services.yml#PortalServices.GetAttackSimUserCoverage'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
