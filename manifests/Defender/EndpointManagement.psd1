# manifests/Defender/EndpointManagement.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'EndpointManagement'
    Operations = @(
@{
            OperationKey = 'GetPreviewFeatures'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/settings/GetPreviewExperienceSetting'
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
                IsOptIn = '$.IsOptIn'
                SliceId = '$.SliceId'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetPreviewFeatures'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetPreviewFeatures'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                IsOptIn = 'boolean'
                SliceId = 'long'
            }
        },
@{
            OperationKey = 'GetMagellanFeatures'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/mdiotSettingsService/settings/v2/MagellanFeatures'
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
                IsCorelightIntegrationEnabled = '$.IsCorelightIntegrationEnabled'
                IsLog4jScanningEnabled = '$.IsLog4jScanningEnabled'
                IsProactiveDiscoveryEnabled = '$.IsProactiveDiscoveryEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetMagellanFeatures'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetMagellanFeatures'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                IsProactiveDiscoveryEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetDiscoveryEnabledTags'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/mdiotSettingsService/settings/DiscoveryEnabledTags'
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
                EnabledTagsForScanJson = '$.EnabledTagsForScan'
                IsAllDevicesEnabled = '$.IsAllDevicesEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetDiscoveryEnabledTags'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetDiscoveryEnabledTags'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                IsAllDevicesEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetPuaConfiguration'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceManagement/configuration/PotentiallyUnwantedApplications'
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
                isEnabled = '$.isEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetPuaConfiguration'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetPuaConfiguration'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'ListCustomCollectionRules'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/customDataCollection/rules'
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
                Description = '$.description'
                frequency = '$.frequency'
                id = '$.id'
                isEnabled = '$.isEnabled'
                name = '$.name'
                query = '$.query'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.ListCustomCollectionRules'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.ListCustomCollectionRules'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetPurviewSharing'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceManagement/configuration/PurviewSharing'
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
                isEnabled = '$.isEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetPurviewSharing'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetPurviewSharing'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetAdvancedFeaturesGet'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/settings/GetAdvancedFeaturesSetting'
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
                AatpIntegrationEnabled = '$.AatpIntegrationEnabled'
                AatpWorkspaceExists = '$.AatpWorkspaceExists'
                AllowWdavNetworkBlock = '$.AllowWdavNetworkBlock'
                AutoResolveInvestigatedAlerts = '$.AutoResolveInvestigatedAlerts'
                BilbaoApproved = '$.BilbaoApproved'
                BilbaoEnabled = '$.BilbaoEnabled'
                BlockListEnabled = '$.BlockListEnabled'
                DartDataCollection = '$.DartDataCollection'
                EnableAggregatedReporting = '$.EnableAggregatedReporting'
                EnableAipIntegration = '$.EnableAipIntegration'
                EnableCustomAsrAdvancedProcessTermination = '$.EnableCustomAsrAdvancedProcessTermination'
                EnableEndpointDlp = '$.EnableEndpointDlp'
                EnableExcludedDevices = '$.EnableExcludedDevices'
                EnableHVAOnboardingOptions = '$.EnableHVAOnboardingOptions'
                EnableMcasIntegration = '$.EnableMcasIntegration'
                EnableQuarantinedFileDownload = '$.EnableQuarantinedFileDownload'
                EnableWdavAntiTampering = '$.EnableWdavAntiTampering'
                EnableWdavAuditMode = '$.EnableWdavAuditMode'
                EnableWdavPassiveModeRemediation = '$.EnableWdavPassiveModeRemediation'
                HidePotentialDuplications = '$.HidePotentialDuplications'
                IsolateIncidentsWithDifferentDeviceGroups = '$.IsolateIncidentsWithDifferentDeviceGroups'
                IsolationExclusionOptIn = '$.IsolationExclusionOptIn'
                LicenseEnabled = '$.LicenseEnabled'
                LowFidelityEnrichmentEnabled = '$.LowFidelityEnrichmentEnabled'
                M365SecureScoreIntegrationEnabled = '$.M365SecureScoreIntegrationEnabled'
                MagellanOptOut = '$.MagellanOptOut'
                MobileDeactivationPeriodInDays = '$.MobileDeactivationPeriodInDays'
                ShowUserAadProfile = '$.ShowUserAadProfile'
                SkypeIntegrationEnabled = '$.SkypeIntegrationEnabled'
                UseSimplifiedConnectivity = '$.UseSimplifiedConnectivity'
                UseSimplifiedConnectivityViaApi = '$.UseSimplifiedConnectivityViaApi'
                WebCategoriesEnabled = '$.WebCategoriesEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetAdvancedFeaturesGet'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetAdvancedFeaturesGet'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AatpIntegrationEnabled = 'boolean'
                AatpWorkspaceExists = 'boolean'
                AllowWdavNetworkBlock = 'boolean'
                AutoResolveInvestigatedAlerts = 'boolean'
                BilbaoApproved = 'boolean'
                BilbaoEnabled = 'boolean'
                BlockListEnabled = 'boolean'
                DartDataCollection = 'boolean'
                EnableAggregatedReporting = 'boolean'
                EnableAipIntegration = 'boolean'
                EnableCustomAsrAdvancedProcessTermination = 'boolean'
                EnableEndpointDlp = 'boolean'
                EnableExcludedDevices = 'boolean'
                EnableHVAOnboardingOptions = 'boolean'
                EnableMcasIntegration = 'boolean'
                EnableQuarantinedFileDownload = 'boolean'
                EnableWdavAntiTampering = 'boolean'
                EnableWdavAuditMode = 'boolean'
                EnableWdavPassiveModeRemediation = 'boolean'
                HidePotentialDuplications = 'boolean'
                IsolateIncidentsWithDifferentDeviceGroups = 'boolean'
                IsolationExclusionOptIn = 'boolean'
                LicenseEnabled = 'boolean'
                LowFidelityEnrichmentEnabled = 'boolean'
                M365SecureScoreIntegrationEnabled = 'boolean'
                MagellanOptOut = 'boolean'
                ShowUserAadProfile = 'boolean'
                SkypeIntegrationEnabled = 'boolean'
                UseSimplifiedConnectivity = 'boolean'
                UseSimplifiedConnectivityViaApi = 'boolean'
                WebCategoriesEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'GetIntuneConnection'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceManagement/configuration/IntuneConnection'
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
                isEnabled = '$.isEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetIntuneConnection'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetIntuneConnection'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'ListAlertEmailNotifications'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/alertsEmailNotifications/email_notifications'
            ResponseShape = 'wrapper'
            ItemsContainer = 'items'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.ListAlertEmailNotifications'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.ListAlertEmailNotifications'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetAuthenticatedTelemetry'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceManagement/configuration/AuthenticatedTelemetry'
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
                isEnabled = '$.isEnabled'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.GetAuthenticatedTelemetry'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.GetAuthenticatedTelemetry'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                isEnabled = 'boolean'
            }
        },
