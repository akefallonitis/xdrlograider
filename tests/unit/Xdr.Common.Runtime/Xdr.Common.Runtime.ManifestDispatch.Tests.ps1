# Regression pin for the iter#18 dispatch-blocker cluster (plan §23):
#   1. Get-XdrManifests · runspace-independent manifest load. profile.ps1 populates $script:LoadedManifests
#      in ONE pooled runspace; the TimerTrigger runs in OTHERS and saw count=0 → 0 dispatch → 0 rows.
#      This proves the loader resolves manifests via the process-scoped env var (visible to all runspaces)
#      and that the Refresh enumeration consequently yields count>=1 for Defender/Operations.
#   2. ConvertTo-XdrSessionHashtable · normalizes any handler-return shape (array-leak · pscustomobject ·
#      ordered · hashtable) to a PLAIN [hashtable] so the downstream .ContainsKey()/.Portal= never throw
#      under StrictMode (the recurring "property 'Portal' cannot be found" PropertyNotFoundException).

#Requires -Module Pester

BeforeAll {
    Set-StrictMode -Version Latest
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $script:ManifestsRoot = (Join-Path $PSScriptRoot '..\..\..\manifests' | Resolve-Path).Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath

    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Storage','Xdr.Common.Auth','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Runtime')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }
}

Describe 'Get-XdrManifests · runspace-independent loader' {

    It 'resolves manifests via $env:XDRLR_MANIFESTS_ROOT (the process-scoped cross-runspace mechanism)' {
        $env:XDRLR_MANIFESTS_ROOT = $script:ManifestsRoot
        $m = Get-XdrManifests -Force
        $m.ContainsKey('Defender') | Should -BeTrue
        $m['Defender'].ContainsKey('Operations') | Should -BeTrue
    }

    It 'resolves manifests via explicit -Root' {
        $m = Get-XdrManifests -Root $script:ManifestsRoot -Force
        $m['Defender'].ContainsKey('Operations') | Should -BeTrue
    }

    It 'caches the result (same reference without -Force)' {
        $null = Get-XdrManifests -Root $script:ManifestsRoot -Force
        $a = Get-XdrManifests
        $b = Get-XdrManifests
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }

    It '-Force re-reads from disk' {
        $a = Get-XdrManifests -Root $script:ManifestsRoot -Force
        $b = Get-XdrManifests -Root $script:ManifestsRoot -Force
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
    }

    It 'returns an empty hashtable for a missing root (never throws)' {
        $bogus = Join-Path ([IO.Path]::GetTempPath()) ('xdrlr-nope-' + [Guid]::NewGuid())
        $m = Get-XdrManifests -Root $bogus -Force
        $m | Should -BeOfType ([hashtable])
        $m.Count | Should -Be 0
    }
}

Describe 'Refresh enumeration · count>=1 (the count=0 regression)' {

    It 'enumerates at least the Operations/GetHistory Operation from the loaded manifest' {
        $loaded = Get-XdrManifests -Root $script:ManifestsRoot -Force
        $entries = @()
        $defenderManifest = $loaded['Defender']
        foreach ($catKey in $defenderManifest.Keys) {
            $catData  = $defenderManifest[$catKey]
            $catBlock = if ($catData.ContainsKey('Defender')) { $catData['Defender'] } else { $catData }
            if (-not $catBlock.ContainsKey('Operations')) { continue }
            foreach ($op in @($catBlock['Operations'])) {
                $entry = @{}
                foreach ($k in $op.Keys) { $entry[$k] = $op[$k] }
                $entries += $entry
            }
        }
        $entries.Count | Should -BeGreaterOrEqual 1
        ($entries.OperationKey -contains 'GetHistory') | Should -BeTrue
    }
}

Describe 'ConvertTo-XdrSessionHashtable · handler-return normalization (.Portal trap)' {

    It 'passes a clean hashtable through unchanged' {
        $s = ConvertTo-XdrSessionHashtable -InputObject @{ Sccauth='a'; Cookie='c' }
        $s | Should -BeOfType ([hashtable])
        $s['Sccauth'] | Should -Be 'a'
    }

    It 'collapses a pipeline-leak array to its dictionary element' {
        $s = ConvertTo-XdrSessionHashtable -InputObject @($true, $false, @{ Sccauth='b'; Cookie='c' })
        $s | Should -BeOfType ([hashtable])
        $s['Sccauth'] | Should -Be 'b'
    }

    It 'rebuilds a [pscustomobject] into a hashtable' {
        $s = ConvertTo-XdrSessionHashtable -InputObject ([pscustomobject]@{ Sccauth='d'; Cookie='c' })
        $s | Should -BeOfType ([hashtable])
        $s['Sccauth'] | Should -Be 'd'
    }

    It 'rebuilds an [ordered]/OrderedDictionary into a hashtable that supports ContainsKey' {
        $s = ConvertTo-XdrSessionHashtable -InputObject ([ordered]@{ Sccauth='e'; Cookie='c' })
        $s | Should -BeOfType ([hashtable])
        $s.ContainsKey('Sccauth') | Should -BeTrue
    }

    It 'returns $null for null input' {
        ConvertTo-XdrSessionHashtable -InputObject $null | Should -BeNullOrEmpty
    }

    It 'output supports the exact downstream ops that used to throw (.ContainsKey + .Portal assign)' {
        foreach ($shape in @(@{Sccauth='a'}, @($true,@{Sccauth='b'}), [pscustomobject]@{Sccauth='d'}, [ordered]@{Sccauth='e'})) {
            $s = ConvertTo-XdrSessionHashtable -InputObject $shape
            { $null = $s.ContainsKey('Sccauth'); $s.Portal = 'Defender' } | Should -Not -Throw
            $s.Portal | Should -Be 'Defender'
        }
    }
}
