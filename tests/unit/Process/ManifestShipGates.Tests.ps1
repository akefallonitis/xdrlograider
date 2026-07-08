#Requires -Version 7.4
# T4 (reaudit 2026-06-12 · runtime-genericity agent) · MANIFEST SHIP-GATE completeness. Validate-Manifests gates
# WINDOW (must have ServerFromDate+LookbackHours) and NaturalKey-subset-of-ProjectionMap, but had NO rule that a
# CURSOR op declares a CursorField AND a NaturalKey. A curated/generated CURSOR op without a CursorField is a silent
# generic-correctness hole: Select-XdrExactlyOnceRows keeps ALL rows every cycle (full re-emit) AND
# Get-XdrAdvancedFrontier persists the page-local server token as the high-water Cursor (a stale token seeds next
# cycle's page loop). Latent on the pilot (GetHistory is correctly CURSOR+EventTime+ActionId), real for expansion.
# Also: LIVESTREAM was in $allowedModes but has NO runtime branch (Resolve-XdrTimeWindow degrades it) and 0 ops use it
# — the allowlist must match the runtime switch (SNAPSHOT/CURSOR/WINDOW). Tests drive the REAL validator against a
# temp repo (a junction to src/ for the Parser import · no schema file → parity skipped → only per-op rules fire).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:vm = Join-Path $script:repo 'tools/Validate-Manifests.ps1'
    $script:temps = @()

    function New-OpManifest([string]$Category, [hashtable]$OpOverride) {
        $op = [ordered]@{
            OperationKey = 'TestOp'; Method = 'GET'; SubPortal = 'mtp'; Path = '/x'
            ResponseShape = 'wrapper'; IngestionMode = 'CURSOR'; Cadence = '00:10:00'
            RequiresProducts = @('MDE'); ProjectionMap = @{ Id = '$.Id'; EventTime = '$.EventTime' }
            DcrStreamName = "Custom-Defender_${Category}_CL"; WorkspaceTable = "Defender_${Category}_CL"
            DcrImmutableIdEnvVar = "XDRLR_DCR_DEFENDER_$($Category.ToUpper())"
            Provenance = @{ OperationId = 'Test.Op'; Postman = $true; OpenApi = $true; Live = $false }
            CursorField = 'EventTime'; NaturalKey = @('Id')
        }
        foreach ($k in $OpOverride.Keys) { if ($null -eq $OpOverride[$k]) { $op.Remove($k) } else { $op[$k] = $OpOverride[$k] } }
        # serialize a .psd1
        $lines = foreach ($k in $op.Keys) {
            $v = $op[$k]
            # if/elseif (NOT switch — `switch ($array)` ITERATES over elements, so @() serializes to nothing and
            # @('Id') drops the array wrapper · the harness bug that made an empty NaturalKey a parse-fail not a rule-hit).
            $rendered =
                if ($v -is [string])    { "'$($v -replace "'","''")'" }
                elseif ($v -is [bool])  { if ($v) { '$true' } else { '$false' } }
                elseif ($v -is [array]) { '@(' + (($v | ForEach-Object { "'$_'" }) -join ', ') + ')' }
                elseif ($v -is [hashtable]) { '@{ ' + (($v.Keys | ForEach-Object { "$_ = '$($v[$_] -replace "'","''")'" }) -join '; ') + ' }' }
                else { "'$v'" }
            "      $k = $rendered"
        }
        "@{`n  Portal = 'Defender'`n  Category = '$Category'`n  Operations = @(`n    @{`n$($lines -join "`n")`n    }`n  )`n}"
    }

    function New-TempRepo([string]$manifestText, [string]$Category) {
        $t = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-vm-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $t "manifests/Defender") -Force | Out-Null
        # src/ must be reachable for the validator's Parser import. CROSS-PLATFORM (the ci runner is ubuntu): Junction on
        # Windows (no elevation needed · symlinks require Developer Mode), SymbolicLink on Linux/macOS (junctions are
        # Windows-only — this was a green-on-Windows / red-on-ci gap the local hook can't catch · postpush ci is the gate).
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $t 'src') -Target (Join-Path $script:repo 'src') | Out-Null
        Set-Content -Path (Join-Path $t "manifests/Defender/$Category.psd1") -Value $manifestText -Encoding utf8
        $script:temps += $t
        $t
    }
    function Invoke-VM([string]$RepoRoot) {
        $out = & pwsh -NoProfile -File $script:vm -RepoRoot $RepoRoot 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Out = $out }
    }
}
AfterAll {
    foreach ($t in $script:temps) {
        if (Test-Path $t) {
            # Remove the src link FIRST (delete the LINK, never the target) so -Recurse can't traverse into the REAL
            # src on a platform that follows symlinks. (Get-Item).Delete() unlinks on both Windows + Linux.
            $srcLink = Join-Path $t 'src'
            if (Test-Path $srcLink) { try { (Get-Item $srcLink -Force).Delete() } catch { } }
            Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'T4 · CURSOR ship-gate · a CURSOR op MUST declare a CursorField (NaturalKey OPTIONAL — keyless CURSOR dedups by RecordId)' {
    It 'a CURSOR op WITHOUT a CursorField is REJECTED (silent-full-re-emit + stale-token cursor)' {
        $m = New-OpManifest 'CursTestA' @{ CursorField = $null }
        $r = Invoke-VM (New-TempRepo $m 'CursTestA')
        $r.ExitCode | Should -Not -Be 0
        $r.Out | Should -Match 'CURSOR op without a CursorField'
    }
    It 'a CURSOR op WITHOUT a NaturalKey is ALLOWED — keyless CURSOR dedups boundary ties by the RecordId content-hash (F-KEYLESS-CURSOR · 2026-06-20)' {
        # The boundary-tie dedup is DEFINED for a keyless CURSOR (Select-XdrExactlyOnceRows + Get-XdrAdvancedFrontier fall
        # back to the row's RecordId when NaturalKey is empty) and CORRECTLY keeps a changed-value same-id row that an
        # id-NaturalKey would wrongly drop (the GetInsights bucketed-date case). So a missing NaturalKey is NOT a cursor
        # defect — the gate must NOT reject it. (CursTestB is a minimal synthetic op so it is Inactive for lack of
        # evidence — incidental, like CursTestC; we assert only the absence of the CURSOR-NaturalKey rejection message.)
        $m = New-OpManifest 'CursTestB' @{ NaturalKey = @() }
        $r = Invoke-VM (New-TempRepo $m 'CursTestB')
        $r.Out | Should -Not -Match 'CURSOR op without a NaturalKey'
    }
    It 'a CURSOR op WITH CursorField + NaturalKey does NOT trip the cursor rule' {
        $m = New-OpManifest 'CursTestC' @{}
        $r = Invoke-VM (New-TempRepo $m 'CursTestC')
        $r.Out | Should -Not -Match 'CURSOR op without'
    }
}

Describe 'T4 · LIVESTREAM allowlist ↔ runtime agreement' {
    It 'LIVESTREAM is no longer an allowed IngestionMode (no runtime branch · 0 ops use it)' {
        $m = New-OpManifest 'LiveTest' @{ IngestionMode = 'LIVESTREAM'; CursorField = $null }
        $r = Invoke-VM (New-TempRepo $m 'LiveTest')
        $r.ExitCode | Should -Not -Be 0
        $r.Out | Should -Match "IngestionMode 'LIVESTREAM' not in"
    }
}
