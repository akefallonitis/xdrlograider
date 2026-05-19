#Requires -Module Pester
# Π11.4j · Manifest mtime cache in run.ps1 cycle-start.
# Skips ~50ms re-parse when manifest file hasn't changed across warm cycles.
# Re-deploy with new manifest hot-reloads on mtime change.
# This test exercises the cache logic via the same script-block evaluator pattern used in run.ps1.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # Inline replica of run.ps1's mtime-cache logic · single source of truth would require
    # extracting a helper from run.ps1 (which we avoid per D-2026-05-18c · NO new exports).
    function script:Load-ManifestWithMTimeCache {
        param([string]$Path)
        $mfMTime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        $cacheHit = $false
        if ((Get-Variable -Name 'TestManifest' -Scope Script -ErrorAction SilentlyContinue) -and (Get-Variable -Name 'TestManifestMTime' -Scope Script -ErrorAction SilentlyContinue)) {
            if ($script:TestManifestMTime -eq $mfMTime -and $script:TestManifest) {
                return [pscustomobject]@{ Manifest = $script:TestManifest; CacheHit = $true; MTime = $mfMTime }
            }
        }
        $m = & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $Path)))
        $script:TestManifest = $m
        $script:TestManifestMTime = $mfMTime
        return [pscustomobject]@{ Manifest = $m; CacheHit = $false; MTime = $mfMTime }
    }

    $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("xdrlr-mtime-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    $script:TmpManifest = Join-Path $script:TmpDir 'fake-manifest.psd1'
}

AfterAll {
    if (Test-Path $script:TmpDir) { Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Π11.4j · Manifest mtime cache' -Tag 'tier1','unit' {

    BeforeEach {
        Remove-Variable -Scope Script -Name TestManifest -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name TestManifestMTime -ErrorAction SilentlyContinue
        @'
@{
    Portal = 'Defender'
    Entries = @(
        @{ EntryKey = 'A::a'; SubArea = 'A'; Slug = 'a'; Path = '/x' }
        @{ EntryKey = 'B::b'; SubArea = 'B'; Slug = 'b'; Path = '/y' }
    )
}
'@ | Set-Content -LiteralPath $script:TmpManifest -Encoding UTF8
    }

    It 'first call is a cache miss (CacheHit=$false · parsed fresh)' {
        $r = Load-ManifestWithMTimeCache -Path $script:TmpManifest
        $r.CacheHit | Should -BeFalse
        $r.Manifest.Entries.Count | Should -Be 2
    }

    It 'second call within same mtime is a cache hit (CacheHit=$true)' {
        Load-ManifestWithMTimeCache -Path $script:TmpManifest | Out-Null
        $r = Load-ManifestWithMTimeCache -Path $script:TmpManifest
        $r.CacheHit | Should -BeTrue
        $r.Manifest.Entries.Count | Should -Be 2
    }

    It 'mtime change (file modified) invalidates cache · re-parse · new entries visible' {
        Load-ManifestWithMTimeCache -Path $script:TmpManifest | Out-Null
        # Wait at least 100ms to guarantee mtime distinct on filesystems with limited resolution
        Start-Sleep -Milliseconds 200
        @'
@{
    Portal = 'Defender'
    Entries = @(
        @{ EntryKey = 'A::a'; SubArea = 'A'; Slug = 'a'; Path = '/x' }
        @{ EntryKey = 'B::b'; SubArea = 'B'; Slug = 'b'; Path = '/y' }
        @{ EntryKey = 'C::c'; SubArea = 'C'; Slug = 'c'; Path = '/z' }
    )
}
'@ | Set-Content -LiteralPath $script:TmpManifest -Encoding UTF8
        $r = Load-ManifestWithMTimeCache -Path $script:TmpManifest
        $r.CacheHit | Should -BeFalse
        $r.Manifest.Entries.Count | Should -Be 3
        $r.Manifest.Entries[2].EntryKey | Should -Be 'C::c'
    }

    It 'cache survives across multiple cycles when file unchanged (100 hits)' {
        Load-ManifestWithMTimeCache -Path $script:TmpManifest | Out-Null
        $hits = 0
        for ($i = 0; $i -lt 100; $i++) {
            $r = Load-ManifestWithMTimeCache -Path $script:TmpManifest
            if ($r.CacheHit) { $hits++ }
        }
        $hits | Should -Be 100
    }
}
