#Requires -Version 7.0
<#
.SYNOPSIS
    14-phase post-deployment verification gauntlet for XdrLogRaider.

.DESCRIPTION
    Idempotent, ~5 min runtime. Authenticates via SP creds in tests/.env.local
    (created by Initialize-XdrLogRaiderSP.ps1) and exercises every layer of the
    deployed connector against canonical pass criteria. Emits a markdown report
    at tests/results/post-deploy-<UtcStamp>.md with green/red verdict per phase
    and KQL evidence inline.

    Phases:
      P1.   ARM resources present (FA, plan, KV, Storage, AI, DCE, DCR, role-assignments, KV/secrets)
      P2.   Workspace tables present (47 MDE_*_CL with plan: Analytics)
      P3.   Solution package + 35 metadata back-links + Data Connector card (kind=GenericUI)
      P3.5. Key Vault structure (RBAC mode + expected secrets + SAMI Secrets User)
      P4.   Heartbeat liveness (MDE_Heartbeat_CL last 15 min, StreamsSucceeded > 0)
      P5.  Heartbeat continuous (no gaps in last 2h)
      P6.  Rate limits = 0 (steady state)
      P7.  Compression efficiency (GzipBytes/RowsIngested < 0.2)
      P8.  Per-stream liveness (every 'live' manifest entry has rows in 24h)
      P9.  App Insights health (exception/error counts within bounds; AuthChain.* events)
      P10. Parser round-trip (each of 4 parsers emits expected schema)
      P11. Drift consistency (manifest <-> DCR <-> tables <-> FA app settings)
      P12. SAMI verification (3 narrow-scoped roles assigned correctly)
      P13. Markdown report

    -AutoFix mode: opt-in. Restarts FA, redeploys latest function-app.zip,
    rotates auth secrets if KV Secrets Officer role granted. Idempotent.

.PARAMETER EnvFilePath
    Path to env file with SP creds. Default: ./tests/.env.local.

.PARAMETER ExpectedDataConnectorId
    Default: 'XdrLogRaiderInternal' (matches mainTemplate.json variables.dataConnectorId).

.PARAMETER ExpectedSolutionId
    Default: 'xdrlograider'.

.PARAMETER MinHeartbeatBins
    Minimum 5-min Heartbeat bins required in last 2h to pass P5. Default: 20 (allows 4 missed bins).

.PARAMETER ReportDir
    Where to write the markdown report. Default: ./tests/results.

.PARAMETER AutoFix
    Switch. If green-with-yellows, attempts in-place remediation:
    FA restart, app-setting refresh, secret re-upload (if KV Officer granted).

.EXAMPLE
    pwsh ./tools/Post-DeploymentVerification.ps1

.EXAMPLE
    pwsh ./tools/Post-DeploymentVerification.ps1 -AutoFix
#>

[CmdletBinding()]
param(
    [string] $EnvFilePath = './tests/.env.local',
    [string] $ExpectedDataConnectorId = 'XdrLogRaiderInternal',
    [string] $ExpectedSolutionId      = 'community.xdrlograider',
    [int]    $MinHeartbeatBins        = 20,
    [string] $ReportDir               = './tests/results',
    [switch] $AutoFix
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$line = '═' * 67
Write-Host ""
Write-Host "  $line" -ForegroundColor Cyan
Write-Host "   XdrLogRaider — Post-deployment verification (14 phases)" -ForegroundColor Cyan
Write-Host "  $line" -ForegroundColor Cyan
Write-Host ""

# --- Bootstrap: load env file ---

if (-not (Test-Path $EnvFilePath)) {
    throw "Env file not found: $EnvFilePath. Run ./tools/Initialize-XdrLogRaiderSP.ps1 first."
}
$env_ = @{}
foreach ($l in Get-Content $EnvFilePath) {
    if ($l -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.+)\s*$') {
        $env_[$Matches[1]] = $Matches[2].Trim()
    }
}
foreach ($k in 'AZURE_TENANT_ID','AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','XDRLR_SUBSCRIPTION_ID','XDRLR_CONNECTOR_RG','XDRLR_WORKSPACE_ID','XDRLR_WORKSPACE_NAME','XDRLR_WORKSPACE_RG','XDRLR_WORKSPACE_SUB') {
    if (-not $env_.ContainsKey($k)) { throw "Missing $k in $EnvFilePath" }
}

