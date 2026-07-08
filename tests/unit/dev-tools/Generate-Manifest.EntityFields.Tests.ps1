#Requires -Version 7.4
# G-B · manifest entity-routing emission. Generate-Manifest must emit DependsOn + EntityResolution for entity ops so
# the runtime can fan them out: Invoke-XdrEntityFanout (Xdr.Common.Runtime.psm1:1184-1190) routes an op to the entity
# fan-out path IFF its manifest entry carries a DependsOn IDictionary AND EntityResolution='Resolved', then reads
# DependsOn.ParentOperationKey / EntityIdField / ParamName. Before G-B those fields were dropped, so every entity op
# silently fell through to the normal poll path (dead {param} URL · never polled). These tests are RED on the pre-G-B
# emitter (DependsOn/EntityResolution absent → fan-out gate false) and GREEN after. They also pin the inverse: a
# non-entity op must NOT carry the fields (lean entry · normal poll path · Operations pilot stays byte-stable).

Describe 'G-B · Generate-Manifest emits runtime entity-routing fields' {
    BeforeAll {
        $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
        $script:gen  = Join-Path $repo 'dev-tools/Generate-Manifest.ps1'
        $script:tmp  = Join-Path ([IO.Path]::GetTempPath()) ("xdrlr-gb-" + [Guid]::NewGuid().ToString('N') + ".psd1")
        # 'Endpoint Management' is the display-group carrying the Resolved entity GETs (EndpointDevices.* + EndpointConfiguration.*)
        & pwsh -NoProfile -File $script:gen -Portal Defender -Group 'Endpoint Management' -OutPath $script:tmp *> $null
        $script:manifest = if (Test-Path $script:tmp) { Import-PowerShellDataFile $script:tmp } else { $null }
        # entity ops = manifest ops whose Path carries a non-TenantId {param} (the runtime fan-out set). DERIVED from the
        # manifest, NOT a hardcoded list, so the gate stays correct as the catalogued entity-fan-out surface expands
        # (ROUND-7 2026-06-22: the device≡machine resolver fix + fan-out-parent fix added GetNdrInterceptingMachines /
        # GetTags / GetRbacGroups / GetRbacGroupScopes / GetTimeline / GetDataSensitivity to the shipped Resolved-entity set).
        $script:entityKeys = @($script:manifest.Operations | Where-Object { ([string]$_.Path) -match '\{(?!TenantId\})[A-Za-z0-9]+\}' } | ForEach-Object { [string]$_.OperationKey })
    }
    AfterAll { if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item $script:tmp -Force -ErrorAction SilentlyContinue } }

    It 'generates the Endpoint Management manifest with shipped ops' {
        $script:manifest | Should -Not -BeNullOrEmpty -Because 'Generate-Manifest must produce the entity-bearing category'
        @($script:manifest.Operations).Count | Should -BeGreaterThan 0
    }

    It 'every Resolved entity op carries a DependsOn IDictionary + EntityResolution=Resolved (the runtime fan-out gate)' {
        $entityOps = @($script:manifest.Operations | Where-Object { $_.OperationKey -in $script:entityKeys })
        $entityOps.Count | Should -BeGreaterThan 0 -Because 'G-H shipped these Resolved entity GETs'
        foreach ($e in $entityOps) {
            $e.EntityResolution | Should -Be 'Resolved' -Because "entity op $($e.OperationKey)"
            $e.DependsOn        | Should -BeOfType [System.Collections.IDictionary] -Because "runtime requires DependsOn as a dict ($($e.OperationKey))"
            $e.DependsOn.ParentOperationKey | Should -Not -BeNullOrEmpty
            $e.DependsOn.EntityIdField      | Should -Not -BeNullOrEmpty
            $e.DependsOn.ParamName          | Should -Not -BeNullOrEmpty
        }
    }

    It 'a non-entity op in the SAME category carries NEITHER field (lean entry · normal poll path)' {
        $nonEntity = @($script:manifest.Operations | Where-Object { $_.OperationKey -notin $script:entityKeys })
        $nonEntity.Count | Should -BeGreaterThan 0
        foreach ($e in $nonEntity) {
            $e.ContainsKey('DependsOn')        | Should -BeFalse -Because "non-entity $($e.OperationKey) never fans out"
            $e.ContainsKey('EntityResolution') | Should -BeFalse -Because "non-entity $($e.OperationKey) needs no resolution gate"
        }
    }

    It 'a Resolved entity op satisfies the EXACT Invoke-XdrEntityFanout routing predicate' {
        # Mirrors the runtime gate at Xdr.Common.Runtime.psm1:1186-1192 verbatim.
        $op = $script:manifest.Operations | Where-Object { $_.OperationKey -eq 'GetMachineTimelineEvents' }
        $op | Should -Not -BeNullOrEmpty
        $routes = ($op.DependsOn -is [System.Collections.IDictionary]) -and
                  ([string]$op.EntityResolution -eq 'Resolved') -and
                  -not [string]::IsNullOrEmpty([string]$op.DependsOn.ParentOperationKey) -and
                  -not [string]::IsNullOrEmpty([string]$op.DependsOn.EntityIdField) -and
                  -not [string]::IsNullOrEmpty([string]$op.DependsOn.ParamName)
        $routes | Should -BeTrue -Because 'the manifest entry must drive the runtime fan-out, not fall through to normal poll'
    }
}
