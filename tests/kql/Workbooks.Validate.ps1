#Requires -Modules Pester

BeforeAll {
    $script:WorkbooksDir = Join-Path $PSScriptRoot '..' '..' 'sentinel' 'workbooks'
}

Describe 'Workbooks — file presence' {
    It 'ships exactly 6 workbook .json files' {
        $files = Get-ChildItem -Path $script:WorkbooksDir -Filter '*.json'
        $files.Count | Should -Be 6
    }

    It 'includes all 6 named workbooks' {
        $expected = @(
            'MDE_ComplianceDashboard.json',
            'MDE_DriftReport.json',
            'MDE_GovernanceScorecard.json',
            'MDE_ExposureMap.json',
            'MDE_IdentityPosture.json',
            'MDE_ResponseAudit.json'
        )
        foreach ($name in $expected) {
            Test-Path (Join-Path $script:WorkbooksDir $name) | Should -BeTrue
        }
    }
}

Describe 'Workbooks — schema validation' {
    BeforeAll {
        $script:Workbooks = Get-ChildItem -Path $script:WorkbooksDir -Filter '*.json' | ForEach-Object {
            @{ Name = $_.Name; Content = Get-Content $_.FullName -Raw | ConvertFrom-Json }
        }
    }

    It 'each workbook is valid JSON' -ForEach $script:Workbooks {
        param($Name, $Content)
        $Content | Should -Not -BeNullOrEmpty
    }

    It 'each workbook has version property' -ForEach $script:Workbooks {
        param($Name, $Content)
        $Content.version | Should -Not -BeNullOrEmpty
    }

    It 'each workbook has items array' -ForEach $script:Workbooks {
        param($Name, $Content)
        $Content.items | Should -Not -BeNullOrEmpty
        $Content.items.Count | Should -BeGreaterThan 0
    }

    It 'each workbook has at least one KqlItem or text header' -ForEach $script:Workbooks {
        param($Name, $Content)
        $hasContent = $Content.items | Where-Object { $_.type -in @(1, 3, 9) }
        $hasContent | Should -Not -BeNullOrEmpty
    }
}
