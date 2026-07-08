#Requires -Version 7.4
# Contract test for tools/Run-PostDeployAudit.ps1 — the reproducible per-category §4.B audit (B1-B11). Pins the
# safety + KQL-hygiene envelope as static-source assertions (no live Azure · CI-safe): CI-refusal security lock,
# SINGLE-quote KQL literals (az.cmd strips double-quotes → silent SemanticError), the _CL op column = 'Operation'
# (NOT OperationName), B5 query-honesty (a failed query → INCONCLUSIVE not 0), and composition of the existing
# verifiers + the B9-B11 lib. The LIVE multi-axis run is exercised post-deploy (not offline).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Run-PostDeployAudit.ps1'
    $script:src  = Get-Content -LiteralPath $script:tool -Raw
}

Describe 'Run-PostDeployAudit · parse + structure' {
    It 'parses with zero errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'requires -Category (per-category audit · Mandatory)' {
        $script:src | Should -Match '(?s)\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$Category'
    }
    It 'dot-sources the B9-B11 pure-gate lib (composition · not a fork)' {
        $script:src | Should -Match "lib/Xdr\.PostDeployAudit\.ps1"
    }
    It 'composes the existing verifiers (Save-XdrCheckpointReset for B3 · Run-PostDeployVerify for the B6 D-gates)' {
        $script:src | Should -Match 'Save-XdrCheckpointReset\.ps1'
        $script:src | Should -Match 'Run-PostDeployVerify\.ps1'
    }
    It 'calls the three NEW gate functions (B9 · B10 · B11)' {
        $script:src | Should -Match 'Test-XdrB9_ErrorRate'
        $script:src | Should -Match 'Test-XdrB10_DupAccumulation'
        $script:src | Should -Match 'Test-XdrB11_FailOpen'
    }
}

Describe 'Run-PostDeployAudit · CI-refusal security lock (creds never in CI)' {
    It 'refuses to run under CI (exit 2 · the reset + the composed content verify auth the service account)' {
        $out = pwsh -NoProfile -Command "`$env:GITHUB_ACTIONS='true'; & '$script:tool' -Category Operations; exit `$LASTEXITCODE" 2>&1
        $LASTEXITCODE | Should -Be 2 -Because 'mirrors Verify-XdrLiveContent / Confirm-PostDeploy — the service account must never authenticate in CI'
        ($out -join "`n") | Should -Match 'LOCAL-ONLY'
    }
}

Describe 'Run-PostDeployAudit · KQL hygiene (the silent-false-negative class)' {
    It 'uses SINGLE-quote KQL string literals (az.cmd strips double-quotes → SemanticError → silent false-negative)' {
        # Every event-name comparison in the queries must be single-quoted.
        $script:src | Should -Match "Name == 'Entry\.Poll\.Succeeded'"
        $script:src | Should -Match "Name == 'Entry\.Poll\.Failed'"
        $script:src | Should -Match "Name == 'Entry\.Poll\.BoundaryDeduped'"
        $script:src | Should -Match "Name == 'Entry\.CadenceNotDue\.Skipped'"
        $script:src | Should -Match "Name == 'Entry\.FailOpen'"
        $script:src | Should -Match "Name == 'Checkpoint\.Reset'"
        $script:src | Should -Match "Name == 'Breaker\.Opened'"
        $script:src | Should -Match "Name == 'Breaker\.Closed'"
    }
    It 'does NOT query the WRONG _CL op column (the column is Operation · OperationName matches nothing)' {
        # A query that filtered/projected on OperationName would silently match nothing. The tool must reference
        # the real envelope column 'Operation' in its _CL queries, never an OperationName comparison/projection.
        $script:src | Should -Not -Match '(where|project|by)\s+OperationName'
        # and it DOES reference the real op column where it scopes a _CL row
        $script:src | Should -Match 'dcount\(RecordId\)'   # B10 reads RecordId on the _CL table (the composite NaturalKey identity)
    }
    It 'scopes a category by the WorkspaceTable/Category property the poll events carry (not a guessed column)' {
        $script:src | Should -Match "Properties\.WorkspaceTable"
        $script:src | Should -Match "Properties\.Category"
    }
    It 'reads the AppEvents op identity via tostring(Properties.OperationKey)' {
        $script:src | Should -Match 'tostring\(Properties\.OperationKey\)'
    }
    It 'B5 query-honesty · a non-Success KQL result feeds -QueryOk:$false (INCONCLUSIVE, never a silent 0)' {
        $script:src | Should -Match '-QueryOk'
        $script:src | Should -Match 'B5 known-good'   # validates the query mechanism on a guaranteed-non-empty case
    }
    It 'flattens the query to a single line before az (az truncates --analytics-query at the first newline)' {
        # The chokepoint collapses all whitespace runs to single spaces: [regex]::Replace($Query, '\s+', ' ')
        $script:src | Should -Match '\[regex\]::Replace\(\$Query'
        $script:src | Should -Match '\\s\+'   # the \s+ whitespace-collapse pattern in source
    }
}

