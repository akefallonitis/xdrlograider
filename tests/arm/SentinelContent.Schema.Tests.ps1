#Requires -Modules Pester
<#
.SYNOPSIS
    Validates Sentinel content YAML/JSON files against Microsoft's published
    Sentinel Solutions schema requirements.

.DESCRIPTION
    Complements tests/kql/AnalyticRules.Tests.ps1 (KQL-query-level asserts)
    with file-level schema validation that would catch regressions Microsoft's
    Content Hub reviewer would reject:

      - Analytic rules: required fields (id GUID, severity enum, queryFrequency
        ISO8601 duration, tactics MITRE-valid, enabled=false per best practice)
      - Hunting queries: required fields + author/version/tags metadata
      - createUiDefinition: required blocks (handler, version, parameters)
      - Data Connector card: required fields (id, title, dataTypes >=1)
      - Analytic rule id uniqueness across the release

    These are "would fail Content Hub submission" checks, not "is it KQL-valid"
    (which Parsers.Tests.ps1 handles).
#>

BeforeAll {
    $script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RulesDir     = Join-Path $script:RepoRoot 'sentinel' 'analytic-rules'
    $script:HuntingDir   = Join-Path $script:RepoRoot 'sentinel' 'hunting-queries'
    $script:WorkbookDir  = Join-Path $script:RepoRoot 'sentinel' 'workbooks'
    $script:CreateUiPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'createUiDefinition.json'
    $script:DataConnectorPath = Join-Path $script:RepoRoot 'deploy' 'solution' 'Data Connectors' 'XdrLogRaider_DataConnector.json'

    # MITRE ATT&CK enterprise tactics as recognised by Sentinel (canonical list).
    $script:ValidTactics = @(
        'Reconnaissance', 'ResourceDevelopment', 'InitialAccess', 'Execution',
        'Persistence', 'PrivilegeEscalation', 'DefenseEvasion', 'CredentialAccess',
        'Discovery', 'LateralMovement', 'Collection', 'CommandAndControl',
        'Exfiltration', 'Impact', 'ImpairProcessControl', 'InhibitResponseFunction'
    )

    $script:ValidSeverities = @('Informational', 'Low', 'Medium', 'High')
}

