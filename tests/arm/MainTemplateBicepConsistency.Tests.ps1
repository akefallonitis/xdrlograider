#Requires -Modules Pester
<#
.SYNOPSIS
    Drift gate between deploy/main.bicep (operator-facing source-of-truth for
    parameter contract) and deploy/compiled/mainTemplate.json (the hand-authored
    ARM artefact actually shipped to Azure Marketplace + the Deploy to Azure
    button).

.DESCRIPTION
    The compiled mainTemplate.json is hand-authored — Bicep CLI is used as a
    syntax checker only (release.yml step "Compile Bicep -> ARM"). That means
    every time the Bicep parameter contract changes, an operator must hand-port
    the change into mainTemplate.json. This file is the lock that prevents drift:
    if a Bicep parameter exists with a given allowedValues / defaultValue, the
    compiled ARM must match.

    The drift surfaced in v0.1.0-beta first publish was three Bicep-only
    parameters (hostingPlan, restrictPublicNetwork, enableKeyVaultDiagnostics)
    that had no ARM counterpart, so the deploy validator reported
    "functionPlanSku 'consumption-y1' is not part of allowed value(s)". This
    test file is the structural fix.

    Gate categories:
      Bicep.ParametersExistInArm         - every param X in main.bicep has parameters.X in mainTemplate.json
      Bicep.AllowedValuesMatch           - @allowed([...]) -> allowedValues array equality (set, not order)
      Bicep.DefaultsMatch                - param X type = 'val' -> defaultValue: 'val' (where literal-comparable)
      Bicep.NoOrphanArmParameters        - every parameters.X in mainTemplate.json has a matching Bicep param

    Expected deltas (NOT failures):
      The Bicep parameter `servicePassword` / `totpSeed` / `passkeyJson` are
      @secure() in Bicep and `securestring` in ARM - the drift gate maps
      @secure -> securestring. They are NOT in the deltas list because the type
      mapping is canonical.
#>

