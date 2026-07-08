#Requires -Version 7.4
<#
.SYNOPSIS
Per-Category DCR + workspace table schema generator from manifest .psd1.

.DESCRIPTION
For a given Category · reads all per-Op entries from manifests/<Portal>/<Category>.psd1 · derives:
- Workspace custom table schema (`<Portal>_<Category>_CL`) with 6 envelope cols + CorrelationId +
  RawJson + N typed cols (union of per-Op ProjectionMap fields · deduped · LA-reserved-safe)
- DCR streamDeclaration (`Custom-<Portal>_<Category>_CL`) matching table columns
- ARM nested deployment block to extend mainTemplate.json (per Plan §3.6)

Output options:
- -OutputMode 'JSON' → writes deploy/per-category-schemas/<Portal>-<Category>.json (build artifact)
- -OutputMode 'ARMBlock'/'Both' → LEGACY · the nested-deployment side file fed the now-removed per-category injector;
  the onboarding flow no longer requests it (Build-MainTemplate assembles the nested block itself from the <Cat>.json). Use 'JSON'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Portal,   # A4 · portal-generic (any portal friendly name); manifest-path lookup validates existence
    [Parameter(Mandatory)] [string] $Category,
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [ValidateSet('JSON','ARMBlock','Both')] [string] $OutputMode = 'Both',
    # V7 (§21.1) · byte-determinism: a wall-clock GeneratedUtc inside a regen→diff-compared artifact (axis-30) is
    # inherently non-deterministic. INJECTABLE + omitted-by-default → bare regen is byte-stable; a release build
    # may pass a deterministic provenance stamp (e.g. the catalogue's git-commit time).
    [string] $GeneratedUtc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# R1 single-source (plan §32): use the ONE canonical reserved-column rewrite shared with the parser +
