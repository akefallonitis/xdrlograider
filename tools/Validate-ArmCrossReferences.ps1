#Requires -Version 7.4
<#
.SYNOPSIS
Offline ARM cross-reference validator · catches "resource referenced but not defined" before push.

.DESCRIPTION
Per plan v11 §10 axis 23 (NEW · added 2026-06-02 after portal validation surfaced a
resourceId reference that ARM could not resolve at pre-validation time).

OUTER-TEMPLATE-ONLY scope: walks the outer template's resources/variables/parameters · does NOT
descend into nested `properties.template` blocks (those are inner-scoped and have their own
parameters · validating cross-references there would produce false positives).

Checks performed (all OFFLINE · no Azure auth needed):
  1. uniqueString() must NOT include deployment().name · phase-evaluation trap (REAL BUG · caught
     by operator at portal pre-validation 2026-06-02).
  2. Every Microsoft.Resources/deployments reference (`resourceId('Microsoft.Resources/deployments', ...)`)
     resolves to a deployment declared at OUTER scope.
  3. Every variable referenced at outer scope is defined.
  4. Every parameter referenced at outer scope is defined.
  6. Microsoft.Resources/deployments with BOTH subscriptionId AND resourceGroup for same-sub
     cross-RG (Microsoft canonical violation · portal pre-val trap).
  7a. NO cross-scope reference() to nested deployment outputs when nested deployment has
      `resourceGroup` property pointing to different RG (ARM rejects · iter#1 §17 confirmed).
  7b. NO `resourceId('Microsoft.Resources/deployments', X)` in dependsOn when X targets a
      cross-RG nested deployment · ARM rejects with "is not defined in template" (iter#3 2026-06-02
      PM confirmed). SIMPLE-NAME STRING form `[variables('nestedDeploymentName')]` IS ALLOWED ·
      ARM does name-lookup against declared resources without computing resourceId paths · this
      works for cross-RG nested deployments and is REQUIRED for ordering (iter#5 confirmed: DCR
      provisioning-time validates destination workspace table existence · must wait for nested).
  8.  Every `parameters('X')` and `variables('X')` reference inside an INNER nested template
      resolves to that inner template's own parameters/variables block · inner has separate
      namespace from outer · orphan refs (typical post-scope-move dead code in outputs/resources)
      will cause ARM to reject at deploy with 'template parameter X not found' (iter#4 2026-06-02
      PM confirmed · the previous structural checks #3/#4 walked only outer scope).
  9.  Log Analytics column-name reservations (corrected iter#7 2026-06-03):
      RESERVED-WITH-MANDATORY-TYPE (must be user-declared with exact type):
        TimeGenerated · datetime  (REQUIRED · every custom table)
      FORBIDDEN (LA auto-populates from context or computes · MUST NOT be user-declared
      anywhere — DCR streamDeclarations OR workspace table schema · including either site
      causes DCR provisioning rejection. iter#6 wrongly added TenantId as 'guid' type ·
      iter#7 'InvalidStreamDeclaration · Type must have one of string,int,long,real,boolean,
      datetime,dynamic' confirmed: 'guid' is NOT a valid DCR stream type · AND declaring
      reserved cols at all is wrong · LA fills them from request context at ingest time):
        TenantId · Type · SourceSystem · _ResourceId · _SubscriptionId · _ItemId · _BilledSize
        · Computer · MG · IsManaged · ResourceProviderType

Exit codes:
  0 · all cross-references resolve
  1 · one or more dangling references / missing definitions
  2 · tool error (template parse fail · IO)
#>
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'deploy\mainTemplate.json')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TemplatePath)) {
    Write-Error "ARM template not found: $TemplatePath"
    exit 2
}

try {
    $arm = Get-Content $TemplatePath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
} catch {
    Write-Error "ARM template parse FAIL: $($_.Exception.Message)"
    exit 2
}

$issues = @()

