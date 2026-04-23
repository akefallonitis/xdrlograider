# Azure Functions profile — runs once per PowerShell worker startup.
# Authenticates with Managed Identity, validates required environment variables,
# imports XdrLogRaider modules, warms the auth cache.

$ErrorActionPreference = 'Stop'

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

$coreModules = @(
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

# Runtime config — resolved once at cold start from the validated env vars above.
# Timer functions consume this via $global:XdrLogRaiderConfig; no re-reads from
# $env:* inside hot paths.
$global:XdrLogRaiderConfig = @{
    KeyVaultUri        = $env:KEY_VAULT_URI
    AuthSecretName     = $env:AUTH_SECRET_NAME
    AuthMethod         = $env:AUTH_METHOD
    ServiceAccountUpn  = $env:SERVICE_ACCOUNT_UPN
    DceEndpoint        = $env:DCE_ENDPOINT
    DcrImmutableId     = $env:DCR_IMMUTABLE_ID
    StorageAccountName = $env:STORAGE_ACCOUNT_NAME
    CheckpointTable    = $env:CHECKPOINT_TABLE_NAME
}

Write-Information "profile.ps1: XdrLogRaider Function App initialised — $(($global:XdrLogRaiderConfig.Keys).Count) config values loaded"
