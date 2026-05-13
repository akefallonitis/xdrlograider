#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Xdr.Defender.Client — Phase 1 new cmdlets:
#   Get-DefenderTenantContext         (Rule 21 dynamic regionality)
#   Get-XdrCustomCollectionRule       (Rule 8 corrected path /mtp/mdeCustomCollection)
#   Get-XdrCustomCollectionRuleById
#   Get-XdrCustomCollectionModel

Describe 'Get-DefenderTenantContext — dynamic regionality (Rule 21)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force
    }

    It 'hits the canonical apiproxy/mtp/sccManagement/mgmt/TenantContext path' {
        $script:CapturedUri = $null
        Mock Invoke-WebRequest -ModuleName Xdr.Defender.Client {
            param($Uri)
            $script:CapturedUri = $Uri
            [pscustomobject]@{
                StatusCode = 200
                Content    = '{"region":"weu","datacenter":"dc-eu-1","tenantId":"00000000-0000-0000-0000-000000000000","sku":"E5"}'
            }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $ctx = Get-DefenderTenantContext -Session $session
        $script:CapturedUri | Should -Match '/apiproxy/mtp/sccManagement/mgmt/TenantContext\?realTime=true'
        $ctx.Region | Should -Be 'weu'
        $ctx.Datacenter | Should -Be 'dc-eu-1'
        $ctx.TenantId | Should -Be '00000000-0000-0000-0000-000000000000'
        $ctx.SkuId | Should -Be 'E5'
        $ctx.ExpiresUtc | Should -BeGreaterThan ([DateTime]::UtcNow)
    }

    It 'caches in $Session.TenantContext for 24h (next call is cache hit)' {
        Mock Invoke-WebRequest -ModuleName Xdr.Defender.Client {
            [pscustomobject]@{ StatusCode = 200; Content = '{"region":"weu","datacenter":"dc","tenantId":"x","sku":"E5"}' }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $ctx1 = Get-DefenderTenantContext -Session $session
        $ctx2 = Get-DefenderTenantContext -Session $session
        Should -Invoke Invoke-WebRequest -ModuleName Xdr.Defender.Client -Times 1
        $ctx2.FetchedUtc | Should -Be $ctx1.FetchedUtc
    }

    It '-ForceRefresh bypasses the cache' {
        Mock Invoke-WebRequest -ModuleName Xdr.Defender.Client {
            [pscustomobject]@{ StatusCode = 200; Content = '{"region":"weu","datacenter":"dc","tenantId":"x","sku":"E5"}' }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Get-DefenderTenantContext -Session $session | Out-Null
        Get-DefenderTenantContext -Session $session -ForceRefresh | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName Xdr.Defender.Client -Times 2
    }

    It 'throws on non-200 status' {
        Mock Invoke-WebRequest -ModuleName Xdr.Defender.Client {
            [pscustomobject]@{ StatusCode = 401; Content = '' }
        }
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        { Get-DefenderTenantContext -Session $session } | Should -Throw '*TenantContext fetch failed*'
    }
}

Describe 'Get-XdrCustomCollectionRule — corrected path /mtp/mdeCustomCollection (Rule 8)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force
    }

    It 'invokes the corrected /mtp/mdeCustomCollection/rules path (NOT /mtp/customDataCollection)' {
        $script:CapturedPath = $null
        Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
            param($Session, $Path, $Method)
            $script:CapturedPath = $Path
            @{ Success = $true; Data = @() }
        }
        $session = [pscustomobject]@{}
        $r = Get-XdrCustomCollectionRule -Session $session
        $script:CapturedPath | Should -Be '/mtp/mdeCustomCollection/rules'
        $script:CapturedPath | Should -Not -Match '/mtp/customDataCollection'
    }

    It 'throws on failure with clear error' {
        Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
            @{ Success = $false; Error = 'HTTP 503 unavailable' }
        }
        $session = [pscustomobject]@{}
        { Get-XdrCustomCollectionRule -Session $session } | Should -Throw '*Get-XdrCustomCollectionRule failed*'
    }
}

Describe 'Get-XdrCustomCollectionRuleById — per-rule drill-down' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force
    }

    It 'URL-encodes the RuleId path segment' {
        $script:CapturedPath = $null
        Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
            param($Session, $Path, $Method)
            $script:CapturedPath = $Path
            @{ Success = $true; Data = [pscustomobject]@{} }
        }
        $session = [pscustomobject]@{}
        Get-XdrCustomCollectionRuleById -Session $session -RuleId 'rule-id with spaces & special?chars'
        $script:CapturedPath | Should -Match '^/mtp/mdeCustomCollection/rules/'
        $script:CapturedPath | Should -Not -Match ' '
        $script:CapturedPath | Should -Not -Match '\?(?!.*$)'
    }
}

Describe 'Get-XdrCustomCollectionModel — schema fetcher' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force
    }

    It 'targets /mtp/mdeCustomCollection/model' {
        $script:CapturedPath = $null
        Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
            param($Session, $Path, $Method)
            $script:CapturedPath = $Path
            @{ Success = $true; Data = [pscustomobject]@{} }
        }
        $session = [pscustomobject]@{}
        Get-XdrCustomCollectionModel -Session $session
        $script:CapturedPath | Should -Be '/mtp/mdeCustomCollection/model'
    }
}

Describe 'Get-MDEEndpointLastResult — LicenseHint field (Rule 23)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force
    }

    It 'side-channel object exposes all 6 fields including LicenseHint' {
        Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
            @{ Success = $true; Data = @([pscustomobject]@{ id = 'a' }) }
        }
        $session = [pscustomobject]@{ Upn='svc@x'; TenantId='00000000-0000-0000-0000-000000000000'; Session=[Microsoft.PowerShell.Commands.WebRequestSession]::new() }
        $null = Invoke-MDEEndpoint -Session $session -EntryKey 'configuration::ListSuppressionRules'
        $r = Get-MDEEndpointLastResult
        $r.Stream | Should -Not -BeNullOrEmpty
        $r.SuccessKind | Should -BeIn @('live','live-empty','rate-limited','error')
        $r.HttpStatus | Should -BeOfType [int]
        $r.PSObject.Properties.Name | Should -Contain 'LicenseHint'
        $r.TimestampUtc | Should -Match '\d{4}-\d{2}-\d{2}T'
    }
}
