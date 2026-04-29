# Azure Functions profile — runs once per PowerShell worker startup.
# Authenticates with Managed Identity, validates required environment variables,
# imports XdrLogRaider modules, warms the auth cache.

$ErrorActionPreference = 'Stop'

# v0.1.0-beta hardening: in PS 7.4, native-command errors don't flow through
# $ErrorActionPreference unless we opt in explicitly. This ensures a non-zero
# exit from az CLI / pwsh / jq / etc. inside a timer body becomes a proper
# terminating error (caught + heartbeat'd) instead of a silent warning.
$PSNativeCommandUseErrorActionPreference = $true

# Cold-start telemetry — consumers in MDE_Heartbeat_CL can compute
# first-fire-after-cold-start latency via (TimeGenerated - ColdStartUtc).
$global:XdrLogRaiderColdStartUtc = [datetime]::UtcNow

# ----------------------------------------------------------------------------
# 1) Azure auth — Managed Identity when running in Azure Functions
# ----------------------------------------------------------------------------
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    try {
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Information "profile.ps1: connected to Azure with Managed Identity"
    } catch {
        Write-Warning "profile.ps1: Connect-AzAccount -Identity FAILED: $_. Azure-side operations (KV reads, DCE ingest, checkpoint writes) will fail until resolved."
    }
}

# ----------------------------------------------------------------------------
# 2) Required environment variables — fail fast on missing config
# ----------------------------------------------------------------------------
# These are set by the ARM deployment as Function App `appSettings`. Missing any
# of them means the deploy is broken or app settings have been mutated manually.
# Throwing here surfaces the problem during cold start (visible in App Insights
# `traces` with severity=Error) instead of silently failing at first timer fire.

$requiredEnvVars = @(
    @{ Name = 'KEY_VAULT_URI';         Purpose = 'URI of the Key Vault holding the portal auth secrets' }
    @{ Name = 'AUTH_SECRET_NAME';      Purpose = 'Prefix for the auth secrets in KV (e.g. mde-portal-auth)' }
    @{ Name = 'AUTH_METHOD';           Purpose = "Auth method: credentials_totp | passkey" }
    @{ Name = 'SERVICE_ACCOUNT_UPN';   Purpose = 'Service-account UPN logged in diagnostics' }
    @{ Name = 'DCE_ENDPOINT';          Purpose = 'Data Collection Endpoint URL (destination for ingested rows)' }
    @{ Name = 'DCR_IMMUTABLE_ID';      Purpose = 'Data Collection Rule immutable ID' }
    @{ Name = 'STORAGE_ACCOUNT_NAME';  Purpose = 'Storage account holding the checkpoint table' }
    @{ Name = 'CHECKPOINT_TABLE_NAME'; Purpose = 'Checkpoint table name (e.g. connectorCheckpoints)' }
)

$missing = @()
foreach ($var in $requiredEnvVars) {
    $val = [Environment]::GetEnvironmentVariable($var.Name)
    if ([string]::IsNullOrWhiteSpace($val)) {
        $missing += "  - $($var.Name) ($($var.Purpose))"
    }
}

if ($missing.Count -gt 0) {
    $message = @"
profile.ps1: FATAL — the Function App is missing $($missing.Count) required environment variable(s):

$($missing -join "`n")

These are set by the ARM deployment as appSettings. Fix by one of:
  1. Redeploy via the ARM template in deploy/compiled/mainTemplate.json
  2. Manually re-add the missing appSettings in Azure Portal → Function App → Configuration
  3. If secrets expired, rerun ./tools/Initialize-XdrLogRaiderAuth.ps1 (only reinstalls KV contents, NOT app settings)

See docs/TROUBLESHOOTING.md → 'Function App env vars missing'.
"@
    Write-Error $message
    throw "profile.ps1 abort: missing required environment variables"
}

# ----------------------------------------------------------------------------
# 3) Import XdrLogRaider modules
# ----------------------------------------------------------------------------
$modulesPath = Join-Path $PSScriptRoot 'Modules'

