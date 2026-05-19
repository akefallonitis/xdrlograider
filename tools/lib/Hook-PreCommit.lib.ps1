#Requires -Version 7.4
<#
.SYNOPSIS
    Pure-functional helpers for tools/Hook-PreCommit.ps1.

.DESCRIPTION
    Extracted to lib for Pester unit testability. Hook-PreCommit.ps1 dot-sources
    this module and orchestrates the gate sequence. Tests dot-source the lib
    directly and exercise the helpers with deterministic input fixtures.

    Helpers:
      Test-CommitMessageHasRequiredSections — verify AXIS / PRIOR GATES / VERIFY / LOCK sections
      Test-StagedFilesNeedT3 — detect auth/portal/manifest/Connect-* staged paths
      Test-StagedFilesNeedArmTtk — detect deploy/arm or deploy/sentinel staged paths
      Test-T3Freshness — verify latest tests/results/iter-*/probe-auth-*.json < N hours old
#>

function Test-CommitMessageHasRequiredSections {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    # Use a strongly-typed List<string> so the return is unambiguously [string[]]
    # (avoids PowerShell's array-unwrapping foot-guns with `,$arr` and `+=`)
    $issues = [System.Collections.Generic.List[string]]::new()

    # AXIS: exactly 1 occurrence
    if ($Message -notmatch '(?m)^AXIS:') {
        [void]$issues.Add('Missing AXIS: section (one-axis-per-commit rule)')
    } else {
        $axisCount = ([regex]::Matches($Message, '(?m)^AXIS:')).Count
        if ($axisCount -gt 1) {
            [void]$issues.Add("Multiple AXIS: sections found ($axisCount) — exactly one axis per commit")
        }
    }

    # PRIOR GATES: matches PRIOR GATES / PRIOR GATES RE-AUDIT / etc.
    if ($Message -notmatch '(?m)^PRIOR GATES') {
        [void]$issues.Add('Missing PRIOR GATES section (Step 1.b re-audit required)')
    }

    # VERIFY / VERIFICATION
    if ($Message -notmatch '(?m)^VERIF') {
        [void]$issues.Add('Missing VERIFY / VERIFICATION section (per-tier matrix evidence required)')
    }

    # LOCK
    if ($Message -notmatch '(?m)^LOCK') {
        [void]$issues.Add('Missing LOCK section (one-axis confirmation required)'  )
    }

    # Pipeline-enumerate convention: callers wrap with @(...) — see tests
    # Unary-comma + .ToArray() wraps in 1-element outer array · don't use it
    return $issues.ToArray()
}

function Test-StagedFilesNeedT3 {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StagedFiles
    )

    return @($StagedFiles | Where-Object {
        $_ -match 'src/Modules/Xdr\.(Auth|Poll)' -or
        $_ -match 'manifests/.*\.psd1$' -or
        $_ -match 'Connect-.*\.ps1?$' -or
        $_ -match 'functionapp/Xdr-Poll'
    }).Count -gt 0
}

function Test-StagedFilesNeedArmTtk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StagedFiles
    )

    return @($StagedFiles | Where-Object {
        $_ -match '^deploy/(arm|sentinel)/' -or
        $_ -match '^deploy/arm/' -or
        $_ -match '^deploy/sentinel/'
    }).Count -gt 0
}

function Test-T3Freshness {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IterRoot,
        [int]$MaxAgeHours = 24
    )

    if (-not (Test-Path $IterRoot)) {
        return @{
            Fresh  = $false
            Reason = "Iter root not found at '$IterRoot'"
            Path   = $null
        }
    }

    $latest = Get-ChildItem -Path $IterRoot -Recurse -Filter 'probe-auth*.json' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if (-not $latest) {
        return @{
            Fresh  = $false
            Reason = "No probe-auth*.json under '$IterRoot' — run pwsh tools/Probe-Auth-Local.ps1 -Portal All first"
            Path   = $null
        }
    }

    $hoursOld = ((Get-Date) - $latest.LastWriteTime).TotalHours
    if ($hoursOld -gt $MaxAgeHours) {
        return @{
            Fresh    = $false
            Reason   = "Latest probe-auth is $([int]$hoursOld)h old (>$MaxAgeHours h) at '$($latest.FullName)'"
            Path     = $latest.FullName
            HoursOld = $hoursOld
        }
    }

    return @{
        Fresh    = $true
        Path     = $latest.FullName
        HoursOld = [math]::Round($hoursOld, 1)
    }
}

