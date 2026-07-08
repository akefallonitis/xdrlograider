# Regression pin for Select-XdrCycleEntries — the per-cycle activity cap + most-overdue-first staggering
# (plan §4.5/§4.9 · the iter32 519-op 10-min-timeout guard). Proves: no-op at/below cap, hard ceiling above
# cap, most-overdue-first ordering, '_OverdueSeconds'-absent → 0, no-checkpoint sentinel sorts first, empty-safe.

#Requires -Module Pester

BeforeAll {
    Set-StrictMode -Version Latest
    $modulesRoot = Join-Path $PSScriptRoot '..\..\..\src\Modules' | Resolve-Path
    $env:PSModulePath = $modulesRoot.Path + [IO.Path]::PathSeparator + $env:PSModulePath
    foreach ($m in @('Xdr.Common.Exceptions','Xdr.Common.Telemetry','Xdr.Common.Cache','Xdr.Common.Storage','Xdr.Common.Auth','Xdr.Common.Parser','Xdr.Common.Ingest','Xdr.Common.Runtime')) {
        Import-Module (Join-Path $modulesRoot.Path "$m\$m.psd1") -Force -DisableNameChecking -ErrorAction Stop
    }

    function New-Entry { param([string]$Key, $Overdue)
        $h = @{ OperationKey = $Key }
        if ($null -ne $Overdue) { $h['_OverdueSeconds'] = $Overdue }
        $h
    }
}

Describe 'Select-XdrCycleEntries · per-cycle activity cap + staggering' {

    It 'is exported by the module' {
        (Get-Command Select-XdrCycleEntries -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'returns ALL entries unchanged when count <= cap (no-op · the v0.1.0 single-Op case)' {
        $in  = @((New-Entry 'A' 10), (New-Entry 'B' 20))
        $out = @(Select-XdrCycleEntries -Entries $in -MaxPerCycle 50)
        $out.Count | Should -Be 2
        $out[0].OperationKey | Should -Be 'A'   # input order preserved when under cap
        $out[1].OperationKey | Should -Be 'B'
    }

    It 'caps to exactly MaxPerCycle when count > cap' {
        $in  = 1..10 | ForEach-Object { New-Entry "Op$_" ($_ * 1.0) }
        $out = @(Select-XdrCycleEntries -Entries @($in) -MaxPerCycle 3)
        $out.Count | Should -Be 3
    }

    It 'dispatches most-overdue-first (descending _OverdueSeconds)' {
        $in  = @((New-Entry 'low' 5), (New-Entry 'high' 500), (New-Entry 'mid' 50))
        $out = @(Select-XdrCycleEntries -Entries $in -MaxPerCycle 2)
        $out.Count | Should -Be 2
        $out[0].OperationKey | Should -Be 'high'   # 500s overdue first
        $out[1].OperationKey | Should -Be 'mid'    # 50s next · 'low' (5s) deferred
    }

    It 'treats a no-checkpoint entry ([double]::MaxValue) as maximally overdue → dispatched first' {
        $in  = @((New-Entry 'cold' ([double]::MaxValue)), (New-Entry 'warm' 100))
        $out = @(Select-XdrCycleEntries -Entries $in -MaxPerCycle 1)
        $out.Count | Should -Be 1
        $out[0].OperationKey | Should -Be 'cold'
    }

    It 'treats a missing _OverdueSeconds key as 0 (lowest priority)' {
        $in  = @((New-Entry 'noKey' $null), (New-Entry 'hasKey' 1))
        $out = @(Select-XdrCycleEntries -Entries $in -MaxPerCycle 1)
        $out.Count | Should -Be 1
        $out[0].OperationKey | Should -Be 'hasKey'   # 1 > 0 (the absent-key default)
    }

    It 'returns an empty array for empty input (cycle no-op safe)' {
        $out = @(Select-XdrCycleEntries -Entries @() -MaxPerCycle 50)
        $out.Count | Should -Be 0
    }

    It 'clamps a non-positive cap to 1 (never dispatches zero when work exists)' {
        $in  = @((New-Entry 'A' 10), (New-Entry 'B' 20))
        $out = @(Select-XdrCycleEntries -Entries $in -MaxPerCycle 0)
        $out.Count | Should -Be 1
    }
}