# iter-14.0 Phase 1: auth module split into L1 + L2 + backward-compat shim.
# Import order matters — Xdr.Common.Auth must load before Xdr.Defender.Auth
# (the shim relies on both being already loaded when its psm1 runs).
#
#   L1 Xdr.Common.Auth   — portal-generic Entra layer (TOTP, passkey, ESTS auth)
#   L2 Xdr.Defender.Auth — Defender-specific cookie exchange (sccauth + XSRF-TOKEN)
#   Shim Xdr.Portal.Auth — backward-compat wrappers (Connect-MDEPortal etc.)
#
# v0.2.0 will add sibling L2 modules (Xdr.Purview.Auth, Xdr.Intune.Auth,
# Xdr.Entra.Auth) by appending to this list.

$coreModules = @(
    # L1 portal-generic modules.
    'Xdr.Common.Auth',
    'Xdr.Sentinel.Ingest',
    # L2 Defender-specific cookie-exchange auth.
    'Xdr.Defender.Auth',
    # L3 Defender-portal manifest dispatcher.
    'Xdr.Defender.Client',
    # L4 portal-routing orchestrator.
    'Xdr.Connector.Orchestrator',
    # Backward-compat shims (re-export legacy names; load LAST so the
    # renamed modules are already present when the shim psm1 imports them).
    'Xdr.Portal.Auth',
    'XdrLogRaider.Client',
    'XdrLogRaider.Ingest'
)

foreach ($m in $coreModules) {
    $manifestPath = Join-Path $modulesPath $m "$m.psd1"
    if (-not (Test-Path $manifestPath)) {
        throw "profile.ps1: module manifest not found — $manifestPath. Function App ZIP is corrupt; redeploy required."
    }
    try {
        Import-Module $manifestPath -Force -ErrorAction Stop
        Write-Information "profile.ps1: imported module $m"
    } catch {
        throw "profile.ps1: Import-Module $m FAILED — $_"
    }
}

# ----------------------------------------------------------------------------
# 4) Global state
# ----------------------------------------------------------------------------
# Auth cookie cache — keyed by service-account UPN so multiple connectors (if
# ever hosted side-by-side in one FA worker) can coexist.
if (-not $global:XdrPortalAuthCache) {
    $global:XdrPortalAuthCache = @{}
}

# Runtime config — resolved at cold start from the validated env vars above.
# Iter 13.3: also exposed as a function `Get-XdrLogRaiderConfig` so timer
# function run.ps1 files can defensively re-build the config from env vars
# WITHOUT depending on $global state propagating across runspaces. With
# PSWorkerInProcConcurrencyUpperBound=1 (set in mainTemplate.json appSettings),
# the propagation bug doesn't trigger — but the helper is cheap insurance.

function global:Get-XdrLogRaiderConfig {
    [pscustomobject]@{
        KeyVaultUri        = $env:KEY_VAULT_URI
        AuthSecretName     = $env:AUTH_SECRET_NAME
        AuthMethod         = $env:AUTH_METHOD
        ServiceAccountUpn  = $env:SERVICE_ACCOUNT_UPN
        DceEndpoint        = $env:DCE_ENDPOINT
        DcrImmutableId     = $env:DCR_IMMUTABLE_ID
        StorageAccountName = $env:STORAGE_ACCOUNT_NAME
        CheckpointTable    = $env:CHECKPOINT_TABLE_NAME
        ExpectedTenantId   = $env:TENANT_ID
    }
}

# Eager-init for warm-runspace performance — but every function ALSO calls
# Get-XdrLogRaiderConfig defensively, so missing $global state isn't fatal.
$global:XdrLogRaiderConfig = Get-XdrLogRaiderConfig

Write-Information "profile.ps1: XdrLogRaider Function App initialised — $(@($global:XdrLogRaiderConfig.PSObject.Properties).Count) config values loaded"
