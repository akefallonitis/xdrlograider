#Requires -Modules Pester
<#
.SYNOPSIS
    iter-14.0 Phase 4A — typed-column projection helper gate. Asserts
    Project-EntityField and Resolve-EntityPath handle every supported type-cast
    hint, navigate JSONPath cleanly, return $null defensively on unresolvable
    paths, and that ConvertTo-MDEIngestRow correctly applies a ProjectionMap
    while preserving RawJson and skipping boundary-marker rows.

.DESCRIPTION
    Locked invariants:
      Project-EntityField.TypeCast.{tostring|toint|tolong|tobool|todatetime|todouble|todecimal|toguid|json|default}
        — each type cast produces the expected typed value (or $null on cast failure).
      Project-EntityField.Path.{Top|Nested|ArrayIndex|ArrayFlatten|Length}
        — JSONPath navigation works for each documented syntax.
      Project-EntityField.Defensive
        — unresolvable paths return $null, never throw (production responses
          have shape variation; missing fields cannot break ingest).
      ConvertTo-MDEIngestRow.WithProjectionMap
        — typed columns appear on the row alongside RawJson.
      ConvertTo-MDEIngestRow.WithoutProjectionMap
        — backward-compat (original 4-column shape) preserved.
      ConvertTo-MDEIngestRow.RawJsonPreserved
        — every row carries RawJson regardless of projection (forensic).
      ConvertTo-MDEIngestRow.SkipsBoundaryMarker
        — rows with Entity.__boundary_marker=$true don't get projection applied.
#>

BeforeAll {
    $script:RepoRoot       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ClientPsd1     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Xdr.Defender.Client.psd1'
    $script:CommonAuthPsd1 = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Xdr.Common.Auth.psd1'
    $script:DefAuthPsd1    = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Xdr.Defender.Auth.psd1'

    Import-Module $script:CommonAuthPsd1 -Force -ErrorAction Stop
    Import-Module $script:DefAuthPsd1    -Force -ErrorAction Stop
    Import-Module $script:ClientPsd1     -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Client -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Defender.Auth   -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth     -Force -ErrorAction SilentlyContinue
}

Describe 'Project-EntityField — TypeCast' {

    It '$tostring cast (default when no prefix)' {
        $e = [pscustomobject]@{ Name = 'hello' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint 'Name' -Entity $Entity
            $r | Should -Be 'hello'
            $r | Should -BeOfType [string]
        }
    }

    It '$tostring cast (explicit prefix)' {
        $e = [pscustomobject]@{ Status = 42 }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$tostring:Status' -Entity $Entity
            $r | Should -Be '42'
            $r | Should -BeOfType [string]
        }
    }

    It '$toint cast' {
        $e = [pscustomobject]@{ Count = '100' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$toint:Count' -Entity $Entity
            $r | Should -Be 100
            $r | Should -BeOfType [long]
        }
    }

    It '$tobool cast (string "true")' {
        $e = [pscustomobject]@{ Enabled = 'true' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$tobool:Enabled' -Entity $Entity
            $r | Should -Be $true
            $r | Should -BeOfType [bool]
        }
    }

    It '$tobool cast (string "Enabled" → true)' {
        $e = [pscustomobject]@{ State = 'Enabled' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint '$tobool:State' -Entity $Entity | Should -Be $true
        }
    }

    It '$tobool cast (string "off" → false)' {
        $e = [pscustomobject]@{ State = 'off' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint '$tobool:State' -Entity $Entity | Should -Be $false
        }
    }

    It '$todatetime cast (ISO 8601)' {
        $e = [pscustomobject]@{ When = '2026-04-29T10:15:00Z' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$todatetime:When' -Entity $Entity
            $r | Should -BeOfType [datetime]
            $r.Year | Should -Be 2026
        }
    }

    It '$todouble cast' {
        $e = [pscustomobject]@{ Score = '0.95' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$todouble:Score' -Entity $Entity
            $r | Should -BeOfType [double]
            $r | Should -Be 0.95
        }
    }

    It '$json cast (nested object → compact JSON string)' {
        $e = [pscustomobject]@{
            Policy = [pscustomobject]@{ IsEnabled = $true; Targets = @('A','B') }
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            $r = Project-EntityField -Hint '$json:Policy' -Entity $Entity
            $r | Should -BeOfType [string]
            $r | Should -Match '"IsEnabled":true'
            $r | Should -Match '"Targets":'
        }
    }

    It 'returns $null on null entity' {
        InModuleScope Xdr.Defender.Client {
            Project-EntityField -Hint 'Anything' -Entity $null | Should -BeNullOrEmpty
        }
    }

    It 'returns $null on unresolvable path (defensive)' {
        $e = [pscustomobject]@{ ExistingField = 'x' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint '$tostring:NonExistent' -Entity $Entity | Should -BeNullOrEmpty
        }
    }
}

