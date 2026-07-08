#Requires -Version 7.4
# Φ4.G + F-FORCE (audit 2026-06-12) · tools/Force-XdrFullCycle.ps1 is the LIVE cadence trigger. TWO root causes are
# pinned here, in order of discovery: (1) Φ4.G — the FA storage account has shared-key DISABLED
# (allowSharedKeyAccess=false · 2026-06-09), so every write must be AAD data-plane (--auth-mode login); the prior
# Az.Storage-SDK account-key path silently failed. (2) F-FORCE — the tool then wrote a 'ForceFullCycle'/'ForceNow'
# marker row to XdrTierState that NO runtime code ever read (the G-Cadence gate reads EXACTLY ONE signal:
# XdrCheckpoint.LastUpdatedUtc) — a silent no-op trigger. The working mechanism: AAD MERGE that blanks
# LastUpdatedUtc on the REAL checkpoint row(s), FORCE-WITHOUT-REWIND (the merge must never write the exactly-once
# frontier: Cursor / BoundaryKeys / Resume*).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:tool = Join-Path $script:repo 'tools/Force-XdrFullCycle.ps1'
    $script:src = Get-Content $script:tool -Raw
    # Comment-stripped view: the rationale docstring legitimately NAMES the dead-marker design + old SDK cmdlets to
    # explain the fix; negative checks must run against CODE only (drop full-line # comments).
    $script:codeOnly = (($script:src -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
}

Describe 'Φ4.G + F-FORCE · Force-XdrFullCycle triggers via the REAL cadence signal, AAD-only' {
    It 'parses with no errors' {
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:tool, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }
    It 'targets the XdrCheckpoint table (the row the G-Cadence gate actually reads) — NOT a marker table' {
        $script:src | Should -Match "TableName = 'XdrCheckpoint'"
        $script:codeOnly | Should -Not -Match 'XdrTierState' -Because 'the XdrTierState marker was a dead trigger NO runtime code read (F-FORCE)'
    }
    It 'clears LastUpdatedUtc via the Table REST API (Invoke-RestMethod PATCH · AAD bearer · shared-key-off-safe · 2026-06-18: az.cmd mangles a composite Op|id pipe + the entity-URL parens, so native REST replaced the CLI merge)' {
        $script:src | Should -Match 'Invoke-RestMethod'
        $script:src | Should -Match '-Method [Pp]atch'
        $script:src | Should -Match 'az account get-access-token'   # AAD bearer for the storage data plane (no shared key)
        $script:src | Should -Match 'storage\.azure\.com'           # the token resource = the data-plane scope
        $script:src | Should -Match '"LastUpdatedUtc":""'           # the merge body blanks ONLY LastUpdatedUtc
        $script:src | Should -Match '--auth-mode login'             # the row LISTING (az storage entity query) is still AAD
    }
    It 'FORCE-WITHOUT-REWIND · the merge PATCH body is exactly {"LastUpdatedUtc":""} (blanks ONLY LastUpdatedUtc · never the exactly-once frontier)' {
        # the Table REST PATCH body must blank LastUpdatedUtc ONLY — never write Cursor/BoundaryKeys/Resume*
        $script:codeOnly | Should -Match '\{"LastUpdatedUtc":""\}' -Because 'the merge body blanks ONLY LastUpdatedUtc'
        foreach ($frontier in @('"Cursor"', '"BoundaryKeys"', '"ResumePage"', '"ResumeCursor"', '"ResumeHighWater"', '"ResumeBoundaryKeys"')) {
            ($script:codeOnly -match [regex]::Escape($frontier)) | Should -BeFalse -Because "the trigger must never write the exactly-once frontier ($frontier)"
        }
    }
    It 'does NOT use the broken shared-key Az.Storage SDK path (Get-AzStorageAccount.Context / Add-AzTableRow)' {
        $script:codeOnly | Should -Not -Match 'Get-AzStorageAccount|Add-AzTableRow|New-AzStorageTable|Get-AzStorageTable|\.CloudTable'
    }
    It 'carries NO destructive operation' {
        $script:codeOnly | Should -Not -Match 'entity delete|table delete|group delete|keyvault (purge|delete)|--no-wait'
    }
    It 'PER-OP mode targets the op row by RowKey filter; ALL-OPS enumerates with continuation paging' {
        $script:src | Should -Match "RowKey eq"
        $script:src | Should -Match 'nextMarker'
    }
    It 'handles the COMPOUND nextMarker (live-proven: az returns {nextpartitionkey,nextrowkey}, present-but-null on completion)' {
        # a bare [string] cast of the marker container stringified the hashtable TYPE NAME into --marker and az
        # dict()-parsed the literal — the loop must build key=value pairs from the INNER VALUES and stop when none.
        $script:codeOnly | Should -Match 'IDictionary'
        $script:codeOnly | Should -Match '\$markerPairs'
        $script:codeOnly | Should -Not -Match '\[string\]\$page\[.nextMarker.\]' -Because 'the marker is a compound object, never cast whole'
    }
}