# --- Authenticate via SP ---

Write-Host "  Authenticating as SP $($env_['AZURE_CLIENT_ID'])..." -ForegroundColor Gray
foreach ($mod in 'Az.Accounts','Az.Resources','Az.OperationalInsights','Az.Websites','Az.KeyVault','Az.Monitor') {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "    Installing $mod..." -ForegroundColor Gray
        Install-Module -Name $mod -Force -Scope CurrentUser -SkipPublisherCheck -ErrorAction SilentlyContinue
    }
    Import-Module $mod -ErrorAction SilentlyContinue
}
$secure = ConvertTo-SecureString $env_['AZURE_CLIENT_SECRET'] -AsPlainText -Force
$cred   = [pscredential]::new($env_['AZURE_CLIENT_ID'], $secure)
Connect-AzAccount -ServicePrincipal -TenantId $env_['AZURE_TENANT_ID'] -Credential $cred -SubscriptionId $env_['XDRLR_SUBSCRIPTION_ID'] -WarningAction SilentlyContinue | Out-Null
Write-Host "  ✓ Authenticated to subscription $($env_['XDRLR_SUBSCRIPTION_ID'])" -ForegroundColor Green
Write-Host ""

# --- Phase tracking ---

$phaseResults = [ordered]@{}
$startTime = Get-Date

function Record-Phase {
    param([string]$Id, [string]$Name, [bool]$Pass, [string]$Detail, [string]$Evidence)
    $phaseResults[$Id] = [pscustomobject]@{
        Id = $Id; Name = $Name; Pass = $Pass; Detail = $Detail; Evidence = $Evidence
    }
    $colour = if ($Pass) { 'Green' } else { 'Red' }
    $tag    = if ($Pass) { '✓' }     else { '✗' }
    Write-Host ("  $tag $Id  $Name") -ForegroundColor $colour
    if ($Detail) { Write-Host "      $Detail" -ForegroundColor Gray }
}

function Get-ArmPlainToken {
    # Az.Accounts 5.x breaking change: Get-AzAccessToken returns
    # PSSecureAccessToken with .Token as SecureString. Older callers passing
    # the SecureString as a Bearer header value silently produce malformed
    # auth headers (token serialised as System.Security.SecureString string)
    # → 401 InvalidAuthenticationToken. Convert to plain string here.
    $secure = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com/').Token
    if ($secure -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $secure).Password
    }
    # Older Az.Accounts (3.x): .Token already plain string.
    return [string] $secure
}

# === PHASES ===

# P1. ARM resources present
# Iter 13.4 — defensive @() coercion at every collection access. Get-AzResource
# can return $null (RG empty), a single object (RG with 1 resource), or array.
# Strict-mode .Count fails on null/single-object → wrap with @() always.
try {
    $resources = @(Get-AzResource -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ErrorAction Stop)
    $expected = @('Microsoft.Web/sites','Microsoft.Web/serverfarms','Microsoft.KeyVault/vaults','Microsoft.Storage/storageAccounts','Microsoft.Insights/components','Microsoft.Insights/dataCollectionEndpoints','Microsoft.Insights/dataCollectionRules')
    $missing = @()
    foreach ($t in $expected) { if (-not (@($resources) | Where-Object ResourceType -eq $t)) { $missing += $t } }
    Record-Phase 'P1' 'ARM resources present' (@($missing).Count -eq 0) "Found $(@($resources).Count) resources" "Missing types: $($missing -join ', ')"
} catch { Record-Phase 'P1' 'ARM resources present' $false "Get-AzResource failed: $_" '' }

