# manifests/Defender/CloudApps.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'CloudApps'
    Operations = @(
@{
            OperationKey = 'AppGovernanceListPolicies'
            Subcategory = 'AppGovernance'
            Method = 'GET'
            SubPortal = 'm365appprotection'
            Path = '/mapg-glsservice/compliance/policies'
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
            RequiresProducts = @('MAPG')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'AppGovernance.ListPolicies'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#AppGovernance.ListPolicies'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetMailSettings'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/mail_settings/get'
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
            ProjectionMap = @{
                tenantEmailJson = '$.tenantEmail'
            }
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.GetMailSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.GetMailSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'CloudAppsListPolicies'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/policies'
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
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.ListPolicies'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.ListPolicies'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetPolicyInsights'
            Subcategory = 'AppGovernance'
            Method = 'GET'
            SubPortal = 'm365appprotection'
            Path = '/mapg-glsservice/compliance/policyinsights'
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
            RequiresProducts = @('MAPG')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'AppGovernance.GetPolicyInsights'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#AppGovernance.GetPolicyInsights'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetPolicy'
            Subcategory = 'AppGovernance'
            Method = 'GET'
            SubPortal = 'm365appprotection'
            Path = '/mapg-glsservice/compliance/Policy'
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
            RequiresProducts = @('MAPG')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'AppGovernance.GetPolicy'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#AppGovernance.GetPolicy'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAppConnectorsLastActivity'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/app_connectors/last_activity'
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
            RequiresProducts = @('MCAS')
            ProjectionMap = @{}
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.GetAppConnectorsLastActivity'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.GetAppConnectorsLastActivity'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetDataEncryptionSettings'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/data_encryption_settings/get'
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
            ProjectionMap = @{
                encryptDataAtRest = '$.encryptDataAtRest'
            }
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.GetDataEncryptionSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.GetDataEncryptionSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetLcncSettings'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/lcnc_settings'
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
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.GetLcncSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.GetLcncSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetSettings'
            Subcategory = 'CloudApps'
            Method = 'GET'
            SubPortal = 'mcas'
            Path = '/cas/api/v1/settings'
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
            ProjectionMap = @{
                adminViewUsersJson = '$.adminViewUsers'
                allowAzIP = '$.allowAzIP'
                allowAzureSecurityIntegration = '$.allowAzureSecurityIntegration'
                allowScopedAdminsInMTP = '$.allowScopedAdminsInMTP'
                appControlEnabled = '$.appControlEnabled'
                blockAppsURL = '$.blockAppsURL'
                customWarnURL = '$.customWarnURL'
                domainsJson = '$.domains'
                emailMaskPolicy = '$.emailMaskPolicy'
                emailMaskPolicyOptionsJson = '$.emailMaskPolicyOptions'
                enableBypassSuffix = '$.enableBypassSuffix'
                enforceSessionProxy = '$.enforceSessionProxy'
                environmentName = '$.environmentName'
                fileMonitoringJson = '$.fileMonitoring'
                fileMonitoringEnabled = '$.fileMonitoringEnabled'
                ignoreExternalAzIP = '$.ignoreExternalAzIP'
                logoFilePath = '$.logoFilePath'
                managedDevicesCrl = '$.managedDevicesCrl'
                mdatpGlobalBypassDurationHours = '$.mdatpGlobalBypassDurationHours'
                mdatpGlobalSeverityLevel = '$.mdatpGlobalSeverityLevel'
                orgDisplayName = '$.orgDisplayName'
                ProxywebPagesCustomizationJson = '$.ProxywebPagesCustomization'
                quarantineSiteJson = '$.quarantineSite'
                quarantineSiteId = '$.quarantineSiteId'
                quarantineUserNotification = '$.quarantineUserNotification'
                rmsDecryptAllConsented = '$.rmsDecryptAllConsented'
                showSuffixDisclaimer = '$.showSuffixDisclaimer'
                signOutTime = '$.signOutTime'
            }
            DcrStreamName = 'Custom-Defender_CloudApps_CL'
            WorkspaceTable = 'Defender_CloudApps_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_CLOUDAPPS'
            Provenance = @{
                OperationId = 'CloudApps.GetSettings'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/cloud_apps.yml#CloudApps.GetSettings'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
