# Enrich-AllPortals-ValueProps.ps1
# Add value-props for ALL portal sub-areas + proper auth-method finding.

#Requires -Version 7.0
[CmdletBinding()] param(
    [string]$ReferencesRoot = "$PSScriptRoot\..\references"
)

# ---------------------------------------------------------------------------
# Per-portal sub-area value props
# ---------------------------------------------------------------------------
$portalValueProps = @{
    'defender' = @{
        'action_center'           = 'Audit trail of auto-IR responses + pending operator approvals — compliance answer to "who approved what response when"'
        'attack_simulator'        = 'Phishing simulation campaigns + training completion — security-awareness program metrics'
        'cloud_apps'              = 'MCAS app inventory + governance — shadow IT discovery, OAuth app sprawl, DLP enforcement'
        'configuration'           = 'Tenant-wide config drift detection: suppression rules, alert tuning, custom detections, RBAC, TI indicators — the audit gap Microsoft does NOT close'
        'data_lake'               = 'Defender Data Lake state + advanced hunting data lifecycle (residency + retention compliance)'
        'endpoint_configuration'  = 'ASR rules, AV policy bodies, Tamper Protection state, EDR-block, web content filtering — endpoint security posture drift'
        'endpoint_devices'        = 'Device inventory with risk + exposure scores; foundation for cross-table joins (Host.MdatpId is the universal join key)'
        'entity_pivots'           = 'On-demand entity context lookups — operator drill-down support'
        'exposure_management'     = 'XSPM attack paths + chokepoints + asset rules + posture metrics — proactive risk posture'
        'files'                   = 'File prevalence + reputation — forensic context for incidents involving binaries'
        'identity'                = 'MDI surface: DSA, DC sensor coverage, dormant accounts, lateral movement paths, alert thresholds — identity-side drift'
        'multi_tenant'            = 'MTO tenant inventory + workload status — MSSP-grade visibility'
        'portal_services'         = 'Portal-side service state (rarely-changed; informational)'
        'secure_score'            = 'Per-category secure score breakdown + historical trend (DCSPM, TVM SCA, V2 control profiles) — Graph only covers overall score history'
        'sentinel_precision'      = 'Sentinel-Defender integration state — cross-portal correlation health'
        'streaming'               = 'Defender XDR Streaming API destinations — audit data egress'
        'threat_analytics'        = 'Threat outbreaks + enriched data + top threats — proactive intel correlation'
        'vulnerability_management'= 'CVE inventory + software inventory + recommendations + advisories — TVM drift detection'
    }
    'purview' = @{
        'audit'                       = 'Unified audit log search history + audit enablement state — compliance backbone'
        'billing'                     = 'Purview billing config + license usage telemetry'
        'communication_compliance'    = 'Communication compliance policy state + review history (eDiscovery for messaging)'
        'compliance_manager'          = 'Compliance assessments + control mapping + improvement actions'
        'copilot'                     = 'Purview Copilot configuration state'
        'data_governance'             = 'Data Governance Services state + classification settings'
        'data_infrastructure'         = 'Entity discovery + asset search + lineage backbone'
        'data_security_investigations'= 'DSI cases + investigation telemetry'
        'dlp_devices'                 = 'Endpoint DLP policy state + device coverage'
        'ediscovery'                  = 'eDiscovery cases + custodians + holds + exports — legal-hold audit trail'
        'exchange_admin'              = 'Exchange admin bridge into Purview'
        'governance_services'         = 'Authorization + DLM + classification framework state'
        'graph_proxy'                 = 'Microsoft Graph proxy used by Purview portal'
        'information_protection'      = 'Sensitivity labels + retention policies — info-protection posture'
        'insider_risk'                = 'Insider risk policies + cases + scoring — behavioral risk telemetry'
        'platform_services'           = 'Shell + IRIS + Azure Purview platform state'
        'purview_for_ai'              = 'DSPM for AI + oversharing assessments + AI governance posture'
        'sharepoint'                  = 'SharePoint integration state inside Purview'
        'openapi'                     = 'Aggregated Purview operations across sub-areas (catalog-level)'
    }
    'entra-ibiza-iam' = @{
        'account_sku'              = 'License SKU inventory + assignment state per user — license audit'
        'application_insights'     = 'App Insights telemetry config for Entra'
        'application_proxy'        = 'On-prem app publishing config + connector health'
        'application_sso'          = 'SSO configurations per app — federation drift'
        'applications'             = 'App registration inventory'
        'authentication_methods'   = 'TOTP/FIDO2/Windows Hello/passkey registrations per user — MFA posture audit'
        'b2b'                      = 'B2B guest invitation + management state'
        'b2c'                      = 'B2C tenant link to Entra (if any)'
        'claim_providers'          = 'Custom claim provider configs'
        'classic_policies'         = 'Legacy classic Entra ID policies (pre-CA)'
        'data_insights'            = 'Entra data insights telemetry'
        'devices'                  = 'Entra-joined/registered device inventory + sync state'
        'directories'              = 'Tenant directory metadata + cross-tenant settings'
        'document_processor_tasks' = 'Entra document processing pipeline state'
        'enterprise_applications'  = 'Service principal + OAuth grant inventory — third-party app sprawl'
        'gdpr'                     = 'Data subject request inventory + completion state'
        'groups'                   = 'Group inventory + dynamic group rules + membership drift'
        'managed_applications'     = 'Microsoft-managed apps (preconfigured) in tenant'
        'mdm_applications'         = 'MDM app integration state'
        'microsoft_entra_connect'  = 'AAD Connect sync state'
        'misc'                     = 'Miscellaneous Entra portal operations'
        'multifactor_authentication' = 'Per-user MFA settings + Conditional Access overlap — auth posture'
        'named_networks'           = 'Named location definitions for CA — network posture'
        'password_reset'           = 'SSPR config + reset history'
        'permissions'              = 'Permission grants + consent inventory'
        'policies'                 = 'Conditional Access + IdProtection + crossTenant policies — auth-policy drift'
        'registered_applications'  = 'Single-tenant + multi-tenant app registrations'
        'reports'                  = 'Entra reports (sign-in / risky users / etc.)'
        'request_approvals'        = 'PIM activation request inventory'
        'roles'                    = 'Built-in + custom role definitions + assignments'
        'security_defaults'        = 'Security Defaults enablement + bypass user list'
        'users'                    = 'User inventory + risk state + AAL+'
    }
    'entra-b2c' = @{
        'openapi'                  = 'Entra B2C tenant policies + custom policies + user flow inventory'
    }
    'entra-iga' = @{
        'openapi'                  = 'Identity Governance & Administration: entitlement management catalogs, access packages, assignment policies'
    }
    'entra-idgov' = @{
        'openapi'                  = 'Access Reviews: review definitions, decisions, completion state'
    }
    'entra-pim' = @{
        'openapi'                  = 'Privileged Identity Management: eligible+active assignments, role activation history, just-in-time access — privileged access audit'
    }
    'intune-portal' = @{
        'openapi'                  = 'Intune admin center same-origin portal API (5 paths — research-gap; needs expansion)'
    }
    'intune-autopatch' = @{
        'openapi'                  = 'Windows Autopatch: MDM app settings, tenant enrollment, admin actions, RBAC scope tags, deployment rings'
    }
    'm365-admin' = @{
        'agents'                   = 'M365 Copilot agents inventory'
        'app_settings'             = 'M365 application configuration state per workload'
        'billing'                  = 'M365 billing + license utilization'
        'company_settings'         = 'Tenant company profile + branding'
        'content_understanding'    = 'SharePoint Premium content understanding telemetry'
        'copilot'                  = 'M365 Copilot configuration state'
        'domains'                  = 'Custom domain inventory + verification status'
        'edge'                     = 'Edge browser tenant config + bookmarks'
        'features'                 = 'M365 feature toggles + preview state'
        'graph_proxy'              = 'Microsoft Graph proxy via admin center'
        'health'                   = 'Service health incidents + advisories'
        'identity_security'        = 'Identity security signals from admin POV'
        'integrated_apps'          = 'Integrated apps inventory (consented apps surface)'
        'miscellaneous'            = 'Misc admin operations'
        'navigation'               = 'Admin center navigation tree config'
        'partners'                 = 'Partner (CSP) relationship inventory'
        'purview'                  = 'Purview integration surfaces from admin center'
        'reports'                  = 'M365 usage + activity reports'
        'search'                   = 'Microsoft Search config + query analytics'
        'security_settings'        = 'Security settings exposed to global admin'
        'tenant'                   = 'Tenant-level config + tenant relationships'
        'tenant_relationships'     = 'GDAP + delegated admin relationships'
        'users_groups'             = 'User + group management ops'
        'viva'                     = 'Viva module configs'
    }
    'm365-apps-config' = @{
        'openapi'                  = 'M365 Apps cloud-attached config (Office apps update channels, feature toggles, GPO replacement)'
    }
    'm365-apps-inventory' = @{
        'openapi'                  = 'M365 Apps deployed-version inventory + health telemetry per device + user'
    }
    'm365-apps-services' = @{
        'openapi'                  = 'M365 Apps shared services API (cross-app config)'
    }
    'power-platform' = @{
        'admin_analytics'          = 'Power Platform admin analytics (Power Apps + Flows usage)'
        'admin_portal'             = 'Admin portal session + bootstrap state'
        'business_app_platform'    = 'BAP core (environments, datapolicies)'
        'config_analytics'         = 'Config analytics telemetry'
        'dynamics_crm'             = 'Dynamics 365 environments + entity inventory + customizations'
        'licensing'                = 'PP license assignment + usage'
        'notification_service'     = 'PP notification service state'
        'power_pages_portal_infra' = 'Power Pages portal infrastructure'
        'tenant_api'               = 'Tenant-level PP API'
    }
    'security-copilot' = @{
        'openapi'                  = 'Security Copilot prompts + skills + plugins + agent telemetry (cross-product AI assistant config)'
    }
    'sharepoint' = @{
        'openapi'                  = 'SharePoint Online admin: tenant settings, sharing controls, hub registration, retention policies'
    }
    'teams' = @{
        'openapi'                  = 'Teams admin: policies (messaging/meeting/calling/app), users, devices, calling plan inventory'
    }
    'exchange' = @{
        'openapi'                  = 'Exchange admin center beta API — out-of-scope (Microsoft Graph covers most of this)'
    }
    'viva' = @{
        'openapi'                  = 'Viva Engage (Yammer-replacement) — low operator-value priority for v0.1.0'
    }
}