Describe 'Analytic rules YAML schema compliance' {

    BeforeAll {
        $script:RuleFiles = Get-ChildItem -Path $script:RulesDir -Filter '*.yaml'
        $script:Rules = $script:RuleFiles | ForEach-Object {
            $raw = Get-Content $_.FullName -Raw
            # PowerShell 7 has ConvertFrom-Yaml via the PSYaml module, but we can
            # parse the minimal subset we need via regex — keeps the test no-deps.
            [pscustomobject]@{
                Name = $_.Name
                Path = $_.FullName
                Raw  = $raw
                Id   = if ($raw -match '(?m)^id:\s+([0-9a-f-]+)\s*$') { $Matches[1] } else { $null }
                RuleName = if ($raw -match '(?m)^name:\s+(.+?)\s*$') { $Matches[1] } else { $null }
                Severity = if ($raw -match '(?m)^severity:\s+(\w+)\s*$') { $Matches[1] } else { $null }
                Enabled  = if ($raw -match '(?m)^enabled:\s+(true|false)') { [bool]::Parse($Matches[1]) } else { $null }
                Tactics  = if ($raw -match '(?sm)^tactics:\s*\n((?:\s+-\s+\w+\s*\n)+)') {
                    [regex]::Matches($Matches[1], '-\s+(\w+)') | ForEach-Object { $_.Groups[1].Value }
                } else { @() }
                QueryFrequency = if ($raw -match '(?m)^queryFrequency:\s+(\S+)') { $Matches[1] } else { $null }
                QueryPeriod    = if ($raw -match '(?m)^queryPeriod:\s+(\S+)') { $Matches[1] } else { $null }
            }
        }
    }

    It 'ships at least 14 analytic rule YAML files' {
        $script:Rules.Count | Should -BeGreaterOrEqual 14
    }

    It 'every rule has a GUID id' {
        $missing = @($script:Rules | Where-Object { -not $_.Id })
        $missingNames = if ($missing.Count -gt 0) { ($missing | ForEach-Object { $_.Name }) -join ', ' } else { '' }
        $missing.Count | Should -Be 0 -Because "rules missing id: $missingNames"
    }

    It 'every rule id is a valid GUID format (8-4-4-4-12 hex)' {
        foreach ($r in $script:Rules) {
            $r.Id | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -Because "rule $($r.Name) has malformed id: '$($r.Id)'"
        }
    }

    It 'every rule id is unique (no collisions across the release)' {
        $duplicates = @($script:Rules | Group-Object Id | Where-Object Count -gt 1)
        $dupNames = if ($duplicates.Count -gt 0) { ($duplicates | ForEach-Object { $_.Name }) -join ', ' } else { '' }
        $duplicates.Count | Should -Be 0 -Because "duplicate rule ids would cause Sentinel import to fail: $dupNames"
    }

    It 'every rule has a valid severity (Informational / Low / Medium / High)' {
        foreach ($r in $script:Rules) {
            $r.Severity | Should -BeIn $script:ValidSeverities -Because "rule $($r.Name) severity '$($r.Severity)' is not a valid Sentinel severity"
        }
    }

    It 'every rule ships with enabled: false (Sentinel Solutions best practice)' {
        foreach ($r in $script:Rules) {
            $r.Enabled | Should -Be $false -Because "rule $($r.Name) must ship disabled — Microsoft best practice prevents alert-fatigue on customer install"
        }
    }

    It 'every rule has at least one MITRE tactic tagged' {
        foreach ($r in $script:Rules) {
            @($r.Tactics).Count | Should -BeGreaterOrEqual 1 -Because "rule $($r.Name) has no tactics declared"
        }
    }

    It 'compiled sentinelContent.json: every technique matches Sentinel API regex ^T\d+$ (no sub-technique suffix)' {
        # Iteration 5 deploy blocker: Sentinel API rejects T1562.001 with
        # `The technique 'T1562.001' is invalid. The expected format is 'T####'`.
        # Sub-technique fidelity remains in hunting query tags (savedSearches
        # accepts any string). Lock the parent-only invariant on alertRules.
        $compiledPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json
        $rules = @($compiled.resources | Where-Object { $_.type -match 'alertRules' })
        foreach ($r in $rules) {
            foreach ($t in @($r.properties.techniques)) {
                $t | Should -Match '^T\d+$' -Because "rule '$($r.name)' technique '$t' violates Sentinel API regex; strip .NNN sub-technique suffix"
            }
        }
    }

    It 'compiled sentinelContent.json: technique→tactic mappings are MITRE-consistent (T1595 → Reconnaissance)' {
        # Sentinel API also enforces that the declared tactics include at least
        # one tactic that the technique maps to. T1595 = Reconnaissance only.
        $compiledPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json
        $rules = @($compiled.resources | Where-Object { $_.type -match 'alertRules' })
        foreach ($r in $rules) {
            $tac = @($r.properties.tactics)
            $tec = @($r.properties.techniques)
            if ($tec -contains 'T1595') {
                $tac | Should -Contain 'Reconnaissance' -Because "rule '$($r.name)' uses T1595 which is a Reconnaissance technique"
            }
        }
    }

    It 'compiled sentinelContent.json has 34 per-content metadata back-links to the XdrLogRaider Solution' {
        # One metadata resource per content item — 14 alertRules, 9 hunting
        # savedSearches, 7 workbooks (incl. MDE_ActionCenter for Action Center +
        # Device Timeline + Machine Actions surfaces), 4 parser savedSearches
        # (one per cadence tier with snapshot semantics; the fast tier carries
        # events not snapshots so has no parser) = 34. Without these
        # back-links, deployed content shows as "not from a solution" in
        # Sentinel UI even though the Solution package exists.
        $compiledPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json
        $metadata = @($compiled.resources | Where-Object {
            $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        })
        # v0.1.0 GA Phase F.1 added 4 ops analytic rules (XdrOps-*) + 1 ConnectorHealth workbook
        # so total metadata back-links: 18 AnalyticsRule + 9 HuntingQuery + 8 Workbook + 4 Parser = 39
        @($metadata).Count | Should -Be 39 -Because 'v0.1.0 GA: 18 AnalyticsRule (14 detection + 4 XdrOps-*) + 9 HuntingQuery + 8 Workbook (7 + ConnectorHealth) + 4 Parser metadata back-links'

        $byKind = $metadata | Group-Object { $_.properties.kind }
        ($byKind | Where-Object Name -eq 'AnalyticsRule').Count | Should -Be 18  # 14 detection + 4 XdrOps-* (Phase F.1)
        ($byKind | Where-Object Name -eq 'HuntingQuery').Count  | Should -Be 9
        ($byKind | Where-Object Name -eq 'Workbook').Count      | Should -Be 8   # 7 + ConnectorHealth (Phase F.1)
        ($byKind | Where-Object Name -eq 'Parser').Count        | Should -Be 4

        # Every metadata back-link must reference the canonical Solution
        foreach ($m in $metadata) {
            $m.properties.source | Should -Not -BeNullOrEmpty -Because "metadata '$($m.name)' must carry source.kind=Solution"
        }
    }

    It 'compiled sentinelContent.json: every metadata.parentId resolves to a content resource of the matching kind' {
        # The metadata.parentId field must contain a resourceId() expression that
        # references an actual content resource of the matching kind:
        #   AnalyticsRule  → Microsoft.SecurityInsights/alertRules
        #   HuntingQuery   → Microsoft.OperationalInsights/workspaces/savedSearches
        #   Parser         → Microsoft.OperationalInsights/workspaces/savedSearches
        #   Workbook       → Microsoft.Insights/workbooks
        # If a metadata back-link points at a non-existent content item, Sentinel
        # silently breaks the "From: <Solution>" badge — content appears orphaned.
        $compiledPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json
        $metadata = @($compiled.resources | Where-Object {
            $_.type -eq 'Microsoft.OperationalInsights/workspaces/providers/metadata'
        })

        # Build a map of every content resource type/name in the same template.
        # The parentId is an ARM expression — match the substring of resource
        # names referenced via resourceId() / extensionResourceId() calls.
        $contentResources = @($compiled.resources | Where-Object {
            $_.type -in @(
                'Microsoft.OperationalInsights/workspaces/providers/alertRules',
                'Microsoft.OperationalInsights/workspaces/savedSearches',
                'Microsoft.Insights/workbooks'
            )
        })

        $expectedTypes = @{
            'AnalyticsRule' = @('alertRules')
            'HuntingQuery'  = @('savedSearches')
            'Parser'        = @('savedSearches')
            'Workbook'      = @('workbooks')
        }

        foreach ($m in $metadata) {
            $kind = $m.properties.kind
            $expectedTypeFragments = $expectedTypes[$kind]
            $expectedTypeFragments | Should -Not -BeNullOrEmpty -Because "metadata kind '$kind' is not one of AnalyticsRule/HuntingQuery/Parser/Workbook"

            $parentId = $m.properties.parentId
            $parentId | Should -Not -BeNullOrEmpty -Because "metadata '$($m.name)' has empty parentId"

            # ParentId must reference one of the expected content resource types.
            $matched = $false
            foreach ($frag in $expectedTypeFragments) {
                if ($parentId -match $frag) { $matched = $true; break }
            }
            $matched | Should -BeTrue -Because "metadata '$($m.name)' (kind=$kind) parentId '$parentId' does not reference any of: $($expectedTypeFragments -join ', ')"
        }

        # Sanity: counts of metadata kinds should match counts of corresponding
        # content resource types within the same template.
        $alertRuleCount = @($compiled.resources | Where-Object { $_.type -match 'alertRules$' }).Count
        $analyticsMetaCount = @($metadata | Where-Object { $_.properties.kind -eq 'AnalyticsRule' }).Count
        $analyticsMetaCount | Should -Be $alertRuleCount -Because 'one AnalyticsRule metadata back-link per alertRule resource'
    }

    It 'compiled sentinelContent.json: every alertRule emits tactics + techniques as JSON arrays' {
        # Bug bash: Sentinel API rejects scalars on these fields with
        # `Error converting value "DefenseEvasion" to type 'AttackTactic[]'`.
        # The simple YAML parser flattens 1-item lists to scalars; @(...) in
        # Build-SentinelContent.ps1 forces array shape. Lock the invariant.
        $compiledPath = Join-Path $script:RepoRoot 'deploy' 'compiled' 'sentinelContent.json'
        $compiled = Get-Content $compiledPath -Raw | ConvertFrom-Json
        $rules = @($compiled.resources | Where-Object { $_.type -match 'alertRules' })
        $rules.Count | Should -BeGreaterOrEqual 14
        foreach ($r in $rules) {
            $t  = $r.properties.tactics
            $te = $r.properties.techniques
            # ConvertFrom-Json materialises JSON arrays as Object[]; scalars remain string/etc.
            ($t -is [System.Array])  | Should -BeTrue -Because "rule '$($r.name)' tactics must be a JSON array, got: $($t.GetType().Name)"
            ($te -is [System.Array]) | Should -BeTrue -Because "rule '$($r.name)' techniques must be a JSON array, got: $($te.GetType().Name)"
        }
    }

    It 'every rule tactic is a valid MITRE ATT&CK enterprise tactic' {
        foreach ($r in $script:Rules) {
            foreach ($t in $r.Tactics) {
                $t | Should -BeIn $script:ValidTactics -Because "rule $($r.Name) declares unknown tactic '$t'"
            }
        }
    }

    It 'every rule queryFrequency matches ISO8601 duration (PT/P...) OR short form (1h, 15m)' {
        foreach ($r in $script:Rules) {
            $r.QueryFrequency | Should -Match '^(PT?\d+[DHMS]|\d+[dhm])$' -Because "rule $($r.Name) queryFrequency '$($r.QueryFrequency)' is not a valid duration"
        }
    }
}

