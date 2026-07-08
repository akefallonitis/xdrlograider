#Requires -Version 7.4
<#
.SYNOPSIS
Per-Category expansion orchestrator — the catalogue's SelectionScore ship-gate + the §6 self-learning expansion loop.

.DESCRIPTION
Uses the catalogue's evidence-coverage SelectionScore to pick the next Category, then
runs the 6-step expansion loop:
  1. Score remaining catalog entries (NormalizedRowCount + Complexity + NoPathParam + IngestionMode + LicenseFit)
  2. Build manifest entry stub from 4-source provenance (Live + Postman + OpenAPI + XDRInternals reference)
  3. Generate per-category-schemas JSON (DCR + workspace table)
  4. Rebuild mainTemplate from foundation + ALL per-category artifacts (via Build-MainTemplate.ps1 · incl. per-DCR role)
  5. Generate Pester replay test from lab fixture
  6. Run the pre-push gauntlet → exit 0

Modes:
  -Pick · score remaining catalog · return top entry as JSON
  -Validate <opKey> · run the evidence pipeline + schema parity for one Op
  -Generate <opKey> -Category <group> · REAL generation · invokes, in order:
      1. dev-tools/Generate-Manifest.ps1     (catalogue.json -> manifests/<Portal>/<Category>.psd1)
      2. dev-tools/Build-PerCategorySchema.ps1 (manifest -> deploy/per-category-schemas/<Portal>-<Category>.json + nested ARM)
      3. dev-tools/Build-MainTemplate.ps1     (SOLE mainTemplate writer · rebuild from foundation + ALL per-category artifacts · incl. per-DCR Monitoring-Metrics-Publisher role · gauntlet axis 36 regen-diff)
      4. scaffold tests/replay/<Portal>/<Category>/<OperationKey>.Tests.ps1 (per-Op replay Pester · if absent)
    Use -ManifestOutPath / -TemplatePath / -SchemaRepoRoot to target a TEMP sandbox (never overwrite committed artifacts when testing).