@{
            OperationKey = 'ListManagedDevices'
            Subcategory = 'Endpoint Configuration'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/unifiedExperience/mde/configurationManagement/mem/proxy/deviceManagement/managedDevices'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointConfiguration.ListManagedDevices'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_configuration.yml#EndpointConfiguration.ListManagedDevices'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetNdrInterceptingMachines'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/ndr/machines/{MachineId}/InterceptingMachines'
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
                ContainsUnauthorizedDevice = '$.ContainsUnauthorizedDevice'
                DeviceId = '$.DeviceId'
                InterceptingDevicesJson = '$.InterceptingDevices'
                IsSeenByMdi = '$.IsSeenByMdi'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetNdrInterceptingMachines'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetNdrInterceptingMachines'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'MachineId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetRbacGroupScopes'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/rbacGroupAssignment/rbacGroupsScopes/{DeviceId}'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetRbacGroupScopes'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetRbacGroupScopes'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'DeviceId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetTags'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/machineTag/machineTags/{DeviceId}'
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
                tag = '$.tag'
                tagType = '$.tagType'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetTags'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetTags'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'DeviceId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetMachineGroups'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/rbacManagementApi/rbac/machine_groups'
            ResponseShape = 'wrapper'
            ItemsContainer = 'items'
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
                AutoRemediationLevel = '$.AutoRemediationLevel'
                Description = '$.Description'
                GroupRulesJson = '$.GroupRules'
                IsUnassignedMachineGroup = '$.IsUnassignedMachineGroup'
                LastUpdated = '$.LastUpdated'
                MachineCount = '$.MachineCount'
                MachineGroupId = '$.MachineGroupId'
                name = '$.Name'
                Priority = '$.Priority'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetMachineGroups'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetMachineGroups'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AutoRemediationLevel = 'long'
                IsUnassignedMachineGroup = 'boolean'
                LastUpdated = 'datetime'
                MachineCount = 'long'
                MachineGroupId = 'long'
                Priority = 'long'
            }
        },
