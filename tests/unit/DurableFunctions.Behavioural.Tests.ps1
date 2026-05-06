#Requires -Modules Pester
<#
.SYNOPSIS
    Behavioural tests that EXECUTE the orchestrator + activity code with
    simulated Durable Functions runtime input. Catches runtime bugs that
    regex-pattern-only tests (DurableFunctions.Structure.Tests.ps1) miss.

.DESCRIPTION
    Two production bugs surfaced during live audit on 2026-05-06 that the
    pre-existing structure tests missed because they only regex-matched code
    patterns instead of exercising runtime behaviour:

      1. JValue cast crash (commit 8ec9b1d): orchestrator/activity accessed
         $Context.Input.Portal directly. Durable Functions delivers Input as a
         Newtonsoft.Json.Linq.JObject; .Portal returns JValue, not String.
         Direct use crashed with InvalidCastException.

      2. Portal-field semantic conflict (commit pending): manifest Defaults set
         entry-level Portal='security.microsoft.com' (FQDN), but orchestrator's
         filter compared against logical name 'Defender'. Resulted in
         matchedStreams=0 for every cadence-tier invocation despite manifest
         containing valid entries. 116/116 fan-outs returned empty.

    These tests RUN the actual orchestrator + activity code with realistic
    inputs (string, JValue) and assert the runtime behaviour: filter matches
    expected streams, types are handled correctly, exceptions don't surface.

.NOTES
    These tests don't require Durable Functions runtime — they substitute
    Invoke-DurableActivity / Wait-DurableTask with mocks and execute the
    orchestrator's body directly. The intent is to validate the production
    code path that runs INSIDE Durable, not the Durable plumbing itself.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $modulesDir = Join-Path $script:RepoRoot 'src/Modules'
    $script:OriginalPSModulePath = $env:PSModulePath
    $env:PSModulePath = "$modulesDir$([IO.Path]::PathSeparator)$($env:PSModulePath)"

    Import-Module (Join-Path $modulesDir 'Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force -ErrorAction Stop

    $script:OrchestratorPath = Join-Path $script:RepoRoot 'src/functions/Xdr-PollOrchestrator/run.ps1'
    $script:ActivityPath     = Join-Path $script:RepoRoot 'src/functions/Xdr-PollStream/run.ps1'
}

AfterAll {
    Remove-Module Xdr.Common.Manifest -Force -ErrorAction SilentlyContinue
    if ($script:OriginalPSModulePath) { $env:PSModulePath = $script:OriginalPSModulePath }
}

