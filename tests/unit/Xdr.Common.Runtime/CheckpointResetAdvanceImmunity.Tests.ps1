#Requires -Version 7.4
# ADVANCE-IMMUNITY (audit 2026-06-24) · the "reset-reader erasure" regression coverage.
#
# THE DEFECT: the audit reset-detector (Get-XdrResetCountFromCheckpointRows in tools/Run-PostDeployAudit.ps1, and the
# identical reader in tools/Verify-DeployedConnector.ps1 for D3/D7) counts only XdrCheckpoint rows whose durable
# ResetUtc still parses IN-WINDOW. But Save-XdrCheckpointAtomic is a FULL-ENTITY Insert-Or-Replace (PUT) that USED to
# OMIT ResetUtc -> the FIRST successful advance after a Save-XdrCheckpointReset ERASED that op's ResetUtc -> the reader
# counted it as NO reset. Net: B10/B9/D3/D7 reset-discrimination silently degraded to "NO reset" and could FALSE-FAIL
# an audit shortly after a reset (it produced a misleading "clean window (NO reset)" B10 FAIL).
#
# THE FIX (at SOURCE): Save-XdrCheckpointAtomic now CARRIES the prior row's ResetUtc/ResetReasonAnnotation FORWARD
# UNCHANGED on every advance (Get-XdrCheckpoint surfaces them; the hot-path callers pass the in-hand value; a caller
# that omits -ResetUtc triggers a best-effort read-back). The reader's own 24h in-window parse-check ages it out.
#
# This suite pins BOTH halves behaviorally:
#   PART 1 (WRITER · real module) — reset-then-advance(s): the PUT keeps carrying the ORIGINAL ResetUtc forward.
#   PART 2 (READER · the REAL function, AST-extracted) — a reset-in-window row IS counted; older-than-window -> 0;
#           no-reset -> 0. (These are the exact cases the defect mis-handled.)

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    # Production read shape: a hashtable serialized to JSON and re-read with -AsHashtable promotes ISO strings to
    # [DateTime] — exactly what Get-XdrTableEntity returns (the same fidelity model as CursorRoundTripFidelity.Tests).
    function ConvertTo-PromotedEntity([hashtable]$row) { $row | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable }
}