# ── Check 1 · uniqueString must NOT include deployment().name ──────────────────────────────────
# Build the OUTER-only text by serializing back to JSON minus the inner template bodies.
# Also strips `comments` fields (documentation prose · contains illustrative resourceId() examples
# that would false-positive Check #2 if scanned · iter#5 2026-06-02 PM fix).
$outerArm = $arm.Clone()
$outerArm.resources = @($arm.resources | ForEach-Object {
    $copy = $_.Clone()
    if ($copy.type -eq 'Microsoft.Resources/deployments' -and $copy.properties -and $copy.properties.template) {
        # Strip the inner template body · we don't validate inner-scoped references at outer
        $propsCopy = $copy.properties.Clone()
        $propsCopy.template = @{ '__stripped' = 'inner template body redacted for outer-scope validation' }
        $copy.properties = $propsCopy
    }
    # Strip comments field at every resource · documentation prose · not evaluated by ARM
    if ($copy.ContainsKey('comments')) {
        $copy.Remove('comments')
    }
    $copy
})
$outerText = $outerArm | ConvertTo-Json -Depth 100

if ($outerText -match "uniqueString\([^)]*deployment\(\)\.name[^)]*\)") {
    $issues += "uniqueString() includes deployment().name · resolves differently across validation phases in portal Custom Template flow · breaks resourceId cross-references (REAL BUG · operator portal pre-validation 2026-06-02)"
}

# ── Check 6 · Microsoft.Resources/deployments with subscriptionId+resourceGroup pair for SAME-sub cross-RG (portal pre-val trap) ─
# Per Microsoft canonical pattern (https://learn.microsoft.com/azure/azure-resource-manager/templates/deploy-to-resource-group):
# Same-subscription cross-RG deployments specify ONLY 'resourceGroup' property. Specifying BOTH 'subscriptionId' AND 'resourceGroup'
# treats the deployment as cross-subscription scope · which breaks resourceId() reference resolution at portal pre-validation
# (resource appears 'not defined in template' even though it is). REAL BUG · operator portal pre-validation 2026-06-02.
foreach ($r in $arm.resources) {
    if ($r.type -eq 'Microsoft.Resources/deployments' -and $r.ContainsKey('subscriptionId') -and $r.ContainsKey('resourceGroup')) {
        # If subscriptionId equals subscription().subscriptionId expression OR derived from same source as current subscription,
        # this is the same-sub-diff-RG bad pattern. Flag it.
        $issues += "Microsoft.Resources/deployments '$($r.name)' specifies BOTH subscriptionId AND resourceGroup · same-sub-cross-RG should specify ONLY resourceGroup (Microsoft canonical) · portal pre-validation breaks otherwise"
    }
}

# ── Check 2 · Microsoft.Resources/deployments references resolve to declared deployments ───────
# Extract OUTER deployment definitions
$outerDeployments = @()
foreach ($r in $arm.resources) {
    if ($r.type -eq 'Microsoft.Resources/deployments') {
        # Strip the [...] wrapper to compare against reference function calls
        $nameExpr = $r.name -replace '^\[' , '' -replace '\]$', ''
        $outerDeployments += $nameExpr
    }
}

# Extract resourceId('Microsoft.Resources/deployments', X) references in OUTER text (stripped of inner template body)
$refMatches = [regex]::Matches($outerText, "resourceId\(\s*'Microsoft\.Resources/deployments'\s*,\s*([^)]+?)\s*\)")
$referencedNames = @()
foreach ($m in $refMatches) {
    $referencedNames += $m.Groups[1].Value.Trim()
}

foreach ($ref in ($referencedNames | Select-Object -Unique)) {
    $found = $false
    # Use substring containment (robust to balanced-paren regex limitations):
    # `variables('nestedDeploymentName'` from a ref · matches `variables('nestedDeploymentName')` def via prefix
    foreach ($def in $outerDeployments) {
        if ($def -eq $ref) { $found = $true; break }
        if ($def.Contains($ref) -or $ref.Contains($def)) { $found = $true; break }
    }
    if (-not $found) {
        $issues += "resourceId('Microsoft.Resources/deployments', $ref) · referenced name does not match any declared deployment (declared: $($outerDeployments -join '; '))"
    }
}