Aligns with the consolidated SSOT (lexical-discovering-babbage.md): the cataloguing ship-gate + the §6
self-learning expansion loop. (Authored against the superseded plan v11; the functional contract is unchanged.)
#>
[CmdletBinding()]
param(
    [ValidateSet('Pick','Validate','Generate')] [string] $Mode = 'Pick',
    [string] $OperationKey,
    [string] $InventoryPath = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'references/INVENTORY.md'),
    [string] $ManifestsRoot = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'manifests'),
    [string] $Portal = 'Defender',
    # Generate mode · the Category(group) to generate artifacts for (catalogue x-tagGroups GROUP · e.g. Operations).
    [string] $Category = 'Operations',
    # Generate mode · optional override roots so the orchestrator can target a TEMP sandbox instead of the
    # committed artifacts (HARD CONSTRAINT 2 · never overwrite committed manifests/mainTemplate when testing).
    # Defaults to the real repo paths for production use.
    [string] $ManifestOutPath,                 # default: manifests/<Portal>/<Category>.psd1 (Generate-Manifest -OutPath)
    [string] $TemplatePath,                    # default: deploy/mainTemplate.json (Build-MainTemplate -OutputPath · temp-sandbox override)
    [string] $SchemaRepoRoot                   # default: repo root (Build-PerCategorySchema -RepoRoot · writes deploy/per-category-schemas/)
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path "$PSScriptRoot\.." | ForEach-Object Path
# Spaced-category fix · the CANONICAL tokenizer for the replay-scaffold table/stream names (NOT a copy · the same
# Get-XdrCategoryToken the deploy-assemblers + Generate-Manifest use, so a spaced Category tokenizes identically).
Import-Module (Join-Path $repoRoot 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1') -Force -DisableNameChecking -ErrorAction Stop

function Get-XdrValidatedOps {
    $validated = @()
    $portalDir = Join-Path $ManifestsRoot $Portal
    if (-not (Test-Path $portalDir)) { return $validated }
    foreach ($f in (Get-ChildItem $portalDir -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
        try {
            $m = Import-PowerShellDataFile $f.FullName -ErrorAction Stop
            if ($m.Operations) {
                foreach ($op in $m.Operations) {
                    if ($op.OperationKey) { $validated += $op.OperationKey }
                }
            }
        } catch { Write-Warning "manifest parse fail: $($f.Name) · $($_.Exception.Message)" }
    }
    return $validated
}

function Get-XdrRemainingCatalog {
    # A6 · CATALOGUE-driven (single source of truth · §5.1). Defender ops not yet onboarded (not in
    # manifests/Defender/*.psd1) and NOT hard-Excluded (write/official-dup), RANKED by the dynamic
    # SelectionScore (value-first). Returns op-keys score-sorted; caches per-key score for Get-XdrOpScore.
    $catPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'references/inventory/nodoc-defender-xdr/catalogue.json'
    if (-not (Test-Path $catPath)) {
        Write-Warning "catalogue.json not present at $catPath · pick disabled"
        return @()
    }
    $validated = Get-XdrValidatedOps
    $script:XdrCatScores = @{}   # OperationKey -> SelectionScore (consumed by Get-XdrOpScore)
    $cat = Get-Content $catPath -Raw | ConvertFrom-Json
    $ranked = foreach ($op in $cat.Operations) {
        if ($op.Status -eq 'Excluded') { continue }      # hard exclusions only (never pruned otherwise · dynamic select)
        if ($op.Operation -in $validated) { continue }   # already onboarded
        $sc = if ($op.PSObject.Properties['SelectionScore']) { [int]$op.SelectionScore } else { 0 }
        $script:XdrCatScores[[string]$op.Operation] = $sc
        [pscustomobject]@{ Key = [string]$op.Operation; Score = $sc }
    }
    return (@($ranked) | Sort-Object Score -Descending | ForEach-Object { $_.Key } | Select-Object -Unique)
}

function Get-XdrOpScore {
    param([string]$OpKey)
    # A6 · the score IS the catalogue's dynamic SelectionScore (§5.1 · OfficialApiOverlap·DuplicateClass·
    # ValueClass·ReadSemantics), cached by Get-XdrRemainingCatalog — value-first + evidence-based, not a naming hunch.
    if ($script:XdrCatScores -and $script:XdrCatScores.ContainsKey($OpKey)) { return [int]$script:XdrCatScores[$OpKey] }
    return 50   # fallback if the catalogue wasn't loaded (e.g. Get-XdrOpScore called standalone)
}

function New-XdrReplayTestScaffold {
    <#
    .SYNOPSIS
    Write a real, parseable per-Op replay Pester test scaffold for <Portal>/<Category>/<OperationKey>.
    Offline-provable assertions (manifest contract + schema parity) are live; the live-fixture fan-out /
    ProjectionMap block is -Skip-gated until the operator captures the lab fixture (§11.1 #7).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Portal,
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $OperationKey
    )
    # Single-quoted here-string (literal · no $-expansion of the test's own Pester variables) with __TOKENS__
    # substituted afterward · keeps the emitted test's $script:/$_ intact without backtick-escaping every one.
    $tpl = @'
# Per-Op Pester replay test · __PORTAL__/__CATEGORY__/__OPKEY__
# GENERATED scaffold (tools/Onboard-NextCategory.ps1 -Generate). Offline contract + schema-parity assertions
# are live now; the live-fixture fan-out + ProjectionMap block is -Skip-gated until the operator captures the
# lab fixture and fills Provenance.Live (plan §11.1 #7). Remove the -Skip once the fixture exists.

#Requires -Module Pester

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $env:PSModulePath = (Join-Path $script:RepoRoot 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module (Join-Path $script:RepoRoot 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    $script:Manifest = Import-PowerShellDataFile -Path (Join-Path $script:RepoRoot 'manifests\__PORTAL__\__CATEGORY__.psd1') -ErrorAction Stop
    $script:Op = @($script:Manifest.Operations | Where-Object { $_.OperationKey -eq '__OPKEY__' })[0]
}

Describe 'Manifest contract · __PORTAL__/__CATEGORY__/__OPKEY__' {
    It 'manifest entry exists for __OPKEY__ · no IsActive flag (v11 §4.11)' {
        $script:Op | Should -Not -BeNullOrEmpty
        $script:Op.OperationKey | Should -Be '__OPKEY__'
        $script:Op.ContainsKey('IsActive') | Should -BeFalse
    }
    It 'carries the required §4.11 fields' {
        foreach ($f in @('Method','SubPortal','Path','ResponseShape','IngestionMode','Cadence','RequiresProducts','ProjectionMap','DcrStreamName','WorkspaceTable','DcrImmutableIdEnvVar','Provenance')) {
            $script:Op.ContainsKey($f) | Should -BeTrue -Because "missing $f"
        }
    }
    It 'canonical table + stream naming' {
        $script:Op.WorkspaceTable | Should -Be '__PORTAL___CATEGORY__CL_PLACEHOLDER'
        $script:Op.DcrStreamName  | Should -Be 'Custom-__PORTAL___CATEGORY__CL_PLACEHOLDER'
    }
}

Describe 'Schema parity · manifest to ARM artifact (per-category-schema)' {
    BeforeAll {
        $script:Artifact = Get-Content (Join-Path $script:RepoRoot 'deploy\per-category-schemas\__PORTAL__-__CATEGORY__.json') -Raw | ConvertFrom-Json -Depth 50
    }
    It 'DCR stream cols == table cols (set-equal · axis 14)' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcr   = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        $table = @($script:Artifact.TableResource.properties.schema.columns | ForEach-Object { "$($_.name):$($_.type)" }) | Sort-Object
        Compare-Object $dcr $table | Should -BeNullOrEmpty
    }
    It 'every manifest ProjectionMap key is present as a DCR column' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrNames = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name })
        foreach ($k in $script:Op.ProjectionMap.Keys) { $dcrNames | Should -Contain $k }
    }
    It 'TenantId is NOT user-declared (LA auto-populates · DCR rejects)' {
        $streamKey = $script:Artifact.DcrResource.properties.streamDeclarations.PSObject.Properties.Name | Select-Object -First 1
        $dcrNames = @($script:Artifact.DcrResource.properties.streamDeclarations.$streamKey.columns | ForEach-Object { $_.name })
        $dcrNames | Should -Not -Contain 'TenantId'
    }
}