Describe 'ADVANCE-IMMUNITY · PART 1 · Save-XdrCheckpointAtomic carries ResetUtc FORWARD across advances (the erasure bug)' {
    BeforeEach {
        # Capture every PUT the atomic save emits so we can assert the persisted props.
        $script:writes = [System.Collections.Generic.List[hashtable]]::new()
        Mock -ModuleName Xdr.Common.Runtime Set-XdrTableEntity {
            $script:writes.Add(@{ Props = $Properties; ETag = $IfMatchETag })
            @{ Success = $true; StatusCode = 204; ETag = 'etag-next' }
        }
    }

    It 'an advance with -ResetUtc supplied (the hot-path caller) PERSISTS that ResetUtc unchanged (not dropped)' {
        $resetIso = ([DateTime]::UtcNow.AddMinutes(-10)).ToString('o')
        $ok = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' `
            -Cursor '2026-06-24T01:00:00.0000000Z' -BoundaryKeys 'K1' `
            -ResetUtc $resetIso -ResetReasonAnnotation 'operator-override' -ExistingETag 'etag-prior'
        $ok | Should -BeTrue
        $script:writes.Count | Should -Be 1
        $props = $script:writes[0].Props
        $props.ContainsKey('ResetUtc') | Should -BeTrue -Because 'the full-entity PUT must now INCLUDE ResetUtc (the omission was the erasure bug)'
        # Carried forward as the SAME instant (write-boundary canonicalisation may reformat, so compare as DateTime).
        ([DateTime]::Parse($props.ResetUtc).ToUniversalTime()) | Should -Be ([DateTime]::Parse($resetIso).ToUniversalTime())
        $props.ResetReasonAnnotation | Should -Be 'operator-override'
    }

    It 'an advance that OMITS -ResetUtc reads the prior row BACK and carries it forward (caller-agnostic immunity)' {
        $resetIso = ([DateTime]::UtcNow.AddMinutes(-30)).ToString('o')
        # The prior row already carries a reset stamp (a Save-XdrCheckpointReset happened, then a cycle advances WITHOUT
        # passing -ResetUtc). The read-back must recover and re-persist it.
        $priorRow = ConvertTo-PromotedEntity @{ Cursor=''; BoundaryKeys=''; ResetUtc=$resetIso; ResetReasonAnnotation='schema-change' }
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { @{ Found = $true; ETag = 'etag-prior'; Entity = $priorRow } }
        $ok = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' `
            -Cursor '2026-06-24T02:00:00.0000000Z' -BoundaryKeys 'K2' -ExistingETag 'etag-prior'
        $ok | Should -BeTrue
        $props = $script:writes[0].Props
        ([DateTime]::Parse($props.ResetUtc).ToUniversalTime()) | Should -Be ([DateTime]::Parse($resetIso).ToUniversalTime()) -Because 'the omitted ResetUtc must be recovered from the prior row, never erased'
        $props.ResetReasonAnnotation | Should -Be 'schema-change'
    }

    It 'reset → advance → advance → advance: the ORIGINAL ResetUtc survives EVERY advance (the exact regression)' {
        $resetIso = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o')
        # Cycle 1 advances passing the just-reset row's ResetUtc (hot path). Each subsequent cycle reads the row Get-
        # XdrCheckpoint returned (which now CARRIES the stamp) and passes it again. We thread the carried value through
        # three advances and assert it never drifts/erases.
        $carried = $resetIso
        1..3 | ForEach-Object {
            $script:writes.Clear()
            $null = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' `
                -Cursor ("2026-06-24T0{0}:00:00.0000000Z" -f $_) -BoundaryKeys ("K$_") `
                -ResetUtc $carried -ResetReasonAnnotation 'operator-override' -ExistingETag "etag-$_"
            $persisted = $script:writes[0].Props.ResetUtc
            ([DateTime]::Parse($persisted).ToUniversalTime()) | Should -Be ([DateTime]::Parse($resetIso).ToUniversalTime()) -Because "advance #$_ must still carry the ORIGINAL reset stamp"
            # what the next cycle's Get-XdrCheckpoint would hand back is this persisted value
            $carried = $persisted
        }
    }

    It 'a NO-reset advance (prior row has no ResetUtc) persists an EMPTY ResetUtc — it does NOT invent one' {
        $priorRow = ConvertTo-PromotedEntity @{ Cursor='2026-06-24T00:00:00.0000000Z'; BoundaryKeys='K0' }   # no ResetUtc column
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { @{ Found = $true; ETag = 'etag-prior'; Entity = $priorRow } }
        $null = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' `
            -Cursor '2026-06-24T03:00:00.0000000Z' -BoundaryKeys 'K3' -ExistingETag 'etag-prior'
        $props = $script:writes[0].Props
        $props.ContainsKey('ResetUtc') | Should -BeTrue
        [string]::IsNullOrEmpty([string]$props.ResetUtc) | Should -BeTrue -Because 'no prior reset → carry-forward writes empty, never a spurious stamp'
    }

    It 'a read-back failure (no -ResetUtc) is NON-FATAL: the advance still SUCCEEDS (never-throws contract holds)' {
        Mock -ModuleName Xdr.Common.Runtime Get-XdrTableEntity { throw [System.Exception]::new('storage 500 - transient') }
        $threw = $false; $ok = $null
        try {
            $ok = Save-XdrCheckpointAtomic -PartitionKey 'Defender_Operations' -OperationKey 'GetHistory' `
                -Cursor '2026-06-24T04:00:00.0000000Z' -BoundaryKeys 'K4' -ExistingETag 'etag-prior'
        } catch { $threw = $true }
        $threw | Should -BeFalse -Because 'the best-effort read-back must never fault the save (FH-7 never-throws)'
        $ok    | Should -BeTrue  -Because 'the PUT still happens; only the breadcrumb carry is skipped this cycle (degraded, not fatal)'
        $script:writes.Count | Should -Be 1
    }
}

Describe 'ADVANCE-IMMUNITY · PART 2 · the REAL audit reader counts a reset-in-window AFTER advances erased nothing' {
    BeforeAll {
        # Extract the ACTUAL Get-XdrResetCountFromCheckpointRows function body from the audit tool (no fork / no
        # reimplementation) and dot-source ONLY that function definition so we exercise the real counting logic.
        $tool = Join-Path $script:Repo 'tools\Run-PostDeployAudit.ps1'
        $ast  = [System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$null)
        $fn   = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-XdrResetCountFromCheckpointRows' }, $true) |
            Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because 'the reader function must exist in the audit tool'
        . ([ScriptBlock]::Create($fn.Extent.Text))   # define Get-XdrResetCountFromCheckpointRows in this scope

        # Script-scope inputs the function reads (its param block only takes -Hours; partition + storage come from scope).
        $script:StorageAccount = 'sttest'
        $script:partitionKey   = 'Defender_Operations'

        # Stub the AAD token + the Table data-plane GET. The GET returns ONE page whose rows we control per-test via
        # $script:rowPage (each row = @{ RowKey=..; ResetUtc=.. } as the nometadata Table JSON shape).
        function az { '<fake-token>' }                                  # az account get-access-token ... -> a token string
        $script:rowPage = @()
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Content = (@{ value = $script:rowPage } | ConvertTo-Json -Depth 6)
                Headers = @{}   # no continuation
            }
        }
    }

    It 'a reset that happened 5 MINUTES ago, then the op advanced (row still carries ResetUtc) → COUNTED (immune)' {
        # This is the EXACT defect: under the bug the advance erased ResetUtc and this returned 0. The carry-forward
        # writer keeps ResetUtc on the row, so the reader sees it and counts the reset within the 24h window.
        $script:rowPage = @( @{ RowKey = 'GetHistory'; ResetUtc = ([DateTime]::UtcNow.AddMinutes(-5)).ToString('o') } )
        $res = Get-XdrResetCountFromCheckpointRows -Hours 24
        $res.Available | Should -BeTrue
        $res.Count     | Should -Be 1 -Because 'a reset-in-window survives advances now → the reader still counts it'
    }

    It 'multiple fanout rows each carrying an in-window ResetUtc are counted per-row' {
        $now = [DateTime]::UtcNow
        $script:rowPage = @(
            @{ RowKey = 'GetHistory|a'; ResetUtc = $now.AddMinutes(-3).ToString('o') }
            @{ RowKey = 'GetHistory|b'; ResetUtc = $now.AddHours(-2).ToString('o') }
        )
        (Get-XdrResetCountFromCheckpointRows -Hours 24).Count | Should -Be 2
    }

    It 'a reset OLDER than the window (26h ago) → NOT counted (the in-window parse-check ages it out)' {
        $script:rowPage = @( @{ RowKey = 'GetHistory'; ResetUtc = ([DateTime]::UtcNow.AddHours(-26)).ToString('o') } )
        (Get-XdrResetCountFromCheckpointRows -Hours 24).Count | Should -Be 0 -Because 'a reset older than -Hours is correctly NOT a reset-in-window'
    }

    It 'NO reset (empty ResetUtc column) → 0 (an advancing-but-never-reset op is never miscounted as a reset)' {
        $script:rowPage = @( @{ RowKey = 'GetHistory'; ResetUtc = '' } )
        (Get-XdrResetCountFromCheckpointRows -Hours 24).Count | Should -Be 0
    }

    It 'a mixed partition (one in-window reset · one aged-out · one never-reset) counts EXACTLY the in-window one' {
        $now = [DateTime]::UtcNow
        $script:rowPage = @(
            @{ RowKey = 'OpA'; ResetUtc = $now.AddMinutes(-15).ToString('o') }  # in-window  → counts
            @{ RowKey = 'OpB'; ResetUtc = $now.AddHours(-30).ToString('o') }    # aged out   → not
            @{ RowKey = 'OpC'; ResetUtc = '' }                                  # never reset → not
        )
        (Get-XdrResetCountFromCheckpointRows -Hours 24).Count | Should -Be 1
    }
}