# ---------------------------------------------------------------------------
# Per-portal auth-method research finding
# ---------------------------------------------------------------------------
$portalAuthFinding = @{
    'defender'         = @{ AuthFlow='OIDC form_post → sccauth+XSRF cookies'; AuthMethod='unattended-TOTP-or-passkey-cookie'; Status='live-verified-via-Get-EntraEstsAuth'; ImplementationModule='Xdr.Defender.Auth' }
    'purview'          = @{ AuthFlow='OIDC form_post → sccauth+XSRF cookies (shares Defender ClientId 80ccca67-...)'; AuthMethod='unattended-TOTP-or-passkey-cookie'; Status='live-verified-via-Get-EntraEstsAuth'; ImplementationModule='Xdr.Defender.Auth — reuses for purview.microsoft.com' }
    'teams'            = @{ AuthFlow='OIDC form_post → TAC cookies'; AuthMethod='unattended-TOTP-or-passkey-cookie'; Status='auth-verified; per-path API hosts override (research-gap for v0.2.0g)'; ImplementationModule='Xdr.Teams.Auth (v0.2.0g)' }
    'intune-portal'    = @{ AuthFlow='MSAL.js SPA; backend = Bearer'; AuthMethod='NOT-unattended-TOTP (ROPC blocked by AADSTS50076 MFA policy; needs device-code or refresh-token-cache)'; Status='programmatic-TOTP-auth-PROVEN-NOT-POSSIBLE-via-ROPC; needs interactive-bootstrap + refresh-token-cache OR Playwright'; ImplementationModule='Xdr.Intune.Auth (v0.2.0d) — design: stored-refresh-token-in-KV + auto-refresh' }
    'intune-autopatch' = @{ AuthFlow='Bearer-token API at services.autopatch.microsoft.com'; AuthMethod='Same as intune-portal — Bearer token acquired via Intune MSAL.js flow'; Status='ROPC AADSTS50076-blocked; needs device-code-bootstrap'; ImplementationModule='Xdr.Intune.Auth (v0.2.0d)' }
    'entra-ibiza-iam'  = @{ AuthFlow='MSAL.js SPA at entra.microsoft.com; backend Bearer at main.iam.ad.ext.azure.com'; AuthMethod='NOT-unattended-TOTP (ROPC blocked)'; Status='programmatic-TOTP-auth-PROVEN-NOT-POSSIBLE-via-ROPC'; ImplementationModule='Xdr.Entra.Auth (v0.2.0b) — design: refresh-token-cache' }
    'entra-pim'        = @{ AuthFlow='Bearer at api.azrbac.mspim.azure.com'; AuthMethod='Bearer token via PIM-scoped MSAL flow'; Status='ROPC-blocked'; ImplementationModule='Xdr.Entra.Auth (v0.2.0b)' }
    'entra-b2c'        = @{ AuthFlow='Bearer at main.b2cadmin.ext.azure.com'; AuthMethod='Bearer via Azure-portal MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.Entra.Auth (v0.2.0b)' }
    'entra-iga'        = @{ AuthFlow='Bearer at elm.iga.azure.com'; AuthMethod='Bearer via Entra MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.Entra.Auth (v0.2.0b)' }
    'entra-idgov'      = @{ AuthFlow='Bearer at api.accessreviews.identitygovernance.azure.com'; AuthMethod='Bearer via Entra MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.Entra.Auth (v0.2.0b)' }
    'm365-admin'       = @{ AuthFlow='MSAL.js SPA at admin.microsoft.com; backend Bearer at admin.cloud.microsoft'; AuthMethod='NOT-unattended-TOTP (ROPC AADSTS50076-blocked for app 00000006-0000-0ff1-ce00-000000000000)'; Status='ROPC-blocked'; ImplementationModule='Xdr.M365Admin.Auth (v0.2.0f)' }
    'm365-apps-config'    = @{ AuthFlow='Bearer at config.office.com'; AuthMethod='Bearer via M365 admin MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.M365Admin.Auth (v0.2.0f)' }
    'm365-apps-inventory' = @{ AuthFlow='Bearer at query.inventory.insights.office.net'; AuthMethod='Bearer via M365 admin MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.M365Admin.Auth (v0.2.0f)' }
    'm365-apps-services'  = @{ AuthFlow='Bearer at clients.config.office.net'; AuthMethod='Bearer via M365 admin MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.M365Admin.Auth (v0.2.0f)' }
    'power-platform'   = @{ AuthFlow='MSAL.js SPA at admin.powerplatform.microsoft.com; per-tenant backend host overrides'; AuthMethod='Bearer via MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.PowerPlatform.Auth (v0.2.0e)' }
    'security-copilot' = @{ AuthFlow='SPA shell at securitycopilot.microsoft.com; backend Bearer at api.securitycopilot.microsoft.com (also api.medeina-ppe.defender.microsoft.com)'; AuthMethod='Bearer via MSAL'; Status='ROPC-blocked'; ImplementationModule='Xdr.SecurityCopilot.Auth (v0.2.0h)' }
    'sharepoint'       = @{ AuthFlow='{tenant}-admin.sharepoint.com — SharePoint Online admin (FedAuth cookie pattern)'; AuthMethod='form-post + FedAuth cookie (similar to Defender)'; Status='not-yet-probed; ClientId TBD; LIKELY unattended-TOTP-compatible (cookie flow)'; ImplementationModule='Xdr.SharePoint.Auth (v0.2.0g)' }
    'exchange'         = @{ AuthFlow='admin.exchange.microsoft.com'; AuthMethod='Graph covers'; Status='out-of-scope'; ImplementationModule='(none — Graph)' }
    'viva'             = @{ AuthFlow='engage.cloud.microsoft GraphQL'; AuthMethod='low priority'; Status='deferred'; ImplementationModule='(none — defer)' }
}