Describe 'Live fan-out + ProjectionMap · __OPKEY__' -Skip {
    # TODO(operator · §11.1 #7): capture the live fixture, set Provenance.Live, then REMOVE the -Skip above.
    # Mirror tests/replay/Defender/Operations/GetHistory.Tests.ps1: ConvertTo-XdrRows fan-out (B1 · no row drop),
    # Apply-XdrProjectionMap typed-col correctness against real row[0], and Compress-XdrRawJson RawJson presence.
    It 'fixture replay proves N>0 rows + typed projection (fill in after fixture capture)' {
        $true | Should -BeTrue
    }
}
'@
    # Spaced-category fix: WorkspaceTable/DcrStreamName are TOKENIZED (e.g. Defender_ExposureManagement_CL), matching the
    # catalogue + the deploy-assemblers — NOT the raw spaced Category. The other __CATEGORY__ slots (manifest/schema paths,
    # Describe titles) stay raw $Category because those artifact FILENAMES carry the spaced category (the established
    # per-category-schema convention). Latent bug: the synthetic EXIT-GATE called Build-MainTemplate directly, never this scaffold.
    $catTok = Get-XdrCategoryToken -Category $Category
    $body = $tpl.
        Replace('__PORTAL___CATEGORY__CL_PLACEHOLDER', "${Portal}_${catTok}_CL").
        Replace('__PORTAL__', $Portal).
        Replace('__CATEGORY__', $Category).
        Replace('__OPKEY__', $OperationKey)
    Set-Content -Path $Path -Value $body -Encoding utf8
}