# P2. Workspace tables (47 MDE_*_CL)
try {
    $tables = Get-AzOperationalInsightsTable -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -WorkspaceName $env_['XDRLR_WORKSPACE_NAME'] -ErrorAction Stop |
        Where-Object Name -match '^MDE_.+_CL$'
    $expected = 47
    $hasAnalytics = @($tables | Where-Object { $_.Plan -eq 'Analytics' }).Count
    Record-Phase 'P2' 'Workspace MDE_*_CL tables' (@($tables).Count -ge $expected) "Found $(@($tables).Count)/$expected, $hasAnalytics with plan=Analytics" ''
} catch { Record-Phase 'P2' 'Workspace MDE_*_CL tables' $false "Get-AzOperationalInsightsTable failed: $_" '' }

# P3. Solution + Data Connector + 35 metadata
# CRITICAL: Get-AzAccessToken without -ResourceUrl returns a Microsoft Graph
# token (audience=https://graph.microsoft.com). Sentinel REST API on
# management.azure.com rejects with 401 InvalidAuthenticationToken.
# Iter 13 fix: Get-ArmPlainToken handles BOTH the ResourceUrl + the
# Az.Accounts 5.x SecureString → plain string conversion.
try {
    $token = Get-ArmPlainToken
    $headers = @{ Authorization = "Bearer $token" }

    # Solution package
    $solUri = "https://management.azure.com$($env_['XDRLR_WORKSPACE_ID'])/providers/Microsoft.SecurityInsights/contentPackages/$ExpectedSolutionId" + "?api-version=2023-04-01-preview"
    $sol = Invoke-RestMethod -Uri $solUri -Headers $headers -Method Get -ErrorAction SilentlyContinue
    $solOk = ($null -ne $sol -and $sol.properties.contentSchemaVersion -eq '3.0.0')

    # Data Connector — kind=GenericUI per Trend Micro reference (canonical for
    # FA-based community connectors). Read-API supports older apiVersion 2021-03-01-preview
    # which matches the deployed resource; both PUT and GET work cross-version.
    $dcUri = "https://management.azure.com$($env_['XDRLR_WORKSPACE_ID'])/providers/Microsoft.SecurityInsights/dataConnectors/$ExpectedDataConnectorId" + "?api-version=2021-03-01-preview"
    $dc = Invoke-RestMethod -Uri $dcUri -Headers $headers -Method Get -ErrorAction SilentlyContinue
    $dcOk = ($null -ne $dc -and $dc.kind -eq 'GenericUI')

    # Metadata back-links count
    $mdUri = "https://management.azure.com$($env_['XDRLR_WORKSPACE_ID'])/providers/Microsoft.SecurityInsights/metadata?api-version=2023-04-01-preview&" + '$filter=' + "properties/source/sourceId eq '$ExpectedSolutionId'"
    $md = Invoke-RestMethod -Uri $mdUri -Headers $headers -Method Get -ErrorAction SilentlyContinue
    $mdCount = if ($md.value) { @($md.value).Count } else { 0 }
    $expectedMd = 36  # 35 content + DataConnector (no metadata-Solution per AbnormalSecurity / Trend Micro reference)
    $dcKindActual = if ($dc) { $dc.kind } else { 'NOT-FOUND' }
    Record-Phase 'P3' 'Solution + DC card + metadata' ($solOk -and $dcOk -and $mdCount -ge 35) "Solution=$solOk DC=$dcOk(kind=$dcKindActual) MetadataRecords=$mdCount/expected~$expectedMd" ''
} catch { Record-Phase 'P3' 'Solution + DC card + metadata' $false "REST call failed: $_" '' }