function Test-T3ProbeSuccess {
    <#
    .SYNOPSIS
        Reads the most recent probe-auth-multi.json and reports per-portal ChainSuccess.

    .DESCRIPTION
        Semantic gate that complements Test-T3Freshness. Where freshness checks
        the file's LastWriteTime, this reads the JSON content and reports actual
        per-portal ChainSuccess. Operator probes are not budget-constrained
        (TOTP is dynamic per autonomous-loop methodology · D-33) so callers can
        require ChainSuccess=true for the portals touched by a commit / phase.

    .OUTPUTS
        @{
          Found       = $true|$false             (probe-auth-multi.json located)
          Path        = <full path or $null>
          HoursOld    = <float>
          ProbeCount  = <int · total Probes[] in file>
          AllSuccess  = $true|$false             (every probe ChainSuccess=true)
          SuccessByPortal = @{ Defender=$true; ... }
          FailuresByPortal = @( @{Portal=...; SubPortal=...; Error=...}; ... )
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IterRoot
    )

    if (-not (Test-Path $IterRoot)) {
        return @{ Found = $false; Path = $null; Reason = "Iter root not found at '$IterRoot'" }
    }

    $latest = Get-ChildItem -Path $IterRoot -Recurse -Filter 'probe-auth*.json' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if (-not $latest) {
        return @{ Found = $false; Path = $null; Reason = "No probe-auth*.json under '$IterRoot'" }
    }

    try {
        $payload = Get-Content -Raw $latest.FullName | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @{
            Found  = $true
            Path   = $latest.FullName
            Reason = "Could not parse probe JSON: $($_.Exception.Message)"
        }
    }

    $probes = @()
    if ($payload.PSObject.Properties['Probes']) {
        $probes = @($payload.Probes)
    } elseif ($payload.PSObject.Properties['Portal']) {
        # Single-portal probe schema · wrap as 1-element array
        $probes = @($payload)
    }

    $successByPortal = [ordered]@{}
    $failures = @()
    foreach ($p in $probes) {
        $portalKey = if ($p.PSObject.Properties['SubPortal'] -and $p.SubPortal) {
            "$($p.Portal)::$($p.SubPortal)"
        } else {
            "$($p.Portal)"
        }
        $ok = [bool]($p.PSObject.Properties['ChainSuccess'] -and $p.ChainSuccess)
        $successByPortal[$portalKey] = $ok
        if (-not $ok) {
            $failures += @{
                Portal    = $p.Portal
                SubPortal = if ($p.PSObject.Properties['SubPortal']) { [string]$p.SubPortal } else { '' }
                Error     = if ($p.PSObject.Properties['Error']) { [string]$p.Error } else { '<no Error field>' }
            }
        }
    }

    return @{
        Found            = $true
        Path             = $latest.FullName
        HoursOld         = [math]::Round(((Get-Date) - $latest.LastWriteTime).TotalHours, 1)
        ProbeCount       = $probes.Count
        AllSuccess       = ($probes.Count -gt 0 -and $failures.Count -eq 0)
        SuccessByPortal  = $successByPortal
        FailuresByPortal = $failures
    }
}

# Dot-source friendly: no Export-ModuleMember (lib is .ps1 · loaded via `. path/Hook-PreCommit.lib.ps1`)
# Hook-PreCommit.ps1 main script + Pester tests both dot-source this file.
