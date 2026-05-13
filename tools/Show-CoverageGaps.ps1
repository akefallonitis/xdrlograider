#Requires -Version 7.0
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
Import-Module Pester -MinimumVersion 5.5.0 -Force
$cfg = New-PesterConfiguration
$cfg.Run.Path = @('tests/unit','tests/arm','tests/kql')
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'None'
$cfg.CodeCoverage.Enabled = $true
$coverageFiles = @(Get-ChildItem -Path 'src/Modules' -Recurse -Include '*.ps1','*.psm1' | ForEach-Object { $_.FullName })
$cfg.CodeCoverage.Path = $coverageFiles
$r = Invoke-Pester -Configuration $cfg

$missed = $r.CodeCoverage.CommandsMissed | Group-Object -Property File | ForEach-Object {
    [pscustomobject]@{
        File = $_.Name.Replace((Join-Path $root 'src/Modules' + [IO.Path]::DirectorySeparatorChar), '')
        Missed = $_.Count
    }
} | Sort-Object Missed -Descending

$missed | Select-Object -First 20 | Format-Table -AutoSize
Write-Output ("Total: " + $r.CodeCoverage.CommandsAnalyzedCount + " analyzed, " + $r.CodeCoverage.CommandsExecutedCount + " executed = " + [math]::Round($r.CodeCoverage.CoveragePercent, 1) + "%")
Pop-Location