@{
            OperationKey = 'GetNdrMachineExclusionDetails'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/ndr/machines/{MachineId}/exclusionDetails'
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
                ExclusionState = '$.ExclusionState'
                Justification = '$.Justification'
                Notes = '$.Notes'
                RequestedByDisplayName = '$.RequestedByDisplayName'
                RequestedByOid = '$.RequestedByOid'
                RequestedOn = '$.RequestedOn'
                SenseMachineId = '$.SenseMachineId'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetNdrMachineExclusionDetails'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetNdrMachineExclusionDetails'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'MachineId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetMachinesWdatp'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/wdatpApi/machines'
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
                aadDeviceId = '$.aadDeviceId'
                agentVersion = '$.agentVersion'
                computerDnsName = '$.computerDnsName'
                deviceValue = '$.deviceValue'
                exclusionReason = '$.exclusionReason'
                exposureLevel = '$.exposureLevel'
                firstSeen = '$.firstSeen'
                healthStatus = '$.healthStatus'
                id = '$.id'
                ipAddressesJson = '$.ipAddresses'
                isAadJoined = '$.isAadJoined'
                IsExcluded = '$.isExcluded'
                isPotentialDuplication = '$.isPotentialDuplication'
                lastExternalIpAddress = '$.lastExternalIpAddress'
                lastIpAddress = '$.lastIpAddress'
                lastSeen = '$.lastSeen'
                machineTagsJson = '$.machineTags'
                ManagedBy = '$.managedBy'
                ManagedByStatus = '$.managedByStatus'
                mergedIntoMachineId = '$.mergedIntoMachineId'
                OnboardingStatus = '$.onboardingStatus'
                osArchitecture = '$.osArchitecture'
                OsBuild = '$.osBuild'
                osPlatform = '$.osPlatform'
                osProcessor = '$.osProcessor'
                rbacGroupId = '$.rbacGroupId'
                rbacGroupName = '$.rbacGroupName'
                riskScore = '$.riskScore'
                version = '$.version'
                vmMetadata = '$.vmMetadata'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetMachinesWdatp'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetMachinesWdatp'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                firstSeen = 'datetime'
                isAadJoined = 'boolean'
                IsExcluded = 'boolean'
                isPotentialDuplication = 'boolean'
                lastSeen = 'datetime'
                OsBuild = 'long'
                rbacGroupId = 'long'
            }
        },
