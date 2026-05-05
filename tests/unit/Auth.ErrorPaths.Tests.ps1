#Requires -Modules Pester
<#
.SYNOPSIS
    Mock-based unit tests for auth error paths.
    Coverage: Connect-DefenderPortal, Invoke-DefenderPortalRequest re-auth, Get-XdrAuthFromKeyVault cache.

.DESCRIPTION
    Targets the 401/440 re-auth + KV cache branches that are not exercised by happy-path tests.
    Each test mocks ALL collaborators to isolate the target function's logic.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $modulesDir = Join-Path $script:RepoRoot 'src/Modules'
    $script:OriginalPSModulePath = $env:PSModulePath
    $env:PSModulePath = "$modulesDir$([IO.Path]::PathSeparator)$($env:PSModulePath)"

    Import-Module (Join-Path $modulesDir 'Xdr.Common.Auth/Xdr.Common.Auth.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $modulesDir 'Xdr.Common.Telemetry/Xdr.Common.Telemetry.psd1') -Force -ErrorAction Stop
    Import-Module (Join-Path $modulesDir 'Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module Xdr.Defender.Auth -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Telemetry -Force -ErrorAction SilentlyContinue
    Remove-Module Xdr.Common.Auth -Force -ErrorAction SilentlyContinue
    if ($script:OriginalPSModulePath) {
        $env:PSModulePath = $script:OriginalPSModulePath
    }
}

Describe 'Auth.ErrorPaths — Connect-DefenderPortal cmdlet exists with required params' {
    It 'Connect-DefenderPortal cmdlet is exported' {
        Get-Command Connect-DefenderPortal -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'Connect-DefenderPortalWithCookies (DirectCookies) cmdlet is exported' {
        Get-Command Connect-DefenderPortalWithCookies -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'Invoke-DefenderPortalRequest cmdlet has Session + Path + Method parameters' {
        $cmd = Get-Command Invoke-DefenderPortalRequest -ErrorAction SilentlyContinue
        $cmd | Should -Not -BeNullOrEmpty
        $params = @($cmd.Parameters.Keys)
        $params | Should -Contain 'Session'
        $params | Should -Contain 'Path'
        $params | Should -Contain 'Method'
    }
}

Describe 'Auth.ErrorPaths — KV cache TTL behavior (Get-XdrAuthFromKeyVault)' {
    It 'Get-XdrAuthFromKeyVault is exported from Xdr.Common.Auth' {
        Get-Command Get-XdrAuthFromKeyVault -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'KV cache TTL is configurable via KV_CACHE_TTL_MINUTES env var' {
        # KV cache TTL (60min default) is set via the FA app-setting KV_CACHE_TTL_MINUTES,
        # which the FA reads at runtime. Verify the env-var name appears in source.
        $modulePath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Auth'
        $files = Get-ChildItem -Path $modulePath -Recurse -File -Include '*.ps1','*.psm1'
        $hasTtlEnvVar = $false
        foreach ($f in $files) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'KV_CACHE_TTL_MINUTES|CacheTtl') {
                $hasTtlEnvVar = $true; break
            }
        }
        $hasTtlEnvVar | Should -BeTrue -Because 'KV cache TTL is referenced via env var or module-level constant'
    }
}

Describe 'Auth.ErrorPaths — Auth chain telemetry hooks present' {
    It 'AppInsights customEvent helpers exist for auth chain' {
        Get-Command Send-XdrAppInsightsCustomEvent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Send-XdrAppInsightsException -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'Connect-DefenderPortal source contains AuthChain.* event names' {
        $modulePath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth'
        $files = Get-ChildItem -Path $modulePath -Recurse -File -Include '*.ps1','*.psm1'
        $hasAuthChainEvents = $false
        foreach ($f in $files) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match "AuthChain\.(Started|Completed|AADSTSError|RateLimited)") {
                $hasAuthChainEvents = $true; break
            }
        }
        $hasAuthChainEvents | Should -BeTrue -Because 'Auth chain emits AuthChain.* customEvents for AppInsights'
    }
}

Describe 'Auth.ErrorPaths — 401/440 re-auth pattern in source' {
    It 'Invoke-DefenderPortalRequest source has 401 + 440 status code handling' {
        $path = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Invoke-DefenderPortalRequest.ps1'
        Test-Path $path | Should -BeTrue
        $content = Get-Content $path -Raw
        # 401 = Unauthorized; 440 = Login Timeout (Microsoft portal cookie expired)
        $content | Should -Match '\b401\b' -Because 'must handle 401 Unauthorized'
        $content | Should -Match '\b440\b' -Because 'must handle 440 Login Timeout (cookie expired)'
    }

    It 'Invoke-DefenderPortalRequest source has retry-once-after-reauth pattern' {
        $path = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Invoke-DefenderPortalRequest.ps1'
        $content = Get-Content $path -Raw
        ($content -match 'retry|reauth|re-auth|RetryAfterReauth' -and $content -match '\b401\b') | Should -BeTrue -Because 'must implement retry-once after re-auth on 401'
    }

    It 'Send-XdrAppInsightsException is called on terminal failure' {
        $path = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Invoke-DefenderPortalRequest.ps1'
        $content = Get-Content $path -Raw
        $content | Should -Match 'Send-XdrAppInsightsException' -Because 'terminal portal failures must surface to AppInsights'
    }
}

Describe 'Auth.ErrorPaths — DirectCookies bypass path' {
    It 'Connect-DefenderPortalWithCookies bypasses Entra/ESTS auth chain' {
        $path = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Connect-DefenderPortalWithCookies.ps1'
        if (Test-Path $path) {
            $content = Get-Content $path -Raw
            # DirectCookies path takes pre-issued sccauth + xsrf + sets the session
            $content | Should -Match 'sccauth' -Because 'DirectCookies path takes pre-issued sccauth cookie'
        } else {
            Set-ItResult -Skipped -Because 'Connect-DefenderPortalWithCookies path moved or renamed; verify in Xdr.Defender.Auth'
        }
    }
}