Describe 'Hunting queries YAML schema compliance' {

    BeforeAll {
        $script:HuntFiles = Get-ChildItem -Path $script:HuntingDir -Filter '*.yaml'
    }

    It 'ships at least 9 hunting query YAML files' {
        @($script:HuntFiles).Count | Should -BeGreaterOrEqual 9
    }

    It 'every hunting query has id, name, description, query, tactics, author, version, tags' {
        foreach ($f in $script:HuntFiles) {
            $raw = Get-Content $f.FullName -Raw
            foreach ($key in 'id:', 'name:', 'description:', 'query:', 'tactics:', 'author:', 'version:', 'tags:') {
                $raw | Should -Match "(?m)^$key" -Because "$($f.Name) missing required field '$($key.TrimEnd(':'))'"
            }
        }
    }

    It 'every hunting query id is unique' {
        $ids = foreach ($f in $script:HuntFiles) {
            $raw = Get-Content $f.FullName -Raw
            if ($raw -match '(?m)^id:\s+([0-9a-f-]+)\s*$') { $Matches[1] }
        }
        ($ids | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }
}

Describe 'createUiDefinition.json schema compliance' {

    BeforeAll {
        $script:Ui = Get-Content $script:CreateUiPath -Raw | ConvertFrom-Json
    }

    It 'has correct $schema and version' {
        $script:Ui.'$schema' | Should -Match 'CreateUIDefinition'
        $script:Ui.version    | Should -Not -BeNullOrEmpty
    }

    It 'has handler = Microsoft.Azure.CreateUIDef' {
        $script:Ui.handler | Should -Be 'Microsoft.Azure.CreateUIDef'
    }

    It 'has parameters.basics, parameters.steps, parameters.outputs' {
        $script:Ui.parameters.basics  | Should -Not -BeNullOrEmpty
        $script:Ui.parameters.steps   | Should -Not -BeNullOrEmpty
        $script:Ui.parameters.outputs | Should -Not -BeNullOrEmpty
    }

    It 'workspaceSettings step uses Microsoft.Solutions.ResourceSelector for the workspace picker' {
        $wsStep = $script:Ui.parameters.steps | Where-Object name -eq 'workspaceSettings'
        $wsStep | Should -Not -BeNullOrEmpty
        $picker = $wsStep.elements | Where-Object type -eq 'Microsoft.Solutions.ResourceSelector'
        $picker | Should -Not -BeNullOrEmpty -Because 'workspace picker must be a ResourceSelector (native dropdown), not a manual TextBox'
        $picker.resourceType | Should -Be 'Microsoft.OperationalInsights/workspaces'
    }

    It 'outputs.existingWorkspaceId derives from the ResourceSelector' {
        $script:Ui.parameters.outputs.existingWorkspaceId | Should -Match 'existingWorkspace\.id'
    }
}

Describe 'Data Connector card schema compliance' {

    BeforeAll {
        $script:Dc = Get-Content $script:DataConnectorPath -Raw | ConvertFrom-Json
    }

    It 'has required top-level fields (id, title, publisher, dataTypes)' {
        foreach ($field in 'id', 'title', 'publisher', 'dataTypes') {
            $script:Dc.PSObject.Properties.Name | Should -Contain $field
        }
    }

    It 'dataTypes array lists 46 tables (45 active streams + Heartbeat; deprecated stream excluded from data connector card; AuthTestResult retired)' {
        @($script:Dc.dataTypes).Count | Should -Be 46
    }

    It 'every dataType has name + lastDataReceivedQuery' {
        foreach ($dt in $script:Dc.dataTypes) {
            $dt.name | Should -Not -BeNullOrEmpty
            $dt.name | Should -Match '^MDE_\w+_CL$'
            $dt.lastDataReceivedQuery | Should -Not -BeNullOrEmpty
        }
    }

    It 'has connectivityCriteria with IsConnectedQuery type' {
        $crits = @($script:Dc.connectivityCriteria)
        $crits.Count | Should -BeGreaterOrEqual 1
        $crits[0].type | Should -Be 'IsConnectedQuery'
    }
}
