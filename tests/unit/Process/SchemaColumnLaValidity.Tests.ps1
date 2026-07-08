#Requires -Version 7.4
# LA column-name validity gate (2026-06-24 · Portal Services defect class). Every column name in every committed
# per-category-schema (the table schema AND the DCR streamDeclarations) MUST be LA-deploy-valid:
#   - match ^[A-Za-z][A-Za-z0-9_]{0,44}$  (LA rejects invalid chars / non-letter lead — e.g. '@odata.context')
#   - NOT be an LA-reserved column name   (LA rejects 'date', 'Type', 'TenantId', ...)
# else the LIVE table-create 400s ("Columns ... are invalid or reserved") AFTER a green gauntlet+CI — the exact
# gap the Portal Services onboard hit ('@odata.context' invalid chars + 'date' reserved reached the ARM deploy).
# Get-XdrSafeColumnName is THE rewrite that must guarantee this; this gate validates its OUTPUT across ALL
# committed schemas so the class is caught OFFLINE, pre-deploy, forever.

$script:repoRoot   = (Resolve-Path "$PSScriptRoot\..\..\..").Path
Import-Module (Join-Path $script:repoRoot 'src\Modules\Xdr.Common.Parser\Xdr.Common.Parser.psd1') -Force -DisableNameChecking
$script:laReserved = @(& (Get-Module Xdr.Common.Parser) { $script:XdrLaReservedColumns })

function Get-XdrSchemaColumnNames {
    param($Root)
    $acc   = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        if ($null -eq $n -or $n -is [string] -or $n -is [ValueType]) { continue }
        if ($n -is [System.Collections.IEnumerable]) { foreach ($e in $n) { $stack.Push($e) }; continue }
        if ($n.PSObject) {
            foreach ($p in $n.PSObject.Properties) {
                if ($p.Name -eq 'columns' -and $p.Value) {
                    foreach ($c in @($p.Value)) { if ($c.PSObject -and $c.PSObject.Properties['name']) { $acc.Add([string]$c.name) } }
                }
                $stack.Push($p.Value)
            }
        }
    }
    return $acc
}

$script:schemaCases = @(
    foreach ($f in (Get-ChildItem (Join-Path $script:repoRoot 'deploy\per-category-schemas') -Filter 'Defender-*.json' |
                     Where-Object { $_.Name -notlike '*-nested-deployment.json' })) {
        $obj = Get-Content $f.FullName -Raw | ConvertFrom-Json -Depth 60
        @{ File = $f.Name; Columns = @(Get-XdrSchemaColumnNames $obj | Sort-Object -Unique) }
    }
)

Describe 'LA column-name validity · every per-category-schema column is deploy-valid' {
    It 'found at least one committed per-category-schema to validate' {
        @($script:schemaCases).Count | Should -BeGreaterThan 0
    }

    It '<File> · table+stream columns match ^[A-Za-z][A-Za-z0-9_]{0,44}$ and are not LA-reserved' -ForEach $script:schemaCases {
        $reserved = $script:laReserved
        $bad = foreach ($c in $Columns) {
            if ($c -notmatch '^[A-Za-z][A-Za-z0-9_]{0,44}$') { "'$c' (invalid chars or non-letter lead)" }
            elseif ($reserved -contains $c) { "'$c' (LA-reserved word)" }
        }
        (@($bad) -join ' | ') | Should -BeNullOrEmpty -Because "Get-XdrSafeColumnName must rewrite every invalid/reserved column name before the live table-create (which 400s otherwise)"
    }
}
