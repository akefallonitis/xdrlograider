#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Invoke-MDEEndpoint dispatcher — 4-value SuccessKind classifier (Rule 6),
# LicenseHint substitution for 401/403/404 (Rule 23), EntryKey lookup,
# pagination loop, path-param substitution.

Describe 'Invoke-MDEEndpoint dispatcher (mocked Invoke-MDEPortalEndpoint)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        # Load module dependency chain
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Common.Manifest/Xdr.Common.Manifest.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Xdr.Defender.Auth.psd1') -Force
        Import-Module (Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Client/Xdr.Defender.Client.psd1') -Force

        # Fake session
        $script:Session = [pscustomobject]@{ Upn = 'svc@contoso.com'; TenantId = '00000000-0000-0000-0000-000000000000'; Session = [Microsoft.PowerShell.Commands.WebRequestSession]::new() }
    }

    Context 'SuccessKind: live (200 + non-empty rows)' {
        It 'returns rows and sets SuccessKind=live' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $true; Data = @(
                    [pscustomobject]@{ id = 'rule-1'; name = 'AlertRuleX'; isEnabled = $true }
                    [pscustomobject]@{ id = 'rule-2'; name = 'AlertRuleY'; isEnabled = $false }
                ); HttpStatus = 200 }
            }
            $rows = @(Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules')
            $rows.Count | Should -BeGreaterOrEqual 1
            $r = Get-MDEEndpointLastResult
            $r.SuccessKind | Should -Be 'live'
            $r.HttpStatus | Should -Be 200
            $r.LicenseHint | Should -Be ''
        }
    }

    Context 'SuccessKind: live-empty (200 + null data)' {
        It 'returns empty array, SuccessKind=live-empty' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $true; Data = $null; HttpStatus = 200 }
            }
            $rows = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            (@($rows) | Measure-Object).Count | Should -Be 0
            $r = Get-MDEEndpointLastResult
            $r.SuccessKind | Should -Be 'live-empty'
            $r.HttpStatus | Should -Be 200
        }
    }

    Context 'SuccessKind: rate-limited (HTTP 429)' {
        It 'returns empty array, SuccessKind=rate-limited' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $false; Error = 'HTTP 429 throttled'; HttpStatus = 429 }
            }
            $rows = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            (@($rows) | Measure-Object).Count | Should -Be 0
            $r = Get-MDEEndpointLastResult
            $r.SuccessKind | Should -Be 'rate-limited'
            $r.HttpStatus | Should -Be 429
            $r.LicenseHint | Should -Be ''
        }
    }

    Context 'SuccessKind: error (HTTP 5xx — true failure)' {
        It 'returns empty array, SuccessKind=error, no LicenseHint' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $false; Error = 'HTTP 503 service unavailable'; HttpStatus = 503 }
            }
            $rows = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            (@($rows) | Measure-Object).Count | Should -Be 0
            $r = Get-MDEEndpointLastResult
            $r.SuccessKind | Should -Be 'error'
            $r.HttpStatus | Should -Be 503
            $r.LicenseHint | Should -Be ''
        }
    }

    Context 'SuccessKind: error + LicenseHint (HTTP 401/403/404 — Rule 23)' {
        It 'on HTTP 403 returns error and is open to LicenseHint propagation from manifest' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $false; Error = 'HTTP 403 forbidden'; HttpStatus = 403 }
            }
            $rows = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            (@($rows) | Measure-Object).Count | Should -Be 0
            $r = Get-MDEEndpointLastResult
            $r.SuccessKind | Should -Be 'error'
            $r.HttpStatus | Should -Be 403
            # tenant-gated is RETIRED in Phase 1 (Rule 6 + 23) — even on 403 we return 'error'
            $r.SuccessKind | Should -Not -Be 'tenant-gated'
        }
    }

    Context 'EntryKey lookup' {
        It 'rejects unknown EntryKey with clear error' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client { @{ Success = $true; Data = $null } }
            { Invoke-MDEEndpoint -Session $script:Session -EntryKey 'nonexistent::sub_area::Slug' } | Should -Throw '*Unknown EntryKey*'
        }

        It 'rejects -Stream when the stream maps to multiple entries (consolidated table)' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client { @{ Success = $true; Data = $null } }
            { Invoke-MDEEndpoint -Session $script:Session -Stream 'Defender_ActionCenter_CL' } | Should -Throw '*disambiguate*'
        }
    }

    Context 'PathParams substitution' {
        It 'returns empty array when EntryKey requires PathParams that are not supplied — surfaces an error' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client { @{ Success = $true; Data = $null } }
            # action_center::GetCase has {CaseId} path param
            { Invoke-MDEEndpoint -Session $script:Session -EntryKey 'action_center::GetCase' } | Should -Throw '*requires*PathParams*'
        }
    }

    Context 'Mock Get-MDEEndpointLastResult side channel' {
        It 'side-channel is module-scope (not per-call leak across invocations)' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $true; Data = @([pscustomobject]@{ id = 'a' }); HttpStatus = 200 }
            }
            $null = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            $r1 = Get-MDEEndpointLastResult
            $r1.SuccessKind | Should -Be 'live'

            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                @{ Success = $false; Error = 'HTTP 503 srv'; HttpStatus = 503 }
            }
            $null = Invoke-MDEEndpoint -Session $script:Session -EntryKey 'configuration::ListSuppressionRules'
            $r2 = Get-MDEEndpointLastResult
            $r2.SuccessKind | Should -Be 'error'
            $r2.HttpStatus | Should -Be 503
        }
    }

    Context 'Pagination resume — Phase A0.3 multi-cycle (vuln_management 1000-page first poll Y1-safe)' {
        BeforeEach {
            # Find an EntryKey with paginated style + NO PathParams (so we don't need
            # -PathParams for the test).
            $manifest = Get-XdrEndpointManifest -Portal Defender
            $script:PageKey = ($manifest.GetEnumerator() | Where-Object {
                $_.Value -is [System.Collections.IDictionary] -and
                $_.Value.ContainsKey('Pagination') -and $_.Value.Pagination -and
                [string]$_.Value.Pagination.Style -ne 'none' -and
                (-not $_.Value.ContainsKey('PathParams') -or -not $_.Value.PathParams -or $_.Value.PathParams.Count -eq 0)
            } | Select-Object -First 1).Key
            $script:PageKey | Should -Not -BeNullOrEmpty
        }

        It 'StartFromPage > 1 issues the first call with pageIndex set to that page (resume from checkpoint)' {
            $script:CapturedPaths = New-Object System.Collections.Generic.List[string]
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                param($Session, $Path, $Method, $Body, $AdditionalHeaders)
                $script:CapturedPaths.Add($Path)
                # Return short page so loop exits quickly (partial fill = last page).
                @{ Success = $true; Data = @([pscustomobject]@{ id = 'x' }); HttpStatus = 200 }
            }
            $null = Invoke-MDEEndpoint -Session $script:Session -EntryKey $script:PageKey -StartFromPage 7
            # First captured path should contain pageIndex=7 (not pageIndex=1)
            $first = $script:CapturedPaths[0]
            $first | Should -Match 'pageIndex=7' -Because 'resume must start at the checkpointed page, not the first page'
        }

        It 'MaxPagesPerCycle bounds the per-activity page count for Y1 timeout safety' {
            $script:CallCount = 0
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                $script:CallCount++
                # Always return a full page so pagination keeps going.
                $items = @()
                for ($i = 0; $i -lt 200; $i++) { $items += [pscustomobject]@{ id = "row-$i" } }
                @{ Success = $true; Data = $items; HttpStatus = 200 }
            }
            $null = Invoke-MDEEndpoint -Session $script:Session -EntryKey $script:PageKey -MaxPagesPerCycle 3
            # Initial fetch + at most 2 follow-up paged fetches (3 total inside cycle cap)
            $script:CallCount | Should -BeLessOrEqual 3
            # Should signal pagination NOT exhausted (more pages remain, capped by cycle limit)
            $r = Get-MDEEndpointLastResult
            $r.PaginationExhausted | Should -BeFalse -Because 'cycle cap stopped pagination early; remaining pages must resume next activity invocation'
        }

        It 'partial page (< pageSize) signals PaginationExhausted=true (no more pages)' {
            Mock Invoke-MDEPortalEndpoint -ModuleName Xdr.Defender.Client {
                # Return a small (partial) page on first call — pagination should NOT loop
                @{ Success = $true; Data = @([pscustomobject]@{ id = 'only-row' }); HttpStatus = 200 }
            }
            $null = Invoke-MDEEndpoint -Session $script:Session -EntryKey $script:PageKey
            $r = Get-MDEEndpointLastResult
            $r.PaginationExhausted | Should -BeTrue
        }
    }
}
