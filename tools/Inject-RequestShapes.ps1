#requires -Version 7.0
<#
.SYNOPSIS
  Inject Query + Headers + (new) ProbeMode reclassifications into manifest entries
  from Postman fallback artefacts.

.DESCRIPTION
  v0.1.0 ITER5 · operator-explicit: "we need to reprobe fixed all endpoint and ensure
  mapping schemas requests catalogue · full coverage". The previous probe showed:
  - 68 error-400 (mostly GET without required Postman query params)
  - 36 html-terminal (auth chain dropped on different sub-portal paths)
  - 4 error-405 (wrong method · need query params per Postman)
  - 63 skipped-pathparams ({xxx} placeholders we don't substitute)

  This tool:
  1. Reads references/Defender/<sub>/<slug>/postman-request.json per entry
  2. Injects Query (hashtable) + Headers (hashtable) into manifest entries
  3. Reclassifies endpoints with `{xxx}` path placeholders → ProbeMode='PathParamGated'
  4. Reclassifies entity-pivot endpoints (mtp/cloudPivot/*) → ProbeMode='RequiresEntity'
  5. Reclassifies cross-sub-portal endpoints (m365appprotection/* · mdi/* · radius/*) → ProbeMode='SubPortalAuth'

  Idempotent · skips entries already injected.

.NOTES
  Author: Alex Kefallonitis <al.kefallonitis@gmail.com>
  Per D-2026-05-18c (NO new modules · in-place tool).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManifestPath  = 'C:\Users\alkef\Desktop\Repos\xdrlograider-mvp\manifests\defender.psd1',
    [string]$ReferencesDir = 'C:\Users\alkef\Desktop\Repos\xdrlograider-mvp\references\Defender'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ManifestPath))  { throw "Manifest not found: $ManifestPath" }
if (-not (Test-Path $ReferencesDir)) { throw "References dir not found: $ReferencesDir" }

# Sub-portal path-prefix classifications (cross-portal auth chains that v0.1.0 Defender-only
# session doesn't cover · v0.2.0 will add Connect-*Portal per sub-portal with proper cookie domain).
$SubPortalAuthPrefixes = @(
    'm365appprotection/',   # AppGovernance · separate Defender for Cloud Apps portal
    'mdi/',                 # MDI sub-portal · separate cookie scope
    'radius/',              # RADIUS sub-portal
    'medeina/',             # Security Copilot sub-portal
    'mdc/'                  # Defender for Cloud sub-portal
)

# Entity-pivot endpoints (need entity input · cannot active-poll without crawling alerts/incidents
# which Memory Rule 2 drops · these are v0.3.0 cross-entity enrichment scope)
$EntityPivotPrefixes = @(
    'mtp/cloudPivot/',      # Domain/URL/IP/File/User prevalence + trend pivots
    'mtp/getMachine/',
    'mtp/getLatestMachineIpsByIds/',
    'mtp/getTopUsersByIds/',
    'mtp/mdeDeepAnalysis/'
)

function Test-PathHasPlaceholder { param([string]$Path) return ($Path -match '\{[^}]+\}') }

function Get-PathPrefixMatch {
    param([string]$Path, [string[]]$Prefixes)
    # Path looks like /apiproxy/<svc>/<rest> · strip /apiproxy/ then test
    $clean = $Path -replace '^/apiproxy/', ''
    foreach ($p in $Prefixes) {
        if ($clean.StartsWith($p)) { return $true }
    }
    return $false
}

$lines = [System.Collections.Generic.List[string]]::new()
Get-Content $ManifestPath | ForEach-Object { [void]$lines.Add($_) }

# Pass 1: locate entry blocks · capture EntryKey + Path + current ProbeMode + Query/Headers presence
$blocks = [System.Collections.Generic.List[hashtable]]::new()
$current = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if (-not $current -and $ln -match '^        @\{\s*$') {
        $current = @{ Start=$i; EntryKey=$null; Path=$null; ProbeMode=$null; Method=$null;
                      HasQuery=$false; HasHeaders=$false; End=$null; SubArea=$null; Slug=$null }
        continue
    }
    if ($current) {
        if ($ln -match "^\s+EntryKey\s+=\s+'([^']+)'")      { $current.EntryKey = $Matches[1] }
        elseif ($ln -match "^\s+Path\s+=\s+'([^']+)'")      { $current.Path     = $Matches[1] }
        elseif ($ln -match "^\s+ProbeMode\s+=\s+'([^']+)'") { $current.ProbeMode = $Matches[1] }
        elseif ($ln -match "^\s+Method\s+=\s+'([^']+)'")    { $current.Method   = $Matches[1] }
        elseif ($ln -match "^\s+SubArea\s+=\s+'([^']+)'")   { $current.SubArea  = $Matches[1] }
        elseif ($ln -match "^\s+Slug\s+=\s+'([^']+)'")      { $current.Slug     = $Matches[1] }
        elseif ($ln -match '^\s+Query\s+=')                 { $current.HasQuery = $true }
        elseif ($ln -match '^\s+Headers\s+=')               { $current.HasHeaders = $true }
        elseif ($ln -match '^        \},?\s*$') {
            $current.End = $i
            [void]$blocks.Add($current); $current = $null
        }
    }
}
Write-Host "Located $($blocks.Count) entry blocks · scanning for request-shape injections..." -ForegroundColor Cyan

# Pass 2: build injection plan
$plan = @{
    QueryHeaderInjects = [System.Collections.Generic.List[hashtable]]::new()
    ProbeModeChanges   = [System.Collections.Generic.List[hashtable]]::new()
}

foreach ($b in $blocks) {
    if (-not $b.Path) { continue }

    # Reclassification (only if current ProbeMode=Probe · don't override Excluded/ReadOnlyPost)
    if ($b.ProbeMode -eq 'Probe') {
        # PathParam-gated → cannot fill {xxx} at v0.1.0 active poll
        if (Test-PathHasPlaceholder -Path $b.Path) {
            [void]$plan.ProbeModeChanges.Add(@{ Block=$b; New='PathParamGated'; Reason="Path has unsubstituted {placeholders}" })
            continue
        }
        # Sub-portal auth (m365appprotection · mdi · radius · medeina · mdc)
        if (Get-PathPrefixMatch -Path $b.Path -Prefixes $SubPortalAuthPrefixes) {
            [void]$plan.ProbeModeChanges.Add(@{ Block=$b; New='SubPortalAuth'; Reason="Sub-portal auth not in v0.1.0 Defender session" })
            continue
        }
        # Entity-pivot → needs entity input
        if (Get-PathPrefixMatch -Path $b.Path -Prefixes $EntityPivotPrefixes) {
            [void]$plan.ProbeModeChanges.Add(@{ Block=$b; New='RequiresEntity'; Reason="Entity-pivot · needs entity input · v0.3.0" })
            continue
        }
    }

    # Query+Headers injection · if Postman fallback exists and current entry lacks them
    if (-not $b.HasQuery -and -not $b.HasHeaders -and $b.SubArea -and $b.Slug) {
        $postmanPath = Join-Path $ReferencesDir "$($b.SubArea)/$($b.Slug)/postman-request.json"
        if (Test-Path $postmanPath) {
            try {
                $pm = Get-Content -Raw $postmanPath | ConvertFrom-Json
                $hasQ = $pm.PSObject.Properties['Query'] -and @($pm.Query).Count -gt 0
                $hasH = $pm.PSObject.Properties['Headers'] -and ($pm.Headers.PSObject.Properties | Measure-Object).Count -gt 1   # >1 because 'Accept' is always default; we want extras
                if ($hasQ -or $hasH) {
                    [void]$plan.QueryHeaderInjects.Add(@{ Block=$b; Postman=$pm })
                }
            } catch { }
        }
    }
}
Write-Host "Plan · ProbeMode reclassifications: $($plan.ProbeModeChanges.Count) · Query/Headers injections: $($plan.QueryHeaderInjects.Count)" -ForegroundColor Yellow

if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Apply $($plan.ProbeModeChanges.Count + $plan.QueryHeaderInjects.Count) injections")) {
    Write-Host "WhatIf · summary:" -ForegroundColor Cyan
    $plan.ProbeModeChanges | Group-Object { $_.New } | Format-Table Count, Name -AutoSize
    return
}

# Pass 3: apply ProbeMode reclassifications (in-place line edit)
$probeMode2Sum = 0
foreach ($change in $plan.ProbeModeChanges) {
    for ($i = $change.Block.Start; $i -le $change.Block.End; $i++) {
        if ($lines[$i] -match "^(\s+ProbeMode\s+=\s+)'([^']+)'(.*)$") {
            $lines[$i] = $Matches[1] + "'$($change.New)'" + $Matches[3]
            $probeMode2Sum++
            break
        }
    }
}

# Pass 4: apply Query/Headers injections (insert lines before block close)
# Sort by End DESCENDING so earlier indices stay valid
$queryHeaderInjects = $plan.QueryHeaderInjects | Sort-Object -Property { $_.Block.End } -Descending
$injectCount = 0
foreach ($inj in $queryHeaderInjects) {
    $b  = $inj.Block
    $pm = $inj.Postman
    $injLines = @()

    # Build Query as @{ ... } · DEDUP by Key (Postman often has array-style repeats like
    # `tenantIds[]` listed N times with the same UUID · first occurrence wins · ARM hashtable
    # literal doesn't allow duplicate keys). Skip empty/null values · operator must pick valid.
    # ITER6 R3 · Filter out Postman SAMPLE values that cause real-request 400s:
    #   - GUIDs (specifically the fake ones like 82f86578-d5e5-cbef-... that Postman uses as examples)
    #   - Sample dates from the 1980s/1990s/early-2000s (clearly not real production timestamps)
    #   - Any value matching {placeholder} pattern (unresolved Postman variable)
    # Drop only the value · KEEP the key (operator can populate at deploy time OR runtime overrides).
    function _IsSamplePostmanValue { param([string]$v)
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        if ($v -match '^\{[^}]+\}$') { return $true }                                      # {placeholder}
        if ($v -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $true }  # bare GUID · likely sample
        if ($v -match '^(0?[1-9]|1[0-2])/\d{1,2}/(19[0-9][0-9]|20[01][0-9])\b') { return $true }  # m/d/YYYY pre-2020 sample date
        return $false
    }
    if ($pm.PSObject.Properties['Query'] -and @($pm.Query).Count -gt 0) {
        $seen = @{}
        $kvs = foreach ($q in @($pm.Query)) {
            if ($null -eq $q -or -not $q.PSObject.Properties['Key'] -or -not $q.Key) { continue }
            if ($seen.ContainsKey($q.Key)) { continue }   # dedup
            $seen[$q.Key] = $true
            $rawVal = if ($q.PSObject.Properties['Value'] -and $null -ne $q.Value) { [string]$q.Value } else { '' }
            # ITER6 R3 · drop sample values · keep key with empty value (manifest signals "this query exists · operator/runtime to populate")
            if (_IsSamplePostmanValue $rawVal) { $rawVal = '' }
            $k = ($q.Key   -replace "'", "''")
            $v = ($rawVal  -replace "'", "''")
            "'$k' = '$v'"
        }
        if (@($kvs).Count -gt 0) {
            $injLines += "            Query                = @{ $($kvs -join '; ') }"
        }
    }

    # Build Headers as @{ ... } · skip default Accept ONLY when value is 'application/json'
    # (Invoke-DefenderApiproxy defaults to JSON · we only carry Accept when Postman canonical differs · text/csv etc)
    # · also dedup by header name (case-insensitive)
    if ($pm.PSObject.Properties['Headers']) {
        $extraProps = @($pm.Headers.PSObject.Properties | Where-Object {
            ($_.Name -ne 'Accept') -or ($_.Value -and [string]$_.Value -ne 'application/json')
        })
        if ($extraProps.Count -gt 0) {
            $seen = @{}
            $kvs = foreach ($h in $extraProps) {
                $hkLower = $h.Name.ToLowerInvariant()
                if ($seen.ContainsKey($hkLower)) { continue }
                $seen[$hkLower] = $true
                $k = ($h.Name  -replace "'", "''")
                $v = if ($null -ne $h.Value) { ([string]$h.Value -replace "'", "''") } else { '' }
                "'$k' = '$v'"
            }
            if (@($kvs).Count -gt 0) {
                $injLines += "            Headers              = @{ $($kvs -join '; ') }"
            }
        }
    }

    if ($injLines.Count -gt 0) {
        for ($k = $injLines.Count - 1; $k -ge 0; $k--) {
            $lines.Insert($b.End, $injLines[$k])
        }
        $injectCount++
    }
}

[System.IO.File]::WriteAllLines($ManifestPath, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
Write-Host ""
Write-Host "DONE · wrote $($lines.Count) lines" -ForegroundColor Green
Write-Host "  ProbeMode reclassifications applied: $probeMode2Sum" -ForegroundColor Green
Write-Host "  Query/Headers injections applied:    $injectCount" -ForegroundColor Green
Write-Host ""
Write-Host "Re-verify: pwsh -c '`$m = & ([scriptblock]::Create((Get-Content -Raw $ManifestPath))); `$m.Entries.Count'" -ForegroundColor Cyan