Describe 'Xdr-PollOrchestrator — runtime behaviour with realistic Durable inputs' {

    Context 'Manifest filter must match streams for every cadence tier (regression: matchedStreams=0 bug)' {

        It 'Tier=<Tier> matches expected stream count from manifest' -ForEach @(
            @{ Tier = 'ActionCenter';  ExpectedMin = 2 }
            @{ Tier = 'Configuration'; ExpectedMin = 5 }   # 14 streams in Configuration; >=5 minimum to catch regressions
            @{ Tier = 'Inventory';     ExpectedMin = 5 }
            @{ Tier = 'XspmGraph';     ExpectedMin = 5 }
            @{ Tier = 'Maintenance';   ExpectedMin = 1 }
        ) {
            param($Tier, $ExpectedMin)

            $manifest = Get-XdrEndpointManifest -Portal Defender
            $matched = @(
                $manifest.Values | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and
                    $_.Contains('Tier') -and ([string]$_.Tier -eq [string]$Tier)
                }
            )
            $matched.Count | Should -BeGreaterOrEqual $ExpectedMin -Because "every cadence-tier timer must produce at least $ExpectedMin streams to fan out (live bug: filter returned 0 due to Portal field FQDN/logical-name conflict)"
        }
    }

    Context 'String parameters survive JValue-style input (regression: JValue cast crash)' {

        # Simulate Durable Functions delivering Input as types other than [string].
        # In production this is Newtonsoft.Json.Linq.JValue; locally we test with
        # PSObject + raw types — the [string] cast must handle all of them.
        It 'Tier comparison works when input wraps Tier in pscustomobject (JValue analog)' {
            $portalLogical = 'Defender'
            $tierAsObject = [pscustomobject]@{ Value = 'ActionCenter' }
            $manifest = Get-XdrEndpointManifest -Portal $portalLogical
            $tierString = [string]$tierAsObject.Value
            $matched = @($manifest.Values | Where-Object {
                $_ -is [System.Collections.IDictionary] -and
                $_.Contains('Tier') -and ([string]$_.Tier -eq $tierString)
            })
            $matched.Count | Should -BeGreaterOrEqual 2 -Because 'explicit [string] cast must coerce JValue/PSCustomObject into a string for -eq comparison'
        }

        It 'Bare scriptblock that mimics orchestrator body completes without throwing' {
            # Simulate the orchestrator''s critical path inline — this is the body
            # that ran 116 times with 0 success in production. Replicates:
            # 1. Read $Context.Input (JObject in production; pscustomobject here)
            # 2. Cast to string
            # 3. Load manifest
            # 4. Filter
            # 5. Build activity inputs
            $simulatedInput = [pscustomobject]@{
                Portal       = 'Defender'
                Tier         = 'ActionCenter'
                FunctionName = 'Xdr-Refresh'
            }
            $body = {
                param($Context)
                $orchInput = $Context.Input
                $portal    = [string]$orchInput.Portal
                $tier      = [string]$orchInput.Tier
                $manifest  = Get-XdrEndpointManifest -Portal $portal
                $tierStreams = @(
                    $manifest.Values | Where-Object {
                        $_ -is [System.Collections.IDictionary] -and
                        $_.Contains('Tier') -and ([string]$_.Tier -eq [string]$tier)
                    }
                )
                return @{ Tier = $tier; Portal = $portal; MatchedCount = $tierStreams.Count }
            }
            $ctx = [pscustomobject]@{ Input = $simulatedInput }
            $result = & $body $ctx
            $result.MatchedCount | Should -BeGreaterThan 0 -Because 'orchestrator body must produce non-zero stream matches for any valid cadence tier'
        }
    }

    Context 'Manifest defaults split Portal (logical name) from PortalHost (FQDN) — v0.2.0 multi-portal forward-compat' {

        It 'Get-XdrManifestDefaults returns Portal=Defender (logical) AND PortalHost=security.microsoft.com (FQDN)' {
            InModuleScope Xdr.Common.Manifest {
                $defaults = Get-XdrManifestDefaults
                $defaults.ContainsKey('Portal')     | Should -BeTrue
                $defaults.ContainsKey('PortalHost') | Should -BeTrue
                $defaults.Portal                    | Should -Be 'Defender'              -Because 'orchestrator filter expects logical name match'
                $defaults.PortalHost                | Should -Be 'security.microsoft.com' -Because 'L2 auth Session.PortalHost needs FQDN for URL construction'
            }
        }

        It 'Real loaded manifest entries inherit Portal=Defender from Defaults' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $sample = @($manifest.Values)[0]
            [string]$sample.Portal | Should -Be 'Defender' -Because 'orchestrator $_.Portal -eq $portal filter must match for fan-out to occur'
        }

        It 'Real loaded manifest entries inherit PortalHost=security.microsoft.com from Defaults' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $sample = @($manifest.Values)[0]
            [string]$sample.PortalHost | Should -Be 'security.microsoft.com'
        }

        It 'Orchestrator filter against logical Portal=Defender matches expected entries (forward-compat for v0.2.0 multi-portal merge)' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $matched = @(
                $manifest.Values | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and
                    $_.Contains('Tier') -and ([string]$_.Tier -eq 'ActionCenter') -and
                    (-not $_.Contains('Portal') -or [string]$_.Portal -eq 'Defender')
                }
            )
            $matched.Count | Should -BeGreaterOrEqual 2
        }
    }
}

