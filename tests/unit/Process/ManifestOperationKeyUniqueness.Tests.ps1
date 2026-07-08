#Requires -Version 7.4
# Manifest OperationKey within-category uniqueness gate (2026-06-24 · Cloud Apps defect class). OperationKey is BOTH
# the checkpoint RowKey (PK=table, RK=OperationKey · Save-XdrCheckpointReset) AND the emitted row Operation value, so a
# DUPLICATE OperationKey within a category's manifest = checkpoint OVERWRITE (one op's cursor clobbers the other) +
# indistinguishable rows. Generate-Manifest disambiguates within-category short-name collisions by prefixing the
# tokenized Subcategory; this gate validates EVERY committed manifest so the class is caught OFFLINE, pre-deploy.
# (Cloud Apps surfaced it: AppGovernance.ListPolicies + CloudApps.ListPolicies both short-name 'ListPolicies'.)

$script:repoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path

$script:manifestCases = @(
    foreach ($f in (Get-ChildItem (Join-Path $script:repoRoot 'manifests\Defender') -Filter '*.psd1')) {
        $m = Import-PowerShellDataFile $f.FullName
        $arr = $null; foreach ($k in $m.Keys) { if ($m[$k] -is [array]) { $arr = $m[$k]; break } }
        $keys = @($arr | ForEach-Object { [string]$_.OperationKey })
        $dups = @($keys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { "$($_.Name) x$($_.Count)" })
        @{ File = $f.Name; Count = $keys.Count; Dups = $dups }
    }
)

Describe 'Manifest OperationKey uniqueness · no within-category checkpoint/row collision' {
    It 'found Defender manifests to validate' {
        @($script:manifestCases).Count | Should -BeGreaterThan 0
    }

    It '<File> (<Count> ops) · every OperationKey is unique within the category manifest' -ForEach $script:manifestCases {
        (@($Dups) -join ', ') | Should -BeNullOrEmpty -Because "a duplicate OperationKey in $File collides checkpoints (RK=OperationKey) and emits indistinguishable rows; Generate-Manifest must disambiguate it (tokenized Subcategory prefix)"
    }
}
