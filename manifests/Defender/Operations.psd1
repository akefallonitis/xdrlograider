# manifests/Defender/Operations.psd1 · GENERATED from references/inventory/nodoc-defender-xdr/catalogue.json (plan v12 §6.2).
# DO NOT hand-edit · re-run dev-tools/Generate-Manifest.ps1. Category = nodoc x-tagGroups GROUP; Subcategory = tag.
# NO IsActive flag · runtime dispatch via plan §4.7 4-gate model.
@{
    Portal   = 'Defender'
    Category = 'Operations'
    Operations = @(
@{
            OperationKey = 'GetPending'
            Subcategory = 'Action Center'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/actionCenter/actioncenterui/pending-actions'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Results'
            Cadence = '00:10:00'
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
                PageIndexStart = 1
                CursorMode = 'pageIndexIncrement'
                LoopGuard = 1000
                SortByQuery = 'sortByField'
                SortOrderQuery = 'sortOrder'
                SortOrder = 'Descending'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                ActionAutomationType = '$.ActionAutomationType'
                ActionDecision = '$.ActionDecision'
                ActionId = '$.ActionId'
                ActionSource = '$.ActionSource'
                ActionStatus = '$.ActionStatus'
                ActionType = '$.ActionType'
                AdditionalFieldsJson = '$.AdditionalFields'
                Comment = '$.Comment'
                ComputerName = '$.ComputerName'
                DecidedBy = '$.DecidedBy'
                EndTime = '$.EndTime'
                EntityType = '$.EntityType'
                EventTime = '$.EventTime'
                InvestigationId = '$.InvestigationId'
                MachineId = '$.MachineId'
                Product = '$.Product'
                RelatedEntitiesJson = '$.RelatedEntities'
                StartTime = '$.StartTime'
                UserPrincipalName = '$.UserPrincipalName'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'ActionCenter.GetPending'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/action_center.yml#ActionCenter.GetPending'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                EventTime = 'datetime'
                StartTime = 'datetime'
            }
        },
@{
            OperationKey = 'ListAutomationRules'
            Subcategory = 'Action Center'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/automation/internal/automation/{TenantId}/automationRules'
            ResponseShape = 'bareArray'
            ItemsContainer = $null
            Cadence = '00:10:00'
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
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'ActionCenter.ListAutomationRules'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/action_center.yml#ActionCenter.ListAutomationRules'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetHistory'
            Subcategory = 'Action Center'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/actionCenter/actioncenterui/history-actions'
            ResponseShape = 'wrapper'
            ItemsContainer = 'Results'
            Cadence = '00:10:00'
            IngestionMode = 'CURSOR'
            CursorField = 'EventTime'
            NaturalKey = @('ActionId')
            TimeFilter = @{
                Mode = 'ClientSideHighWater'
                FieldName = 'EventTime'
            }
            Pagination = @{
                Mode = 'pageSize'
                ParamLocation = 'query'
                PageSizeQuery = 'pageSize'
                PageSize = 50
                PageIndexQuery = 'pageIndex'
                PageIndexStart = 1
                CursorMode = 'pageIndexIncrement'
                LoopGuard = 1000
                SortByQuery = 'sortByField'
                SortOrderQuery = 'sortOrder'
                SortOrder = 'Descending'
                TotalCountPath = 'Count'
                SortByField = 'EventTime'
                StopWhenCursorPassed = $true
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                ActionAutomationType = '$.ActionAutomationType'
                ActionDecision = '$.ActionDecision'
                ActionId = '$.ActionId'
                ActionSource = '$.ActionSource'
                ActionStatus = '$.ActionStatus'
                ActionType = '$.ActionType'
                AdditionalFieldsJson = '$.AdditionalFields'
                Comment = '$.Comment'
                ComputerName = '$.ComputerName'
                DecidedBy = '$.DecidedBy'
                EndTime = '$.EndTime'
                EntityType = '$.EntityType'
                EventTime = '$.EventTime'
                InvestigationId = '$.InvestigationId'
                MachineId = '$.MachineId'
                Product = '$.Product'
                RelatedEntitiesJson = '$.RelatedEntities'
                StartTime = '$.StartTime'
                UserPrincipalName = '$.UserPrincipalName'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'ActionCenter.GetHistory'
                Live = 'references/live/source-xdrlograider-raw/MDE_ActionCenter_CL-raw.json'
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/action_center.yml#ActionCenter.GetHistory'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                EventTime = 'datetime'
                StartTime = 'datetime'
            }
        },
@{
            OperationKey = 'GetEffectiveTenantGroup'
            Subcategory = 'Multi-Tenant'
            Method = 'GET'
            SubPortal = 'mtoapi'
            Path = '/tenantGroups/effective/'
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
            RequiresProducts = @('MTO')
            ProjectionMap = @{
                etag_x = '$._etag'
                allTenantsCount = '$.allTenantsCount'
                creationTime = '$.creationTime'
                description = '$.description'
                EntityType = '$.entityType'
                exposedTargetTenantsInfoJson = '$.exposedTargetTenantsInfo'
                id = '$.id'
                lastUpdated = '$.lastUpdated'
                lastUpdatedByUpn = '$.lastUpdatedByUpn'
                name = '$.name'
                tenantGroupId = '$.tenantGroupId'
                tenantId_x = '$.tenantId'
                ttl = '$.ttl'
                type_x = '$.type'
                userId = '$.userId'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'MultiTenant.GetEffectiveTenantGroup'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/multi_tenant.yml#MultiTenant.GetEffectiveTenantGroup'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetTenantContext'
            Subcategory = 'Multi-Tenant'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/sccManagement/mgmt/TenantContext'
            ResponseShape = 'singleObject'
            ItemsContainer = $null
            Cadence = '06:00:00'
            IngestionMode = 'SNAPSHOT'
            CursorField = $null
            NaturalKey = @('OrgId')
            TimeFilter = @{
                Mode = 'None'
                FieldName = $null
            }
            Pagination = @{
                Mode = 'none'
            }
            RequiresProducts = @('MDE')
            ProjectionMap = @{
                AadIpMtpPermissionsJson = '$.AadIpMtpPermissions'
                AatpIntegrationEnabled = '$.AatpIntegrationEnabled'
                AatpWorkspaceExists = '$.AatpWorkspaceExists'
                AccountMode = '$.AccountMode'
                AccountType = '$.AccountType'
                ActiveMtpWorkloadsJson = '$.ActiveMtpWorkloads'
                AdIotIntegrationStatus = '$.AdIotIntegrationStatus'
                AdminMisconduct = '$.AdminMisconduct'
                AllowedActions = '$.AllowedActions'
                AuthInfoJson = '$.AuthInfo'
                AutomatedIrLiveResponse = '$.AutomatedIrLiveResponse'
                DataCenter = '$.DataCenter'
                DirRolesJson = '$.DirRoles'
                DlpMtpPermissionsJson = '$.DlpMtpPermissions'
                EnvironmentName = '$.EnvironmentName'
                ExcludeSentinelAlertsFromXDRCorrelation = '$.ExcludeSentinelAlertsFromXDRCorrelation'
                ExposedSentinelWorkspacesJson = '$.ExposedSentinelWorkspaces'
                FeaturesJson = '$.Features'
                GeoRegion = '$.GeoRegion'
                HasFinishedPostOnboardingForSmb = '$.HasFinishedPostOnboardingForSmb'
                HasMachineGroups = '$.HasMachineGroups'
                IotFlavor = '$.IotFlavor'
                IrmMtpPermissionsJson = '$.IrmMtpPermissions'
                IsAadIpActive = '$.IsAadIpActive'
                IsAutomatedIrEnabled = '$.IsAutomatedIrEnabled'
                IsBilbaoTenant = '$.IsBilbaoTenant'
                IsDeceptionEnabled = '$.IsDeceptionEnabled'
                IsDeleted = '$.IsDeleted'
                IsDexLicense = '$.IsDexLicense'
                IsDlpActive = '$.IsDlpActive'
                IsEnhancedTelemetryEnabled = '$.IsEnhancedTelemetryEnabled'
                IsEvaluationEnabled = '$.IsEvaluationEnabled'
                IsExposedToAllMachineGroups = '$.IsExposedToAllMachineGroups'
                IsIrmActive = '$.IsIrmActive'
                IsIsolationExclusionOptIn = '$.IsIsolationExclusionOptIn'
                IsItpActive = '$.IsItpActive'
                IsMapgActive = '$.IsMapgActive'
                IsMdatpActive = '$.IsMdatpActive'
                IsMdatpLicenseExpired = '$.IsMdatpLicenseExpired'
                IsMdcActive = '$.IsMdcActive'
                IsMdiActive = '$.IsMdiActive'
                IsMtpEligible = '$.IsMtpEligible'
                IsOatpActive = '$.IsOatpActive'
                IsOnboardingComplete = '$.IsOnboardingComplete'
                IsPermittedOnboarding = '$.IsPermittedOnboarding'
                IsSecurityCopilotHasLicense = '$.IsSecurityCopilotHasLicense'
                IsSentinelActive = '$.IsSentinelActive'
                IsSiemEnabled = '$.IsSiemEnabled'
                IsSuspended = '$.IsSuspended'
                IsTvmEligible = '$.IsTvmEligible'
                IsTvmEnabled = '$.IsTvmEnabled'
                IsTvmOnboardingComplete = '$.IsTvmOnboardingComplete'
                IsTvmPremiumDfsP2Enabled = '$.IsTvmPremiumDfsP2Enabled'
                ItpMtpPermissionsJson = '$.ItpMtpPermissions'
                KustoHotStorageInDays = '$.KustoHotStorageInDays'
                MagellanOptOut = '$.MagellanOptOut'
                MapgMtpPermissionsJson = '$.MapgMtpPermissions'
                MdatpMtpPermissionsJson = '$.MdatpMtpPermissions'
                MdcMtpPermissionsJson = '$.MdcMtpPermissions'
                MdeFlavor = '$.MdeFlavor'
                MdiMtpPermissionsJson = '$.MdiMtpPermissions'
                MdIotM365IntegrationStatus = '$.MdIotM365IntegrationStatus'
                MixedLicenseMode = '$.MixedLicenseMode'
                MtpConsent = '$.MtpConsent'
                MtpPermissionsJson = '$.MtpPermissions'
                OatpMtpPermissionsJson = '$.OatpMtpPermissions'
                OnboardingTileDismissed = '$.OnboardingTileDismissed'
                OrgId = '$.OrgId'
                OtFlavor = '$.OtFlavor'
                RedirectAlertsToAttackStory = '$.RedirectAlertsToAttackStory'
                RolesJson = '$.Roles'
                SecurityCopilotLicenseStatus = '$.SecurityCopilotLicenseStatus'
                SentinelMtpPermissionsJson = '$.SentinelMtpPermissions'
                ServiceUrlsJson = '$.ServiceUrls'
                TvmLicensesJson = '$.TvmLicenses'
                UserAuthEnforcementMode = '$.UserAuthEnforcementMode'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'MultiTenant.GetTenantContext'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/multi_tenant.yml#MultiTenant.GetTenantContext'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
            ColumnTypes = @{
                AatpIntegrationEnabled = 'boolean'
                AatpWorkspaceExists = 'boolean'
                AccountMode = 'long'
                AllowedActions = 'long'
                AutomatedIrLiveResponse = 'boolean'
                HasFinishedPostOnboardingForSmb = 'boolean'
                HasMachineGroups = 'boolean'
                IsAadIpActive = 'boolean'
                IsAutomatedIrEnabled = 'boolean'
                IsBilbaoTenant = 'boolean'
                IsDeceptionEnabled = 'boolean'
                IsDeleted = 'boolean'
                IsDexLicense = 'boolean'
                IsDlpActive = 'boolean'
                IsEvaluationEnabled = 'boolean'
                IsExposedToAllMachineGroups = 'boolean'
                IsIrmActive = 'boolean'
                IsIsolationExclusionOptIn = 'boolean'
                IsItpActive = 'boolean'
                IsMapgActive = 'boolean'
                IsMdatpActive = 'boolean'
                IsMdatpLicenseExpired = 'boolean'
                IsMdcActive = 'boolean'
                IsMdiActive = 'boolean'
                IsMtpEligible = 'boolean'
                IsOatpActive = 'boolean'
                IsOnboardingComplete = 'boolean'
                IsPermittedOnboarding = 'boolean'
                IsSecurityCopilotHasLicense = 'boolean'
                IsSentinelActive = 'boolean'
                IsSiemEnabled = 'boolean'
                IsSuspended = 'boolean'
                IsTvmEligible = 'boolean'
                IsTvmEnabled = 'boolean'
                IsTvmOnboardingComplete = 'boolean'
                IsTvmPremiumDfsP2Enabled = 'boolean'
                KustoHotStorageInDays = 'long'
                MagellanOptOut = 'boolean'
                MtpConsent = 'boolean'
                OnboardingTileDismissed = 'boolean'
                RedirectAlertsToAttackStory = 'boolean'
            }
        },
@{
            OperationKey = 'ListTenantGroups'
            Subcategory = 'Multi-Tenant'
            Method = 'GET'
            SubPortal = 'mtoapi'
            Path = '/tenantGroups'
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
            RequiresProducts = @('MTO')
            ProjectionMap = @{
                etag_x = '$._etag'
                allTenantsCount = '$.allTenantsCount'
                creationTime = '$.creationTime'
                description = '$.description'
                EntityType = '$.entityType'
                exposedTargetTenantsInfoJson = '$.exposedTargetTenantsInfo'
                id = '$.id'
                lastUpdated = '$.lastUpdated'
                lastUpdatedByUpn = '$.lastUpdatedByUpn'
                name = '$.name'
                tenantGroupId = '$.tenantGroupId'
                tenantId_x = '$.tenantId'
                ttl = '$.ttl'
                type_x = '$.type'
                userId = '$.userId'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'MultiTenant.ListTenantGroups'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/multi_tenant.yml#MultiTenant.ListTenantGroups'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetWorkloadStatus'
            Subcategory = 'Multi-Tenant'
            Method = 'GET'
            SubPortal = 'mtoapi'
            Path = '/tenants/{TenantId}/workloadStatus'
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
            RequiresProducts = @('MTO')
            ProjectionMap = @{
                tenantId_x = '$.tenantId'
                workloadsJson = '$.workloads'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'MultiTenant.GetWorkloadStatus'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/multi_tenant.yml#MultiTenant.GetWorkloadStatus'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'ListAssignments'
            Subcategory = 'Multi-Tenant'
            Method = 'GET'
            SubPortal = 'mtoapi'
            Path = '/assignments'
            ResponseShape = 'wrapper'
            ItemsContainer = 'items'
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
            RequiresProducts = @('MTO')
            ProjectionMap = @{
                createdBy = '$.createdBy'
                createdOn = '$.createdOn'
                description = '$.description'
                eTag = '$.eTag'
                id = '$.id'
                isVariablePerTemplate = '$.isVariablePerTemplate'
                lastSyncedBy = '$.lastSyncedBy'
                lastSyncedOn = '$.lastSyncedOn'
                name = '$.name'
                syncUnitStatusesJson = '$.syncUnitStatuses'
                targetTenantIdsJson = '$.targetTenantIds'
                targetTenantIdsWithoutRelationship = '$.targetTenantIdsWithoutRelationship'
                templatesJson = '$.templates'
                templateVariablesJson = '$.templateVariables'
                variablesJson = '$.variables'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'MultiTenant.ListAssignments'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/multi_tenant.yml#MultiTenant.ListAssignments'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        },
@{
            OperationKey = 'GetConfiguration'
            Subcategory = 'Streaming API'
            Method = 'GET'
            SubPortal = 'mtp'
            Path = '/streamingapi/streamingApiConfiguration'
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
                destinationsJson = '$.destinations'
                isEnabled = '$.isEnabled'
            }
            DcrStreamName = 'Custom-Defender_Operations_CL'
            WorkspaceTable = 'Defender_Operations_CL'
            DceEndpoint = '<env:DCE_ENDPOINT>'
            DcrImmutableIdEnvVar = 'XDRLR_DCR_DEFENDER_OPERATIONS'
            Provenance = @{
                OperationId = 'StreamingApi.GetConfiguration'
                Live = $null
                Postman = 'references/postman/defender.collection.json'
                OpenApi = 'references/openapi/nodoc-defender-xdr/specification/streaming.yml#StreamingApi.GetConfiguration'
                DerivedFrom = 'catalogue.json (v12 6-stage engine)'
            }
        }
    )
}