@{
            OperationKey = 'GetSensorCompatibleMachines'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/mdi/tri/defensor/onboarding/devices/sensor_compatible_machines'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetSensorCompatibleMachines'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetSensorCompatibleMachines'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'List'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/ndr/machines'
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
                Mode = 'pageSize'
                ParamLocation = 'query'
                PageSizeQuery = 'pageSize'
                PageSize = 50
                PageIndexQuery = 'pageIndex'
                PageIndexStart = 0
                CursorMode = 'pageIndexIncrement'
                LoopGuard = 1000
                SortByQuery = 'sortByField'
                SortOrderQuery = 'sortOrder'
                SortOrder = 'Descending'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                aadDeviceId = '$.AadDeviceId'
                AdiotPlcKeyState = '$.AdiotPlcKeyState'
                AdiotPlcModeLastUpdate = '$.AdiotPlcModeLastUpdate'
                AdiotPlcRunState = '$.AdiotPlcRunState'
                AdiotProtocolsJson = '$.AdiotProtocols'
                AdiotPurdueLevel = '$.AdiotPurdueLevel'
                AdiotSiteName = '$.AdiotSiteName'
                AdiotSiteTag = '$.AdiotSiteTag'
                AssetInsightsJson = '$.AssetInsights'
                AssetValue = '$.AssetValue'
                CloudResourceDetailsJson = '$.CloudResourceDetails'
                computerDnsName = '$.ComputerDnsName'
                ComputerNetBIOSName = '$.ComputerNetBIOSName'
                CriticalityLevel = '$.CriticalityLevel'
                DataSourcesJson = '$.DataSources'
                DeviceCategory = '$.DeviceCategory'
                DeviceRolesJson = '$.DeviceRoles'
                DeviceSubtype = '$.DeviceSubtype'
                DeviceType = '$.DeviceType'
                DiscoverySourcesJson = '$.DiscoverySources'
                Domain = '$.Domain'
                DynamicAssetValue = '$.DynamicAssetValue'
                DynamicRulesTagsJson = '$.DynamicRulesTags'
                ExclusionState = '$.ExclusionState'
                ExploitLevel = '$.ExploitLevel'
                ExposureScore = '$.ExposureScore'
                FirmwareVersion = '$.FirmwareVersion'
                firstSeen = '$.FirstSeen'
                healthStatus = '$.HealthStatus'
                HvaMode = '$.HvaMode'
                InternalMachineId = '$.InternalMachineId'
                InternetFacingReason = '$.InternetFacingReason'
                isAadJoined = '$.IsAadJoined'
                IsAdiotAuthorized = '$.IsAdiotAuthorized'
                IsAdiotLocalSubnet = '$.IsAdiotLocalSubnet'
                IsAdiotPlcSecured = '$.IsAdiotPlcSecured'
                IsAdiotProgramming = '$.IsAdiotProgramming'
                IsAdiotScanner = '$.IsAdiotScanner'
                IsExcluded = '$.IsExcluded'
                IsInternetFacing = '$.IsInternetFacing'
                IsLowFidelity = '$.IsLowFidelity'
                IsManagedByMdatp = '$.IsManagedByMdatp'
                IsolationState = '$.IsolationState'
                IsTransient = '$.IsTransient'
                IsUsiServer = '$.IsUsiServer'
                lastExternalIpAddress = '$.LastExternalIpAddress'
                lastIpAddress = '$.LastIpAddress'
                LastIpV6Address = '$.LastIpV6Address'
                LastMacAddress = '$.LastMacAddress'
                lastSeen = '$.LastSeen'
                LowFidelitySourcesJson = '$.LowFidelitySources'
                MachineGroup = '$.MachineGroup'
                MachineGuid = '$.MachineGuid'
                machineId = '$.MachineId'
                MachineTags = '$.MachineTags'
                ManagedBy = '$.ManagedBy'
                ManagedByStatus = '$.ManagedByStatus'
                OnboardingStatus = '$.OnboardingStatus'
                OsBuild = '$.OsBuild'
                osPlatform = '$.OsPlatform'
                OsPlatformFriendlyName = '$.OsPlatformFriendlyName'
                OsVersionFriendlyName = '$.OsVersionFriendlyName'
                rbacGroupId = '$.RbacGroupId'
                ReleaseVersion = '$.ReleaseVersion'
                riskScore = '$.RiskScore'
                SecurityScore = '$.SecurityScore'
                SenseGroupId = '$.SenseGroupId'
                SenseMachineId = '$.SenseMachineId'
                SensorNamesJson = '$.SensorNames'
                SensorSite = '$.SensorSite'
                SensorSiteDisplayName = '$.SensorSiteDisplayName'
                SensorType = '$.SensorType'
                SensorZone = '$.SensorZone'
                SystemManufacturer = '$.SystemManufacturer'
                SystemProductName = '$.SystemProductName'
                VulnerabilityAgeLevel = '$.VulnerabilityAgeLevel'
                VulnerabilitySeverityLevel = '$.VulnerabilitySeverityLevel'
                WcdMachineId = '$.WcdMachineId'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.List'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.List'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                firstSeen = 'datetime'
                isAadJoined = 'boolean'
                IsExcluded = 'boolean'
                lastSeen = 'datetime'
                OsBuild = 'long'
                rbacGroupId = 'long'
            }
        },