switch ($Mode) {
    'Pick' {
        $remaining = Get-XdrRemainingCatalog
        if ($remaining.Count -eq 0) {
            Write-Host "[Onboard-NextCategory] No remaining catalog entries · all Defender Operations validated OR inventory not populated"
            exit 0
        }
        $scored = foreach ($k in $remaining) {
            [PSCustomObject]@{ OperationKey = $k; Score = (Get-XdrOpScore $k) }
        }
        $top = $scored | Sort-Object Score -Descending | Select-Object -First 5
        Write-Host "[Onboard-NextCategory] Top 5 candidates (lightweight scoring · full §4.19 in Validate mode):"
        $top | Format-Table -AutoSize | Out-Host
        # Return as JSON for automation
        $top | ConvertTo-Json -Depth 5
        exit 0
    }
    'Validate' {
        if (-not $OperationKey) { Write-Error "-OperationKey required for Validate mode"; exit 1 }
        Write-Host "[Onboard-NextCategory] Validate mode · OperationKey=$OperationKey"
        Write-Host '  Step 1 · 4-source provenance check (Live + Postman + OpenAPI + XDRInternals reference)'
        Write-Host '  Step 2 · ProjectionMap JSONPath resolution against lab fixture'
        Write-Host '  Step 3 · DCR ↔ workspace table column parity check'
        Write-Host '  Step 4 · Schema-parity vs per-category-schemas JSON'
        Write-Host ''
        Write-Host '  Delegating to tools/Validate-Manifests.ps1 (canonical §4.17 evidence pipeline)'
        & pwsh -NoProfile -File (Join-Path $repoRoot 'tools/Validate-Manifests.ps1') -Detailed
        exit $LASTEXITCODE
    }
    'Generate' {
        if (-not $OperationKey) { Write-Error "-OperationKey required for Generate mode"; exit 1 }
        if (-not $Category)     { Write-Error "-Category required for Generate mode";     exit 1 }

        # Resolve effective output targets · default to committed repo paths · override for TEMP-sandbox testing.
        $effManifestOut = if ($ManifestOutPath) { $ManifestOutPath } else { Join-Path $repoRoot "manifests/$Portal/$Category.psd1" }
        $effTemplate    = if ($TemplatePath)    { $TemplatePath }    else { Join-Path $repoRoot 'deploy/mainTemplate.json' }
        $effSchemaRoot  = if ($SchemaRepoRoot)  { $SchemaRepoRoot }  else { $repoRoot }

        Write-Host "[Onboard-NextCategory] Generate mode · Portal=$Portal · Category=$Category · OperationKey=$OperationKey"
        Write-Host "  manifest out   : $effManifestOut"
        Write-Host "  template        : $effTemplate"
        Write-Host "  schema repoRoot : $effSchemaRoot (writes deploy/per-category-schemas/$Portal-$Category.json)"
        Write-Host ''

        $genManifest  = Join-Path $repoRoot 'dev-tools/Generate-Manifest.ps1'
        $buildSchema  = Join-Path $repoRoot 'dev-tools/Build-PerCategorySchema.ps1'
        $buildMt      = Join-Path $repoRoot 'dev-tools/Build-MainTemplate.ps1'
        foreach ($t in @($genManifest, $buildSchema, $buildMt)) {
            if (-not (Test-Path $t)) { Write-Error "Generate dependency missing: $t"; exit 1 }
        }
        $null = New-Item -ItemType Directory -Path (Split-Path $effManifestOut) -Force -ErrorAction SilentlyContinue

        # ── Step 1 · catalogue.json -> manifest .psd1 ───────────────────────────────────────────────
        Write-Host '  Step 1 · Generate-Manifest (catalogue -> manifest .psd1)'
        & pwsh -NoProfile -File $genManifest -Portal $Portal -Group $Category -OutPath $effManifestOut
        if ($LASTEXITCODE -ne 0) { Write-Error "Step 1 Generate-Manifest failed (exit $LASTEXITCODE)"; exit 1 }

        # Build-PerCategorySchema reads manifests/<Portal>/<Category>.psd1 under its -RepoRoot. When the manifest
        # was written elsewhere (TEMP -ManifestOutPath), stage a copy at the expected location under the schema
        # repoRoot so the generator finds it · without ever touching the committed tree when -SchemaRepoRoot is TEMP.
        $expectedManifest = Join-Path $effSchemaRoot "manifests/$Portal/$Category.psd1"
        if ((Resolve-Path $effManifestOut).Path -ne (Join-Path $effSchemaRoot "manifests/$Portal/$Category.psd1" | ForEach-Object { try { (Resolve-Path $_ -ErrorAction Stop).Path } catch { $_ } })) {
            $null = New-Item -ItemType Directory -Path (Split-Path $expectedManifest) -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $effManifestOut -Destination $expectedManifest -Force
        }

        # ── Step 2 · manifest -> per-category schema JSON + nested ARM block ─────────────────────────
        Write-Host '  Step 2 · Build-PerCategorySchema (manifest -> per-category schema JSON + nested ARM)'
        & pwsh -NoProfile -File $buildSchema -Portal $Portal -Category $Category -RepoRoot $effSchemaRoot -OutputMode JSON
        if ($LASTEXITCODE -ne 0) { Write-Error "Step 2 Build-PerCategorySchema failed (exit $LASTEXITCODE)"; exit 1 }
        $schemaArtifact = Join-Path $effSchemaRoot "deploy/per-category-schemas/$Portal-$Category.json"
        if (-not (Test-Path $schemaArtifact)) { Write-Error "Step 2 produced no schema artifact at $schemaArtifact"; exit 1 }

        # ── Step 3 · REBUILD mainTemplate.json from foundation + ALL per-category artifacts ───────────
        #    Build-MainTemplate is the SOLE mainTemplate writer (gauntlet axis 36 regen->diff). It emits the
        #    per-DCR Monitoring-Metrics-Publisher role grant each category needs to publish metrics — the
        #    an earlier per-category injector pattern OMITTED that grant, so a 2nd category's DCR
        #    would 403 on publish -> silent 0-rows. Build-PerCategorySchema (Step 2) just wrote THIS category's
        #    artifact under $effSchemaRoot/deploy/per-category-schemas/, so the rebuild picks it up with the rest.
        Write-Host '  Step 3 · Build-MainTemplate (rebuild mainTemplate from foundation + all per-category artifacts · incl. per-DCR role)'
        $effSchemaDir = Join-Path $effSchemaRoot 'deploy/per-category-schemas'
        & pwsh -NoProfile -File $buildMt -OutputPath $effTemplate -SchemaDir $effSchemaDir
        if ($LASTEXITCODE -ne 0) { Write-Error "Step 3 Build-MainTemplate failed (exit $LASTEXITCODE)"; exit 1 }

        # ── Step 4 · scaffold per-Op replay Pester test (only if absent · never clobber a completed test) ──
        Write-Host '  Step 4 · scaffold per-Op replay Pester test'
        $replayDir  = Join-Path $repoRoot "tests/replay/$Portal/$Category"
        $replayFile = Join-Path $replayDir "$OperationKey.Tests.ps1"
        if (Test-Path $replayFile) {
            Write-Host "    · replay test already exists · left untouched: $replayFile"
        } else {
            $null = New-Item -ItemType Directory -Path $replayDir -Force -ErrorAction SilentlyContinue
            New-XdrReplayTestScaffold -Path $replayFile -Portal $Portal -Category $Category -OperationKey $OperationKey
            Write-Host "    · scaffolded: $replayFile"
        }

        Write-Host ''
        Write-Host "[Onboard-NextCategory] Generate DONE for $Portal/$Category/$OperationKey"
        Write-Host '  Next (operator · per §11.1 #7): capture live fixture · fill ProjectionMap · then:'
        Write-Host '    pwsh tools/Validate-Manifests.ps1 -Detailed   # evidence + schema parity'
        Write-Host '    pwsh tools/Run-PrePushGauntlet.ps1            # pre-push gate (offline · exactly-once replay + schema regen->diff)'
        exit 0
    }
}
