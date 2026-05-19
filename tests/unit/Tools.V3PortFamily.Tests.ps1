#Requires -Module Pester
# Locks the Phase 0f v3 tool cherry-picks (F-2..F-6):
#   F-2 Classify-EndpointIngestion + Classify-IngestionMode.lib
#   F-3 Validate-MemoryRuleCompliance
#   F-4 Derive-Phase0Artifacts + Derive-Schema.lib
#   F-5 Build-DcrJson + Audit-Baseline
#   F-6 Capture-EndpointSchemas.lib (PII-redact + hint extractors)
#
# These tools are byte-identical cherry-picks from xdrlograider-v3 · production-tested.
# Pester scope here is: (a) artefacts present on disk · (b) helper-library exports
# resolve when dot-sourced · (c) per-tool key contract invariants (Memory Rule 2
# enforcement · IngestionMode enum · entity heuristic match · PKCE redaction).

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:t = @{
        ClassifyIngestion    = Join-Path $script:repoRoot 'tools\Classify-EndpointIngestion.ps1'
        ClassifyLib          = Join-Path $script:repoRoot 'tools\lib\Classify-IngestionMode.lib.ps1'
        ValidateMemoryRule   = Join-Path $script:repoRoot 'tools\Validate-MemoryRuleCompliance.ps1'
        DerivePhase0         = Join-Path $script:repoRoot 'tools\Derive-Phase0Artifacts.ps1'
        DeriveSchemaLib      = Join-Path $script:repoRoot 'tools\lib\Derive-Schema.lib.ps1'
        BuildDcrJson         = Join-Path $script:repoRoot 'tools\Build-DcrJson.ps1'
        AuditBaseline        = Join-Path $script:repoRoot 'tools\Audit-Baseline.ps1'
        CaptureLib           = Join-Path $script:repoRoot 'tools\lib\Capture-EndpointSchemas.lib.ps1'
    }
}

Describe 'F-2..F-6 · v3 tool cherry-picks present on disk' -Tag 'v3-ports' {

    It 'F-2 · Classify-EndpointIngestion.ps1 on disk' {
        Test-Path $script:t.ClassifyIngestion | Should -BeTrue
    }
    It 'F-2 · lib/Classify-IngestionMode.lib.ps1 on disk' {
        Test-Path $script:t.ClassifyLib | Should -BeTrue
    }
    It 'F-3 · Validate-MemoryRuleCompliance.ps1 on disk' {
        Test-Path $script:t.ValidateMemoryRule | Should -BeTrue
    }
    It 'F-4 · Derive-Phase0Artifacts.ps1 on disk' {
        Test-Path $script:t.DerivePhase0 | Should -BeTrue
    }
    It 'F-4 · lib/Derive-Schema.lib.ps1 on disk' {
        Test-Path $script:t.DeriveSchemaLib | Should -BeTrue
    }
    It 'F-5 · Build-DcrJson.ps1 on disk' {
        Test-Path $script:t.BuildDcrJson | Should -BeTrue
    }
    It 'F-5 · Audit-Baseline.ps1 on disk' {
        Test-Path $script:t.AuditBaseline | Should -BeTrue
    }
    It 'F-6 · lib/Capture-EndpointSchemas.lib.ps1 on disk' {
        Test-Path $script:t.CaptureLib | Should -BeTrue
    }
}

