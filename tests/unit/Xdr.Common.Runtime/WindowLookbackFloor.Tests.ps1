#Requires -Version 7.4
# §4.B FIX-1 · WINDOW LOOKBACK FLOOR (the runtime-BEHAVIORAL SelfTest · GMTE 0-events root cause).
#
# Root cause verified from the code: Resolve-XdrTimeWindow (Xdr.Common.Runtime.psm1) resolves a WINDOW op's cold-start
# window as [now - LookbackHours, now]. The naive `if ($Entry['LookbackHours'])` truthy-test let a MALFORMED value
# (absent, 0, negative, or a non-numeric string that [int] coerces to 0) through as <= 0 → now.AddHours(0)/future =
# a ~now→now EMPTY window → 0 rows that are merely window-too-narrow, NOT genuinely absent (the GMTE class). The
# catalogue side (WindowDerivation.Tests.ps1) pins that every WINDOW op CARRIES LookbackHours > 0; THIS file pins the
# ENGINE contract — Resolve-XdrTimeWindow can NEVER resolve a trivial/empty lookback window for a WINDOW op, even when
# the manifest value is missing or malformed (the FIX-1b sane-lookback floor). Together they make the defect-class
# (a WINDOW op silently getting an empty window) impossible at BOTH the data and the engine seam.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    $psd1s = Get-ChildItem (Join-Path $script:Repo 'src\Modules') -Directory |
        ForEach-Object { Join-Path $_.FullName ($_.Name + '.psd1') } | Where-Object { Test-Path $_ }
    for ($pass = 1; $pass -le 4; $pass++) {
        foreach ($p in $psd1s) { try { Import-Module $p -Force -DisableNameChecking -ErrorAction Stop } catch { } }
    }
    # The minimum window a WINDOW op must resolve. A trivial window is the bug; anything materially larger is fine.
    # The engine floor is 24h; this lower bound (60 min) only has to exclude the now→now / sub-minute empty span.
    $script:MinWindowMinutes = 60
}

Describe '§4.B FIX-1b · Resolve-XdrTimeWindow · a WINDOW op NEVER resolves a trivial/empty cold-start window (the sane-lookback floor)' {
    It 'a WINDOW op with NO LookbackHours falls to the 24h default (NOT now→now)' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'X'; IngestionMode = 'WINDOW'; TimeFilter = @{ Mode = 'ServerFromDate'; FromDateParam = 'f'; ToDateParam = 't'; FieldName = 'f' } }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            $span = ([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalHours
            [Math]::Round($span) | Should -Be 24 -Because 'a WINDOW op with no LookbackHours must default to a 24h backfill, never an empty window'
        }
    }
    It 'a WINDOW op with LookbackHours=0 (malformed) is FLOORED to 24h, never a 0-length now→now window' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'Y'; IngestionMode = 'WINDOW'; LookbackHours = 0; TimeFilter = @{ Mode = 'ServerFromDate'; FromDateParam = 'f'; ToDateParam = 't'; FieldName = 'f' } }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            $span = ([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalHours
            [Math]::Round($span) | Should -Be 24 -Because 'LookbackHours=0 is the now.AddHours(0)=now→now empty-window trap — the floor must catch it'
        }
    }
    It 'a WINDOW op with a NEGATIVE LookbackHours is FLOORED to 24h (never a FUTURE StartUtc > EndUtc)' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'Z'; IngestionMode = 'WINDOW'; LookbackHours = -5; TimeFilter = @{ Mode = 'ServerFromDate'; FromDateParam = 'f'; ToDateParam = 't'; FieldName = 'f' } }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            ([datetime]$w.StartUtc) | Should -BeLessThan ([datetime]$w.EndUtc) -Because 'a negative lookback would push StartUtc into the future (inverted window) — the floor must catch it'
            [Math]::Round((([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalHours)) | Should -Be 24
        }
    }
    It 'a WINDOW op with a non-numeric LookbackHours is FLOORED to 24h (StrictMode-safe parse)' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'W'; IngestionMode = 'WINDOW'; LookbackHours = 'garbage'; TimeFilter = @{ Mode = 'ServerFromDate'; FromDateParam = 'f'; ToDateParam = 't'; FieldName = 'f' } }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            [Math]::Round((([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalHours)) | Should -Be 24
        }
    }
    It 'a WINDOW op WITH a real LookbackHours (168) honours it (the floor never CAPS a valid larger backfill)' {
        InModuleScope Xdr.Common.Runtime {
            $entry = @{ OperationKey = 'GetMachineTimelineEvents'; IngestionMode = 'WINDOW'; LookbackHours = 168; TimeFilter = @{ Mode = 'ServerFromDate'; FromDateParam = 'fromDate'; ToDateParam = 'toDate'; FieldName = 'fromDate' } }
            $w = Resolve-XdrTimeWindow -Entry $entry -Checkpoint @{}
            [Math]::Round((([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalHours)) | Should -Be 168 -Because 'the curation backfill (168h) must reach the engine window unchanged'
        }
    }
}

Describe '§4.B FIX-1 · EVERY shipped WINDOW op in the live catalogue resolves a NON-TRIVIAL window through the real engine' {
    BeforeAll {
        $cat = Get-Content (Join-Path $script:Repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json
        $script:windowOps = @($cat.Operations | Where-Object { $_.Shipped -eq $true -and $_.IngestionMode -eq 'WINDOW' })
    }
    It 'the catalogue has at least one shipped WINDOW op (the universe is non-trivial)' {
        $script:windowOps.Count | Should -BeGreaterThan 0
    }
    It 'each shipped WINDOW op, cold-started, resolves a window span > the trivial floor (never now→now · 0 events that are merely window-too-narrow)' {
        $tooSmall = @()
        foreach ($op in $script:windowOps) {
            # Build the runtime entry the way Generate-Manifest emits it (the fields Resolve-XdrTimeWindow reads).
            $tf = @{}
            if ($op.TimeFilter) { foreach ($pp in $op.TimeFilter.PSObject.Properties) { $tf[$pp.Name] = $pp.Value } }
            $entry = @{
                OperationKey  = [string]$op.Operation
                IngestionMode = [string]$op.IngestionMode
                LookbackHours = $op.LookbackHours
                TimeFilter    = $tf
            }
            $span = InModuleScope Xdr.Common.Runtime -Parameters @{ E = $entry } {
                param($E)
                $w = Resolve-XdrTimeWindow -Entry $E -Checkpoint @{}
                ([datetime]$w.EndUtc - [datetime]$w.StartUtc).TotalMinutes
            }
            if ($span -lt $script:MinWindowMinutes) {
                $tooSmall += "$([string]$op.OperationId) · resolved window = $([Math]::Round($span,1))min (< $script:MinWindowMinutes min · trivial/empty)"
            }
        }
        $tooSmall -join "`n" | Should -BeNullOrEmpty -Because 'a WINDOW op whose cold-start window is trivial returns 0 rows that LOOK like an absent feature but are merely a too-narrow window (the GMTE root cause)'
    }
}