@{
            OperationKey = 'GetRbacGroups'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/rbacGroupAssignment/machineRbacGroupAssignments/{DeviceId}'
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
                rbacGroupId = '$.rbacGroupId'
                rbacGroupName = '$.rbacGroupName'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetRbacGroups'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetRbacGroups'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'DeviceId'
                MatchKind = 'CurationOverride'
            }
            ColumnTypes = @{
                rbacGroupId = 'long'
            }
        },
@{
            OperationKey = 'GetNdrDeviceTypeDistribution'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/ndr/machines/deviceTypeDistribution'
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
                DeviceCategory = '$.DeviceCategory'
                DeviceType = '$.DeviceType'
                DeviceTypeCount = '$.DeviceTypeCount'
                HighValueAssetTotal = '$.HighValueAssetTotal'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetNdrDeviceTypeDistribution'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetNdrDeviceTypeDistribution'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                DeviceTypeCount = 'long'
                HighValueAssetTotal = 'long'
            }
        },
@{
            OperationKey = 'GetDataSensitivity'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/getDataSensitivity/machines/{MachineId}/dataSensitivity'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetDataSensitivity'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetDataSensitivity'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'MachineId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetMachineTimelineEvents'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/mdeTimelineExperience/machines/{MachineId}/events'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Items'
            Cadence = '01:00:00'
            IngestionMode = 'WINDOW'
            CursorField = $null
            NaturalKey = @()
            TimeFilter = @{
                Mode = 'ServerFromDate'
                FieldName = 'fromDate'
                FromDateParam = 'fromDate'
                ToDateParam = 'toDate'
                ParamLocation = 'query'
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                ActionTime = '$.ActionTime'
                ActionTimeIsoString = '$.ActionTimeIsoString'
                ActionType = '$.ActionType'
                AlertIdsJson = '$.AlertIds'
                CyberActionTypeJson = '$.CyberActionType'
                Description = '$.Description'
                EntitiesJson = '$.Entities'
                HiddenDetailsJson = '$.HiddenDetails'
                Icon = '$.Icon'
                InitiatingProcessJson = '$.InitiatingProcess'
                InitiatingProcessParentJson = '$.InitiatingProcessParent'
                InitiatingUserJson = '$.InitiatingUser'
                IsBoldEvent = '$.IsBoldEvent'
                IsCyberData = '$.IsCyberData'
                MachineJson = '$.Machine'
                MergedItemsReportIdsJson = '$.MergedItemsReportIds'
                MergedItemsReportIdsToTimesJson = '$.MergedItemsReportIdsToTimes'
                MitreInfoJson = '$.MitreInfo'
                ProcessJson = '$.Process'
                RelatedObservationName = '$.RelatedObservationName'
                ReportId = '$.ReportId'
                SourceProvider = '$.SourceProvider'
                tagsJson = '$.Tags'
                TypedDetailsJson = '$.TypedDetails'
                UserJson = '$.User'
            }
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetMachineTimelineEvents'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetMachineTimelineEvents'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'MachineId'
                MatchKind = 'CurationOverride'
            }
            LookbackHours = 168
        },
@{
            OperationKey = 'GetTimeline'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceTimeline/timeline/{DeviceId}'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetTimeline'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetTimeline'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            EntityResolution = 'Resolved'
            DependsOn = @{
                ParentOperationKey = 'GetMachinesWdatp'
                ParentOperationId = 'EndpointDevices.GetMachinesWdatp'
                EntityIdField = 'id'
                ParamName = 'DeviceId'
                MatchKind = 'CurationOverride'
            }
        },
@{
            OperationKey = 'GetLicenseReport'
            Subcategory = 'Endpoint Devices'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/deviceManagement/deviceLicenseReport'
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
            DcrStreamName = 'Custom-Defender_EndpointManagement_CL'
            WorkspaceTable = 'Defender_EndpointManagement_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_ENDPOINTMANAGEMENT'
            Provenance = @{
                OperationId = 'EndpointDevices.GetLicenseReport'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/endpoint_devices.yml#EndpointDevices.GetLicenseReport'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