# ---------------------------------------------------------------------------
# Walk + update
# ---------------------------------------------------------------------------
$portalDirs = Get-ChildItem -Path $ReferencesRoot -Directory
foreach ($pd in $portalDirs) {
    $portalKey = $pd.Name
    $authFinding = $portalAuthFinding[$portalKey]

    # Update each sub-area
    Get-ChildItem -Path $pd.FullName -Directory | ForEach-Object {
        $saIndexPath = Join-Path $_.FullName '_SUBAREA.json'
        if (-not (Test-Path $saIndexPath)) { return }
        try {
            $sa = Get-Content $saIndexPath -Raw | ConvertFrom-Json -Depth 30
        } catch { return }
        $saName = $_.Name
        $vp = if ($portalValueProps.ContainsKey($portalKey) -and $portalValueProps[$portalKey].ContainsKey($saName)) {
            $portalValueProps[$portalKey][$saName]
        } else {
            "(value-prop not yet defined for $portalKey/$saName)"
        }
        $sa | Add-Member -NotePropertyName 'valueProp' -NotePropertyValue $vp -Force
        $sa | ConvertTo-Json -Depth 30 | Set-Content $saIndexPath
    }

    # Update portal index
    $portalIndexPath = Join-Path $pd.FullName '_PORTAL.json'
    if (Test-Path $portalIndexPath) {
        try {
            $pi = Get-Content $portalIndexPath -Raw | ConvertFrom-Json -Depth 30
        } catch { return }
        if ($authFinding) {
            $pi | Add-Member -NotePropertyName 'authFinding' -NotePropertyValue $authFinding -Force
        }
        # also embed valueProp per sub-area in the portal-level index
        if ($pi.subAreas) {
            $newSubAreas = @()
            foreach ($s in $pi.subAreas) {
                $newS = $s | Select-Object *
                $vp = if ($portalValueProps.ContainsKey($portalKey) -and $portalValueProps[$portalKey].ContainsKey($s.subArea)) {
                    $portalValueProps[$portalKey][$s.subArea]
                } else { "(value-prop not yet defined for $portalKey/$($s.subArea))" }
                $newS | Add-Member -NotePropertyName 'valueProp' -NotePropertyValue $vp -Force
                $newSubAreas += $newS
            }
            $pi | Add-Member -NotePropertyName 'subAreas' -NotePropertyValue $newSubAreas -Force
        }
        $pi | ConvertTo-Json -Depth 30 | Set-Content $portalIndexPath
    }
}

Write-Host "Done. Value-props + auth-flow findings applied to all portals."