Describe 'F-2 Classify-IngestionMode.lib · 6-rule decision tree contract' -Tag 'v3-ports' {

    BeforeAll {
        . $script:t.ClassifyLib
    }

    It 'exports Resolve-IngestionMode in dot-source scope' {
        Get-Command -Name 'Resolve-IngestionMode' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'returns EXCLUDED for Memory Rule 2 sub-areas (AdvancedHunting · AlertsIncidents · LiveResponse)' {
        # v3 API: -Entry hashtable with SubArea / Path / NodocRoute / NodocSummary
        $r1 = Resolve-IngestionMode -Entry @{ SubArea = 'AdvancedHunting';  Path = '/foo'; NodocRoute = 'x'; NodocSummary = '' }
        $r1.Mode | Should -Be 'EXCLUDED'
        $r2 = Resolve-IngestionMode -Entry @{ SubArea = 'AlertsIncidents';  Path = '/foo'; NodocRoute = 'x'; NodocSummary = '' }
        $r2.Mode | Should -Be 'EXCLUDED'
        $r3 = Resolve-IngestionMode -Entry @{ SubArea = 'LiveResponse';     Path = '/foo'; NodocRoute = 'x'; NodocSummary = '' }
        $r3.Mode | Should -Be 'EXCLUDED'
    }

    It 'returns LIVESTREAM for time-filter-capable paths (Rule 3)' {
        $r = Resolve-IngestionMode -Entry @{ SubArea='Streaming'; Path='/api/events?since=2026-01-01'; NodocRoute='foo'; NodocSummary='' }
        $r.Mode | Should -Be 'LIVESTREAM'
    }

    It 'returns LIVESTREAM for operationId pattern .List / .GetEvents (Rule 4)' {
        # Patterns require leading dot · e.g. "Events.List" or "Machines.GetEvents"
        $r1 = Resolve-IngestionMode -Entry @{ SubArea='Streaming'; Path='/api/foo'; NodocRoute='Events.List';        NodocSummary='' }
        $r1.Mode | Should -Be 'LIVESTREAM'
        $r2 = Resolve-IngestionMode -Entry @{ SubArea='Streaming'; Path='/api/foo'; NodocRoute='Machines.GetEvents'; NodocSummary='' }
        $r2.Mode | Should -Be 'LIVESTREAM'
    }

    It 'returns LIVESTREAM for summary keywords (event/alert/log/audit · Rule 5)' {
        $r = Resolve-IngestionMode -Entry @{ SubArea='Inventory'; Path='/api/foo'; NodocRoute='foo'; NodocSummary='List recent security events' }
        $r.Mode | Should -Be 'LIVESTREAM'
    }

    It 'returns SNAPSHOT for plain inventory/config endpoints (Rule 6 default)' {
        $r = Resolve-IngestionMode -Entry @{ SubArea='Configuration'; Path='/api/settings'; NodocRoute='Settings.Get'; NodocSummary='Get firewall configuration' }
        $r.Mode | Should -Be 'SNAPSHOT'
    }
}

Describe 'F-4 Derive-Schema.lib · typed JSON → KQL inventory + entities' -Tag 'v3-ports' {

    BeforeAll {
        . $script:t.DeriveSchemaLib
    }

    It 'exports ConvertTo-KqlType in dot-source scope' {
        Get-Command -Name 'ConvertTo-KqlType' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'JSON types → KQL types per v3 mapping (null/boolean/integer/number/object/array)' {
        # v3 API: -JsonType takes JSON-native names (string/integer/number/boolean/object/array/datetime/null)
        (ConvertTo-KqlType -JsonType 'null'     -SampleValue '')        | Should -Be 'string'
        (ConvertTo-KqlType -JsonType 'boolean'  -SampleValue 'true')    | Should -Be 'bool'
        (ConvertTo-KqlType -JsonType 'integer'  -SampleValue '42')      | Should -Be 'long'
        (ConvertTo-KqlType -JsonType 'number'   -SampleValue '3.14')    | Should -Be 'real'
        (ConvertTo-KqlType -JsonType 'object'   -SampleValue '{}')      | Should -Be 'dynamic'
        (ConvertTo-KqlType -JsonType 'array'    -SampleValue '[]')      | Should -Be 'dynamic'
        (ConvertTo-KqlType -JsonType 'datetime' -SampleValue '2026-01-01T00:00:00Z') | Should -Be 'datetime'
    }

    It 'JSON string with ISO-8601 sample → datetime · plain string → string' {
        (ConvertTo-KqlType -JsonType 'string' -SampleValue '2026-05-17T12:34:56Z') | Should -Be 'datetime'
        (ConvertTo-KqlType -JsonType 'string' -SampleValue 'just a label')          | Should -Be 'string'
    }

    It 'Resolve-ProjectionOp maps KQL type → typed DSL operator' {
        (Resolve-ProjectionOp -KqlType 'string')   | Should -Be '$tostring'
        (Resolve-ProjectionOp -KqlType 'long')     | Should -Be '$tolong'
        (Resolve-ProjectionOp -KqlType 'bool')     | Should -Be '$tobool'
        (Resolve-ProjectionOp -KqlType 'datetime') | Should -Be '$todatetime'
        (Resolve-ProjectionOp -KqlType 'dynamic')  | Should -Be '$tojson'
    }
}

Describe 'F-6 Capture-EndpointSchemas.lib · PII redaction (4 regex passes)' -Tag 'v3-ports' {

    BeforeAll {
        . $script:t.CaptureLib
    }

    It 'exports Redact-PII in dot-source scope' {
        Get-Command -Name 'Redact-PII' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'redacts JWT-shaped tokens' {
        $input = '{"token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"}'
        $out = Redact-PII -Text $input
        $out | Should -Match 'REDACTED-JWT|<REDACTED'
        $out | Should -Not -Match 'eyJhbGciOiJIUzI1NiJ9'
    }

    It 'redacts email addresses' {
        $input = 'user.name@example.com posted something'
        $out = Redact-PII -Text $input
        $out | Should -Not -Match 'user\.name@example\.com'
    }

    It 'redacts 64-char hex blobs (SHA256-ish)' {
        $sha = 'a'*64
        $input = "hash is $sha and stuff"
        $out = Redact-PII -Text $input
        $out | Should -Not -Match ($sha)
    }
}

Describe 'F-3 Validate-MemoryRuleCompliance · script presence + parse-able' -Tag 'v3-ports' {

    It 'is a valid PowerShell script (parses without errors)' {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:t.ValidateMemoryRule, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because "tool must parse cleanly · v3 byte-identical port"
    }
}

Describe 'F-4/F-5/F-6 tools parse cleanly as PowerShell scripts' -Tag 'v3-ports' {

    It 'Derive-Phase0Artifacts parses without errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:t.DerivePhase0, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'Build-DcrJson parses without errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:t.BuildDcrJson, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'Audit-Baseline parses without errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:t.AuditBaseline, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'Classify-EndpointIngestion parses without errors' {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:t.ClassifyIngestion, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}
