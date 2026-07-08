# manifests/Defender/Identity.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'Identity'
    Operations = @(
@{
            OperationKey = 'GetPasswordPolicyReports'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/pdProtection/mdaReports/PasswordPolicies'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{
                EntraJson = '$.Entra'
            }
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetPasswordPolicyReports'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetPasswordPolicyReports'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetMachinesManagedByStatus'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/siamApi/MachinesManagedByStatus'
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
                mde = '$.mde'
                mdm_x = '$.mdm'
                osPlatform = '$.osPlatform'
                sccm = '$.sccm'
                total = '$.total'
                unknown = '$.unknown'
            }
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetMachinesManagedByStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetMachinesManagedByStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetPasswordPolicyReportDefinitions'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/pdProtection/reportDefinitions/PasswordPolicies'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetPasswordPolicyReportDefinitions'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetPasswordPolicyReportDefinitions'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAlertThreshold'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/alertThreshold'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetAlertThreshold'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetAlertThreshold'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAlertThresholdsWithExpiry'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/alertthresholds/withExpiry'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetAlertThresholdsWithExpiry'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetAlertThresholdsWithExpiry'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetDefensorConfiguration'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/defensor/defensorConfiguration'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetDefensorConfiguration'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetDefensorConfiguration'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetWorkspaceMonitoringAlerts'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/odata/workspaceMonitoringAlerts'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetWorkspaceMonitoringAlerts'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetWorkspaceMonitoringAlerts'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetOnboardedMachinesStatus'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/siamApi/OnboardedMachinesStatus'
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
                certificateError = '$.certificateError'
                clockSyncIssue = '$.clockSyncIssue'
                connectivityIssue = '$.connectivityIssue'
                dnsError = '$.dnsError'
                generalError = '$.generalError'
                generalHybridJoinFailure = '$.generalHybridJoinFailure'
                hybridErrorServiceConnectionPoint = '$.hybridErrorServiceConnectionPoint'
                ldapApiError = '$.ldapApiError'
                mdeOsFamilyOnboardedMachinesJson = '$.mdeOsFamilyOnboardedMachines'
                mdeWithError = '$.mdeWithError'
                memConfigurationIssue = '$.memConfigurationIssue'
                onPremiseSyncIssue = '$.onPremiseSyncIssue'
                success = '$.success'
                tenantMismatch = '$.tenantMismatch'
            }
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetOnboardedMachinesStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetOnboardedMachinesStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAlertThresholdsRecommendedTestMode'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/alertthresholds/withExpiry/recommendedTestMode'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetAlertThresholdsRecommendedTestMode'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetAlertThresholdsRecommendedTestMode'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetGlobalExclusionEntities'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/odata/ExclusionEntityDatas/Global'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetGlobalExclusionEntities'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetGlobalExclusionEntities'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetMemOnboardStatus'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/siamApi/memonboardstatus'
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
                isOnboarded = '$.isOnboarded'
            }
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetMemOnboardStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetMemOnboardStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetSyslogConfiguration'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/workspace/configuration/syslog'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetSyslogConfiguration'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetSyslogConfiguration'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetOnboardingStatus'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/status'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{
                isOnboarded = '$.isOnboarded'
                sensorCount = '$.sensorCount'
            }
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetOnboardingStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetOnboardingStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetRemediationActionsConfig'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/remediationActions/configuration'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetRemediationActionsConfig'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetRemediationActionsConfig'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetVpnConfiguration'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/api/mtp/vpnConfiguration'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetVpnConfiguration'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetVpnConfiguration'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetUserTimeline'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/user/timeline'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetUserTimeline'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetUserTimeline'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetPasswordDomainsPolicies'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'mdi'
            Path = '/identity/userapiservice/pdProtection/domainsPolicies'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetPasswordDomainsPolicies'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetPasswordDomainsPolicies'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetSecurityAlertExclusions'
            Subcategory = 'Identity'
            Method = 'GET'
            SubPortal = 'aatp'
            Path = '/odata/SecurityAlertExclusionDatas'
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
            RequiresProducts = @('MDI')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_Identity_CL'
            WorkspaceTable = 'Defender_Identity_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_IDENTITY'
            Provenance = @{
                OperationId = 'Identity.GetSecurityAlertExclusions'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/identity.yml#Identity.GetSecurityAlertExclusions'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
