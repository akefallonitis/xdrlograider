#Requires -Version 7.4
# FH-9 · entity-DAG read-fanout ADVANCED to v0.1.0 (the Validate-Scope Rule20 decision). A RESOLVED entity op
# (EntityResolution=Resolved with a COMPLETE DependsOn edge: ParentOperationKey + EntityIdField + ParamName) is
# IN-SCOPE — the runtime Invoke-XdrEntityFanout polls the parent, harvests the id, substitutes the {token}, and polls
# the child under a composite-key checkpoint (fanout COMPLETE · EntityFanout.Tests 19/19). UNRESOLVED/half-resolved
# entity ops STAY deferred (no parent linkage → the child URL can't be built). {TenantId} stays a runtime-context
# token (always in-scope). This pins Rule20's per-op verdict so the advancement can never silently regress either way.

BeforeAll {
    $script:repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $script:repo 'tools\Validate-Scope.ps1')   # dot-source · InvocationName '.' skips the live manifest scan
    function script:New-Op([hashtable]$Over) {
        $base = @{
            OperationKey = 'X'; Method = 'GET'; Path = '/posture/oversight/things'
            Provenance   = @{ Live = $null; Postman = 'references/postman/defender.collection.json'; OpenApi = $null }
        }
        foreach ($k in $Over.Keys) { $base[$k] = $Over[$k] }
        return $base
    }
}

Describe 'FH-9 · Rule20 entity-DAG (Resolved in-scope · Unresolved deferred)' {
    It '{TenantId}-only path is in-scope (runtime-context token · no Rule20)' {
        $v = Test-OperationScope -Op (New-Op @{ Path = '/tenants/{TenantId}/workloadStatus' }) -PortalName 'Defender' -CategoryName 'X'
        @($v.Violations | Where-Object { $_ -match 'Rule20' }) | Should -BeNullOrEmpty
    }
    It 'a non-placeholder path has no Rule20 violation' {
        $v = Test-OperationScope -Op (New-Op @{ Path = '/posture/oversight/metrics' }) -PortalName 'Defender' -CategoryName 'X'
        @($v.Violations | Where-Object { $_ -match 'Rule20' }) | Should -BeNullOrEmpty
    }
    It 'a RESOLVED entity op ({Id} + complete DependsOn) is IN-SCOPE (entity-DAG advanced to v0.1.0)' {
        $op = New-Op @{
            Path             = '/posture/oversight/initiatives/{InitiativeId}'
            EntityResolution = 'Resolved'
            DependsOn        = @{ ParentOperationKey = 'ListPostureOversightInitiatives'; EntityIdField = 'id'; ParamName = 'InitiativeId' }
        }
        $v = Test-OperationScope -Op $op -PortalName 'Defender' -CategoryName 'X'
        @($v.Violations | Where-Object { $_ -match 'Rule20' }) | Should -BeNullOrEmpty -Because 'a Resolved entity op with a complete DependsOn is pollable via Invoke-XdrEntityFanout'
    }
    It 'an UNRESOLVED entity op ({Id}, no Resolved DependsOn) is DEFERRED (Rule20 fires)' {
        $op = New-Op @{ Path = '/posture/oversight/initiatives/{InitiativeId}' }   # no EntityResolution / DependsOn
        $v = Test-OperationScope -Op $op -PortalName 'Defender' -CategoryName 'X'
        @($v.Violations | Where-Object { $_ -match 'Rule20' }) | Should -Not -BeNullOrEmpty -Because 'an unresolved entity-DAG op cannot build the child URL'
    }
    It 'a RESOLVED claim WITHOUT a complete DependsOn still defers (no half-resolved bypass)' {
        $op = New-Op @{ Path = '/posture/oversight/initiatives/{InitiativeId}'; EntityResolution = 'Resolved'; DependsOn = @{ ParentOperationKey = 'P' } }  # missing EntityIdField + ParamName
        $v = Test-OperationScope -Op $op -PortalName 'Defender' -CategoryName 'X'
        @($v.Violations | Where-Object { $_ -match 'Rule20' }) | Should -Not -BeNullOrEmpty
    }
}