Describe 'Run-PostDeployAudit · §4.B FIX-3 · reset discrimination reads the DURABLE checkpoint-row ResetUtc (telemetry-lag-immune)' {
    # The defect: the reset-count helper read ONLY the Checkpoint.Reset TELEMETRY event (AppEvents), which lags/drops on
    # ingest → the gate reported "NO reset" despite resets having happened (3 resets unseen → B9/B10 FALSE-FAILed on
    # reset churn). The cure makes the AUTHORITATIVE source the durable checkpoint ROW field ResetUtc (in storage the
    # instant Save-XdrCheckpointReset writes it); the telemetry event is a FALLBACK only when storage is unreachable.
    It 'defines a checkpoint-ROW reset reader (Get-XdrResetCountFromCheckpointRows) — the durable primary source' {
        $script:src | Should -Match 'function\s+Get-XdrResetCountFromCheckpointRows'
    }
    It 'the row reader queries the XdrCheckpoint table for THIS partition and reads the ResetUtc column' {
        $script:src | Should -Match 'XdrCheckpoint\(\)'                 # Table data-plane query
        $script:src | Should -Match '\$select=RowKey,ResetUtc'          # selects the durable ResetUtc field
        $script:src | Should -Match "PartitionKey%20eq%20'\`$pkAddr'"   # scoped to the category partition
        $script:src | Should -Match '\.ResetUtc'                        # reads ResetUtc off each row
    }
    It 'Get-XdrResetCountInWindow prefers the checkpoint-row source and only FALLS BACK to the telemetry event' {
        # The row reader is called first; the AppEvents Checkpoint.Reset count is the documented fallback path.
        $script:src | Should -Match 'Get-XdrResetCountFromCheckpointRows'
        $script:src | Should -Match "Source = 'checkpoint-row\.ResetUtc'"
        $script:src | Should -Match "Source = 'telemetry-event\(fallback\)'"
    }
    It 'the row-reset window is computed against now-Hours (a reset is reset-IN-WINDOW iff ResetUtc >= cutoff)' {
        $script:src | Should -Match 'AddHours\(-1 \* \$Hours\)'
        $script:src | Should -Match '\$dt -ge \$cutoff'
    }
    It 'uses the AAD storage data-plane (shared-key is disabled · same path as Save-XdrCheckpointReset · no shared key)' {
        $script:src | Should -Match 'az account get-access-token --resource https://storage\.azure\.com/'
        $script:src | Should -Not -Match 'allowSharedKeyAccess|account-key|SharedKey'
    }
}

Describe 'Run-PostDeployAudit · §4.B THROTTLE-BACKOFF · Invoke-XdrAuditKql exponential backoff + jitter + Retry-After' {
    # The defect: a sustained LA query throttle (HTTP 429 · 'ResponseSizeError'/'throttle') SURVIVED the prior LINEAR
    # 5·10·15·20s backoff → the audit FALSE-read INCONCLUSIVE ('transient/throttle survived retry'). The cure is
    # EXPONENTIAL backoff + jitter + a Retry-After hint, WITHOUT breaking B5 (an unexecutable query still ends
    # Success=$false → the pure B-fn marks the axis INCONCLUSIVE, never a silent 0).
    It 'the retry loop calls the exponential-backoff helper (NOT the old linear Min(25, 5*$a) schedule)' {
        $body = [regex]::Match($script:src, '(?s)function Invoke-XdrAuditKql.*?\n\}').Value
        $body | Should -Match 'Get-XdrAuditKqlBackoffSeconds -Attempt \$a'
        $body | Should -Not -Match '5 \* \$a'    # the dead linear schedule is gone
    }
    It 'the backoff helper is exponential (Math.Pow(2, ...)), jitters (Get-Random), parses Retry-After, and caps' {
        $fn = [regex]::Match($script:src, '(?s)function Get-XdrAuditKqlBackoffSeconds.*?\n\}').Value
        $fn | Should -Match '\[Math\]::Pow\(2'
        $fn | Should -Match 'Get-Random'
        $fn | Should -Match 'retry\[\\s-\]\?after'
        $fn | Should -Match 'CapSeconds'
    }
    It 'the loop makes 6 bounded attempts (was 5) then is B5-honest (Success=$false → INCONCLUSIVE, never 0)' {
        $body = [regex]::Match($script:src, '(?s)function Invoke-XdrAuditKql.*?\n\}').Value
        $body | Should -Match '\$attempts = 6'
        $body | Should -Match 'Success = \$false'
        $body | Should -Match 'did not execute after \$attempts tries'
    }
    It 'BEHAVIOR (pure helper extracted + invoked offline): exponential growth · jitter · Retry-After honored · capped' {
        # Extract ONLY the pure backoff function from source and load it in an isolated scope (the driver itself can't be
        # dot-sourced — it exits under CI). This RED-proves the actual computation, not just its presence.
        $fnText = [regex]::Match($script:src, '(?s)function Get-XdrAuditKqlBackoffSeconds.*?\n\}').Value
        $fnText | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($fnText))
        # exponential: attempt-2 floor (>=2) >= attempt-1 ceiling (<=2) across many jittered draws
        $a1max = 0; $a2min = [int]::MaxValue
        1..200 | ForEach-Object {
            $a1 = Get-XdrAuditKqlBackoffSeconds -Attempt 1; if ($a1 -gt $a1max) { $a1max = $a1 }
            $a2 = Get-XdrAuditKqlBackoffSeconds -Attempt 2; if ($a2 -lt $a2min) { $a2min = $a2 }
        }
        $a1max | Should -BeLessOrEqual 2
        $a2min | Should -BeGreaterOrEqual 2
        # jitter: >1 distinct value for the same attempt
        (@(1..80 | ForEach-Object { Get-XdrAuditKqlBackoffSeconds -Attempt 4 } | Sort-Object -Unique).Count) | Should -BeGreaterThan 1
        # Retry-After honored when longer + clamped to the cap
        (Get-XdrAuditKqlBackoffSeconds -Attempt 1 -ErrorText 'az query exit=1: Retry-After: 25') | Should -Be 25
        (Get-XdrAuditKqlBackoffSeconds -Attempt 1 -ErrorText 'Retry-After: 9999') | Should -Be 60
        # cap holds for a high attempt
        1..30 | ForEach-Object { (Get-XdrAuditKqlBackoffSeconds -Attempt 12) | Should -BeLessOrEqual 60 }
        Remove-Item function:Get-XdrAuditKqlBackoffSeconds -ErrorAction SilentlyContinue
    }
}

