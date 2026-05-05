#requires -Module Pester

<#
.SYNOPSIS
    Phase K regression test — gate the MDE_Heartbeat_CL -> XdrConnectorHealth_CL rename.

.DESCRIPTION
    Per directive 44 + multi-portal forward-compat (D'.16): the connector-health
    table is XdrConnectorHealth_CL (NOT MDE_Heartbeat_CL). The Xdr* prefix signals
    "produced by xdrlograider connector, transcends portal" — when v0.2.0 adds
    Entra/Purview/Intune, all 4 portals write to the SAME XdrConnectorHealth_CL.

    This test gates against regression — if anyone reintroduces MDE_Heartbeat_CL
    in src/, sentinel/, deploy/, tools/, tests/, docs/ (excluding CHANGELOG history
    and this test file), the test fails with the offending file paths.
#>
BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
}

Describe 'Phase K rename: MDE_Heartbeat_CL -> XdrConnectorHealth_CL' {
    Context 'No active code references MDE_Heartbeat_CL' {
        It 'src/ has 0 active references to MDE_Heartbeat_CL (historical rename comments excepted)' {
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/src" -Recurse -File |
                Where-Object { $_.Extension -in '.ps1','.psm1','.psd1','.json' } |
                Select-String -Pattern 'MDE_Heartbeat_CL' -SimpleMatch |
                Where-Object { $_.Line -notmatch 'renamed|Phase K' })
            $matches | Should -BeNullOrEmpty -Because "src/ should reference XdrConnectorHealth_CL only (historical rename comments allowed)"
        }

        It 'sentinel/ has 0 occurrences of MDE_Heartbeat_CL' {
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/sentinel" -Recurse -File |
                Where-Object { $_.Extension -in '.json','.yaml','.yml','.kql' } |
                Select-String -Pattern 'MDE_Heartbeat_CL' -SimpleMatch)
            $matches | Should -BeNullOrEmpty -Because "sentinel content should reference XdrConnectorHealth_CL only"
        }

        It 'deploy/ has 0 occurrences of MDE_Heartbeat_CL' {
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/deploy" -Recurse -File |
                Where-Object { $_.Extension -in '.json','.yaml','.yml','.md' } |
                Select-String -Pattern 'MDE_Heartbeat_CL' -SimpleMatch)
            $matches | Should -BeNullOrEmpty -Because "deploy artifacts should reference XdrConnectorHealth_CL only"
        }

        It 'tools/ has 0 occurrences of MDE_Heartbeat_CL (cleanup tools allowed to reference legacy names)' {
            # Cleanup-PriorDeployment.ps1 legitimately references the legacy
            # MDE_Heartbeat_CL name to clean up workspaces from older deployments.
            # All other tools must reference XdrConnectorHealth_CL only.
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/tools" -Recurse -File |
                Where-Object { $_.Extension -in '.ps1','.psm1','.psd1' } |
                Where-Object { $_.Name -notmatch 'Cleanup-' } |
                Select-String -Pattern 'MDE_Heartbeat_CL' -SimpleMatch)
            $matches | Should -BeNullOrEmpty -Because "non-cleanup operator tools should reference XdrConnectorHealth_CL only"
        }

        It 'docs/ has 0 stale references to MDE_Heartbeat_CL (clean revamp; XdrConnectorHealth_CL is the only ops table)' {
            # v0.1.0 GA is a fresh-install with no migration content. The ops
            # table is named XdrConnectorHealth_CL throughout. Any lingering
            # MDE_Heartbeat_CL reference is a doc bug.
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/docs" -Recurse -File -Filter '*.md' |
                Select-String -Pattern 'MDE_Heartbeat_CL' -SimpleMatch |
                Where-Object { $_.Line -notmatch 'XdrConnectorHealth_CL' -and
                               $_.Line -notmatch 'renamed|formerly|migrate|Phase K' })
            $matches | Should -BeNullOrEmpty -Because "operator docs should reference XdrConnectorHealth_CL except in migration descriptions"
        }
    }

    Context 'XdrConnectorHealth_CL is now the canonical name' {
        It 'src/ has at least 1 occurrence of XdrConnectorHealth_CL' {
            $matches = @(Get-ChildItem -Path "$script:RepoRoot/src" -Recurse -File |
                Where-Object { $_.Extension -in '.ps1','.psm1','.psd1','.json' } |
                Select-String -Pattern 'XdrConnectorHealth_CL' -SimpleMatch)
            $matches.Count | Should -BeGreaterThan 0
        }

        It 'deploy/compiled/mainTemplate.json declares XdrConnectorHealth_CL table + DCR streamDeclaration' {
            $template = Get-Content "$script:RepoRoot/deploy/compiled/mainTemplate.json" -Raw
            $template | Should -Match 'XdrConnectorHealth_CL' -Because 'mainTemplate must declare the table'
            $template | Should -Match 'Custom-XdrConnectorHealth_CL' -Because 'DCR streamDeclaration uses Custom- prefix'
        }
    }

    Context 'IsConnectedQuery on connector card gates on actual data flow (D''.16)' {
        It 'connector card IsConnectedQuery references XdrConnectorHealth_CL' {
            $card = Get-Content "$script:RepoRoot/deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json" -Raw
            $card | Should -Match 'IsConnectedQuery' -Because 'connector card declares IsConnected gate'
            $card | Should -Match 'XdrConnectorHealth_CL' -Because 'IsConnectedQuery reads from connector-health table'
        }

        It 'IsConnectedQuery excludes Tier=Heartbeat liveness rows (per D''.16)' {
            $card = Get-Content "$script:RepoRoot/deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json" -Raw
            $card | Should -Match "Tier\s*!=\s*'Heartbeat'" -Because 'liveness alone does not prove data flowing'
        }

        It 'IsConnectedQuery requires StreamsSucceeded > 0 AND RowsIngested > 0 (per D''.16)' {
            $card = Get-Content "$script:RepoRoot/deploy/solution/Data Connectors/XdrLogRaider_DataConnector.json" -Raw
            $card | Should -Match 'StreamsSucceeded' -Because 'gate on stream success'
            $card | Should -Match 'RowsIngested' -Because 'gate on actual ingestion'
        }
    }

    Context 'Write-Heartbeat Tier ValidateSet supports new Heartbeat value' {
        It 'Write-Heartbeat.ps1 ValidateSet includes Heartbeat (replaces overhead)' {
            $func = Get-Content "$script:RepoRoot/src/Modules/Xdr.Sentinel.Ingest/Public/Write-Heartbeat.ps1" -Raw
            $func | Should -Match "ValidateSet[^\)]+Heartbeat" -Because 'Heartbeat is the new tier value for liveness rows'
        }

        It 'Write-Heartbeat writes to Custom-XdrConnectorHealth_CL stream' {
            $func = Get-Content "$script:RepoRoot/src/Modules/Xdr.Sentinel.Ingest/Public/Write-Heartbeat.ps1" -Raw
            $func | Should -Match "Custom-XdrConnectorHealth_CL" -Because 'DCE outputStream is the renamed table'
        }
    }

    Context 'Connector-Heartbeat function uses Heartbeat tier' {
        It 'Connector-Heartbeat run.ps1 calls Write-Heartbeat with -Tier Heartbeat' {
            $run = Get-Content "$script:RepoRoot/src/functions/Connector-Heartbeat/run.ps1" -Raw
            $run | Should -Match "-Tier\s+'Heartbeat'" -Because 'pure liveness ping'
        }

        It 'Connector-Heartbeat run.ps1 resolves DCR for XdrConnectorHealth_CL stream' {
            $run = Get-Content "$script:RepoRoot/src/functions/Connector-Heartbeat/run.ps1" -Raw
            $run | Should -Match "Get-DcrImmutableIdForStream\s+-StreamName\s+'XdrConnectorHealth_CL'" -Because 'DCR lookup uses new table name'
        }
    }
}
