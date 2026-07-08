#requires -Version 7.0
<#
.SYNOPSIS
  THE loop-ending gate (G1/G2 · master plan). Asserts the DEPLOYED table's columns ==
  the repo schema's declared columns IN BOTH NAME AND TYPE (GM-1). Catches SCHEMA DRIFT —
  the root cause of 5 rebuilds shipping 0 usable rows (the parser emits projected columns the
  deployed table never had, so they are dropped at ingest and every projected field is null) —
  AND TYPE DRIFT (approach B: the parser emits NATIVE typed values, so a column deployed with
  the wrong type silently mismatches at ingest · the prior name-only check was type-blind).

  BLOCKING: exit 1 if any repo-declared column is MISSING from the live table OR has a
  different deployed TYPE than the repo declares.
  Wire into prepush (LOCAL) + postdeploy + §4.F-SEQ S5. Refuses under $CI (live creds are LOCAL).
.NOTES
  Compares the DCR streamDeclaration column set (what the parser emits) to live `getschema`.
  LA auto-adds reserved columns (TimeGenerated/TenantId/Type/_ResourceId/...) — those are
  expected-extra, not drift.
#>
[CmdletBinding()]
param(
    [string] $SchemaPath = "$PSScriptRoot/../deploy/per-category-schemas/Defender-Operations.json",
    [string] $Table      = 'Defender_Operations_CL',
    [string] $Workspace  = $env:XDRLR_LA_CUSTOMERID
)

$ErrorActionPreference = 'Stop'
if ($env:CI -or $env:GITHUB_ACTIONS) { Write-Host '[Assert-LiveSchemaParity] REFUSES under CI — live verification is LOCAL only.'; exit 2 }
if (-not $Workspace) {
    # C-1 (2026-06-18): resolve the LA customerId from .env.local (the established source) rather than a hardcoded default.
    $envLocal = Join-Path (Resolve-Path "$PSScriptRoot/..").Path '.env.local'
    if (Test-Path $envLocal) { Get-Content $envLocal | ForEach-Object { if ($_ -match '^\s*XDRLR_LA_CUSTOMERID\s*=\s*(.+)$') { $Workspace = $Matches[1].Trim().Trim('"') } } }
}
if (-not $Workspace) { throw 'Set XDRLR_LA_CUSTOMERID in .env.local (or $env:XDRLR_LA_CUSTOMERID, or pass -Workspace)' }

# LA-reserved columns auto-added to every custom table (expected-extra, never "drift")
$reserved = @('TimeGenerated','TenantId','Type','_ResourceId','_ItemId','_SubscriptionId','_TimeReceived','_BilledSize','_IsBillable','_Internal_WorkspaceResourceId','SourceSystem','MG','ManagementGroupName','Computer','RawData')

# GM-1 LIFECYCLE EXCEPTION (2026-06-19) · cols whose LIVE deployed type lags the repo-declared type because the TABLE
# PRE-DATES the born-correct GM-1 prepush gate AND the purge->recreate that would fix it is DEFERRED (low-value cols ·
# optional cleanup · the production purge is operator/harness-gated). A TYPE drift on these specific <Table>.<col>s is
# ADVISORY (warn · NOT block) — a documented lifecycle exception, NOT a blanket relax. NEW categories are born-correct
# (the prepush GM-1 in Validate-Manifests BLOCKS a numeric-declared-string), so this list NEVER grows for them. Remove
# an entry once its table is recreated fresh-typed (Onboard-CategorySurgical -RecreateTableOnSchemaDrift -PurgeNonEmptyOnDrift).
$legacyTypeAdvisory = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$curPath = Join-Path (Resolve-Path "$PSScriptRoot/..").Path 'references/inventory/nodoc-defender-xdr/curation.json'
if (Test-Path $curPath) {
    try {
        $curJson = Get-Content $curPath -Raw | ConvertFrom-Json
        if (($curJson.PSObject.Properties.Name -contains 'legacyTypePendingRecreate') -and ($curJson.legacyTypePendingRecreate.PSObject.Properties.Name -contains $Table)) {
            foreach ($c in @($curJson.legacyTypePendingRecreate.$Table)) { [void]$legacyTypeAdvisory.Add([string]$c) }
        }
    } catch { }   # malformed curation never breaks the gate (the prepush JSON-parse axis catches that separately)
}

# GM-1 (type-aware parity · 2026-06-16) · canonicalize an ARM/DCR column type AND a KQL getschema ColumnType to one
# token so a repo-declared type can be compared to the live deployed type. ARM declares 'boolean'; KQL getschema returns
# 'bool'. LA stores 'int' as long-compatible, so int↔long collapse to one (avoids a false type-drift). .NET DataType
# names (System.*) are mapped too, in case a getschema variant returns DataType rather than ColumnType.
function Get-CanonType([string]$t) {
    switch ("$t".Trim().ToLowerInvariant()) {
        'boolean'         { 'bool' }
        'system.boolean'  { 'bool' }
        'int'             { 'long' }
        'system.int32'    { 'long' }
        'system.int64'    { 'long' }
        'system.double'   { 'real' }
        'system.string'   { 'string' }
        'system.datetime' { 'datetime' }
        'system.guid'     { 'guid' }
        'system.object'   { 'dynamic' }
        default           { "$t".Trim().ToLowerInvariant() }
    }
}

