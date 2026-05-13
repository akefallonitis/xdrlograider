# Annotate-ReadSemantics.ps1
#
# Walks every metadata.json under references/ and adds a `readSemantics` field
# derived from operationId / slug prefix. Idempotent.
#
# Classification:
#   read    — slug starts with: List|Get|Query|Search|Filter|Export|Probe|Fetch|Read|Inspect|Audit|Find|Resolve|Validate|Check|Test
#   write   — slug starts with: Create|Update|Delete|Save|Add|Remove|Move|Patch|Modify|Submit|Invoke|Run|Refresh|Reset|Reload|Reboot|Trigger|Send|Post|Put|Push|Apply|Approve|Reject|Suppress|Unsuppress|Disable|Enable|Override|Set
#   unknown — neither
#
# After Annotate-ReadSemantics, run Resolve-Unknowns.ps1 (companion) to bulk-mark
# semantic-aware unknowns (Count*, Aggregate*, Autocomplete* → read; Log* → write).

#Requires -Version 7.0
[CmdletBinding()]
param([string]$ReferencesRoot = "$PSScriptRoot\..\references")

$ErrorActionPreference = 'Stop'

$readPrefixes  = @('List','Get','Query','Search','Filter','Export','Probe','Fetch','Read','Inspect','Audit','Find','Resolve','Validate','Check','Test')
$writePrefixes = @('Create','Update','Delete','Save','Add','Remove','Move','Patch','Modify','Submit','Invoke','Run','Refresh','Reset','Reload','Reboot','Trigger','Send','Post','Put','Push','Apply','Approve','Reject','Suppress','Unsuppress','Disable','Enable','Override','Set')

# Semantic-aware overrides for known unknowns (per Phase 0 deep audit)
$readOverridePrefixes  = @('Count','Aggregate','Autocomplete','Has','Is','Generate','GoHunt','Prefetch')
$writeOverridePrefixes = @('Log')

function Get-ReadSemantics {
    param([string]$Slug, [string]$OperationId)
    $name = if ($OperationId) { $OperationId -replace '^[^.]+\.', '' } else { $Slug }
    foreach ($p in $readPrefixes)  { if ($name -clike "$p*") { return @{ kind='read';    reason='prefix-explicit' } } }
    foreach ($p in $writePrefixes) { if ($name -clike "$p*") { return @{ kind='write';   reason='prefix-explicit' } } }
    foreach ($p in $readOverridePrefixes)  { if ($name -clike "$p*") { return @{ kind='read';    reason='semantic-override' } } }
    foreach ($p in $writeOverridePrefixes) { if ($name -clike "$p*") { return @{ kind='write';   reason='semantic-override' } } }
    return @{ kind='unknown'; reason='no-prefix-match' }
}

$counts = @{ read=0; write=0; unknown=0 }
$writeList   = @()
$unknownList = @()

$metaFiles = Get-ChildItem -Path $ReferencesRoot -Recurse -Filter 'metadata.json' -ErrorAction SilentlyContinue
Write-Host "Annotating $($metaFiles.Count) metadata.json files..." -ForegroundColor Cyan

foreach ($mf in $metaFiles) {
    try {
        $raw  = Get-Content $mf.FullName -Raw
        $meta = $raw | ConvertFrom-Json -AsHashtable
    } catch { continue }

    $rs = Get-ReadSemantics -Slug $meta.slug -OperationId $meta.operationId
    $meta['readSemantics']       = $rs.kind
    $meta['readSemanticsReason'] = $rs.reason

    # Defender-only tracking lists
    if ($meta.portal -eq 'defender') {
        $counts[$rs.kind]++
        if ($rs.kind -eq 'write')   { $writeList   += [pscustomobject]@{ SubArea=$meta.subArea; Slug=$meta.slug; OperationId=$meta.operationId } }
        if ($rs.kind -eq 'unknown') { $unknownList += [pscustomobject]@{ SubArea=$meta.subArea; Slug=$meta.slug; OperationId=$meta.operationId } }
    }

    $meta | ConvertTo-Json -Depth 12 | Set-Content -Path $mf.FullName -NoNewline
}

Write-Host ""
Write-Host "=== Defender ReadSemantics distribution ===" -ForegroundColor Cyan
Write-Host "  read   : $($counts.read)"
Write-Host "  write  : $($counts.write)"
Write-Host "  unknown: $($counts.unknown)"
Write-Host ""

# Emit audit MD
$auditFile = Join-Path $ReferencesRoot 'defender\_READ_SEMANTICS_AUDIT.md'
$md = @()
$md += "# Defender ReadSemantics audit"
$md += ""
$md += "Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
$md += ""
$md += "## Distribution"
$md += ""
$md += "| Kind | Count |"
$md += "|---|---:|"
$md += "| read | $($counts.read) |"
$md += "| write | $($counts.write) |"
$md += "| unknown | $($counts.unknown) |"
$md += "| **Total Defender** | **$($counts.read + $counts.write + $counts.unknown)** |"
$md += ""
$md += "## Write-shaped endpoints (excluded from Phase 1 manifest — we are READ-ONLY connector)"
$md += ""
$md += "| Sub-area | Slug | OperationId |"
$md += "|---|---|---|"
foreach ($w in ($writeList | Sort-Object SubArea,Slug)) {
    $md += "| $($w.SubArea) | $($w.Slug) | ``$($w.OperationId)`` |"
}
$md += ""
$md += "## Unknown-classification endpoints (manual review needed)"
$md += ""
if ($unknownList.Count -eq 0) {
    $md += "_All unknowns auto-classified via semantic overrides._"
} else {
    $md += "| Sub-area | Slug | OperationId |"
    $md += "|---|---|---|"
    foreach ($u in ($unknownList | Sort-Object SubArea,Slug)) {
        $md += "| $($u.SubArea) | $($u.Slug) | ``$($u.OperationId)`` |"
    }
}
$md += ""
Set-Content -Path $auditFile -Value ($md -join "`n") -NoNewline
Write-Host "Audit written: $auditFile" -ForegroundColor Green