Describe 'Run-PostDeployAudit · exit-code contract (0 all-pass · 1 inconclusive · 2 any-fail)' {
    It 'exits 2 on any FAIL axis' {
        $script:src | Should -Match '(?s)if \(\$failCount -gt 0\).*?exit 2'
    }
    It 'exits 1 on inconclusive-but-no-fail (never a silent green)' {
        $script:src | Should -Match '(?s)if \(\$incCount -gt 0\).*?exit 1'
    }
    It 'exits 0 only when all axes PASS' {
        $script:src | Should -Match '(?s)ALL PASS.*?exit 0'
    }
}

Describe 'Run-PostDeployAudit · execution-order (a script-level fn must be DEFINED before its first CALL)' {
    # The class that escaped the B9-B11 lib SelfTests (which exercise the PURE decision fns, NOT the driver's
    # top-to-bottom call ordering): Get-XdrAuditCount was defined AFTER its first use at the B5 known-good probe, so
    # the FIRST live run died with 'Get-XdrAuditCount is not recognized'. PowerShell binds a script-level function
    # only once execution REACHES its definition, so every driver-defined fn must precede its earliest call site.
    BeforeAll {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$null)
        # driver-defined function name → definition start line
        $script:defLine = @{}
        $script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            ForEach-Object { $script:defLine[$_.Name] = $_.Extent.StartLineNumber }
    }

    It 'every driver-defined function is referenced only AT or AFTER its definition line' {
        $violations = @()
        $script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object {
            $name = $_.GetCommandName()
            # Only driver-defined functions are order-sensitive here; lib/dot-sourced fns are loaded at line 61.
            if ($name -and $script:defLine.ContainsKey($name)) {
                $callLine = $_.Extent.StartLineNumber
                if ($callLine -lt $script:defLine[$name]) {
                    $violations += "$name called@$callLine before def@$($script:defLine[$name])"
                }
            }
        }
        $violations -join ' · ' | Should -BeNullOrEmpty -Because 'a script-level function called before it is defined fails at runtime with "is not recognized" (the Get-XdrAuditCount regression)'
    }

    It 'the driver loads + every command it invokes RESOLVES once the lib is dot-sourced (no unresolved fn)' {
        # Dot-source the lib (as the driver does at line 61) so the lib-provided helpers (Get-XdrAuditCount,
        # ConvertTo-XdrAuditInt, Get-XdrAuditRowValue, the Test-XdrB* gates) are in scope, then assert that every
        # NON-builtin command the driver calls is now resolvable — i.e. nothing the driver invokes is missing.
        $lib = Join-Path $script:repo 'tools/lib/Xdr.PostDeployAudit.ps1'
        . $lib
        $defNames = @($script:defLine.Keys)                                  # functions the driver defines itself
        $invoked = $script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
        $unresolved = @()
        foreach ($name in $invoked) {
            if ($defNames -contains $name) { continue }                      # defined in the driver body
            if (Get-Command -Name $name -ErrorAction SilentlyContinue) { continue }  # builtin / lib-provided / on PATH
            $unresolved += $name
        }
        $unresolved -join ' · ' | Should -BeNullOrEmpty -Because 'a command the driver invokes that resolves to nothing (after the lib dot-source) is the not-recognized class'
    }

    It 'Get-XdrAuditCount resolves from the lib (its home · used by the B5 known-good probe before the driver body)' {
        $lib = Join-Path $script:repo 'tools/lib/Xdr.PostDeployAudit.ps1'
        . $lib
        Get-Command Get-XdrAuditCount -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        # and the driver no longer DEFINES it (it lives in the lib next to the coercions it composes)
        $script:defLine.ContainsKey('Get-XdrAuditCount') | Should -BeFalse -Because 'Get-XdrAuditCount was moved into the lib so it is defined the instant the lib is dot-sourced'
    }
}
