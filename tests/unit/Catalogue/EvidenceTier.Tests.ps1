#Requires -Version 7.4
# WS2.3 · EvidenceTier provenance + postman saved-response SHAPE evidence (the per-field waterfall, labelled).
# Pins: (1) every op carries an EvidenceTier from the closed set; (2) the hard case verified across all three
# sources — ActionCenter.ListAutomationRules (openapi 200-schema = "pending" stub · postman example = "[]" ·
# no live capture) — is labelled postman-example with ResponseShape=bareArray and an honest EMPTY ProjectionMap
# (zero fabrication; RawJson floor + self-heal at first live rows); (3) the live-proven op stays live-evidence.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:cat = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 40
    $script:ops = @($script:cat['Operations'])
    $script:byId = @{}; foreach ($o in $script:ops) { $script:byId[[string]$o['OperationId']] = $o }
}

Describe 'WS2.3 · EvidenceTier (strongest-source provenance · closed set · never fabricated)' {
    It 'every operation carries an EvidenceTier from the closed set' {
        $set = @('live-evidence','live-captured','postman-example','openapi-schema','conservative')
        foreach ($o in $script:ops) {
            $o.ContainsKey('EvidenceTier') | Should -BeTrue -Because $o['OperationId']
            $set | Should -Contain ([string]$o['EvidenceTier'])
        }
    }
    It 'the behavioral-fixture op is live-evidence (GetHistory)' {
        [string]$script:byId['ActionCenter.GetHistory']['EvidenceTier'] | Should -Be 'live-evidence'
    }
    It 'ListAutomationRules: postman-example tier · bareArray shape from the empty example · EMPTY ProjectionMap (honest)' {
        $op = $script:byId['ActionCenter.ListAutomationRules']
        [string]$op['EvidenceTier']   | Should -Be 'postman-example'
        [string]$op['ResponseShape']  | Should -Be 'bareArray'
        @($op['ProjectionMap'].Keys).Count | Should -Be 0
    }
    It 'no Shipped op is left shape-less (postman/openapi/conservative always supply a container shape)' {
        foreach ($o in @($script:ops | Where-Object { $_['Shipped'] })) {
            [string]$o['ResponseShape'] | Should -Not -BeNullOrEmpty -Because $o['OperationId']
        }
    }
}
