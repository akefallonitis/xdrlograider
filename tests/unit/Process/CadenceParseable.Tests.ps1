#Requires -Version 7.4
# FH-9 #3 · CADENCE PARSEABILITY (runtime-parity offline gate · re-grounding audit 2026-06-15). Every manifest op's
# Cadence MUST parse via the EXACT parse the runtime G-Cadence gate uses — [TimeSpan]::Parse(value, InvariantCulture)
# (src/functions/XdrDefenderRefresh/run.ps1) — and be strictly positive. WHY a dedicated gate on top of the
# Validate-Manifests parse check (axis 16): (a) the runtime parses with InvariantCulture, so a culture-sensitive value
# that parses on the dev box could FAIL-OPEN at runtime (cadence not enforced → poll-rate hammering) or be SILENTLY
# DROPPED from the D7 verifier's cadence map (the pre-FH-9 empty catch in Verify-DeployedConnector) — this pins the
# InvariantCulture contract so offline == runtime everywhere. (b) a zero/negative Cadence PARSES fine yet means
# "always due" (poll hammering); Validate-Manifests does not reject it, this does. Generic across every portal/category.
# RED-demonstrable: set any manifest Cadence to 'banana' (parse) or '00:00:00' (positivity).

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:inv  = [System.Globalization.CultureInfo]::InvariantCulture
    $script:ops  = [System.Collections.Generic.List[object]]::new()
    $mroot = Join-Path $script:repo 'manifests'
    if (Test-Path $mroot) {
        foreach ($f in (Get-ChildItem $mroot -Recurse -Filter '*.psd1' -ErrorAction SilentlyContinue)) {
            $m = Import-PowerShellDataFile -LiteralPath $f.FullName -ErrorAction SilentlyContinue
            if (-not $m -or -not $m.ContainsKey('Operations')) { continue }
            foreach ($op in @($m.Operations)) {
                if ($op.ContainsKey('Cadence')) {
                    $script:ops.Add([pscustomobject]@{ Manifest = $f.Name; Op = [string]$op.OperationKey; Cadence = [string]$op.Cadence })
                }
            }
        }
    }
}

Describe 'FH-9 #3 · every manifest Cadence parses with runtime semantics (InvariantCulture · strictly positive)' {
    It 'discovers manifest cadence values (the gate is not vacuous)' {
        $script:ops.Count | Should -BeGreaterThan 0
    }
    It 'every Cadence parses via [TimeSpan]::Parse(value, InvariantCulture) — exactly as the runtime G-Cadence gate' {
        $bad = @()
        foreach ($o in $script:ops) {
            try { $null = [TimeSpan]::Parse($o.Cadence, $script:inv) }
            catch { $bad += "$($o.Manifest)/$($o.Op)='$($o.Cadence)'" }
        }
        $bad | Should -BeNullOrEmpty -Because "unparseable by the runtime parse (fail-open / D7 silent-drop class): $($bad -join ', ')"
    }
    It 'every Cadence is strictly positive (a zero/negative cadence means always-due → poll hammering)' {
        $bad = @()
        foreach ($o in $script:ops) {
            try {
                $ts = [TimeSpan]::Parse($o.Cadence, $script:inv)
                if ($ts -le [TimeSpan]::Zero) { $bad += "$($o.Manifest)/$($o.Op)='$($o.Cadence)'" }
            } catch { }   # unparseable values are flagged by the prior assertion; not double-counted here
        }
        $bad | Should -BeNullOrEmpty -Because "not strictly positive: $($bad -join ', ')"
    }
}
