#Requires -Modules Pester
<#
.SYNOPSIS
    Iter 13.15 hosting-plan invariant gate. Asserts the Bicep templates
    correctly tier their behavior across the 3 supported hostingPlan values
    (consumption-y1, flex-fc1, premium-ep1).

.DESCRIPTION
    Bicep static-analysis tests — we read the .bicep source directly and
    validate the conditional logic without compiling/deploying. This catches
    drift between the documented matrix (in docs/HOSTING-PLANS.md) and the
    actual Bicep behavior.

    The matrix:

      hostingPlan       AzureWebJobsStorage form          ContentShare form          allowSharedKeyAccess  alwaysOn
      consumption-y1    __accountName (MI)                shared key (Y1 limit)      true (required)       false
      flex-fc1          __accountName (MI)                __accountName (MI)         false                 optional
      premium-ep1       __accountName (MI)                __accountName (MI)         false                 true

    SAMI roles per tier:

      Role                                          Y1   FC1  EP1
      Key Vault Secrets User                        Y    Y    Y
      Storage Table Data Contributor                Y    Y    Y
      Monitoring Metrics Publisher                  Y    Y    Y
      Storage Blob Data Owner                       Y    Y    Y
      Storage Queue Data Contributor                Y    Y    Y
      Storage File Data SMB Share Contributor       N    Y    Y    (Y1 uses shared key for files)
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MainBicep      = Get-Content (Join-Path $script:RepoRoot 'deploy' 'main.bicep') -Raw
    $script:FunctionAppBicep = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'function-app.bicep') -Raw
    $script:StorageBicep   = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'storage.bicep') -Raw
    $script:RoleBicep      = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'role-assignments.bicep') -Raw
    $script:KvBicep        = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'key-vault.bicep') -Raw
    $script:AiBicep        = Get-Content (Join-Path $script:RepoRoot 'deploy' 'modules' 'app-insights.bicep') -Raw
}

Describe 'main.bicep — hostingPlan parameter shape' {

    It 'declares hostingPlan as an enum with exactly 3 allowed values' {
        # Bicep allowed-values lists separate either by commas (single-line) OR
        # newlines (multi-line). Accept both.
        $script:MainBicep | Should -Match "@allowed\(\s*\[\s*'consumption-y1'[,\s]+'flex-fc1'[,\s]+'premium-ep1'\s*\]\s*\)" -Because 'hostingPlan must be a 3-tier enum: consumption-y1 / flex-fc1 / premium-ep1'
        $script:MainBicep | Should -Match 'param hostingPlan string' -Because 'hostingPlan parameter must be declared'
    }

    It 'defaults hostingPlan to consumption-y1 (cheapest entry point per Microsoft connector parity)' {
        $script:MainBicep | Should -Match "param hostingPlan string\s*=\s*'consumption-y1'" -Because 'v0.1.0-beta default is the cheapest tier; v1.2 Marketplace will flip to flex-fc1'
    }

    It 'derives useFullManagedIdentity = (hostingPlan != consumption-y1)' {
        $script:MainBicep | Should -Match "var useFullManagedIdentity\s*=\s*hostingPlan\s*!=\s*'consumption-y1'" -Because 'full MI is incompatible with Y1 due to content-share platform limit'
    }

    It 'derives serverfarmSku from hostingPlan (Y1/FC1/EP1)' {
        $script:MainBicep | Should -Match "var serverfarmSku\s*=\s*hostingPlan\s*==\s*'consumption-y1'\s*\?\s*'Y1'" -Because 'consumption-y1 → Y1 SKU'
    }

    It 'derives alwaysOn = (hostingPlan == premium-ep1)' {
        $script:MainBicep | Should -Match "var alwaysOn\s*=\s*hostingPlan\s*==\s*'premium-ep1'" -Because 'AlwaysOn supported only on EP*'
    }
}