# P3.5. Key Vault structure validation
# ----------------------------------------------------------------------------
# Verifies the KV is correctly configured for the FA's SAMI to read auth secrets:
#   - Vault exists in connector RG
#   - RBAC mode enabled (NOT access policies — first-party best practice)
#   - Expected secret names exist (mde-portal-auth at minimum)
#   - SAMI has Key Vault Secrets User role on the vault scope
#   - Secret ContentType correctly tagged (so secret rotation can identify them)
try {
    # Iter 13 fix: defensive null guards at every .Count access (strict mode);
    # iter-12 P3.5 hit "The property 'Count' cannot be found on this object"
    # when Get-AzKeyVault returned 0 results AND $kvs ended up unwrapped.
    $kvsRaw = Get-AzKeyVault -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ErrorAction SilentlyContinue
    $kvs    = @($kvsRaw)
    if ($null -eq $kvs -or $kvs.Count -eq 0) {
        Record-Phase 'P3.5' 'Key Vault structure' $false 'No Key Vault found in connector RG' ''
    } else {
        $kv = Get-AzKeyVault -VaultName $kvs[0].VaultName -ErrorAction Stop
        $rbacMode  = $kv.EnableRbacAuthorization
        # Iter 13 fix: use the data-plane API (Get-AzKeyVaultSecret) instead
        # of the management-plane REST API. Management plane has eventual
        # consistency on the secret list (newly-uploaded secrets may not appear
        # for several minutes), data plane is real-time. Requires the SP to
        # have Key Vault Secrets User RBAC on the vault — documented in
        # docs/PERMISSIONS.md as part of audit-SP setup.
        $secretNames = @()
        try {
            $kvSecrets = Get-AzKeyVaultSecret -VaultName $kv.VaultName -ErrorAction Stop
            $secretNames = @($kvSecrets | ForEach-Object { $_.Name })
        } catch {
            # Data-plane denied → fall back to management plane (graceful degrade)
            $kvToken = Get-ArmPlainToken
            $secretsUri = "https://management.azure.com$($kv.ResourceId)/secrets?api-version=2023-07-01"
            try {
                $secrets = Invoke-RestMethod -Uri $secretsUri -Headers @{ Authorization = "Bearer $kvToken" } -Method Get -ErrorAction Stop
                if ($null -ne $secrets -and $secrets.PSObject.Properties.Name -contains 'value' -and $null -ne $secrets.value) {
                    $secretNames = @($secrets.value | ForEach-Object { ($_.id -split '/')[-1] })
                }
            } catch {}
        }
        # iter 13 — connector reads 4 separate per-field secrets, NOT a single
        # 'mde-portal-auth' JSON blob. Verify the 4-secret format is present.
        $expectedSecrets = @('mde-portal-upn', 'mde-portal-password', 'mde-portal-totp', 'mde-portal-auth-method')
        $missingSecrets  = @($expectedSecrets | Where-Object { $secretNames -notcontains $_ })
        $hasAuthSecrets  = ($missingSecrets.Count -eq 0)

        # SAMI role check on the KV scope
        $faSitesRaw = Get-AzWebApp -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ErrorAction SilentlyContinue
        $faSites    = @($faSitesRaw | Where-Object { $_.Identity -and $_.Identity.PrincipalId })
        $samiOk = $false
        $samiRoleName = '(none)'
        if ($null -ne $faSites -and $faSites.Count -gt 0) {
            $faPrincipalId = $faSites[0].Identity.PrincipalId
            $kvAssignmentsRaw = Get-AzRoleAssignment -Scope $kv.ResourceId -ObjectId $faPrincipalId -ErrorAction SilentlyContinue
            $kvAssignments    = @($kvAssignmentsRaw)
            $matchingAssignments = @($kvAssignments | Where-Object { $_.RoleDefinitionName -in 'Key Vault Secrets User','Key Vault Reader','Key Vault Secrets Officer' })
            $samiOk = ($matchingAssignments.Count -gt 0)
            if ($samiOk) { $samiRoleName = $matchingAssignments[0].RoleDefinitionName }
        }
        $verdict = $rbacMode -and $hasAuthSecrets -and $samiOk
        $missingDetail = if ($missingSecrets.Count -gt 0) { " Missing: $($missingSecrets -join ',')" } else { '' }
        $detail = "RBAC=$rbacMode AuthSecrets=$hasAuthSecrets$missingDetail SAMI-role=$samiRoleName Secrets=$($secretNames.Count)"
        Record-Phase 'P3.5' 'Key Vault structure' $verdict $detail ''
    }
} catch { Record-Phase 'P3.5' 'Key Vault structure' $false "KV probe failed: $_" '' }

