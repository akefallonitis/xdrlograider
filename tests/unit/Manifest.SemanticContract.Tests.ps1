#Requires -Modules Pester
<#
.SYNOPSIS
    Layer A regression-locker — manifest field-purpose semantic contract.

.DESCRIPTION
    Live forensic 2026-05-06 (commit 45fa16d): manifest Defaults set
    Portal='security.microsoft.com' (FQDN) but the orchestrator's filter
    compared $_.Portal -eq 'Defender' (logical name). matchedStreams=0 for
    every cadence-tier invocation; 116 fan-outs returned empty.

    Field-purpose contract:
      - Portal     = LOGICAL portal name (matches orchestrator filter target)
      - PortalHost = FQDN of the portal (used by L2 auth Session URL construction)

    These two distinct concerns must never be conflated again.

    Per Section R Layer A, plan file
    C:\Users\akefa\.claude\plans\immutable-splashing-waffle.md.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulesDir = Join-Path $script:RepoRoot 'src/Modules'
    $script:OriginalPSModulePath = $env:PSModulePath
    $env:PSModulePath = "$($script:ModulesDir)$([IO.Path]::PathSeparator)$($env:PSModulePath)"

    Import-Module (Join-Path $script:ModulesDir 'Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force
    Import-Module (Join-Path $script:ModulesDir 'Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force

    $script:KnownPortalLogicalNames = @('Defender','Entra','Purview','Intune')
}

AfterAll {
    Remove-Module Xdr.Common.Manifest -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
    if ($script:OriginalPSModulePath) { $env:PSModulePath = $script:OriginalPSModulePath }
}

Describe 'Manifest.SemanticContract — Portal (logical) vs PortalHost (FQDN) fields' {

    Context 'Defaults block separates the two concerns' {

        It 'Get-XdrManifestDefaults returns Portal=Defender (logical) AND PortalHost=security.microsoft.com (FQDN)' {
            InModuleScope Xdr.Common.Manifest {
                $defaults = Get-XdrManifestDefaults
                $defaults.ContainsKey('Portal')     | Should -BeTrue -Because 'logical-name field MUST exist'
                $defaults.ContainsKey('PortalHost') | Should -BeTrue -Because 'FQDN field MUST exist (separate concern)'
                $defaults.Portal                    | Should -Be 'Defender' -Because 'orchestrator filter expects logical name'
                $defaults.PortalHost                | Should -Be 'security.microsoft.com' -Because 'L2 auth Session.PortalHost requires FQDN'
                $defaults.Portal                    | Should -Not -Be $defaults.PortalHost -Because 'two fields, two concerns — never conflate'
            }
        }
    }

    Context 'Loaded manifest entries inherit both fields correctly' {

        It 'every entry has Portal in {Defender, Entra, Purview, Intune} (logical-name set)' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $offenders = @()
            foreach ($entry in $manifest.Values) {
                if (-not ($entry -is [System.Collections.IDictionary])) { continue }
                if (-not $entry.Contains('Portal')) {
                    $offenders += "$($entry.Stream): missing Portal field"
                    continue
                }
                if ($entry.Portal -notin $script:KnownPortalLogicalNames) {
                    $offenders += "$($entry.Stream): Portal='$($entry.Portal)' not in {$($script:KnownPortalLogicalNames -join ',')}"
                }
            }
            $offenders | Should -BeNullOrEmpty -Because "Portal field MUST be a logical name. FQDN values (e.g. 'security.microsoft.com') belong in PortalHost. Offenders:`n  $($offenders -join "`n  ")"
        }

        It 'every entry has PortalHost as a parseable FQDN (contains a dot, no scheme, no path)' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $offenders = @()
            foreach ($entry in $manifest.Values) {
                if (-not ($entry -is [System.Collections.IDictionary])) { continue }
                if (-not $entry.Contains('PortalHost')) {
                    $offenders += "$($entry.Stream): missing PortalHost field"
                    continue
                }
                $ph = [string]$entry.PortalHost
                if ($ph -notmatch '^[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}$') {
                    $offenders += "$($entry.Stream): PortalHost='$ph' is not a valid FQDN"
                }
            }
            $offenders | Should -BeNullOrEmpty -Because "PortalHost MUST be a hostname-only FQDN (no scheme, no path). Offenders:`n  $($offenders -join "`n  ")"
        }

        It 'orchestrator filter against Portal=Defender (logical) MUST match >0 streams' {
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $matched = @(
                $manifest.Values | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and
                    $_.Contains('Tier') -and ([string]$_.Tier -eq 'ActionCenter') -and
                    (-not $_.Contains('Portal') -or [string]$_.Portal -eq 'Defender')
                }
            )
            $matched.Count | Should -BeGreaterThan 0 -Because 'live regression: matchedStreams=0 because filter compared logical-name "Defender" against FQDN "security.microsoft.com"'
        }
    }
}