Describe 'function-app.bicep — tiered AzureWebJobsStorage + content-share' {

    It 'computes sharedKeyConnectionString variable for Y1 fallback' {
        $script:FunctionAppBicep | Should -Match 'var sharedKeyConnectionString\s*=' -Because 'Y1 still needs the shared-key form for the content share'
    }

    It 'gates AzureWebJobsStorage form on useFullManagedIdentity' {
        $script:FunctionAppBicep | Should -Match 'useFullManagedIdentity\s*\?\s*\{\s*\r?\n\s*AzureWebJobsStorage__accountName' -Because 'true → __accountName (MI); false → connection-string with key'
    }

    It 'uses AzureWebJobsStorage__accountName form (NOT connection string) when useFullManagedIdentity = true' {
        $script:FunctionAppBicep | Should -Match 'AzureWebJobsStorage__accountName:\s*storageAccount\.name' -Because 'MI form per Microsoft docs'
    }

    It 'uses WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName when useFullManagedIdentity = true' {
        $script:FunctionAppBicep | Should -Match 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING__accountName:\s*storageAccount\.name' -Because 'FC1/EP1 supports MI on the content share; Y1 does not'
    }

    It 'falls back to shared-key connection string for content share when useFullManagedIdentity = false' {
        $script:FunctionAppBicep | Should -Match 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING:\s*sharedKeyConnectionString' -Because 'Y1 platform-limit fallback for content share'
    }

    It 'wires alwaysOn parameter onto siteConfig (only true on EP*)' {
        $script:FunctionAppBicep | Should -Match 'alwaysOn:\s*alwaysOn' -Because 'siteConfig.alwaysOn must consume the alwaysOn parameter'
    }

    It 'serverfarm.kind switches on serverfarmSku' {
        $script:FunctionAppBicep | Should -Match "kind:\s*serverfarmSku\s*==\s*'Y1'\s*\?\s*'functionapp'" -Because 'Y1 = functionapp; FC1 = functionapp,linux,flexconsumption; EP* = elastic'
    }
}

Describe 'storage.bicep — allowSharedKeyAccess + restrictPublicNetwork gating' {

    It 'allowSharedKeyAccess gated on disableSharedKey parameter' {
        $script:StorageBicep | Should -Match 'allowSharedKeyAccess:\s*!disableSharedKey' -Because 'disableSharedKey true → allowSharedKeyAccess false (full MI); disableSharedKey false → allowSharedKeyAccess true (Y1 fallback)'
    }

    It 'networkAcls.defaultAction gated on restrictPublicNetwork parameter' {
        $script:StorageBicep | Should -Match "defaultAction:\s*restrictPublicNetwork\s*\?\s*'Deny'\s*:\s*'Allow'" -Because 'true → Deny (private only); false → Allow (open)'
    }

    It 'always sets bypass: AzureServices (so FA SAMI can reach data plane via trusted-services exemption)' {
        $script:StorageBicep | Should -Match "bypass:\s*'AzureServices'" -Because 'FA SAMI uses trusted-services exemption when restrictPublicNetwork=true'
    }
}