BeforeAll {
    $script:RepoRoot         = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:BicepPath        = Join-Path $script:RepoRoot 'deploy' 'main.bicep'
    $script:ArmPath          = Join-Path $script:RepoRoot 'deploy' 'compiled' 'mainTemplate.json'

    $script:BicepText        = Get-Content -LiteralPath $script:BicepPath -Raw
    $script:ArmJson          = Get-Content -LiteralPath $script:ArmPath  -Raw | ConvertFrom-Json -Depth 50

    # Parse Bicep param declarations. Format the gate cares about:
    #   @description('...')
    #   @minLength(N)
    #   @maxLength(N)
    #   @allowed([ 'a', 'b', ... ])      // single-line OR multi-line
    #   @secure()
    #   param NAME TYPE = DEFAULT
    #   param NAME TYPE                   // no default (required)
    #
    # The matcher is anchored at `param NAME TYPE` and walks BACKWARDS through
    # the preceding decorator block to harvest @allowed + @secure metadata. This
    # keeps the parser robust against multi-line @allowed arrays.
    $script:BicepParams = @{}

    # Pass 1: locate every `param NAME TYPE [= DEFAULT]` line.
    $paramLineRegex = [regex] '(?m)^param\s+(?<name>\w+)\s+(?<type>\w+)(?:\s*=\s*(?<default>[^\r\n]+))?\s*$'
    $paramMatches = $paramLineRegex.Matches($script:BicepText)

    foreach ($m in $paramMatches) {
        $name = $m.Groups['name'].Value
        $type = $m.Groups['type'].Value
        $defaultExpr = if ($m.Groups['default'].Success) { $m.Groups['default'].Value.Trim() } else { $null }

        # Walk backwards from the param line to capture preceding decorators.
        $blockStart = $m.Index
        # Look at the ~600 chars before this param line for the decorator
        # block. Stop when we encounter a non-decorator/non-comment/non-blank
        # line (i.e., another param's last line).
        $sliceStart = [math]::Max(0, $blockStart - 800)
        $headerSlice = $script:BicepText.Substring($sliceStart, $blockStart - $sliceStart)
        $headerLines = $headerSlice -split "`r?`n"
        # Iterate from end (= just-before-param) backwards. Stop at the first
        # line that is neither blank, comment, nor decorator.
        $decoratorBlock = New-Object System.Collections.Generic.List[string]
        for ($i = $headerLines.Length - 1; $i -ge 0; $i--) {
            $line = $headerLines[$i].TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $trimmed = $line.TrimStart()
            if ($trimmed.StartsWith('//')) { continue }
            if ($trimmed.StartsWith('@') -or $trimmed.StartsWith(']') -or $trimmed.StartsWith("'") -or $trimmed.StartsWith(',')) {
                # Likely a decorator OR a continuation of @allowed([...])
                $decoratorBlock.Insert(0, $line)
                continue
            }
            break
        }
        $decoratorText = ($decoratorBlock -join "`n")

        # Extract @allowed([...]) — single-line OR multi-line. The values are
        # quoted with single-quotes per Bicep convention; unwrap them.
        $allowedValues = $null
        $allowedRegex = [regex] "(?s)@allowed\(\s*\[(?<items>.*?)\]\s*\)"
        $am = $allowedRegex.Match($decoratorText)
        if ($am.Success) {
            $items = $am.Groups['items'].Value
            $valueRegex = [regex] "'([^']+)'"
            $allowedValues = @($valueRegex.Matches($items) | ForEach-Object { $_.Groups[1].Value })
        }

        # Detect @secure()
        $isSecure = $decoratorText -match '@secure\(\s*\)'

        $script:BicepParams[$name] = [pscustomobject]@{
            Name          = $name
            Type          = $type
            DefaultExpr   = $defaultExpr
            AllowedValues = $allowedValues
            IsSecure      = $isSecure
        }
    }

    # Convert ARM parameters to a hashtable for symmetric lookup.
    $script:ArmParams = @{}
    foreach ($p in $script:ArmJson.parameters.PSObject.Properties) {
        $script:ArmParams[$p.Name] = $p.Value
    }

    # Bicep params that are not expected to map 1:1 to mainTemplate.json
    # parameters - reasons documented inline.
    #   workspaceLocation is NOT a delta (it IS in ARM with the same shape)
    #   None today. If a delta is genuinely required, list it here with a
    #   comment naming the architectural reason and update the test.
    $script:ExpectedDeltas = @()
}

Describe 'Bicep.ParametersExistInArm' {

    It 'every param declared in main.bicep has a matching parameters.X in mainTemplate.json' {
        $missing = @()
        foreach ($name in $script:BicepParams.Keys) {
            if ($name -in $script:ExpectedDeltas) { continue }
            if (-not $script:ArmParams.ContainsKey($name)) {
                $missing += $name
            }
        }
        $missing | Should -BeNullOrEmpty -Because "Bicep params with no ARM counterpart cause deploy-time validation failures (the operator-facing wizard emits the value but the ARM validator rejects it). Missing in mainTemplate.json: $($missing -join ', ')"
    }
}