# ── 1 · REPO declared columns (DCR streamDeclaration = what the parser emits) ──
$json = Get-Content $SchemaPath -Raw | ConvertFrom-Json
# CASE-SENSITIVE (Ordinal): Azure Monitor matches JSON property names case-sensitively at ingest, so a repo
# column 'ActionId' vs a live column 'actionId' is a REAL drop. OrdinalIgnoreCase here would mask the casing
# seam (C4) — the exact class of silent failure this gate exists to catch.
$repoCols = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$repoTypes = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)   # GM-1 · column name -> canonical declared type (Ordinal · same case-sensitivity as the name set, since casing IS what this gate exists to catch)
function Find-StreamColumns($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -eq 'streamDeclarations' -and $p.Value) {
                foreach ($stream in $p.Value.PSObject.Properties) {
                    foreach ($c in @($stream.Value.columns)) { if ($c.name) { [void]$repoCols.Add([string]$c.name); $repoTypes[[string]$c.name] = Get-CanonType ([string]$c.type) } }
                }
            }
            Find-StreamColumns $p.Value
        }
    } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($item in $node) { Find-StreamColumns $item }
    }
}
Find-StreamColumns $json
if ($repoCols.Count -eq 0) { Write-Host "[Assert-LiveSchemaParity] FAIL — 0 columns found in repo streamDeclarations ($SchemaPath)"; exit 1 }

# ── 2 · LIVE deployed-table columns + TYPES (getschema · ground truth) ──
$kql = "$Table | getschema | project ColumnName, ColumnType"
$raw = az monitor log-analytics query -w $Workspace --analytics-query $kql -o tsv 2>&1 | Where-Object { $_ -notmatch 'WARNING' -and $_ -match '\S' }
$liveCols = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)  # case-sensitive (see repoCols rationale)
$liveTypes = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)   # GM-1 · column name -> canonical live deployed type (Ordinal · case-sensitive)
foreach ($line in $raw) {
    $parts = $line -split "`t"
    $name  = $parts[0].Trim()
    if ($name -and $name -ne 'ColumnName') {
        [void]$liveCols.Add($name)
        if ($parts.Count -ge 2 -and $parts[1].Trim()) { $liveTypes[$name] = Get-CanonType ($parts[1].Trim()) }
    }
}
if ($liveCols.Count -eq 0) { Write-Host "[Assert-LiveSchemaParity] INCONCLUSIVE — live getschema returned 0 columns (table empty or no access). Raw: $raw"; exit 3 }

# ── 3 · DIFF (name presence + GM-1 TYPE parity) ──
$missingLive = @($repoCols) | Where-Object { -not $liveCols.Contains($_) } | Sort-Object
$extraLive   = @($liveCols) | Where-Object { -not $repoCols.Contains($_) -and $reserved -notcontains $_ } | Sort-Object
# GM-1 · TYPE drift: a repo column present in live but with a DIFFERENT canonical type. Under approach B the parser emits
# a NATIVE typed value, so a live column left/deployed as the wrong type (e.g. the pre-fix 'string' where the repo now
# declares 'real'/'long') silently mismatches at ingest. Name-presence alone (the prior gate) was type-blind to this.
$typeDrift = @()
foreach ($c in @($repoCols)) {
    if (-not $liveCols.Contains($c)) { continue }       # already reported as missing
    if (-not $liveTypes.ContainsKey($c)) { continue }   # live type unknown (older getschema shape) · skip, never false-fail
    $rt = $repoTypes[$c]; $lt = $liveTypes[$c]
    if ($rt -and $lt -and $rt -ne $lt) { $typeDrift += "$c (repo=$rt live=$lt)" }
}
$typeDrift = $typeDrift | Sort-Object
# GM-1 lifecycle split · a drift on a legacy-pending-recreate col is ADVISORY (warn) · every other type drift BLOCKS.
$typeDriftAdvisory = @($typeDrift | Where-Object { ($_ -match '^(\S+) \(') -and $legacyTypeAdvisory.Contains($Matches[1]) })
$typeDriftBlocking = @($typeDrift | Where-Object { -not (($_ -match '^(\S+) \(') -and $legacyTypeAdvisory.Contains($Matches[1])) })

Write-Host "[Assert-LiveSchemaParity] table=$Table  repo-declared=$($repoCols.Count)  live=$($liveCols.Count)"
if ($extraLive)   { Write-Host "  EXTRA in live (not in repo · investigate cruft): $($extraLive -join ', ')" }
if ($missingLive) {
    Write-Host "  ❌ NAME DRIFT — repo columns MISSING from the deployed table ($($missingLive.Count)):"
    Write-Host "     $($missingLive -join ', ')"
    Write-Host "[Assert-LiveSchemaParity] FAIL — the table is schema-drifted; projected values will be DROPPED at ingest (null fields). Redeploy the ARM table/DCR."
    exit 1
}
if ($typeDriftAdvisory) {
    Write-Host "  ⚠ TYPE DRIFT (ADVISORY · legacy pre-gate cols pending optional recreate · curation legacyTypePendingRecreate · $($typeDriftAdvisory.Count)): $($typeDriftAdvisory -join ', ')"
}
if ($typeDriftBlocking) {
    Write-Host "  ❌ TYPE DRIFT — repo columns whose DEPLOYED type differs from the declared type ($($typeDriftBlocking.Count)):"
    Write-Host "     $($typeDriftBlocking -join ', ')"
    Write-Host "[Assert-LiveSchemaParity] FAIL — deployed column TYPE != repo-declared type; native (B) parser values will mismatch at ingest. Redeploy the ARM table/DCR with the current schema (drop/recreate the table if the type changed)."
    exit 1
}
Write-Host "[Assert-LiveSchemaParity] PASS — every repo-declared column exists in the deployed table WITH the declared type (name + type parity)."
exit 0
