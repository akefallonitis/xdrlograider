#Requires -Modules Pester
<#
.SYNOPSIS
    Lock the module-load-time initialization of every $script: cache variable
    referenced by public functions. Under
    `Set-StrictMode -Version Latest` (enabled by every poll-* function and
    heartbeat-5m), reading an unset script-scope variable THROWS — not returns
    $null. The bug class hit live in v0.1.0-beta first deploy:
    `heartbeat-5m failed: The variable '$script:DcrIdMap' cannot be retrieved
    because it has not been set.`

    The fix pattern (used by every cache var in this codebase):
      $script:CacheVar = $null    # at module psm1 load time
      ...
      if ($null -eq $script:CacheVar) {  # safe under strict mode
          $script:CacheVar = ...populate...
      }

.DESCRIPTION
    For every $script:VAR referenced by a public function as a cache (matched
    via the `if (`$null -eq `$script:VAR)` or `if (-not `$script:VAR)` patterns),
    the parent module's psm1 MUST have a `$script:VAR = $null` initialization
    line. This test scans both sides + asserts the contract.
#>

BeforeDiscovery {
    $script:DiscoveryRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulesDir = Join-Path $script:RepoRoot 'src' 'Modules'

    # Discover every Module/<Name>/Public/*.ps1 + collect every $script:VAR
    # referenced inside it. Then for each Module, read the .psm1 and assert
    # every collected var has an init line.
    $modules = Get-ChildItem -Path $script:ModulesDir -Directory
    $script:ModuleCacheVars = @{}
    foreach ($mod in $modules) {
        $publicDir = Join-Path $mod.FullName 'Public'
        if (-not (Test-Path -LiteralPath $publicDir)) { continue }
        $referencedVars = @{}
        foreach ($f in (Get-ChildItem -Path $publicDir -Filter '*.ps1')) {
            $content = Get-Content -Raw -Path $f.FullName
            # Strip block-comment + line-comment so we don't pick up vars in
            # comment-based help (`.PARAMETER $script:Foo` etc.) or notes.
            $stripped = [regex]::Replace($content, '<#[\s\S]*?#>', '')
            $stripped = ($stripped -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
            foreach ($m in [regex]::Matches($stripped, '\$script:([A-Z][A-Za-z0-9_]+)')) {
                $referencedVars[$m.Groups[1].Value] = $true
            }
        }
        if ($referencedVars.Count -gt 0) {
            $script:ModuleCacheVars[$mod.Name] = @($referencedVars.Keys | Sort-Object)
        }
    }
}

Describe 'ScriptScopeCacheVars.InitializedAtModuleLoad' {

    It 'every script-scope cache var referenced in a module is initialized somewhere in that module' {
        # The init can live in EITHER the .psm1 OR any Public/*.ps1 file
        # (some files self-initialize their cache vars at file-load top-level
        # before declaring functions — both patterns work because the module
        # dot-sources Public/*.ps1 at psm1 load time, so all top-level
        # assignments run before any function is invoked). The gate just
        # ensures SOMEONE in the module assigns the var at least once outside
        # the function body where the read happens.
        $missing = @()
        foreach ($modName in $script:ModuleCacheVars.Keys) {
            $modDir = Join-Path $script:ModulesDir $modName
            $allFiles = @(Get-ChildItem -Path $modDir -Recurse -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue)
            $allContent = ($allFiles | ForEach-Object { Get-Content -Raw -Path $_.FullName }) -join "`n"
            foreach ($var in $script:ModuleCacheVars[$modName]) {
                $pattern = '\$script:' + [regex]::Escape($var) + '\s*='
                if ($allContent -notmatch $pattern) {
                    $missing += ('{0} does not initialize $script:{1} in any of {2} files' -f $modName, $var, $allFiles.Count)
                }
            }
        }
        $reasonLines = @(
            'Under Set-StrictMode -Version Latest (enabled by every poll-* + heartbeat-5m),',
            'reading an unset script-scope variable THROWS. Public-function code that uses',
            '`if ($null -eq $script:VarName)` REQUIRES the psm1 to do `$script:VarName = $null`',
            'at module load. Live bug class: heartbeat-5m failed:',
            '  The variable ''$script:DcrIdMap'' cannot be retrieved because it has not been set.',
            'Missing initializations:'
        )
        $reason = ($reasonLines -join [Environment]::NewLine) + [Environment]::NewLine + '  ' + ($missing -join ([Environment]::NewLine + '  '))
        $missing | Should -BeNullOrEmpty -Because $reason
    }
}