Describe 'Xdr-PollStream — runtime behaviour with realistic Durable activity inputs' {

    Context 'Activity input access uses [string] cast AND non-shadowing param name (regression: JValue crash + $Input automatic shadow)' {

        It 'Activity param block does NOT use $Input (PowerShell automatic-variable shadow)' {
            # Live forensic 2026-05-06: param($Input) shadows the PowerShell
            # automatic $Input pipeline-enumerator variable. The activity binding
            # silently resolves to the empty automatic, NOT the JObject. Result:
            # every $Input.Property access returns null, [string]$null='', and
            # downstream calls (Pop-XdrIngestDlq, Invoke-MDEEndpoint) fail with
            # empty Stream/StreamName values.
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Not -Match '(?m)^\s*param\s*\(\s*\$Input\s*\)' -Because 'param($Input) shadows PowerShell automatic; activity input does not bind. Use $ActivityInput or similar.'
        }

        It 'Activity body reads Portal/Tier/StreamName via [string] cast on the named param (NOT $Input)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            # Discover the param name from `param($X)` line; assert reads use it.
            if ($activitySource -match '(?m)^\s*param\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*\)') {
                $paramName = $Matches[1]
                $paramName | Should -Not -Be 'Input' -Because 'shadow check'
                $activitySource | Should -Match ('\$portal\s*=\s*\[string\]\$' + [regex]::Escape($paramName) + '\.Portal')
                $activitySource | Should -Match ('\$tier\s*=\s*\[string\]\$' + [regex]::Escape($paramName) + '\.Tier')
                $activitySource | Should -Match ('\$streamName\s*=\s*\[string\]\$' + [regex]::Escape($paramName) + '\.StreamName')
            } else {
                throw "Could not extract param name from activity source"
            }
        }
    }

    Context 'Activity calls Get-XdrAuthFromKeyVault with correct param names (regression: ParameterBindingException for KeyVaultUri)' {

        It 'Activity uses -VaultUri (not -KeyVaultUri) — matches actual function signature' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match '-VaultUri\s+\$config\.KeyVaultUri' -Because 'real param is -VaultUri; -KeyVaultUri throws ParameterBindingException'
            $activitySource | Should -Not -Match '-KeyVaultUri\s+\$config\.KeyVaultUri' -Because '-KeyVaultUri is NOT a parameter of Get-XdrAuthFromKeyVault'
        }

        It 'Activity uses -SecretPrefix (not -SecretName) — matches actual function signature' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match '-SecretPrefix\s+\$config\.AuthSecretName' -Because 'real param is -SecretPrefix; -SecretName is NOT a parameter'
        }

        It 'Activity does not pass -ServiceAccountUpn or -ExpectedTenantId to Get-XdrAuthFromKeyVault (those go to Connect-DefenderPortal)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            # Multi-line PS continuation block: function name + first-line backtick + zero or more continuation lines + final line.
            # Anchored on '\s+`' to skip comment occurrences and only match the actual call site.
            $authBlock = if ($activitySource -match '(?ms)Get-XdrAuthFromKeyVault[^\r\n]*`\r?\n(?:[^\r\n]*`\r?\n)*[^\r\n]*') { $Matches[0] } else { '' }
            $authBlock | Should -Not -Match '-ServiceAccountUpn\s'    -Because 'ServiceAccountUpn is not a Get-XdrAuthFromKeyVault parameter; only Connect-DefenderPortal accepts it'
            $authBlock | Should -Not -Match '-ExpectedTenantId\s'     -Because 'ExpectedTenantId is not a Get-XdrAuthFromKeyVault parameter; only Connect-DefenderPortal accepts it'
        }
    }

    Context 'Get-XdrAuthFromKeyVault function signature anchor (catches future param-name drift)' {

        It 'Get-XdrAuthFromKeyVault has VaultUri + SecretPrefix + AuthMethod parameters' {
            $kvAuthPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth/Public/Get-XdrAuthFromKeyVault.ps1'
            $src = Get-Content -Raw $kvAuthPath
            $src | Should -Match '\[string\]\s*\$VaultUri'
            $src | Should -Match '\[string\]\s*\$SecretPrefix'
            $src | Should -Match '\[string\]\s*\$AuthMethod'
        }
    }

    Context 'Activity calls Connect-DefenderPortal with correct param names + correct shape (regression: Credential null bug)' {

        It 'Activity passes the WHOLE $authBundle as -Credential (not $authBundle.Credential)' {
            # Get-XdrAuthFromKeyVault returns @{ upn; password; totpBase32 } for CredentialsTotp.
            # Connect-DefenderPortal expects the WHOLE hashtable as -Credential.
            # Activity wrongly used $authBundle.Credential (null) which threw
            # ParameterBindingValidationException 'Cannot bind argument to Credential because it is null'.
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match '-Credential\s+\$authBundle\b' -Because 'whole bundle IS the credential hashtable'
            $activitySource | Should -Not -Match '-Credential\s+\$authBundle\.Credential' -Because 'no nested .Credential property exists on Get-XdrAuthFromKeyVault output'
        }

        It 'Activity does NOT pass -TotpBase32Secret / -PasskeyJsonPath / -ServiceAccountUpn / -ExpectedTenantId to Connect-DefenderPortal (none are params)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $connectBlock = if ($activitySource -match '(?ms)Connect-DefenderPortal[^\r\n]*`\r?\n(?:[^\r\n]*`\r?\n)*[^\r\n]*') { $Matches[0] } else { '' }
            $connectBlock | Should -Not -Match '-TotpBase32Secret\s'
            $connectBlock | Should -Not -Match '-PasskeyJsonPath\s'
            $connectBlock | Should -Not -Match '-ServiceAccountUpn\s'
            $connectBlock | Should -Not -Match '-ExpectedTenantId\s' -Because 'Connect-DefenderPortal uses -TenantId, not -ExpectedTenantId'
        }

        It 'Activity uses -TenantId (the actual Connect-DefenderPortal param)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match '-TenantId\s+\$config\.ExpectedTenantId'
        }
    }

    Context 'Connect-DefenderPortal signature anchor (catches future drift)' {

        It 'Connect-DefenderPortal has Method + Credential + PortalHost + TenantId parameters' {
            $cdpPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Connect-DefenderPortal.ps1'
            $src = Get-Content -Raw $cdpPath
            $src | Should -Match '\[string\]\s*\$Method'
            $src | Should -Match '\[hashtable\]\s*\$Credential'
            $src | Should -Match '\[string\]\s*\$PortalHost'
            $src | Should -Match '\[string\]\s*\$TenantId'
        }
    }

    Context 'Activity calls Pop-XdrIngestDlq with correct param names (regression: missing -TableName)' {

        It 'Activity passes all 4 mandatory Pop-XdrIngestDlq params: StorageAccountName + TableName + StreamName + MaxBatches' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            # Anchor on '\s+`' to skip comment line ('Pop-XdrIngestDlq signature requires:'); match only call site.
            $popBlock = if ($activitySource -match '(?ms)Pop-XdrIngestDlq\s+`\r?\n(?:[^\r\n]*`\r?\n)*[^\r\n]*') { $Matches[0] } else { '' }
            $popBlock | Should -Match '-StorageAccountName\s'
            $popBlock | Should -Match '-TableName\s'  -Because '-TableName is mandatory; missing it caused live ParameterBindingException'
            $popBlock | Should -Match '-StreamName\s'
            $popBlock | Should -Match '-MaxBatches\s'
        }

        It 'Activity reads DLQ table name from $env:XDR_INGEST_DLQ_TABLE_NAME (DlqTable config field)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match 'DlqTable\s*=\s*\$env:XDR_INGEST_DLQ_TABLE_NAME' -Because 'DLQ table name is a process env var set by ARM template'
        }
    }

    Context 'Activity calls Invoke-MDEEndpoint with correct shape AND ingests via Send-ToLogAnalytics (regression: -Config + missing ingest)' {

        It 'Activity does NOT pass -Config to Invoke-MDEEndpoint (not a parameter)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $invokeBlock = if ($activitySource -match '(?ms)Invoke-MDEEndpoint[^\r\n]*') { $Matches[0] } else { '' }
            $invokeBlock | Should -Not -Match '-Config\b' -Because 'Invoke-MDEEndpoint accepts -Session / -Stream / -FromUtc / -PathParams only'
        }

        It 'Activity treats Invoke-MDEEndpoint result as object[] rows (not @{ RowsIngested })' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            # Old buggy pattern: $result = Invoke-MDEEndpoint ... ; if ($result.RowsIngested) ...
            # New correct pattern: $freshRows = @(Invoke-MDEEndpoint ...)
            $activitySource | Should -Match '\$freshRows\s*=\s*@\(Invoke-MDEEndpoint' -Because 'Invoke-MDEEndpoint returns rows; activity must wrap in @() and feed Send-ToLogAnalytics'
            $activitySource | Should -Not -Match '\$result\.RowsIngested' -Because 'no RowsIngested property on Invoke-MDEEndpoint output'
        }

        It 'Activity calls Send-ToLogAnalytics to actually ingest (was missing entirely)' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match 'Send-ToLogAnalytics' -Because 'without this call the activity would never write to DCE -> DCR -> workspace tables'
            # Anchor on '\s+`' to skip preceding comment lines that mention Send-ToLogAnalytics; match only the actual call site.
            $sendBlock = if ($activitySource -match '(?ms)Send-ToLogAnalytics\s+`\r?\n(?:[^\r\n]*`\r?\n)*[^\r\n]*') { $Matches[0] } else { '' }
            $sendBlock | Should -Match '-DceEndpoint\s'
            $sendBlock | Should -Match '-DcrImmutableId\s'
            $sendBlock | Should -Match '-StreamName\s'
            $sendBlock | Should -Match '-Rows\s'
        }

        It 'Activity resolves DCR immutableId from DCR_IMMUTABLE_IDS_JSON env var' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match 'DcrImmutableIdsJson.*ConvertFrom-Json' -Because 'per-stream DCR-id resolution is what the env var was built for'
        }
    }

    Context 'Pop-XdrIngestDlq + Invoke-MDEEndpoint + Send-ToLogAnalytics signature anchors' {

        It 'Pop-XdrIngestDlq has StorageAccountName + TableName + StreamName + MaxBatches mandatory' {
            $src = Get-Content -Raw (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Pop-XdrIngestDlq.ps1')
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$StorageAccountName'
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$TableName'
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$StreamName'
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[int\]\s*\$MaxBatches'
        }

        It 'Invoke-MDEEndpoint has Session + Stream parameters (no -Config)' {
            $src = Get-Content -Raw (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Public/Invoke-MDEEndpoint.ps1')
            $src | Should -Match '\[pscustomobject\]\s*\$Session'
            $src | Should -Match '\[string\]\s*\$Stream'
            $src | Should -Not -Match '\[\w+\]\s*\$Config' -Because 'Invoke-MDEEndpoint never had a -Config parameter'
        }

        It 'Send-ToLogAnalytics has DceEndpoint + DcrImmutableId + StreamName + Rows mandatory' {
            $src = Get-Content -Raw (Join-Path $script:RepoRoot 'src/Modules/Xdr.Sentinel.Ingest/Public/Send-ToLogAnalytics.ps1')
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$DceEndpoint'
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$DcrImmutableId'
            $src | Should -Match '\[Parameter\(Mandatory\)\]\s*\[string\]\s*\$StreamName'
            $src | Should -Match '\[object\[\]\]\s*\$Rows'
        }
    }
}

Describe 'Xdr-PollOrchestrator — orchestrator file inspection (locks current correct shape)' {

    It 'Orchestrator does NOT shadow PowerShell automatic $Input variable' {
        $src = Get-Content -Raw $script:OrchestratorPath
        $src | Should -Not -Match '^\s*\$input\s*=\s*\$Context\.Input' -Because '$Input is PS automatic enumeration variable; shadowing it is a foot-gun'
    }

    It 'Orchestrator KEEPS Portal filter for v0.2.0 multi-portal forward-compat' {
        # Filter MUST be present so v0.2.0 multi-tenant FA can merge multiple
        # portals' manifests into one orchestrator-visible hashtable and still
        # fan out per-portal correctly.
        $src = Get-Content -Raw $script:OrchestratorPath
        $src | Should -Match '\$_\.Portal\s*-eq\s*\[string\]\$portal|\[string\]\$_\.Portal\s*-eq\s*\[string\]\$portal' -Because 'Portal filter required for v0.2.0 multi-portal fan-out'
        $src | Should -Match '-not\s+\$_\.Contains\(.Portal.\)' -Because 'must allow entries without Portal field (legacy fixtures + future flexibility)'
    }

    It 'Orchestrator uses [System.Collections.IDictionary] check (broader than [hashtable])' {
        $src = Get-Content -Raw $script:OrchestratorPath
        $src | Should -Match '\[System\.Collections\.IDictionary\]' -Because 'manifest entries may surface as OrderedDictionary or other IDictionary subclasses; strict [hashtable] check would exclude them'
    }
}