# ── Check 3 · variables('X') referenced at outer scope must be defined ────────────────────────
$varRefs = [regex]::Matches($outerText, "variables\(\s*'([^']+)'\s*\)")
$varNames = @($varRefs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$definedVars = @($arm.variables.Keys)
foreach ($v in $varNames) {
    if ($v -notin $definedVars) {
        $issues += "variables('$v') referenced at outer scope but not defined"
    }
}

# ── Check 4 · parameters('Y') referenced at outer scope must be defined ───────────────────────
$paramRefs = [regex]::Matches($outerText, "parameters\(\s*'([^']+)'\s*\)")
$paramNames = @($paramRefs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$definedParams = @($arm.parameters.Keys)
foreach ($p in $paramNames) {
    if ($p -notin $definedParams) {
        $issues += "parameters('$p') referenced at outer scope but not defined"
    }
}

# ── Check #7 · forbid cross-scope reference() to nested deployments with `resourceGroup` property ──
# Per plan §17.11: ARM does NOT support outer-template reference() to a nested deployment whose
# `resourceGroup` property points to a different RG than the outer template's deploying RG.
# Empirically confirmed via az validate (6 patterns tested · all fail with InvalidTemplate).
# The architectural fix: pass the resource ID PATH (string concat) · resolve immutable ID at
# runtime via Az REST. This check prevents the bug from being re-introduced.
$crossRgNestedNames = @()
foreach ($r in $arm.resources) {
    if ($r.type -eq 'Microsoft.Resources/deployments' -and $r.ContainsKey('resourceGroup')) {
        $nameExpr = $r.name -replace '^\[' , '' -replace '\]$', ''
        $crossRgNestedNames += $nameExpr
    }
}

if ($crossRgNestedNames.Count -gt 0) {
    # Search for reference() calls that target any of these cross-RG nested deployment names
    $refCallMatches = [regex]::Matches($outerText, "reference\(\s*resourceId\([^)]*['""]Microsoft\.Resources/deployments['""]\s*,\s*([^)]+)\s*\)\s*,\s*'[^']+'\s*\)\.outputs\.")
    foreach ($m in $refCallMatches) {
        $refTargetExpr = $m.Groups[1].Value.Trim()
        # Check if this reference targets a cross-RG nested deployment
        foreach ($nName in $crossRgNestedNames) {
            if ($refTargetExpr.Contains($nName) -or $nName.Contains($refTargetExpr) -or
                $refTargetExpr.Contains('nestedDeploymentName') -or $refTargetExpr.Contains('workspaceResourceGroup')) {
                $issues += "Check #7a FAIL · cross-scope reference() to nested deployment outputs with `resourceGroup` property: $($m.Value.Substring(0, [Math]::Min(150, $m.Value.Length)))... · ARM does not support reading outputs from cross-RG nested deployments · co-locate the referenced resource in the outer-template RG"
                break
            }
        }
    }

    # ── Check #7b · forbid cross-scope dependsOn → cross-RG nested deployment ─────────────────────
    # 2026-06-02 PM iter#3 discovery: ARM rejects NOT ONLY reference() to cross-RG nested deployment
    # outputs · ALSO resourceId('Microsoft.Resources/deployments', X) when used in dependsOn array
    # of an outer resource where X targets a cross-RG nested. The error surface is
    # "'Microsoft.Resources/deployments/<name>' is not defined in the template" even though it IS
    # defined · because resourceId() computes a path in the CURRENT RG and the nested is deployed
    # cross-RG. The structural fix is identical: drop the dependsOn entirely · ARM provisions in
    # parallel · use indirect ordering (e.g., a downstream resource that dependsOn both the cross-RG
    # nested AND the cross-scope resource · which acts as the natural ordering barrier).
    foreach ($r in $arm.resources) {
        if (-not $r.dependsOn) { continue }
        foreach ($dep in $r.dependsOn) {
            # Match resourceId(...'Microsoft.Resources/deployments'...) pattern
            $depMatches = [regex]::Matches($dep, "resourceId\(\s*['""]Microsoft\.Resources/deployments['""]\s*,\s*([^)]+)\s*\)")
            foreach ($dm in $depMatches) {
                $depTargetExpr = $dm.Groups[1].Value.Trim()
                foreach ($nName in $crossRgNestedNames) {
                    if ($depTargetExpr.Contains($nName) -or $nName.Contains($depTargetExpr) -or
                        $depTargetExpr.Contains('nestedDeploymentName')) {
                        $resourceName = if ($r.name) { $r.name } else { $r.type }
                        $issues += "Check #7b FAIL · cross-scope dependsOn to nested deployment with ``resourceGroup`` property: outer resource '$resourceName' has dependsOn '$($dm.Value)' targeting cross-RG nested · ARM rejects this exactly like Check #7a reference() · DROP the dependsOn · rely on FA-as-natural-barrier (FA dependsOn both DCR and nested · sequential)"
                        break
                    }
                }
            }
        }
    }
}

# ── Check #8 · inner-nested-template parameter/variable resolution (iter#4 audit-gap fix) ─────────
# 2026-06-02 PM iter#4 discovery: structural check #3/#4 (variables/parameters referenced) walks only
# OUTER scope. Inner nested templates (`properties.template`) have SEPARATE parameter + variable
# namespaces · refs to `parameters('X')` inside inner MUST resolve to inner template's `parameters`
# block · NOT the outer's. When you move a resource between scopes (e.g. moved DCR outer-ward) and
# forget to delete its references from inner (typical orphan-output bug) · ARM evaluates the inner
# template at deploy time and rejects with "The template parameter 'X' is not found".
# This check walks every inner nested template · validates every `parameters('X')` and
# `variables('X')` reference resolves within that inner scope.
foreach ($r in $arm.resources) {
    if ($r.type -ne 'Microsoft.Resources/deployments') { continue }
    if (-not $r.properties.template) { continue }
    $innerTpl = $r.properties.template
    $innerJson = $innerTpl | ConvertTo-Json -Depth 50 -Compress

    # Inner-template parameter namespace · names of its declared parameters.
    # NOTE: $arm is parsed with -AsHashtable · use .Keys NOT .PSObject.Properties.Name
    # (the latter returns Hashtable type properties like Count/Keys/Values instead of dict keys).
    $innerParamNames = @()
    if ($innerTpl.parameters -and $innerTpl.parameters -is [System.Collections.IDictionary]) {
        $innerParamNames = @($innerTpl.parameters.Keys)
    }
    # Inner-template variable namespace
    $innerVarNames = @()
    if ($innerTpl.variables -and $innerTpl.variables -is [System.Collections.IDictionary]) {
        $innerVarNames = @($innerTpl.variables.Keys)
    }

    $nestedDeployName = $r.name -replace '^\[', '' -replace '\]$', ''

    # Find all parameters('X') refs in the inner template body
    $innerParamRefs = [regex]::Matches($innerJson, "parameters\('([^']+)'\)")
    $refdParams = @($innerParamRefs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($p in $refdParams) {
        if ($p -notin $innerParamNames) {
            $issues += "Check #8 FAIL · inner nested template '$nestedDeployName' references parameters('$p') · NOT declared in inner.parameters block (declared: $($innerParamNames -join ',')) · ARM will reject at deploy with 'template parameter not found' · DROP the orphan ref (likely dead-code in outputs/resources after a scope move)"
        }
    }

    # Find all variables('X') refs in the inner template body
    $innerVarRefs = [regex]::Matches($innerJson, "variables\('([^']+)'\)")
    $refdVars = @($innerVarRefs | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($v in $refdVars) {
        if ($v -notin $innerVarNames) {
            $issues += "Check #8 FAIL · inner nested template '$nestedDeployName' references variables('$v') · NOT declared in inner.variables block · inner has separate variable scope from outer · ARM will reject · either declare the variable in inner OR pass via inner.parameters from outer"
        }
    }
}

# ── Check #9 · Log Analytics RESERVED column types (iter#6 audit-gap fix · 2026-06-02 PM) ──────
# Log Analytics service-side reserves specific column NAMES with mandatory TYPES. DCR + workspace
# table column type MUST match. ARM-TTK is template-structure only · doesn't know LA semantics ·
# az validate doesn't catch this either (the check happens at DCR provisioning time when LA tries
# to bind streamDeclaration columns to the destination table). Iter#6 hit:
#   "InvalidTransformOutput · Types of transform output columns do not match the ones defined by
#    the output stream: TenantId [produced:'String', output:'Guid']"
# Walk every DCR streamDeclarations.columns AND every workspace-table schema.columns · verify
# reserved-name cols use reserved-type · forbidden-name cols are absent.
# LA-reserved column rules (corrected iter#7 2026-06-03 after deploy revealed actual behavior):
#   - TimeGenerated MUST be present with type 'datetime' (LA-mandatory · all custom tables)
#   - TenantId + other auto-computed cols MUST NOT be user-declared (LA auto-fills from request
#     context at ingest · declaring them causes DCR provisioning rejection)
$laReservedTypes = @{
    'TimeGenerated' = 'datetime'
}
# Forbidden cols · LA auto-populates from request/system context · NOT user-declared anywhere.
$laForbiddenCols = @(
    'TenantId',           # LA auto-fills from workspace's authenticated tenant context
    'Type',               # LA computes (table name)
    'SourceSystem',       # LA computes (agent/data-source identity)
    '_ResourceId',        # LA auto-fills from request-context resource path
    '_SubscriptionId',    # LA auto-fills from request-context subscription
    '_ItemId',            # LA computes (per-row identity)
    '_BilledSize',        # LA computes (size for billing)
    'Computer',           # LA-reserved for AMA agent-source rows
    'MG',                 # LA-reserved for Operations Manager management-group context
    'IsManaged',          # LA-reserved for AMA managed-status
    'ResourceProviderType' # LA-reserved
)

function Test-LaReservedTypes {
    param([array]$Columns, [string]$ContextPath)
    $localIssues = @()
    foreach ($col in $Columns) {
        if (-not $col.name) { continue }
        $colName = $col.name
        $colType = if ($col.type) { $col.type.ToLowerInvariant() } else { '' }
        # Reserved-name → must match reserved-type
        if ($laReservedTypes.ContainsKey($colName)) {
            $expected = $laReservedTypes[$colName]
            if ($colType -ne $expected) {
                $localIssues += "Check #9 FAIL · LA-reserved col '$colName' at $ContextPath declared as type='$colType' · LA-service reserves '$colName' for type='$expected' · DCR provisioning rejects mismatch with 'InvalidTransformOutput' (iter#6) · change type to '$expected' in ALL sites (workspace table + DCR streamDeclaration · all per-category-schemas files)"
            }
        }
        # Forbidden col-name → must NOT appear
        if ($colName -in $laForbiddenCols) {
            $localIssues += "Check #9 FAIL · LA-forbidden col '$colName' at $ContextPath · LA auto-computes this column (NOT user-declared) · including it causes DCR provisioning rejection · REMOVE from schema"
        }
    }
    return $localIssues
}

# Walk outer-template DCRs
foreach ($r in $arm.resources) {
    if ($r.type -eq 'Microsoft.Insights/dataCollectionRules' -and $r.properties -and $r.properties.streamDeclarations) {
        $streams = $r.properties.streamDeclarations
        foreach ($streamName in $streams.Keys) {
            $stream = $streams[$streamName]
            if ($stream.columns) {
                $issues += Test-LaReservedTypes -Columns @($stream.columns) -ContextPath "outer DCR '$($r.name)' streamDeclarations.$streamName.columns"
            }
        }
    }
}

# Walk inner-template workspace tables + DCRs
foreach ($r in $arm.resources) {
    if ($r.type -ne 'Microsoft.Resources/deployments') { continue }
    if (-not $r.properties.template) { continue }
    $innerResources = @($r.properties.template.resources)
    foreach ($ir in $innerResources) {
        if ($ir.type -eq 'Microsoft.OperationalInsights/workspaces/tables' -and $ir.properties.schema -and $ir.properties.schema.columns) {
            $issues += Test-LaReservedTypes -Columns @($ir.properties.schema.columns) -ContextPath "inner nested '$($r.name)' workspace-table '$($ir.name)' schema.columns"
        }
        if ($ir.type -eq 'Microsoft.Insights/dataCollectionRules' -and $ir.properties.streamDeclarations) {
            $istreams = $ir.properties.streamDeclarations
            foreach ($sName in $istreams.Keys) {
                $s = $istreams[$sName]
                if ($s.columns) {
                    $issues += Test-LaReservedTypes -Columns @($s.columns) -ContextPath "inner nested '$($r.name)' DCR '$($ir.name)' streamDeclarations.$sName.columns"
                }
            }
        }
    }
}

# ── Check #10 · Azure built-in role-definition GUID validation (iter#9 audit-gap fix · 2026-06-03) ──
# Catches HARDCODED-GUID-TYPOS that ARM-validate cannot detect (because the GUID syntax is valid · only
# the role-def lookup at deploy-time fails with 'RoleDefinitionDoesNotExist'). 7 prior iter#1-iter#8
# all failed this way before we built this check. Maintain a canonical list of Azure built-in role
# GUIDs that this template actually assigns · cross-check every `subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '<GUID>')`
# against the canonical list. Update this list ONLY by querying `az role definition list --name '<name>'`
# against a working Azure tenant · NEVER by guessing / copy-paste.
#
# Last verified against Azure built-in roles: 2026-06-03 (operator's Azure for Students sub)
$AzureBuiltInRoleGuidsCanonical = @{
    '4633458b-17de-408a-b874-0445c86b69e6' = 'Key Vault Secrets User'
    '3913510d-42f4-4e42-8a64-420c390055eb' = 'Monitoring Metrics Publisher'
    '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' = 'Storage Table Data Contributor'
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe' = 'Storage Blob Data Contributor'
    '974c5e8b-45b9-4653-ba55-5f855dd0fb88' = 'Storage Queue Data Contributor'
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
    'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Owner'
}

# Find every roleDefinitionId GUID the template references via subscriptionResourceId('...roleDefinitions', '<GUID>')
$roleDefGuidPattern = "subscriptionResourceId\(\s*'Microsoft\.Authorization/roleDefinitions'\s*,\s*'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'\s*\)"
$roleDefMatches = [regex]::Matches($outerText, $roleDefGuidPattern)
$seenGuids = @{}
foreach ($m in $roleDefMatches) {
    $guid = $m.Groups[1].Value
    if ($seenGuids.ContainsKey($guid)) { continue }
    $seenGuids[$guid] = $true
    if (-not $AzureBuiltInRoleGuidsCanonical.ContainsKey($guid)) {
        $issues += "Check #10 FAIL · template references role-definition GUID '$guid' · NOT in canonical Azure built-in role GUIDs list (used: $($AzureBuiltInRoleGuidsCanonical.Keys -join ', ')) · either the GUID is a typo (verify against ``az role definition list --name '<name>' --query [].name -o tsv``) or it's a new role being used (add to ``AzureBuiltInRoleGuidsCanonical`` in Validate-ArmCrossReferences.ps1 after empirical Azure verification)"
    }
}

# ── Check #11 · per-DCR Monitoring Metrics Publisher COMPLETENESS (FA SAMI → every DCR · 2026-06-15) ──
# Every top-level DCR MUST have a scoped Monitoring Metrics Publisher role assignment — the principalId-seeded
# nested role Build-MainTemplate emits per category (Build-MainTemplate.ps1 ~:241 · ledger A2/WS4.1). Without it
# the FA SAMI cannot publish to that DCR → ingestion 403s and the category SILENTLY lands 0 rows (the cat#2 failure
# class). Axis 36 (mainTemplate == Build-MainTemplate rebuild) CANNOT catch a role the generator fails to emit —
# both sides agree-wrong and the regen→diff passes. This is the INDEPENDENT structural invariant on the committed
# artifact: link DCR↔role by the shared '-dcr-<token>-' category token and assert 1:1 (no DCR without its MMP role;
# no orphan MMP role for a missing DCR). Belt+suspenders: the role nested deployments seed roleDefinitionId from the
# 'monitoringMetricsPublisherRoleId' variable — assert that variable actually resolves to the MMP GUID.
$mmpRoleGuid = '3913510d-42f4-4e42-8a64-420c390055eb'
$dcrTokens   = @{}
$mmpRoleTokens = @{}
foreach ($r in $arm.resources) {
    if ($r.type -eq 'Microsoft.Insights/dataCollectionRules' -and ([string]$r.name) -match '-dcr-([a-z0-9]+)-') {
        $dcrTokens[$Matches[1]] = [string]$r.name
    }
    if ($r.type -eq 'Microsoft.Resources/deployments' -and ([string]$r.name) -match 'role-dcr-([a-z0-9]+)-') {
        $tok = $Matches[1]
        # confirm THIS nested deployment actually grants the MMP role (by inline GUID or the seeding variable)
        $roleJson = $r | ConvertTo-Json -Depth 30 -Compress
        if ($roleJson -match [regex]::Escape($mmpRoleGuid) -or $roleJson -match 'monitoringMetricsPublisherRoleId') {
            $mmpRoleTokens[$tok] = [string]$r.name
        }
    }
}
foreach ($tok in $dcrTokens.Keys) {
    if (-not $mmpRoleTokens.ContainsKey($tok)) {
        $issues += "Check #11 FAIL · DCR '$($dcrTokens[$tok])' (category token '$tok') has NO scoped Monitoring Metrics Publisher role assignment · the FA SAMI cannot publish to it → ingestion 403 → the category SILENTLY lands 0 rows (cat#2 class) · Build-MainTemplate must emit the per-DCR MMP nested role (ledger A2/WS4.1)"
    }
}
foreach ($tok in $mmpRoleTokens.Keys) {
    if (-not $dcrTokens.ContainsKey($tok)) {
        $issues += "Check #11 FAIL · orphan Monitoring Metrics Publisher role '$($mmpRoleTokens[$tok])' (token '$tok') targets a DCR that does not exist at outer scope · stale role or renamed DCR"
    }
}
$mmpVar = if ($arm.variables -and $arm.variables.ContainsKey('monitoringMetricsPublisherRoleId')) { [string]$arm.variables['monitoringMetricsPublisherRoleId'] } else { '' }
if ($mmpRoleTokens.Count -gt 0 -and $mmpVar -notmatch [regex]::Escape($mmpRoleGuid)) {
    $issues += "Check #11 FAIL · variable 'monitoringMetricsPublisherRoleId' (seeds every per-DCR role) does not resolve to the MMP GUID $mmpRoleGuid (got: '$mmpVar') · the per-DCR roles would grant the WRONG role"
}

# ── REPORT ──────────────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '======================================================================'
Write-Host "Validate-ArmCrossReferences · $($TemplatePath | Split-Path -Leaf)"
Write-Host '======================================================================'
Write-Host "Outer Microsoft.Resources/deployments declarations : $($outerDeployments.Count)"
Write-Host "Outer resourceId() references to ^                  : $(($referencedNames | Select-Object -Unique).Count)"
Write-Host "Outer variables referenced                          : $($varNames.Count) (defined: $($definedVars.Count))"
Write-Host "Outer parameters referenced                         : $($paramNames.Count) (defined: $($definedParams.Count))"
Write-Host '----------------------------------------------------------------------'

if ($issues.Count -eq 0) {
    Write-Host 'Validate-ArmCrossReferences GREEN · no dangling references at outer scope'
    exit 0
}

Write-Host "FAIL · $($issues.Count) cross-reference issues:"
foreach ($i in $issues) { Write-Host "  - $i" }
exit 1
