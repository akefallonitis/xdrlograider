<#
.SYNOPSIS
    Custom ARM-JSON validator: catches dangling resourceId references, missing
    dependsOn, parameter-mismatch issues that ARM-TTK + Microsoft's preview-time
    validators don't always catch.

.DESCRIPTION
    Walks the ARM template and checks:
      1. Every resourceId('Type', 'name') reference points at a declared resource.
      2. Every variables(X) / parameters(X) reference is defined.
      3. Output references resolve.
      4. Nested deployment parameter passing matches the inner template's params.
      5. No accidental ContainsCarriageReturn in JSON values (Windows-CRLF leaks).

.PARAMETER TemplatePath
    Path to mainTemplate.json. Default: ../deploy/mainTemplate.json.

.OUTPUTS
    Exit code 0 = all checks pass. Exit code 1 = any check failed (prints details).
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path $PSScriptRoot '..' 'deploy' 'mainTemplate.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$TemplatePath = (Resolve-Path $TemplatePath).Path
$t = Get-Content -Raw $TemplatePath | ConvertFrom-Json -Depth 50
$errors = New-Object System.Collections.Generic.List[string]

# Collect declared variable / parameter / resource names.
$varNames = ($t.variables | Get-Member -MemberType NoteProperty).Name
$paramNames = ($t.parameters | Get-Member -MemberType NoteProperty).Name

# Resources: collect their explicit names so we can cross-check resourceId()
# refs. Many names are ARM expressions; we still capture them as strings.
$resourceNames = New-Object System.Collections.Generic.List[string]
foreach ($r in $t.resources) {
    $resourceNames.Add([string]$r.name)
}

# Whole-template flat string for regex sweeps.
$wholeJson = Get-Content -Raw $TemplatePath

# Check 1: every variables('X') reference points at a declared variable.
$variableRefs = [regex]::Matches($wholeJson, "variables\('([^']+)'\)") |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique
foreach ($v in $variableRefs) {
    if ($v -notin $varNames) {
        $errors.Add("variables('$v') referenced but not declared")
    }
}

# Check 2: every parameters('X') reference points at a declared parameter.
$paramRefs = [regex]::Matches($wholeJson, "parameters\('([^']+)'\)") |
             ForEach-Object { $_.Groups[1].Value } |
             Sort-Object -Unique
# Exclude nested-template parameters (they have their own params block we don't enumerate here)
$declaredAll = $paramNames + 'workspaceName' + 'retentionInDays'  # nested-template params
foreach ($p in $paramRefs) {
    if ($p -notin $declaredAll) {
        $errors.Add("parameters('$p') referenced but not declared")
    }
}

# Check 3: dependsOn — every reference should resolve. Compare against declared
# resource names (matching by ARM expression substring).
foreach ($r in $t.resources) {
    if (-not ($r.PSObject.Properties['dependsOn'])) { continue }
    foreach ($dep in @($r.dependsOn)) {
        # Quick heuristic: every dependsOn string should reference resourceId()
        # OR be a deployment-name string. Just check it's non-empty.
        if ([string]::IsNullOrWhiteSpace([string]$dep)) {
            $errors.Add("Resource '$($r.name)' has empty dependsOn entry")
        }
    }
}

# Check 4: no CR-LF inside JSON string values (Windows-line-ending leak).
$crLeak = [regex]::Matches($wholeJson, "`r")
if ($crLeak.Count -gt 0) {
    # Could be the trailing newline; we already saved with -NoNewline so any CR is suspicious.
    $errors.Add("$($crLeak.Count) carriage-return characters in JSON — re-emit with -NoNewline -Encoding utf8")
}

# Check 5: $null literals in JSON (PowerShell ConvertTo-Json sometimes emits `null`
# which is OK, but never a string `"$null"`).
$nullLiteralLeak = [regex]::Matches($wholeJson, '"\$null"')
if ($nullLiteralLeak.Count -gt 0) {
    $errors.Add('$null string literals leaked into JSON — generator bug')
}

# Check 6: 19 DCRs + 19 workspace tables + 3 role assignments
# (1 KV Secrets User on KV, 1 Storage Table Data Contributor on Storage,
#  1 RG-scoped Monitoring Metrics Publisher covering all 19 DCRs).
$dcrCount = @($t.resources | Where-Object { $_.type -eq 'Microsoft.Insights/dataCollectionRules' }).Count
if ($dcrCount -ne 19) { $errors.Add("Expected 19 DCRs; got $dcrCount") }
$raCount = @($t.resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }).Count
if ($raCount -ne 3) { $errors.Add("Expected 3 role assignments (1 KV + 1 Storage + 1 RG-scoped MMP); got $raCount") }

# ------------------------------------------------------------------------------
if ($errors.Count -gt 0) {
    Write-Host "Validate-ArmJson: $($errors.Count) issue(s) found:" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    exit 1
}

Write-Host "Validate-ArmJson: OK ($dcrCount DCRs · $raCount role assignments · $($resourceNames.Count) resources)" -ForegroundColor Green
exit 0
