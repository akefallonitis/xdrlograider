#Requires -Module Pester
# Locks tools/Write-PhaseState.ps1 + tools/Read-LatestPhaseState.ps1 contracts:
#   - Writer emits JSON with required schema (phase · exit_at · gates_ticked · etc.)
#   - Reader returns latest phase checkpoint by phase-rank, then by LastWriteTime
#   - Reader honors -Phase filter and -AllPhases
#   - Round-trip: write → read returns equivalent object
# Tests invoke scripts in-process via & $scriptPath (not pwsh -File) so arrays/hashtables
# bind properly and object returns survive.

BeforeAll {
    $script:repoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:writeScript = Join-Path $script:repoRoot 'tools\Write-PhaseState.ps1'
    $script:readScript  = Join-Path $script:repoRoot 'tools\Read-LatestPhaseState.ps1'

    # Helper · seed a fixture PHASE_STATE_<phase>.json directly
    function Write-FixtureCheckpoint {
        param(
            [Parameter(Mandatory)][string]$Repo,
            [Parameter(Mandatory)][string]$Phase,
            [Parameter(Mandatory)][string]$IterName
        )
        $iter = Join-Path $Repo "tests/results/$IterName"
        New-Item -ItemType Directory -Path $iter -Force | Out-Null
        $payload = [ordered]@{
            phase        = $Phase
            exit_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            gates_ticked = @("$Phase.test.gate")
            t1_green     = $true
            head_commit  = "fixture-$Phase"
        }
        $payload | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $iter "PHASE_STATE_$Phase.json")
    }
}

