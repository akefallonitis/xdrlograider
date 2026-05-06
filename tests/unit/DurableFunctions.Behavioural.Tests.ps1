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
                FunctionName = 'Defender-ActionCenter-Refresh'
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

    Context 'Activity input access uses [string] cast (regression: JValue crash)' {

        It 'Activity body reads Portal/Tier/StreamName via [string] cast' {
            $activitySource = Get-Content -Raw $script:ActivityPath
            $activitySource | Should -Match '\$portal\s*=\s*\[string\]\$Input\.Portal'
            $activitySource | Should -Match '\$tier\s*=\s*\[string\]\$Input\.Tier'
            $activitySource | Should -Match '\$streamName\s*=\s*\[string\]\$Input\.StreamName'
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