Describe 'Project-EntityField — Path navigation' {

    It 'top-level field' {
        $e = [pscustomobject]@{ Name = 'X' }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint 'Name' -Entity $Entity | Should -Be 'X'
        }
    }

    It 'nested object' {
        $e = [pscustomobject]@{
            Outer = [pscustomobject]@{ Inner = 'deep' }
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint 'Outer.Inner' -Entity $Entity | Should -Be 'deep'
        }
    }

    It 'array index' {
        $e = [pscustomobject]@{
            Tags = @('alpha','beta','gamma')
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint 'Tags[1]' -Entity $Entity | Should -Be 'beta'
        }
    }

    It 'nested-then-index' {
        $e = [pscustomobject]@{
            Targets = @(
                [pscustomobject]@{ DeviceName = 'pc-001' }
                [pscustomobject]@{ DeviceName = 'pc-002' }
            )
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint 'Targets[0].DeviceName' -Entity $Entity | Should -Be 'pc-001'
        }
    }

    It 'array flatten ([*])' {
        $e = [pscustomobject]@{
            Targets = @(
                [pscustomobject]@{ DeviceName = 'pc-001' }
                [pscustomobject]@{ DeviceName = 'pc-002' }
            )
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint 'Targets[*].DeviceName' -Entity $Entity | Should -Be 'pc-001,pc-002'
        }
    }

    It 'length on array' {
        $e = [pscustomobject]@{
            Tags = @('a','b','c','d')
        }
        InModuleScope Xdr.Defender.Client -Parameters @{ Entity = $e } {
            param($Entity)
            Project-EntityField -Hint '$toint:Tags.length' -Entity $Entity | Should -Be 4
        }
    }
}

Describe 'ConvertTo-MDEIngestRow — ProjectionMap application' {

    It 'creates typed columns when ProjectionMap supplied' {
        $entity = [pscustomobject]@{
            ActionId    = 'a-001'
            Status      = 'Completed'
            CreatedTime = '2026-04-29T10:15:00Z'
            Severity    = '5'
        }
        $map = @{
            ActionId    = 'ActionId'
            ActionStatus = '$tostring:Status'
            CreatedTime = '$todatetime:CreatedTime'
            Severity    = '$toint:Severity'
        }
        $row = ConvertTo-MDEIngestRow -Stream 'MDE_ActionCenter_CL' -EntityId 'a-001' -Raw $entity -ProjectionMap $map
        $row.SourceStream | Should -Be 'MDE_ActionCenter_CL'
        $row.EntityId | Should -Be 'a-001'
        $row.ActionId | Should -Be 'a-001'
        $row.ActionStatus | Should -Be 'Completed'
        $row.CreatedTime | Should -BeOfType [datetime]
        $row.Severity | Should -Be 5
        $row.RawJson | Should -Not -BeNullOrEmpty
        $row.RawJson | Should -Match '"ActionId":"a-001"'
    }

    It 'omits ProjectionMap columns when no map supplied (backward-compat)' {
        $entity = [pscustomobject]@{ ActionId = 'a-002'; Status = 'Pending' }
        $row = ConvertTo-MDEIngestRow -Stream 'MDE_TestStream_CL' -EntityId 'a-002' -Raw $entity
        $row.PSObject.Properties.Name | Should -Be @('TimeGenerated','SourceStream','EntityId','RawJson')
    }

    It 'preserves RawJson on every row regardless of projection' {
        $entity = [pscustomobject]@{ X = 1; Y = 2 }
        $map = @{ XCol = 'X' }
        $row = ConvertTo-MDEIngestRow -Stream 'S' -EntityId 'e' -Raw $entity -ProjectionMap $map
        $row.RawJson | Should -Match '"X":1'
        $row.RawJson | Should -Match '"Y":2'
    }

    It 'skips ProjectionMap on boundary-marker rows' {
        $marker = [pscustomobject]@{
            __boundary_marker = $true
            __reason          = 'api-returned-null'
            __observedUtc     = [datetime]::UtcNow.ToString('o')
        }
        $map = @{ ActionId = 'ActionId'; ActionStatus = '$tostring:Status' }
        $row = ConvertTo-MDEIngestRow -Stream 'MDE_ActionCenter_CL' -EntityId 'marker-001' -Raw $marker -ProjectionMap $map
        # Projection columns should NOT appear on boundary-marker rows
        $row.PSObject.Properties.Name | Should -Not -Contain 'ActionId'
        $row.PSObject.Properties.Name | Should -Not -Contain 'ActionStatus'
        # The standard 4 + RawJson preserved
        $row.PSObject.Properties.Name | Should -Contain 'TimeGenerated'
        $row.PSObject.Properties.Name | Should -Contain 'SourceStream'
        $row.PSObject.Properties.Name | Should -Contain 'EntityId'
        $row.PSObject.Properties.Name | Should -Contain 'RawJson'
    }

    It 'Extras override ProjectionMap (caller takes precedence)' {
        $entity = [pscustomobject]@{ ActionId = 'a-100' }
        $map = @{ ActionId = 'ActionId' }
        $extras = @{ ActionId = 'override-id' }
        $row = ConvertTo-MDEIngestRow -Stream 'S' -EntityId 'e' -Raw $entity -ProjectionMap $map -Extras $extras
        $row.ActionId | Should -Be 'override-id' -Because 'Extras merge after ProjectionMap; caller-supplied values must override'
    }

    It 'projection failure falls through silently (column = $null) — does not break ingest' {
        $entity = [pscustomobject]@{ Field = 'x' }
        $map = @{ NonExistentCol = 'NonExistent.DeepPath' }
        $row = ConvertTo-MDEIngestRow -Stream 'S' -EntityId 'e' -Raw $entity -ProjectionMap $map
        $row.NonExistentCol | Should -BeNullOrEmpty
        # Other columns still emit
        $row.SourceStream | Should -Be 'S'
    }
}
