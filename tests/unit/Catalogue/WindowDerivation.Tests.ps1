#Requires -Version 7.4
# G-C/G-D · WINDOW derivation. An op exposing a from+to time-window query PAIR in Postman (the OpenAPI spec carries
# none) must poll a SERVER time window, not a SNAPSHOT full-re-emit. Build-Catalogue derives IngestionMode='WINDOW' +
# TimeFilter ServerFromDate{FromDateParam,ToDateParam,FieldName} + LookbackHours; Generate-Manifest emits LookbackHours.
# The runtime contract (verified): Resolve-XdrTimeWindow keys on IngestionMode='WINDOW'+LookbackHours (Runtime.psm1:1841-
# 1898); the URL builder injects {FromDateParam=StartUtc, ToDateParam=EndUtc} for Mode='ServerFromDate', requiring
# FieldName non-empty (:1721-1733). These tests are RED on the pre-fix catalogue (the timeline op was SNAPSHOT/None).

Describe 'G-C/G-D · WINDOW IngestionMode + ServerFromDate TimeFilter + LookbackHours' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:cat  = Get-Content "$repo\references\inventory\nodoc-defender-xdr\catalogue.json" -Raw | ConvertFrom-Json
        $script:ops  = $script:cat.Operations
        $script:windowOps = @($script:ops | Where-Object { $_.IngestionMode -eq 'WINDOW' })
    }

    It 'EndpointDevices.GetMachineTimelineEvents (fromDate/toDate · shipped) is WINDOW, not SNAPSHOT' {
        $o = $script:ops | Where-Object { $_.OperationId -eq 'EndpointDevices.GetMachineTimelineEvents' }
        $o | Should -Not -BeNullOrEmpty
        $o.Shipped         | Should -BeTrue
        $o.IngestionMode   | Should -Be 'WINDOW' -Because 'a per-machine timeline-events op with a fromDate/toDate window must NOT SNAPSHOT-re-emit'
        $o.LookbackHours   | Should -BeGreaterThan 0
        $o.TimeFilter.Mode          | Should -Be 'ServerFromDate'
        $o.TimeFilter.FromDateParam | Should -Be 'fromDate'
        $o.TimeFilter.ToDateParam   | Should -Be 'toDate'
        $o.TimeFilter.FieldName     | Should -Not -BeNullOrEmpty -Because 'the URL builder gate (Runtime.psm1:1726) requires FieldName non-empty'
    }

    It 'every WINDOW op carries the COMPLETE runtime contract (ServerFromDate · From+To params · FieldName · LookbackHours)' {
        $script:windowOps.Count | Should -BeGreaterThan 0 -Because 'the corpus has at least one from+to time-window op'
        foreach ($o in $script:windowOps) {
            $o.TimeFilter.Mode          | Should -Be 'ServerFromDate' -Because "WINDOW op $($o.OperationId)"
            $o.TimeFilter.FromDateParam | Should -Not -BeNullOrEmpty -Because "WINDOW op $($o.OperationId) must inject a from param"
            $o.TimeFilter.ToDateParam   | Should -Not -BeNullOrEmpty -Because "WINDOW op $($o.OperationId) must inject a to param"
            $o.TimeFilter.FieldName     | Should -Not -BeNullOrEmpty
            $o.LookbackHours            | Should -BeGreaterThan 0 -Because "WINDOW cold-start needs a lookback ($($o.OperationId))"
        }
    }

    It 'a SNAPSHOT op carries NO LookbackHours (WINDOW-only field · lean envelope)' {
        $snap = $script:ops | Where-Object { $_.OperationId -eq 'ActionCenter.GetPending' }
        $snap | Should -Not -BeNullOrEmpty
        $snap.IngestionMode | Should -Be 'SNAPSHOT'
        ($snap.PSObject.Properties.Name -contains 'LookbackHours') | Should -BeFalse
    }

    It 'Generate-Manifest emits IngestionMode=WINDOW + LookbackHours + ServerFromDate for the WINDOW op (chain end-to-end)' {
        $gen = Join-Path $script:repo 'dev-tools/Generate-Manifest.ps1'
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-gcgd-" + [Guid]::NewGuid().ToString('N') + ".psd1")
        try {
            & pwsh -NoProfile -File $gen -Portal Defender -Group 'Endpoint Management' -OutPath $tmp *> $null
            (Test-Path $tmp) | Should -BeTrue
            $m = Import-PowerShellDataFile $tmp
            $e = $m.Operations | Where-Object { $_.OperationKey -eq 'GetMachineTimelineEvents' }
            $e | Should -Not -BeNullOrEmpty
            $e.IngestionMode        | Should -Be 'WINDOW'
            $e.LookbackHours        | Should -BeGreaterThan 0
            $e.TimeFilter.Mode      | Should -Be 'ServerFromDate'
            $e.TimeFilter.ToDateParam | Should -Be 'toDate'
        } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
    }
}