Describe 'Write-PhaseState · script artefact + minimal write' -Tag 'phase-state' {

    It 'tools/Write-PhaseState.ps1 is on disk' {
        Test-Path $script:writeScript | Should -BeTrue
    }

    It 'tools/Read-LatestPhaseState.ps1 is on disk' {
        Test-Path $script:readScript | Should -BeTrue
    }

    It 'writes a JSON checkpoint with required schema fields' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-ps-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            # In-process invocation preserves array param binding
            & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.test.gate1','0a.test.gate2') `
                -NextPhase '0b' `
                -IterDir $tmpIter `
                -NoT1Check | Out-Null

            $checkpoint = Join-Path $tmpIter 'PHASE_STATE_0a.json'
            Test-Path $checkpoint | Should -BeTrue

            $payload = Get-Content -Raw $checkpoint | ConvertFrom-Json
            $payload.phase | Should -Be '0a'
            $payload.next_phase | Should -Be '0b'
            @($payload.gates_ticked).Count | Should -Be 2
            @($payload.gates_ticked) | Should -Contain '0a.test.gate1'
            $payload.PSObject.Properties.Name | Should -Contain 'exit_at'
            $payload.PSObject.Properties.Name | Should -Contain 'head_commit'
            $payload.PSObject.Properties.Name | Should -Contain 'prior_phase'
            $payload.PSObject.Properties.Name | Should -Contain 'sibling_repo_refs_cited'
            # exit_at is a valid ISO timestamp — verify by re-parsing raw JSON text (ConvertFrom-Json auto-coerces to [datetime])
            $rawJson = Get-Content -Raw $checkpoint
            $rawJson | Should -Match '"exit_at":\s*"\d{4}-\d{2}-\d{2}T'
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'computes prior_phase from phase chain (0d → prior=0c)' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-ps-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            & $script:writeScript `
                -Phase '0d' -GatesTicked @('x') -NextPhase '0e' `
                -IterDir $tmpIter -NoT1Check | Out-Null
            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0d.json') | ConvertFrom-Json
            $payload.prior_phase | Should -Be '0c'
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'returns prior_phase as $null for first phase 0a' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-ps-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            & $script:writeScript `
                -Phase '0a' -GatesTicked @('x') -NextPhase '0b' `
                -IterDir $tmpIter -NoT1Check | Out-Null
            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0a.json') | ConvertFrom-Json
            $payload.prior_phase | Should -BeNullOrEmpty
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'merges ExtraData hashtable into payload' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-ps-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            & $script:writeScript `
                -Phase '0a' -GatesTicked @() -NextPhase '0b' `
                -IterDir $tmpIter -NoT1Check `
                -ExtraData @{ custom_field = 'value'; nested = @{ a = 1 } } | Out-Null

            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0a.json') | ConvertFrom-Json
            $payload.custom_field | Should -Be 'value'
            $payload.nested.a | Should -Be 1
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Read-LatestPhaseState · checkpoint discovery + ordering' -Tag 'phase-state' {

    BeforeEach {
        # Per-test repo-isolated temp dir (tests/results · tools)
        $script:tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-rd-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $script:tmpRepo 'tests/results') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmpRepo 'tools') -Force | Out-Null
        Copy-Item -Path $script:readScript -Destination (Join-Path $script:tmpRepo 'tools\Read-LatestPhaseState.ps1') -Force
        $script:tmpReadScript = Join-Path $script:tmpRepo 'tools\Read-LatestPhaseState.ps1'
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tmpRepo -ErrorAction SilentlyContinue
    }

    It 'returns $null when no checkpoints exist' {
        $result = & $script:tmpReadScript
        $result | Should -BeNullOrEmpty
    }

    It 'returns latest phase by rank (G > 0m > 0a)' {
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0a' -IterName 'iter-20260501T000000Z'
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0m' -IterName 'iter-20260502T000000Z'
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase 'G'  -IterName 'iter-20260503T000000Z'

        $result = & $script:tmpReadScript
        $result.phase | Should -Be 'G'
    }

    It '-Phase filter returns specific phase checkpoint' {
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0a' -IterName 'iter-x1'
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0b' -IterName 'iter-x2'

        $result = & $script:tmpReadScript -Phase '0a'
        $result.phase | Should -Be '0a'
    }

    It '-Phase filter returns nothing for missing phase' {
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0a' -IterName 'iter-x'
        $result = & $script:tmpReadScript -Phase '0g'
        $result | Should -BeNullOrEmpty
    }

    It '-AllPhases returns one entry per phase' {
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0a' -IterName 'iter-1'
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0b' -IterName 'iter-2'
        Write-FixtureCheckpoint -Repo $script:tmpRepo -Phase '0c' -IterName 'iter-3'

        $result = & $script:tmpReadScript -AllPhases
        @($result).Count | Should -Be 3
    }
}

Describe 'Write-PhaseState · -StrictVerify gate-evidence disk verification (S-7)' -Tag 'phase-state' {

    It 'writes successfully when all gates have file: evidence on disk' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.repo.readme-only-md') `
                -GateEvidence @{ '0a.repo.readme-only-md' = 'file:README.md' } `
                -StrictVerify `
                -NextPhase '0b' -IterDir $tmpIter -NoT1Check | Out-Null

            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0a.json') | ConvertFrom-Json
            $payload.gates_strict_verified | Should -BeTrue
            $payload.gate_evidence.'0a.repo.readme-only-md' | Should -Be 'file:README.md'
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'writes successfully when all gates have commit: evidence in git history' {
        # Skip if baseline commit 3809bf5 not reachable (post-squash orphan branch · CI shallow clone)
        $baselineExists = & git -C $script:repoRoot rev-parse --verify --quiet '3809bf5' 2>$null
        if (-not $baselineExists) {
            Set-ItResult -Skipped -Because '3809bf5 not in git history (post-squash orphan branch · expected · operator-local has it via reflog)'
            return
        }
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            # Use the S-1 hook-installed commit as a real evidence anchor
            & $script:writeScript `
                -Phase '0d' `
                -GatesTicked @('0d.s1.hook-installed') `
                -GateEvidence @{ '0d.s1.hook-installed' = 'commit:3809bf5' } `
                -StrictVerify `
                -NextPhase '0e' -IterDir $tmpIter -NoT1Check | Out-Null

            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0d.json') | ConvertFrom-Json
            $payload.gates_strict_verified | Should -BeTrue
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'THROWS to refuse-write when -StrictVerify and gate has no evidence' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            # Hashtables don't cross pwsh -File boundary · use in-process invocation + Should-Throw
            { & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.missing.evidence') `
                -GateEvidence @{} `
                -StrictVerify `
                -NextPhase '0b' -IterDir $tmpIter -NoT1Check } | Should -Throw -ExpectedMessage '*StrictVerify REFUSED*'
            Test-Path (Join-Path $tmpIter 'PHASE_STATE_0a.json') | Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'THROWS when commit: evidence points to non-existent SHA' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            { & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.fake.commit') `
                -GateEvidence @{ '0a.fake.commit' = 'commit:deadbeefcafe1234' } `
                -StrictVerify `
                -NextPhase '0b' -IterDir $tmpIter -NoT1Check } | Should -Throw -ExpectedMessage '*REFUSED*'
            Test-Path (Join-Path $tmpIter 'PHASE_STATE_0a.json') | Should -BeFalse
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'THROWS when file: evidence points to non-existent file' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            { & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.fake.file') `
                -GateEvidence @{ '0a.fake.file' = 'file:tools/Nonexistent.ps1' } `
                -StrictVerify `
                -NextPhase '0b' -IterDir $tmpIter -NoT1Check } | Should -Throw -ExpectedMessage '*REFUSED*'
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'resolves test: evidence by grepping the assertion text in the test file' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            # Real test file + real assertion from this very file
            & $script:writeScript `
                -Phase '0d' `
                -GatesTicked @('0d.s2.phasestate-tests-exist') `
                -GateEvidence @{ '0d.s2.phasestate-tests-exist' = 'test:tests/unit/PhaseState.Tests.ps1::Write-PhaseState' } `
                -StrictVerify `
                -NextPhase '0e' -IterDir $tmpIter -NoT1Check | Out-Null
            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0d.json') | ConvertFrom-Json
            $payload.gates_strict_verified | Should -BeTrue
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }

    It 'accepts text: as soft (operator-asserted) but logs the claim · last-resort use only' {
        $tmpIter = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-strict-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmpIter -Force | Out-Null
        try {
            & $script:writeScript `
                -Phase '0a' `
                -GatesTicked @('0a.soft.claim') `
                -GateEvidence @{ '0a.soft.claim' = 'text:operator-verified-manually' } `
                -StrictVerify `
                -NextPhase '0b' -IterDir $tmpIter -NoT1Check | Out-Null
            $payload = Get-Content -Raw (Join-Path $tmpIter 'PHASE_STATE_0a.json') | ConvertFrom-Json
            $payload.gates_strict_verified | Should -BeTrue
            $payload.gate_evidence.'0a.soft.claim' | Should -Be 'text:operator-verified-manually'
        } finally {
            Remove-Item -Recurse -Force $tmpIter -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Round-trip · Write then Read returns equivalent checkpoint' -Tag 'phase-state' {

    It 'phase + gates_ticked + next_phase + sibling-repo refs survive write→read' {
        $tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("xdr-rt-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'tests/results') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'tools') -Force | Out-Null
        Copy-Item -Path $script:writeScript -Destination (Join-Path $tmpRepo 'tools\Write-PhaseState.ps1') -Force
        Copy-Item -Path $script:readScript  -Destination (Join-Path $tmpRepo 'tools\Read-LatestPhaseState.ps1') -Force
        $tmpWriteScript = Join-Path $tmpRepo 'tools\Write-PhaseState.ps1'
        $tmpReadScript  = Join-Path $tmpRepo 'tools\Read-LatestPhaseState.ps1'

        try {
            $iter = Join-Path $tmpRepo 'tests/results/iter-roundtrip'
            New-Item -ItemType Directory -Path $iter -Force | Out-Null

            & $tmpWriteScript `
                -Phase '0e' `
                -GatesTicked @('0e.test.alpha','0e.test.beta') `
                -NextPhase '0f' `
                -SiblingRepoRefsCited @('xdrlograider-v3/src/foo.psm1:42') `
                -IterDir $iter `
                -NoT1Check | Out-Null

            $result = & $tmpReadScript
            $result.phase | Should -Be '0e'
            $result.next_phase | Should -Be '0f'
            @($result.gates_ticked).Count | Should -Be 2
            @($result.sibling_repo_refs_cited)[0] | Should -Be 'xdrlograider-v3/src/foo.psm1:42'
        } finally {
            Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue
        }
    }
}
