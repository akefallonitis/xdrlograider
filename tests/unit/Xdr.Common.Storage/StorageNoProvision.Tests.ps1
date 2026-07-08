#Requires -Version 7.4
# WS3.3 · A11 locked directive: the RUNTIME NEVER provisions storage — every table/container pre-exists from ARM.
# Pins it two ways: (1) the Storage module exports no create/new primitives; (2) the module source contains no
# table-create REST call (Azure Tables creation = POST to the '/Tables' collection endpoint — entity writes go to
# '/<TableName>(PartitionKey=...)' resources instead). Reintroduce an auto-create path → RED.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:psm = Get-Content (Join-Path $repo 'src\Modules\Xdr.Common.Storage\Xdr.Common.Storage.psm1') -Raw
    Import-Module (Join-Path $repo 'src\Modules\Xdr.Common.Storage\Xdr.Common.Storage.psd1') -Force -DisableNameChecking
}

Describe 'A11 · runtime never provisions storage (tables/containers pre-exist from ARM)' {
    It 'Xdr.Common.Storage exports no create/new/provision primitive' {
        $bad = @(Get-Command -Module Xdr.Common.Storage | Where-Object { $_.Name -match '^(Create|New|Provision)-' })
        $bad | Should -BeNullOrEmpty
    }
    It "module source issues no Tables-collection create (POST .../Tables)" {
        # The Azure Tables CREATE endpoint is the collection resource named exactly 'Tables'.
        ($script:psm -match "(?i)/Tables['""\)]") | Should -BeFalse
    }
    It 'module source never references container creation' {
        ($script:psm -match '(?i)restype=container') | Should -BeFalse
    }
}
