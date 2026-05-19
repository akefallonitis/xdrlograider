# Phase 0 Step 5 · DECLARATIVE per-portal mapping · tag → SubArea + DROP rules + Capability annotation
#
# Inputs to tools/Build-CandidateManifest.ps1
#   - SpecRoot           : per-portal nodoc spec dir (relative to repo root)
#   - ExcludeFiles       : yml files to skip when globbing SpecRoot (meta-only)
#   - SpecGroup          : sub-portal split for multi-spec portals (Entra/Intune)
#   - TagMap             : nodoc tag → SubArea (PascalCase auto-mapping for unknown tags)
#   - SubAreaCapability  : SubArea → capability flag (Is<Product>Active) · annotates entries · D-34 portability
#   - DropSubAreas       : sub-areas WHOLESALE excluded per Memory Rule 2
#   - DropOpIdRegex      : per-portal regex matching operationIds to drop (Graph dupes · forbidden)
#   - DropPathRegex      : per-portal regex matching paths to drop (Graph dupes · forbidden)
#   - Rule1CanonicalSubArea : per-Path-collision canonical SubArea (drop the others) · Memory Rule 1 dedup
#
# Memory Rule 1 (ReadSemantics ≠ HTTP method · dedup cross-sub-area Path collisions):
#   - When the same Path appears in multiple SubAreas, the canonical SubArea wins · others dropped.
#
# Memory Rule 2 (LOCKED · NEVER reverse-include):
#   - AdvancedHunting · AlertsIncidents · LiveResponse  ← Defender wholesale-excluded
#
# Decision D-34 (license portability):
#   - Capability flags ANNOTATE entries · do NOT drop · runtime AADSTS500011 surfaces in App Insights.
#
# Decision D-36 (Internal portal access · graph.microsoft.com / graph.windows.net FORBIDDEN)
#
@{
    Defender = @{
        Title         = 'Microsoft Defender XDR'
        Portal        = 'Defender'
        AuthScheme    = 'cookie-sccauth'
        SpecRoot      = 'references/_external/nodoc/specifications/nodoc-defender-xdr/specification'
        ExcludeFiles  = @('openapi.yml','common.yml')  # meta-only · top-level openapi.yml has only $ref stubs
        TagMap        = @{
            'Alerts'                    = 'AlertsIncidents'
            'Incidents'                 = 'AlertsIncidents'
            'Advanced Hunting'          = 'AdvancedHunting'
            'Files'                     = 'Files'
            'Entity Pivots'             = 'EntityPivots'
            'Endpoint Devices'          = 'EndpointDevices'
            'Live Response'             = 'LiveResponse'
            'Endpoint Configuration'    = 'EndpointConfiguration'
            'Vulnerability Management'  = 'VulnerabilityManagement'
            'Identity'                  = 'Identity'
            'Configuration'             = 'Configuration'
            'Exposure Management'       = 'ExposureManagement'
            'Data Lake'                 = 'DataLake'
            'Threat Analytics'          = 'ThreatAnalytics'
            'Action Center'             = 'ActionCenter'
            'Multi-Tenant'              = 'MultiTenant'
            'Streaming API'             = 'Streaming'
            'Secure Score'              = 'SecureScore'
            'Portal Services'           = 'PortalServices'
            'AttackSimulator'           = 'AttackSimulator'
            'CloudApps'                 = 'CloudApps'
            'AppGovernance'             = 'AppGovernance'
            'Sentinel'                  = 'SentinelPrecision'
        }
        DropSubAreas  = @('AdvancedHunting', 'AlertsIncidents', 'LiveResponse')   # Memory Rule 2 WHOLESALE
        DropOpIdRegex = '^(MsGraph|GraphProxy|MicrosoftGraph)\.'
        DropPathRegex = '/(msgraph|GraphProxy)/'
        PathPrefix    = '/apiproxy'   # nodoc Servers URL is https://security.microsoft.com/apiproxy

        # Per Step 4 evidence (operator lab tenant flags · Get-XdrTenantWorkloadStatus) · D-34: annotate, don't drop.
        # SubArea → capability flag in TenantContext snapshot ($Config blob). Lab-tenant flag
        # values are illustrative · production tenants set their own per-license activation.
        SubAreaCapability = @{
            'ActionCenter'             = 'IsMdatpActive'
            'AppGovernance'            = 'IsMdatpActive'
            'AttackSimulator'          = 'IsOatpActive'      # Office 365 ATP · license-gated
            'CloudApps'                = 'IsMcasActive'
            'Configuration'            = 'IsMdatpActive'
            'DataLake'                 = 'IsXspmActive'
            'EndpointConfiguration'    = 'IsMdatpActive'
            'EndpointDevices'          = 'IsMdatpActive'
            'EntityPivots'             = 'IsMdatpActive'
            'ExposureManagement'       = 'IsXspmActive'
            'Files'                    = 'IsMdatpActive'
            'Identity'                 = 'IsMdiActive'       # MDI · license-gated
            'MultiTenant'              = 'IsMtoActive'
            'PortalServices'           = ''                  # portal-level · no specific gate
            'SecureScore'              = ''                  # always available
            'SentinelPrecision'        = ''                  # Sentinel-side
            'Streaming'                = 'IsMdatpActive'
            'ThreatAnalytics'          = 'IsMdatpActive'
            'VulnerabilityManagement'  = 'IsMdatpActive'
        }

        # Memory Rule 1 · Path-collision canonical-SubArea map.
        # When the same Path appears in multiple SubAreas, the listed SubArea wins · others dropped.
        # Format: Path-prefix-regex (case-insensitive) → canonical SubArea
        Rule1CanonicalSubArea = @{
            '^/apiproxy/mcas/cas/api/v1/settings$'  = 'CloudApps'        # observed dupe with Configuration
        }
    }

    Purview = @{
        Title         = 'Microsoft Purview Portal'
        Portal        = 'Purview'
        AuthScheme    = 'cookie-sccauth'
        SpecRoot      = 'references/_external/nodoc/specifications/nodoc-purview/specification'
        ExcludeFiles  = @('openapi.yml','common.yml')
        TagMap        = @{
            'Audit'                      = 'Audit'
            'Auth'                       = 'Auth'
            'Billing'                    = 'Billing'
            'Communication Compliance'   = 'CommunicationCompliance'
            'Compliance Manager'         = 'ComplianceManager'
            'Copilot'                    = 'Copilot'
            'Data Governance'            = 'DataGovernance'
            'Data Infrastructure'        = 'DataInfrastructure'
            'Data Security Investigations' = 'DataSecurityInvestigations'
            'DLP Devices'                = 'DlpDevices'
            'eDiscovery'                 = 'Ediscovery'
            'Exchange Admin'             = 'ExchangeAdmin'
            'Governance Services'        = 'GovernanceServices'
            'Graph Proxy'                = 'GraphProxy'
            'Information Protection'     = 'InformationProtection'
            'Insider Risk'               = 'InsiderRisk'
            'Platform Services'          = 'PlatformServices'
            'Purview for AI'             = 'PurviewForAi'
            'SharePoint'                 = 'Sharepoint'
        }
        DropSubAreas  = @()
        DropOpIdRegex = ''
        DropPathRegex = '/(msgraph|GraphProxy)/v[0-9]+\.[0-9]+/'
        PathPrefix    = '/apiproxy'
        SubAreaCapability = @{}    # Purview-level · operator-tenant determines · v0.2.0 expansion
        Rule1CanonicalSubArea = @{}
    }

    Entra = @{
        Title         = 'Microsoft Entra Admin Center'
        Portal        = 'Entra'
        AuthScheme    = 'bearer-entra'
        IsMultiSpec   = $true
        SpecGroup     = @{
            'IAM'   = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-ibiza-iam/specification';   ExcludeFiles = @('openapi.yml','common.yml') }
            'PIM'   = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-entra-pim/specification';    ExcludeFiles = @() }
            'IDGov' = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-entra-idgov/specification';  ExcludeFiles = @() }
            'IGA'   = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-entra-iga/specification';    ExcludeFiles = @() }
            'B2C'   = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-entra-b2c/specification';    ExcludeFiles = @() }
        }
        TagMap        = @{}   # PascalCase auto-mapping (Entra tag set too broad)
        DropSubAreas  = @()
        DropOpIdRegex = ''
        DropPathRegex = ''
        PathPrefix    = ''   # bearer-auth · no apiproxy prefix
        SubAreaCapability = @{}    # Entra sub-portal license-gating (P1/P2/IGA) · v0.2.0 expansion
        Rule1CanonicalSubArea = @{}
    }

    Intune = @{
        Title         = 'Microsoft Intune Admin Center'
        Portal        = 'Intune'
        AuthScheme    = 'bearer-intune'
        IsMultiSpec   = $true
        SpecGroup     = @{
            'Portal'    = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-intune-portal/specification';    ExcludeFiles = @() }
            'Autopatch' = @{ SpecRoot = 'references/_external/nodoc/specifications/nodoc-intune-autopatch/specification'; ExcludeFiles = @() }
        }
        TagMap        = @{}
        DropSubAreas  = @()
        DropOpIdRegex = ''
        DropPathRegex = ''
        PathPrefix    = ''
    }

    SecurityCopilot = @{
        Title         = 'Microsoft Security Copilot'
        Portal        = 'SecurityCopilot'
        AuthScheme    = 'bearer-securitycopilot'
        SpecRoot      = 'references/_external/nodoc/specifications/nodoc-security-copilot/specification'
        ExcludeFiles  = @()
        TagMap        = @{}
        DropSubAreas  = @()
        DropOpIdRegex = ''
        DropPathRegex = ''
        PathPrefix    = ''
    }
}
