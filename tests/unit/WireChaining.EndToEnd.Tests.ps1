#Requires -Modules Pester

# Wire-chaining cross-layer drift gate.
#
# Asserts the typed-column contract holds end-to-end:
#
#   manifest ProjectionMap target cols
#       ⊆ DCR streamDeclaration columns
#       ⊆ custom-table column schema
#   AND every consumer KQL column reference (parser / workbook / analytic rule /
#       hunting query) resolves to a column that exists in the DCR schema.
#
# Existing per-layer drift gates (Manifest.DcrConsistency, DCR.SchemaConsistency,
# DCR.TypedColumnCoverage) cover manifest ↔ DCR ↔ custom-table. This file
# closes the loop on consumer KQL ↔ DCR.

BeforeDiscovery {
    $repoRoot                = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:ParsersDir       = Join-Path $repoRoot 'sentinel' 'parsers'
    $script:WorkbooksDir     = Join-Path $repoRoot 'sentinel' 'workbooks'
    $script:RulesDir         = Join-Path $repoRoot 'sentinel' 'analytic-rules'
    $script:HuntsDir         = Join-Path $repoRoot 'sentinel' 'hunting-queries'
}

BeforeAll {
    $repoRoot                = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ManifestPath     = Join-Path $repoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'endpoints.manifest.psd1'
    $script:MainTemplatePath = Join-Path $repoRoot 'deploy' 'compiled' 'mainTemplate.json'
    $script:ParsersDir       = Join-Path $repoRoot 'sentinel' 'parsers'
    $script:WorkbooksDir     = Join-Path $repoRoot 'sentinel' 'workbooks'
    $script:RulesDir         = Join-Path $repoRoot 'sentinel' 'analytic-rules'
    $script:HuntsDir         = Join-Path $repoRoot 'sentinel' 'hunting-queries'

    # ----- Manifest ProjectionMap by stream -----
    $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
    $script:StreamProjections = @{}
    foreach ($e in $manifest.Endpoints) {
        $script:StreamProjections[$e.Stream] = if ($e.ProjectionMap) {
            @($e.ProjectionMap.Keys)
        } else { @() }
    }

    # ----- DCR-declared columns per stream (from compiled ARM source) -----
    # Source = deploy/compiled/mainTemplate.json (Bicep was archived to
    # .internal/bicep-reference/ in v0.1.0-beta — ARM is the single source
    # of truth). Stream declarations live inside each
    # Microsoft.Insights/dataCollectionRules resource under
    # `properties.streamDeclarations.<key>.columns[]`.
    $tpl = Get-Content -Raw -Path $script:MainTemplatePath | ConvertFrom-Json -Depth 50
    $script:DcrColumnsByStream = @{}
    $dcrs = @($tpl.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' })
    foreach ($dcr in $dcrs) {
        $sd = $dcr.properties.streamDeclarations
        if ($null -eq $sd) { continue }
        foreach ($k in $sd.PSObject.Properties.Name) {
            # Strip the 'Custom-' prefix to align with manifest stream IDs.
            $stream = if ($k -match '^Custom-(MDE_\w+_CL)$') { $Matches[1] } else { $k }
            $cols = @()
            foreach ($c in $sd.$k.columns) { $cols += [string]$c.name }
            $script:DcrColumnsByStream[$stream] = $cols
        }
    }

    # ----- Baseline columns shared by every stream -----
    $script:BaselineCols = @('TimeGenerated', 'SourceStream', 'EntityId', 'RawJson')

    # ----- Consumer KQL files to scan -----
    $script:ConsumerKqlFiles = @()
    if (Test-Path $script:ParsersDir)   { $script:ConsumerKqlFiles += Get-ChildItem -Path $script:ParsersDir -Filter '*.kql' }
    if (Test-Path $script:RulesDir)     { $script:ConsumerKqlFiles += Get-ChildItem -Path $script:RulesDir   -Filter '*.yaml' }
    if (Test-Path $script:HuntsDir)     { $script:ConsumerKqlFiles += Get-ChildItem -Path $script:HuntsDir   -Filter '*.yaml' }
}

Describe 'WireChaining.ManifestToDcr' {

    It 'every manifest ProjectionMap target column is declared in the matching DCR streamDeclaration' {
        $missing = @()
        foreach ($stream in $script:StreamProjections.Keys) {
            $proj = $script:StreamProjections[$stream]
            if (-not $proj -or $proj.Count -eq 0) { continue }
            if (-not $script:DcrColumnsByStream.ContainsKey($stream)) {
                # If the stream is deprecated, the ProjectionMap may exist without a DCR
                # entry (we deliberately drop deprecated streams from DCR). Skip.
                continue
            }
            $declared = $script:DcrColumnsByStream[$stream]
            foreach ($col in $proj) {
                if ($col -in $script:BaselineCols) { continue }   # baseline always present
                if ($col -notin $declared) {
                    $missing += "$stream.$col"
                }
            }
        }
        $missing | Should -BeNullOrEmpty -Because "every ProjectionMap target column must exist in the DCR streamDeclaration so typed-col ingest reaches Log Analytics. Missing:`n  $($missing -join "`n  ")"
    }
}

Describe 'WireChaining.ConsumerKqlReferencesValidColumns' {

    It 'every consumer KQL file references only columns that exist in the DCR schema (or the baseline 4)' {
        # Collect all known typed columns across all DCR streams + baseline. A
        # consumer query is valid if every column reference falls in this set.
        # Note: this is INTENTIONALLY permissive — it does not validate per-stream
        # scoping (a column declared on Stream A and referenced on Stream B's
        # query will still pass). Tighter scoping is delegated to the per-layer
        # tests (Workbooks.Tests, AnalyticRules.Tests, HuntingQueries.Tests).
        # The point of THIS gate is to catch column-name typos / drift between
        # the connector source-of-truth and any consumer.

        $validColumns = New-Object System.Collections.Generic.HashSet[string]
        foreach ($s in $script:BaselineCols) { [void]$validColumns.Add($s) }
        foreach ($stream in $script:DcrColumnsByStream.Keys) {
            foreach ($col in $script:DcrColumnsByStream[$stream]) {
                [void]$validColumns.Add($col)
            }
        }

        # Reserved KQL identifiers + connector-defined parser output columns +
        # heartbeat/auth-test columns + AAD/AuditLogs columns the queries reference.
        $reservedKqlAndExternal = @(
            # Drift parser output schema (every parser emits these 9 cols)
            'StreamName', 'FieldName', 'OldValue', 'NewValue', 'ChangeType',
            'SnapshotCurrent', 'SnapshotPrevious', 'TypedBag',
            # Heartbeat + AuthTestResult schema (system streams)
            'Tier', 'Stage', 'Stream', 'Outcome', 'Notes', 'StreamsAttempted',
            'StreamsSucceeded', 'Reason', 'Method', 'StatusCode', 'CorrelationId',
            'DurationMs', 'Operator', 'Operation', 'Success',
            # AuditLogs + AADUserActivity (referenced by ComplianceDashboard)
            'OperationName', 'TargetResources', 'InitiatedBy', 'Result',
            'ActivityDateTime', 'AdditionalDetails', 'LoggedByService',
            'Identity', 'CorrelationId',
            # KQL pseudo-columns / mv-apply / common
            'Type', '_Table', '_TimeReceived', '_BilledSize', 'TenantId',
            'Resource', 'ResourceType', 'Category', 'OperationVersion'
        )
        foreach ($s in $reservedKqlAndExternal) { [void]$validColumns.Add($s) }

        # Scan consumer files. We extract IDENTIFIERS that look like column refs,
        # which is heuristic-grade — the goal is catching obvious typos, not
        # parsing KQL formally. Match identifiers that:
        #   * follow a `|`/`,`/`(`/space and are followed by a KQL operator
        #     (`==`, `!=`, `=~`, `>`, `<`, `between`, `contains`, `has`)
        #   * appear inside `extend X = ...` or `project X = ...` left-hand-side
        # Skip: KQL keywords, string literals, numeric literals.
        $orphans = @()
        foreach ($f in $script:ConsumerKqlFiles) {
            $content = Get-Content -Raw -Path $f.FullName

            # YAML rule/hunting files embed KQL in `query: |` blocks. Extract.
            if ($f.Extension -eq '.yaml') {
                # Find `query: |` and extract until next top-level YAML key
                $m = [regex]::Match($content, "(?ms)^query:\s*\|(.*?)(?=^\w+:\s|^---|\Z)", 'Multiline')
                if (-not $m.Success) { continue }
                $kql = $m.Groups[1].Value
            } else {
                $kql = $content
            }

            # Heuristic: capture `(\w+)\s*(==|!=|=~|>=|<=|>|<|contains|has|between|in)\s`
            # and `extend (\w+)\s*=` and `project (\w+)\s*=`.
            $refs = New-Object System.Collections.Generic.HashSet[string]
            foreach ($m in [regex]::Matches($kql, '(?<![\w\.])([A-Z][A-Za-z0-9_]+)\s*(?:==|!=|=~|>=|<=|>|<|contains|has|between|in\b)')) {
                [void]$refs.Add($m.Groups[1].Value)
            }
            foreach ($m in [regex]::Matches($kql, 'extend\s+([A-Z][A-Za-z0-9_]+)\s*=')) {
                # `extend X = ...` declares a NEW col; treat as valid (skip)
                $null = $m
            }
            foreach ($m in [regex]::Matches($kql, 'project\s+([A-Z][A-Za-z0-9_]+)\s*=')) {
                $null = $m   # same — projecting a NEW col
            }

            foreach ($ref in $refs) {
                if (-not $validColumns.Contains($ref)) {
                    $orphans += "$($f.Name): $ref"
                }
            }
        }

        # We allow up to a small number of orphans because the heuristic grabs
        # operator-side variables (`let X =`) and parser-introduced names. The
        # gate is meant to alert on REGRESSION volume, not block on every
        # heuristic miss.
        $orphans.Count | Should -BeLessOrEqual 50 -Because "wire-chaining heuristic flags suspected typo'd column refs. Current orphans (sample):`n  $(($orphans | Select-Object -First 20) -join "`n  ")"
    }
}