Describe 'role-assignments.bicep — tiered SAMI role matrix' {

    It 'declares useFullManagedIdentity bool parameter (default false)' {
        $script:RoleBicep | Should -Match 'param useFullManagedIdentity bool\s*=\s*false' -Because 'tier-driven role gating'
    }

    It 'always grants Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6) on all 3 tiers' {
        $script:RoleBicep | Should -Match "var kvSecretsUserRoleId\s*=\s*'4633458b-17de-408a-b874-0445c86b69e6'" -Because 'KV Secrets User canonical role GUID'
        # Resource present unconditionally
        $script:RoleBicep | Should -Match "resource kvRole 'Microsoft\.Authorization/roleAssignments" -Because 'KV role must always be granted'
    }

    It 'always grants Storage Table Data Contributor (0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3)' {
        $script:RoleBicep | Should -Match "var storageTableContributorRoleId\s*=\s*'0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'"
        $script:RoleBicep | Should -Match 'resource stTableRole'
    }

    It 'always grants Monitoring Metrics Publisher (3913510d-42f4-4e42-8a64-420c390055eb)' {
        $script:RoleBicep | Should -Match "var monitoringMetricsPublisherRoleId\s*=\s*'3913510d-42f4-4e42-8a64-420c390055eb'"
        $script:RoleBicep | Should -Match 'resource dcrRole'
    }

    It 'always grants Storage Blob Data Owner (b7e6dc6d-f1e8-4753-8033-0f276bb0955b) — required on ALL plans for AzureWebJobsStorage MI per Microsoft docs' {
        $script:RoleBicep | Should -Match "var storageBlobDataOwnerRoleId\s*=\s*'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'"
        $script:RoleBicep | Should -Match 'resource stBlobRole'
    }

    It 'always grants Storage Queue Data Contributor (974c5e8b-45b9-4653-ba55-5f855dd0fb88) — Functions runtime queue leases' {
        $script:RoleBicep | Should -Match "var storageQueueDataContributorRoleId\s*=\s*'974c5e8b-45b9-4653-ba55-5f855dd0fb88'"
        $script:RoleBicep | Should -Match 'resource stQueueRole'
    }

    It 'CONDITIONALLY grants Storage File Data SMB Share Contributor (0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb) ONLY when useFullManagedIdentity = true' {
        $script:RoleBicep | Should -Match "var storageFileSmbShareContributorRoleId\s*=\s*'0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'"
        # The resource MUST be guarded by `if (useFullManagedIdentity)` since Y1 doesn't support MI for the content share
        $script:RoleBicep | Should -Match 'resource stFileRole.*=\s*if\s*\(useFullManagedIdentity\)' -Because 'Y1 hosts using shared key for content share — file role would be a useless grant'
    }
}

Describe 'key-vault.bicep — restrictPublicNetwork + diagnostic settings gating' {

    It 'declares restrictPublicNetwork bool parameter' {
        $script:KvBicep | Should -Match 'param restrictPublicNetwork bool' -Because 'operator-selectable network restriction'
    }

    It 'declares enableDiagnostics bool parameter (default true)' {
        $script:KvBicep | Should -Match 'param enableDiagnostics bool\s*=\s*true' -Because 'KV audit logs default-on per security best practice'
    }

    It 'publicNetworkAccess gated on restrictPublicNetwork' {
        $script:KvBicep | Should -Match "publicNetworkAccess:\s*restrictPublicNetwork\s*\?\s*'Disabled'\s*:\s*'Enabled'"
    }

    It 'diagnostic settings resource conditionally deployed when enableDiagnostics is true AND workspaceResourceId is provided' {
        $script:KvBicep | Should -Match "resource kvDiagnostics 'Microsoft\.Insights/diagnosticSettings@.+' = if \(enableDiagnostics && !empty\(workspaceResourceId\)\)" -Because 'avoid empty workspaceId deploy errors'
    }

    It 'diagnostic settings include audit categoryGroup' {
        $script:KvBicep | Should -Match "categoryGroup:\s*'audit'" -Because 'AuditEvent capture is the load-bearing forensic need'
    }
}

Describe 'app-insights.bicep — restrictPublicNetwork query gating' {

    It 'ingestion stays Enabled regardless of restrictPublicNetwork (FA needs to write telemetry)' {
        $script:AiBicep | Should -Match "publicNetworkAccessForIngestion:\s*'Enabled'" -Because 'ingestion lockdown breaks the FA without VNet integration'
    }

    It 'query access gated on restrictPublicNetwork' {
        $script:AiBicep | Should -Match "publicNetworkAccessForQuery:\s*restrictPublicNetwork\s*\?\s*'Disabled'\s*:\s*'Enabled'" -Because 'query lockdown is safe — operators query via Sentinel workspace or Bastion'
    }
}
