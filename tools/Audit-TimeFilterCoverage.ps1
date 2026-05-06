<#
.SYNOPSIS
    Operator-side audit: every workspace-table query in sentinel/ yaml MUST be
    either time-bounded (`where TimeGenerated > ago(...)` or `between`) OR
    wrapped in an MDE_Drift_* parser invocation (which has internal bounds).

.DESCRIPTION
    Unbounded queries scan every row in the workspace table — expensive,
    slow, and can break Sentinel rule evaluation budgets. This script flags
    yaml files in sentinel/analytic-rules + sentinel/hunting-queries whose
    query: block references a workspace table without a nearby time bound.

    Returns 0 (clean) / non-zero (findings).
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$dirs = @('sentinel/hunting-queries', 'sentinel/analytic-rules')
$findings = @()
foreach ($d in $dirs) {
    $full = Join-Path $RepoRoot $d
    if (-not (Test-Path $full)) { continue }
    Get-ChildItem -Path $full -Filter '*.yaml' -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content -Raw $_.FullName
        if ($content -match '(?ms)^query:\s*\|?\s*\r?\n((?:^[ \t]+.+\r?\n?)+)') {
            $q = $matches[1]
            $tablePattern = '\b(Defender_\w+_CL|XdrConnectorHealth_CL|AppRequests|AppExceptions|AppEvents|AppDependencies|AppTraces|AppMetrics)\b(?!_)'
            $parserPattern = 'MDE_Drift_\w+\s*\('
            foreach ($m in [regex]::Matches($q, $tablePattern)) {
                $ctxStart = [Math]::Max(0, $m.Index - 80)
                $ctxLen = [Math]::Min($q.Length - $ctxStart, 280)
                $ctx = $q.Substring($ctxStart, $ctxLen)
                $hasTimeFilter = $ctx -match 'TimeGenerated\s*[<>]\s*ago|TimeGenerated\s+between'
                $hasParser = $ctx -match $parserPattern
                if (-not $hasTimeFilter -and -not $hasParser) {
                    $findings += [pscustomobject]@{
                        File    = $_.FullName.Substring($RepoRoot.Length + 1)
                        Table   = $m.Groups[1].Value
                        Context = ($ctx -replace '\s+', ' ').Trim()
                    }
                }
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host 'OK: every workspace-table query in sentinel/ yaml is time-bounded or parser-wrapped' -ForegroundColor Green
    exit 0
} else {
    Write-Host "FOUND $($findings.Count) UNBOUNDED REFERENCES:" -ForegroundColor Yellow
    $findings | ForEach-Object {
        Write-Host ""
        Write-Host ("  {0}: {1}" -f $_.File, $_.Table) -ForegroundColor Yellow
        Write-Host ("    {0}" -f $_.Context.Substring(0, [Math]::Min(160, $_.Context.Length)))
    }
    exit 1
}