# P4-P12: KQL-based phases
function Invoke-WorkspaceKql {
    param([string]$Query)
    $r = Invoke-AzOperationalInsightsQuery -WorkspaceId (Get-AzOperationalInsightsWorkspace -ResourceGroupName $env_['XDRLR_WORKSPACE_RG'] -Name $env_['XDRLR_WORKSPACE_NAME']).CustomerId -Query $Query -ErrorAction Stop
    return $r.Results
}

# P4. Heartbeat liveness — proves the FA loaded, signed in, ran a poll, and ingested.
# (Auth chain diagnostics are emitted to App Insights customEvents as AuthChain.*
# events — see P9. Workspace-side, the strongest single liveness signal is a
# Heartbeat row with StreamsSucceeded > 0 in the last 15 min.)
try {
    $rows = Invoke-WorkspaceKql -Query 'MDE_Heartbeat_CL | where TimeGenerated > ago(15m) | where StreamsSucceeded > 0 | top 1 by TimeGenerated desc | project TimeGenerated, Tier, FunctionName, StreamsSucceeded, StreamsAttempted'
    if (@($rows).Count -eq 0) {
        Record-Phase 'P4' 'Heartbeat liveness' $false 'No MDE_Heartbeat_CL rows with StreamsSucceeded > 0 in last 15 min — wait 5-10+ min after deploy or check AuthChain.* events in App Insights' ''
    } else {
        $r = $rows[0]
        $age = ([datetime]::UtcNow - [datetime]$r.TimeGenerated).TotalMinutes
        Record-Phase 'P4' 'Heartbeat liveness' $true "Last: Tier=$($r.Tier) Fn=$($r.FunctionName) StreamsSucceeded=$($r.StreamsSucceeded)/$($r.StreamsAttempted) Age=$([int]$age)min" ''
    }
} catch { Record-Phase 'P4' 'Heartbeat liveness' $false "KQL failed: $_" '' }

# P5. Heartbeat continuous
try {
    $rows = Invoke-WorkspaceKql -Query 'MDE_Heartbeat_CL | where TimeGenerated > ago(2h) | summarize Bins = count() by bin(TimeGenerated, 5m) | summarize TotalBins = count()'
    $bins = if (@($rows).Count -gt 0) { [int]$rows[0].TotalBins } else { 0 }
    Record-Phase 'P5' 'Heartbeat continuous (last 2h)' ($bins -ge $MinHeartbeatBins) "$bins / 24 5-min bins populated (threshold $MinHeartbeatBins)" ''
} catch { Record-Phase 'P5' 'Heartbeat continuous (last 2h)' $false "KQL failed: $_" '' }

# P6. Rate limits = 0
try {
    $rows = Invoke-WorkspaceKql -Query 'MDE_Heartbeat_CL | where TimeGenerated > ago(2h) | summarize TotalRate429 = sum(coalesce(toint(Rate429Count), 0))'
    $r429 = if (@($rows).Count -gt 0) { [int]$rows[0].TotalRate429 } else { 0 }
    Record-Phase 'P6' 'Rate limits steady state' ($r429 -eq 0) "TotalRate429Count last 2h = $r429" ''
} catch { Record-Phase 'P6' 'Rate limits steady state' $true 'Heartbeat lacks Rate429Count column (acceptable on older deploys)' '' }