Describe 'Bicep.AllowedValuesMatch' {

    It 'every Bicep @allowed([...]) matches the ARM allowedValues for the same parameter' {
        $mismatches = @()
        foreach ($name in $script:BicepParams.Keys) {
            if ($name -in $script:ExpectedDeltas) { continue }
            $bp = $script:BicepParams[$name]
            if (-not $bp.AllowedValues) { continue }   # no constraint in Bicep
            if (-not $script:ArmParams.ContainsKey($name)) { continue }  # already caught by ParametersExistInArm
            $ap = $script:ArmParams[$name]
            if (-not $ap.allowedValues) {
                $mismatches += "${name}: Bicep declares allowedValues=[$($bp.AllowedValues -join ', ')] but ARM has none"
                continue
            }
            $bicepSet = @($bp.AllowedValues) | Sort-Object
            $armSet   = @($ap.allowedValues) | Sort-Object
            $diff = Compare-Object -ReferenceObject $bicepSet -DifferenceObject $armSet
            if ($diff) {
                $mismatches += "${name}: Bicep [$($bicepSet -join ', ')] vs ARM [$($armSet -join ', ')]"
            }
        }
        $mismatches | Should -BeNullOrEmpty -Because "allowedValues drift between Bicep and ARM lets operators submit values from the wizard that the ARM validator then rejects. Mismatches:`n  $($mismatches -join "`n  ")"
    }
}

Describe 'Bicep.DefaultsMatch' {

    It 'every literal Bicep default value matches the ARM defaultValue for the same parameter' {
        $mismatches = @()
        foreach ($name in $script:BicepParams.Keys) {
            if ($name -in $script:ExpectedDeltas) { continue }
            $bp = $script:BicepParams[$name]
            if (-not $bp.DefaultExpr) { continue }   # required param with no default
            if (-not $script:ArmParams.ContainsKey($name)) { continue }
            $ap = $script:ArmParams[$name]

            # Only compare when the Bicep default is a string/bool literal.
            # Skip computed defaults (resourceGroup().location, expressions, etc.)
            $rawDefault = $bp.DefaultExpr.Trim()
            $literalString = $null
            $literalBool   = $null
            if ($rawDefault -match "^'(.*)'$") {
                $literalString = $Matches[1]
            }
            elseif ($rawDefault -in @('true', 'false')) {
                $literalBool = ($rawDefault -eq 'true')
            }
            else {
                # Computed expression - skip (e.g., resourceGroup().location).
                continue
            }

            $armDefault = $null
            if ($ap.PSObject.Properties['defaultValue']) {
                $armDefault = $ap.defaultValue
            }

            if ($null -ne $literalString) {
                if ($armDefault -ne $literalString) {
                    $mismatches += "${name}: Bicep default '$literalString' vs ARM default '$armDefault'"
                }
            }
            elseif ($null -ne $literalBool) {
                if ($armDefault -ne $literalBool) {
                    $mismatches += "${name}: Bicep default $literalBool vs ARM default $armDefault"
                }
            }
        }
        $mismatches | Should -BeNullOrEmpty -Because "default-value drift makes the wizard pre-populate one value while ARM falls back to another. Mismatches:`n  $($mismatches -join "`n  ")"
    }
}

Describe 'Bicep.NoOrphanArmParameters' {

    It 'every parameters.X in mainTemplate.json has a matching Bicep param' {
        # Catches the OPPOSITE drift direction: a param exists in ARM but not
        # in Bicep. Means an operator hand-edited mainTemplate.json without
        # back-porting to main.bicep -> next Bicep regen will obliterate it.
        $orphans = @()
        foreach ($name in $script:ArmParams.Keys) {
            if (-not $script:BicepParams.ContainsKey($name)) {
                $orphans += $name
            }
        }
        $orphans | Should -BeNullOrEmpty -Because "ARM parameters with no Bicep counterpart are orphaned: a Bicep regen would silently drop them. Add the Bicep param. Orphans: $($orphans -join ', ')"
    }
}

Describe 'Bicep.SecureTypeMappingCorrect' {

    It '@secure() Bicep params map to securestring in ARM (not plain string)' {
        $bad = @()
        foreach ($name in $script:BicepParams.Keys) {
            $bp = $script:BicepParams[$name]
            if (-not $bp.IsSecure) { continue }
            if (-not $script:ArmParams.ContainsKey($name)) { continue }
            $ap = $script:ArmParams[$name]
            if ($ap.type -ne 'securestring') {
                $bad += "${name}: Bicep @secure() but ARM type='$($ap.type)' (expected 'securestring')"
            }
        }
        $bad | Should -BeNullOrEmpty -Because "secret values must be securestring in ARM so they don't leak in deployment history. Mismatches:`n  $($bad -join "`n  ")"
    }
}
