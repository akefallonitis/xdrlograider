# Schema defaults + nodoc taxonomy lookup tables.
# Internal to Xdr.Common.Manifest module. Not exported.

# Per-entry defaults applied at load time. Per-entry values OVERRIDE these.
function Get-XdrManifestDefaults {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        # Portal: LOGICAL name (Defender / Entra / Purview / Intune). Matches
        # the orchestrator's $portal parameter so the entry-level filter
        # (Where-Object { $_.Portal -eq $portal }) works for both single-portal
        # (v0.1.0) and multi-portal (v0.2.0+) topologies. The forward-compat
        # filter is kept on the orchestrator side for v0.2.0 multi-tenant FA
        # which will fan out across MULTIPLE portals' manifests.
        #
        # PortalHost: FQDN of the portal endpoint host. Used by L2 auth modules
        # (Connect-DefenderPortal -> Session.PortalHost) for URL construction.
        # Decoupling logical name from FQDN prevents the cast conflict that
        # surfaced in the v0.1.0 GA preflight (live audit 2026-05-06):
        # Defaults set Portal='security.microsoft.com' (FQDN) but orchestrator
        # passed Portal='Defender' (logical) - they never matched -> 0 streams.
        Portal                  = 'Defender'                  # logical portal name (orchestrator filter target)
        PortalHost              = 'security.microsoft.com'    # FQDN endpoint host (auth-session URL construction)
        MFAMethodsSupported     = @('CredentialsTotp', 'Passkey')
        AuditScope              = 'portal-only'
        IdProperty              = $null                       # null -> Expand-MDEResponse heuristic
        ProjectionMap           = @{}                         # populated per-stream
        SchemaSource            = 'live-capture'              # Phase E directive 15
        StreamSubtype           = 'portal-api'                # v0.2.0 adds 'xdrinternals' / 'hybrid'
        SnapshotDedupRationale  = 'snapshot-replace'          # Phase I directive 32
    }
}

# Nodoc 10-category authoritative taxonomy.
# Maps NodocCategoryId (1-10) to (Slug, PascalName) tuple.
# Slug is kebab-case (ARM-stable identifier). PascalName drives Defender_<PascalName>_CL
# table naming for Phase J consolidation.
function Get-XdrNodocCategoryMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        1  = @{ Slug = 'endpoint-device-management';   PascalName = 'EndpointDeviceManagement';   FullName = 'Endpoint Device Management' }
        2  = @{ Slug = 'endpoint-configuration';        PascalName = 'EndpointConfiguration';       FullName = 'Endpoint Configuration' }
        3  = @{ Slug = 'vulnerability-management';      PascalName = 'VulnerabilityManagement';     FullName = 'Vulnerability Management (TVM)' }
        4  = @{ Slug = 'identity-protection';           PascalName = 'IdentityProtection';          FullName = 'Identity Protection (MDI)' }
        5  = @{ Slug = 'configuration-and-settings';    PascalName = 'ConfigurationAndSettings';    FullName = 'Configuration and Settings' }
        6  = @{ Slug = 'exposure-management';           PascalName = 'ExposureManagement';          FullName = 'Exposure Management (XSPM)' }
        7  = @{ Slug = 'threat-analytics';              PascalName = 'ThreatAnalytics';             FullName = 'Threat Analytics' }
        8  = @{ Slug = 'action-center';                 PascalName = 'ActionCenter';                FullName = 'Action Center' }
        9  = @{ Slug = 'multi-tenant-operations';       PascalName = 'MultiTenantOperations';       FullName = 'Multi-Tenant Operations' }
        10 = @{ Slug = 'streaming-api';                 PascalName = 'StreamingApi';                FullName = 'Streaming API' }
    }
}

# Mandatory fields per manifest entry. Loader skips entries missing any of these.
function Get-XdrManifestMandatoryFields {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @('Stream', 'Path', 'Tier', 'Category', 'Purpose', 'Availability')
}

# Portal name -> client module name mapping.
# Used to resolve manifest path: <repo>/src/Modules/<ClientModule>/endpoints.manifest.psd1
function Get-XdrPortalClientModuleMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        Defender = 'Xdr.Defender.Client'
        Entra    = 'Xdr.Entra.Client'    # v0.2.0
        Purview  = 'Xdr.Purview.Client'  # v0.2.0
        Intune   = 'Xdr.Intune.Client'   # v0.2.0
    }
}