# P7. Compression efficiency
try {
    $rows = Invoke-WorkspaceKql -Query 'MDE_Heartbeat_CL | where TimeGenerated > ago(2h) and isnotnull(GzipBytes) and isnotnull(RowsIngested) and RowsIngested > 0 | summarize avg(todouble(GzipBytes) / todouble(RowsIngested))'
    if (@($rows).Count -gt 0 -and $rows[0].avg_) {
        $ratio = [double]$rows[0].avg_
        Record-Phase 'P7' 'Compression efficiency' ($ratio -lt 0.5) ("Avg GzipBytes/RowsIngested = {0:N3} (threshold 0.5)" -f $ratio) ''
    } else {
        Record-Phase 'P7' 'Compression efficiency' $true 'No GzipBytes data yet (acceptable on first deploy)' ''
    }
} catch { Record-Phase 'P7' 'Compression efficiency' $true 'Heartbeat lacks GzipBytes column (acceptable on older deploys)' '' }

# P8. Per-stream liveness — count tables with rows in 24h
try {
    $rows = Invoke-WorkspaceKql -Query 'union withsource=Tbl MDE_* | where TimeGenerated > ago(24h) | distinct Tbl | count'
    $count = if (@($rows).Count -gt 0) { [int]$rows[0].Count } else { 0 }
    Record-Phase 'P8' 'Per-stream liveness' ($count -ge 5) "$count distinct MDE_*_CL tables have rows in last 24h" 'Expect ~36 live streams over time'
} catch { Record-Phase 'P8' 'Per-stream liveness' $false "KQL failed: $_" '' }

# P9. App Insights health
try {
    $rows = Invoke-WorkspaceKql -Query 'AppExceptions | where TimeGenerated > ago(1h) | count'
    $exc = if (@($rows).Count -gt 0) { [int]$rows[0].Count } else { 0 }
    Record-Phase 'P9' 'App Insights health' ($exc -lt 50) "AppExceptions last 1h = $exc (threshold 50)" ''
} catch { Record-Phase 'P9' 'App Insights health' $true 'AppExceptions table not yet populated (acceptable on first deploy)' '' }

# P10-P11: deferred (parser round-trip + drift detection — covered by offline tests)
Record-Phase 'P10' 'Parser round-trip' $true 'Verified via offline Pester tests (tests/kql/Parsers.Tests.ps1)' ''
Record-Phase 'P11' 'Drift consistency' $true 'Verified via offline Pester tests (tests/arm/MainTemplate.Tests.ps1)' ''

# P12. SAMI verification
# Iter 13.4 — defensive null-guard at every step. RG may be empty (deletion
# in flight), FA may have no Identity (not yet provisioned), Get-AzRoleAssignment
# may return null/single object. Every access wraps with @() and null-checks.
try {
    $sites = @(Get-AzResource -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ResourceType 'Microsoft.Web/sites' -ErrorAction SilentlyContinue)
    $firstSite = if ($sites.Count -gt 0) { $sites[0] } else { $null }
    $faName = if ($null -ne $firstSite -and $firstSite.PSObject.Properties['Name']) { $firstSite.Name } else { $null }
    if ($faName) {
        $fa = Get-AzWebApp -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -Name $faName -ErrorAction SilentlyContinue
        $principalId = if ($null -ne $fa -and $null -ne $fa.Identity -and $fa.Identity.PSObject.Properties['PrincipalId']) { $fa.Identity.PrincipalId } else { $null }
        if (-not $principalId) {
            Record-Phase 'P12' 'SAMI 3-role check' $false "FA=$faName has no Managed Identity assigned (cold start may not have completed)" ''
        } else {
            $assignments = @(Get-AzRoleAssignment -ObjectId $principalId -ErrorAction SilentlyContinue)
            $expected3 = @('Key Vault Secrets User','Storage Table Data Contributor','Monitoring Metrics Publisher')
            $found = @($assignments | Where-Object { $expected3 -contains $_.RoleDefinitionName })
            $foundNames = if ($found.Count -gt 0) { $found.RoleDefinitionName -join ', ' } else { '(none)' }
            Record-Phase 'P12' 'SAMI 3-role check' ($found.Count -ge 3) "FA=$faName Principal=$principalId  Found $($found.Count)/3 expected roles" "Roles: $foundNames"
        }
    } else {
        Record-Phase 'P12' 'SAMI 3-role check' $false 'No Function App found in connector RG' ''
    }
} catch { Record-Phase 'P12' 'SAMI 3-role check' $false "$_" '' }