# validator so the generated DCR/table column name ALWAYS equals the parser's output column name.
Import-Module (Join-Path $PSScriptRoot '..\src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking

$manifestPath = Join-Path $RepoRoot "manifests/$Portal/$Category.psd1"
if (-not (Test-Path $manifestPath)) {
    throw "[Build-PerCategorySchema] Manifest not found: $manifestPath · run Generate-Manifest first"
}

$manifest = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
# WS2.2 · THE shared category tokenizer — table/stream/DCR names all derive from the SAME token the catalogue used.
$categoryToken = Get-XdrCategoryToken -Category $Category
$portalBlock = if ($manifest.ContainsKey($Portal)) { $manifest[$Portal] } else { $manifest }
$operations = @($portalBlock.Operations)

if ($operations.Count -eq 0) {
    throw "[Build-PerCategorySchema] No Operations in $manifestPath"
}

# LA-reserved rewrite is now the SHARED Get-XdrSafeColumnName (imported above · single source w/ the parser).

# ─── Envelope columns (always present) · SINGLE-SOURCE from Xdr.Common.Parser (R1 · plan §35.6) ───────
# Was a hand-maintained inline copy that drifted from the validator (the live-RED gate).
# Now the ONE Get-XdrEnvelopeColumns definition (imported above) drives BOTH this generator AND
# Validate-Manifests, so the envelope cannot drift. 8 cols · NO TenantId (LA-reserved · see Get-XdrSafeColumnName):
# TimeGenerated·OperationKey·Portal·Category·Subcategory·Operation·CorrelationId·RawJson (v12 §4.3 added Subcategory).
$envelopeCols = @(Get-XdrEnvelopeColumns)

# ─── Union typed columns from per-Op ProjectionMap ───────────────────────────
# DETERMINISM (axis-30 regen→diff): Import-PowerShellDataFile returns each Op's ProjectionMap as a plain
# Hashtable, whose .Keys enumeration order is process-seed-randomized. Iterating it unsorted makes the
# emitted typed-column SEQUENCE differ on every run → the committed schema can never byte/structurally match
# a regeneration (axis 30 compares column order). Sort the keys per Op (same `| Sort-Object` discipline the
# catalogue builder uses) so the column order is reproducible. Column SET + count are unaffected.
# F4 (§21.8) · column-casing canonicality: process LIVE-PROVEN ops FIRST so their column casing wins the
# case-insensitive union ($typedCols is an [ordered]@{} · case-insensitive · FIRST casing wins). A conservative
# spec op (camelCase actionId) must NOT override a live-proven op's canonical casing (PascalCase ActionId · the
# existing committed + live table column) — that would rename GetHistory's columns and break its byte-identity.
$operations = @($operations | Sort-Object `
    @{ Expression = { if ($_['Provenance'] -and $_['Provenance']['Live']) { 0 } else { 1 } } }, `
    @{ Expression = { [string]$_['OperationKey'] } })
$typedCols = [ordered]@{}
foreach ($op in $operations) {
    if (-not $op.ContainsKey('ProjectionMap')) { continue }
    foreach ($colKey in @($op.ProjectionMap.Keys | Sort-Object)) {
        $colName = Get-XdrSafeColumnName -Name $colKey  # canonical `<name>_x` rewrite (shared with parser)

        # FH-3 · TYPED COLUMNS · the operator-verified type from the manifest's ColumnTypes seam (curation-sourced from
        # LIVE evidence · Generate-Manifest passthrough). SPARSE: a column not listed => string (the safe default). The
        # ProjectionMap key ($colKey) IS the column name in ColumnTypes. The all-string pilot carries no ColumnTypes, so
        # every pilot column stays string · byte-identical. (Replaces the confirmed-dead $colSpec.Type {Path;Type} branch:
        # ProjectionMap values are JSONPath strings, never {Path;Type} hashtables, so that branch always fell to 'string'.)
        $colType = if ($op.ContainsKey('ColumnTypes') -and $op.ColumnTypes.ContainsKey($colKey)) { [string]$op.ColumnTypes[$colKey] } else { 'string' }

        # Type conflict resolution · 'string' is the UNKNOWN/default (a column absent from an op's ColumnTypes · :85),
        # NOT a proven string — so a KNOWN type (real/bool/long/datetime) proven by one op must NOT be downgraded just
        # because another op that shares the same column lacks type info. Lattice: unknown(string) ⊑ known. Rules:
        #   • same type            → keep
        #   • existing unknown     → PROMOTE to the incoming known type
        #   • incoming unknown     → KEEP the existing known type (no downgrade)
        #   • two DIFFERENT knowns → genuine ambiguity → downgrade to string (the safe widening)
        # Generic across all categories/ops · order-independent (a no-evidence op can no longer clobber a live-proven
        # typed column · the F1-B regression: adding ExposureManagement attack-surface ops dragging latestScore→string).
        if ($typedCols.Contains($colName)) {
            $existing = [string]$typedCols[$colName].type
            if ($existing -eq $colType) {
                # identical — keep
            } elseif ($existing -eq 'string') {
                $typedCols[$colName] = @{ name = $colName; type = $colType }            # unknown → known (promote)
            } elseif ($colType -eq 'string') {
                # incoming has no type info — keep the proven known type (no downgrade)
            } else {
                Write-Warning "[Build-PerCategorySchema] Type conflict for $colName ($existing vs $colType) · downgrading to string"
                $typedCols[$colName] = @{ name = $colName; type = 'string' }
            }
        } else {
            $typedCols[$colName] = @{ name = $colName; type = $colType }
        }
    }
}

# ─── Build workspace table schema (Microsoft.OperationalInsights/workspaces/tables) ─────
$tableName = "${Portal}_${categoryToken}_CL"
# .get_Values() not .Values: $typedCols is an ordered hashtable keyed by COLUMN NAME · a column literally named
# 'values' (or 'keys'/'count') would shadow the .Values member accessor and return that ONE column entry instead of
# the whole collection (silently dropping every other typed column). The .get_X() method form is collision-immune.
$tableColumns = @($envelopeCols) + @($typedCols.get_Values())

# B (type-at-source · 2026-06-16 · operator-decided): the DCR STREAM declares the SAME native types as the TABLE and the
# dataFlow transformKql stays the UNIFORM 'source' — the runtime parser emits NATIVE values for typed columns
# (Apply-XdrProjectionMap reads the op's ColumnTypes · ConvertTo-XdrTypedColumnValue), so a native [double]/[bool]/[long]
# lands directly in the native stream+table column (no string→typed coercion · no per-category transform · the DCR shape
# is identical for every category). datetime is emitted as an ISO-8601 string and coerced string→datetime at the stream
# boundary (the ONE lenient LA coercion · the pilot's TimeGenerated). All-string categories (no ColumnTypes) → all-string
# stream==table, byte-identical to the pilot. The type lives ONCE in curation ColumnTypes, applied at source = the parser.

$tableResource = [ordered]@{
    type = 'Microsoft.OperationalInsights/workspaces/tables'
    apiVersion = '2023-09-01'
    name = "[concat(parameters('workspaceName'), '/', '$tableName')]"
    properties = @{
        plan = 'Analytics'
        schema = @{
            name = $tableName
            columns = @($tableColumns | ForEach-Object { @{ name = $_.name; type = $_.type } })
        }
    }
}

# ─── Build DCR streamDeclaration (Microsoft.Insights/dataCollectionRules) ────────────
$streamName = "Custom-${Portal}_${categoryToken}_CL"
$dcrName = "xdrlr-dcr-$($categoryToken.ToLowerInvariant())"
$dcrResource = [ordered]@{
    type = 'Microsoft.Insights/dataCollectionRules'
    apiVersion = '2023-03-11'
    name = "[concat(variables('namePrefix'), '-dcr-$($categoryToken.ToLowerInvariant())-', variables('suffix'))]"
    location = "[parameters('location')]"
    dependsOn = @(
        "[resourceId('Microsoft.OperationalInsights/workspaces/tables', parameters('workspaceName'), '$tableName')]"
    )
    properties = @{
        dataCollectionEndpointId = "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
        streamDeclarations = @{
            $streamName = @{
                columns = @($tableColumns | ForEach-Object { @{ name = $_.name; type = $_.type } })
            }
        }
        destinations = @{
            logAnalytics = @(
                @{
                    workspaceResourceId = "[parameters('workspaceResourceId')]"
                    name = "xdrlr-${categoryToken}-dest"
                }
            )
        }
        dataFlows = @(
            @{
                streams = @($streamName)
                destinations = @("xdrlr-${categoryToken}-dest")
                transformKql = 'source'
                outputStream = $streamName
            }
        )
    }
}

# ─── Build nested deployment block (cross-scope · workspace RG) ──────────────
$nestedDeployment = [ordered]@{
    type = 'Microsoft.Resources/deployments'
    apiVersion = '2024-03-01'
    name = "[concat('xdrlr-nested-$($categoryToken.ToLowerInvariant())-', variables('suffix'))]"
    subscriptionId = "[variables('workspaceSubscriptionId')]"
    resourceGroup = "[variables('workspaceResourceGroup')]"
    dependsOn = @(
        "[resourceId('Microsoft.Insights/dataCollectionEndpoints', variables('dceName'))]"
    )
    properties = @{
        mode = 'Incremental'
        expressionEvaluationOptions = @{ scope = 'inner' }
        parameters = @{
            workspaceName = @{ value = "[variables('workspaceName')]" }
            workspaceResourceId = @{ value = "[parameters('workspaceResourceId')]" }
            location = @{ value = "[parameters('location')]" }
            namePrefix = @{ value = "[variables('namePrefix')]" }
            suffix = @{ value = "[variables('suffix')]" }
            dceName = @{ value = "[variables('dceName')]" }
        }
        template = @{
            '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
            contentVersion = '1.0.0.0'
            parameters = @{
                workspaceName = @{ type = 'string' }
                workspaceResourceId = @{ type = 'string' }
                location = @{ type = 'string' }
                namePrefix = @{ type = 'string' }
                suffix = @{ type = 'string' }
                dceName = @{ type = 'string' }
            }
            variables = @{
                namePrefix = "[parameters('namePrefix')]"
                suffix = "[parameters('suffix')]"
                dceName = "[parameters('dceName')]"
            }
            resources = @($tableResource, $dcrResource)
            outputs = @{
                dcrImmutableId = @{
                    type = 'string'
                    value = "[reference(resourceId('Microsoft.Insights/dataCollectionRules', concat(parameters('namePrefix'), '-dcr-$($categoryToken.ToLowerInvariant())-', parameters('suffix'))), '2023-03-11').immutableId]"
                }
                tableName = @{ type = 'string'; value = "'$tableName'" }
                streamName = @{ type = 'string'; value = "'$streamName'" }
            }
        }
    }
}

# ─── Write outputs ──────────────────────────────────────────────────────────
$outRoot = Join-Path $RepoRoot 'deploy/per-category-schemas'
$null = New-Item -ItemType Directory -Path $outRoot -Force -ErrorAction SilentlyContinue
$summary = [ordered]@{
    Portal             = $Portal
    Category           = $Category
    TableName          = $tableName
    StreamName         = $streamName
    EnvelopeColumnCount = $envelopeCols.Count
    # .get_Count() not .Count · a column literally named 'count' (ExposureManagement) shadows the .Count accessor on
    # this ordered hashtable → returns that column's entry, not the integer count (then serialized as an object,
    # breaking Validate-Manifests' envelope+typed arithmetic · axis 7/16). Method form is collision-immune.
    # ($envelopeCols/$tableColumns/$operations are arrays · their .Count is safe.)
    TypedColumnCount   = $typedCols.get_Count()
    TotalColumnCount   = $tableColumns.Count
    OperationCount     = $operations.Count
    OperationKeys      = @($operations | ForEach-Object { $_.OperationKey })
}
# V7 · only stamp when explicitly injected (deterministic) — never wall-clock (would break axis-30 regen→diff).
if ($GeneratedUtc) { $summary['GeneratedUtc'] = $GeneratedUtc }

function ConvertTo-XdrOrderedArtifact {
    # F12 (determinism · 2026-06-16) · recursively impose a DETERMINISTIC key order so the emitted JSON is byte-stable
    # across processes: an [ordered] dict (OrderedDictionary · intentional ARM resource order) KEEPS its insertion order;
    # a plain hashtable (process-seed-randomized .Keys — the column {name;type} objects, properties, schema, …) is SORTED.
    # Lists recurse (array-preserving); scalars pass through. ONE choke point makes every nested @{} deterministic without
    # converting each literal · axis-30 canonical comparison MASKED the churn, so the working tree reordered every regen.
    param([AllowNull()] $Node)
    if ($Node -is [System.Collections.Specialized.OrderedDictionary]) {
        $r = [ordered]@{}; foreach ($k in @($Node.Keys)) { $r[[string]$k] = ConvertTo-XdrOrderedArtifact $Node[$k] }; return $r
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $r = [ordered]@{}; foreach ($k in (@($Node.Keys) | Sort-Object { [string]$_ })) { $r[[string]$k] = ConvertTo-XdrOrderedArtifact $Node[$k] }; return $r
    }
    if (($Node -is [System.Collections.IList]) -and ($Node -isnot [string])) {
        return ,@($Node | ForEach-Object { ConvertTo-XdrOrderedArtifact $_ })
    }
    return $Node
}

if ($OutputMode -in @('JSON','Both')) {
    $jsonPath = Join-Path $outRoot "$Portal-$Category.json"
    # F12 (determinism · 2026-06-16) · [ordered] so the artifact's TOP-LEVEL key order is fixed (a plain @{} is
    # process-seed-randomized → the schema JSON's top-level block order churned across regens · axis-30 canonical
    # comparison MASKED it, but the git diff/working-tree churned). Columns are already deterministic (lines 71-77).
    $artifact = [ordered]@{
        Summary           = $summary
        TableResource     = $tableResource
        DcrResource       = $dcrResource
        NestedDeployment  = $nestedDeployment
    }
    (ConvertTo-XdrOrderedArtifact $artifact) | ConvertTo-Json -Depth 30 | Out-File -FilePath $jsonPath -Encoding utf8
    Write-Host "[Build-PerCategorySchema] Wrote schema artifact: $jsonPath"
}

if ($OutputMode -in @('ARMBlock','Both')) {
    $armPath = Join-Path $outRoot "$Portal-$Category-nested-deployment.json"
    (ConvertTo-XdrOrderedArtifact $nestedDeployment) | ConvertTo-Json -Depth 30 | Out-File -FilePath $armPath -Encoding utf8
    Write-Host "[Build-PerCategorySchema] Wrote ARM nested deployment block: $armPath"
}

Write-Host ''
Write-Host "[Build-PerCategorySchema] Summary:"
Write-Host "  · Portal: $Portal · Category: $Category"
Write-Host "  · Table: $tableName · Stream: $streamName"
Write-Host "  · Columns: $($envelopeCols.Count) envelope + $($typedCols.get_Count()) typed = $($tableColumns.Count) total"
Write-Host "  · Operations: $($operations.Count)"
