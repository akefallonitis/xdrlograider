# Azure Functions profile — runs once per PowerShell worker startup.
# Authenticates with managed identity, imports XdrLogRaider modules, warms auth cache.

if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    try {
        $null = Connect-AzAccount -Identity -ErrorAction Stop
        Write-Information "Connected to Azure with managed identity"
    } catch {
        Write-Warning "Failed to connect with managed identity: $_"
    }
}

# Import XdrLogRaider modules (each timer function imports what it needs, but the
# common path is preloaded here to reduce cold-start time).
$modulesPath = Join-Path $PSScriptRoot 'Modules'

$coreModules = @(
    'Xdr.Portal.Auth',
    'XdrLogRaider.Client',
    'XdrLogRaider.Ingest'
)

foreach ($m in $coreModules) {
    $manifestPath = Join-Path $modulesPath $m "$m.psd1"
    if (Test-Path $manifestPath) {
        try {
            Import-Module $manifestPath -Force -ErrorAction Stop
            Write-Information "Imported module: $m"
        } catch {
            Write-Error "Failed to import $m : $_"
        }
    } else {
        Write-Warning "Module manifest not found: $manifestPath"
    }
}

# Global shared state — persists across function invocations within same worker instance.
# Auth cookie cache is keyed by service-account UPN so multiple connectors can coexist.
if (-not $global:XdrPortalAuthCache) {
    $global:XdrPortalAuthCache = @{}
}

# Config resolved once at startup — cached in module scope.
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

Write-Information "XdrLogRaider Function App profile initialized"