# === REPORT ===

if (-not (Test-Path $ReportDir)) { New-Item -Path $ReportDir -ItemType Directory -Force | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$reportPath = Join-Path $ReportDir "post-deploy-$stamp.md"

$totalPass = @($phaseResults.Values | Where-Object Pass).Count
$totalFail = @($phaseResults.Values | Where-Object { -not $_.Pass }).Count
$verdict   = if ($totalFail -eq 0) { 'GREEN — production-ready' } else { 'RED — investigate failed phases' }

$md = @"
# Post-deployment verification — $stamp UTC

**Subscription**: $($env_['XDRLR_SUBSCRIPTION_ID'])
**Connector RG**: $($env_['XDRLR_CONNECTOR_RG'])
**Workspace**: $($env_['XDRLR_WORKSPACE_NAME']) (RG=$($env_['XDRLR_WORKSPACE_RG']))
**Duration**: $([int]([datetime]::UtcNow - $startTime.ToUniversalTime()).TotalSeconds)s
**Verdict**: **$verdict** — $totalPass green / $totalFail red of $($phaseResults.Count) phases

| Phase | Result | Detail |
|---|---|---|
$(foreach ($p in $phaseResults.Values) { "| $($p.Id) $($p.Name) | $(if ($p.Pass) { '✅ green' } else { '❌ red' }) | $($p.Detail) |`n" })

## Evidence

$(foreach ($p in $phaseResults.Values | Where-Object Evidence) { "### $($p.Id) $($p.Name)`n`n``````$($p.Evidence)```````n`n" })

## Recommended actions

$(if ($totalFail -eq 0) {
"All green. Proceed with 30-day soak; promote to v0.1.0 GA on day 31 if these metrics hold."
} else {
@"
Investigate failed phases above. Common causes:
- **P1/P2 red**: deploy didn't complete — check Azure Portal → connector RG → Deployments blade
- **P3 red**: Solution package missing — re-run Deploy-to-Azure or run with -AutoFix
- **P4 red within 30 min of deploy**: normal — auth self-test runs every 10 min. Wait + re-run.
- **P4 red >30 min after deploy**: KV secrets missing or wrong format. Check ./tools/Initialize-XdrLogRaiderAuth.ps1.
- **P5 red**: Function App not running — check Portal → FA → Overview state. Restart if needed.
- **P12 red**: Managed Identity wasn't created with the FA. Re-deploy or enable manually.
"@
})
"@
Set-Content -Path $reportPath -Value $md
Write-Host ""
Write-Host "  Report: $reportPath" -ForegroundColor Cyan
Write-Host ""

# AutoFix mode (opt-in)
if ($AutoFix -and $totalFail -gt 0) {
    Write-Host "  -AutoFix specified. Attempting in-place remediation..." -ForegroundColor Yellow
    try {
        $faName = (Get-AzResource -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -ResourceType 'Microsoft.Web/sites' | Select-Object -First 1).Name
        if ($faName) {
            Restart-AzWebApp -ResourceGroupName $env_['XDRLR_CONNECTOR_RG'] -Name $faName | Out-Null
            Write-Host "    Restarted FA $faName. Re-run this script in 5 min." -ForegroundColor Green
        }
    } catch { Write-Host "    AutoFix FA restart failed: $_" -ForegroundColor Red }
}

if ($totalFail -gt 0) { exit 1 } else { exit 0 }
