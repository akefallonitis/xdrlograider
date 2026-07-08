#Requires -Version 7.4
# T4a (audit 2026-06-12) · ONE-POLL-PER-ENDPOINT ship gate. The Dedupe stage correctly CLASSIFIES SamePath twins
# (IsCanonical=False · AliasFor) but the final Shipped recompute never read that classification — so BOTH members
# of a SamePath group could ship (found live in the catalogue: Configuration.GetCloudAppsSettings + CloudApps.
# GetSettings both Shipped; VulnerabilityManagement.ListChangeEvents shipped TWICE) = a double-poll of the same
# endpoint (duplicate rows + double load) the moment the category onboards. The gate: per SamePath endpoint group,
# exactly ONE record ships — canonical preferred; an operator-curated ALIAS may legitimately carry the slot when
# the canonical does NOT ship (the live-proven pilot op MultiTenant.GetTenantContext is exactly that promotion —
# pinned below so no future "only canonical ships" simplification can break the pilot).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $script:cat = Get-Content (Join-Path $repo 'references\inventory\nodoc-defender-xdr\catalogue.json') -Raw | ConvertFrom-Json
    $script:shipped = @($script:cat.Operations | Where-Object { $_.Shipped })
}

Describe 'T4a · one-poll-per-endpoint (SamePath ship dedup)' {
    It 'no two Shipped ops poll the same SubPortal+Path+Method endpoint' {
        $groups = $script:shipped | Group-Object { "$($_.SubPortal)|$($_.Path)|$($_.Method)" } | Where-Object { $_.Count -gt 1 }
        $offenders = @($groups | ForEach-Object { ($_.Group | ForEach-Object { $_.OperationId }) -join ' + ' })
        $offenders | Should -BeNullOrEmpty -Because "each endpoint must be polled by exactly ONE shipped op (double-poll = duplicate rows): $($offenders -join ' · ')"
    }
    It 'a SamePath group with a SHIPPED canonical never also ships the alias (canonical wins)' {
        foreach ($o in @($script:shipped | Where-Object { -not $_.IsCanonical })) {
            $twin = @($script:shipped | Where-Object { $_.IsCanonical -and $_.OperationId -ne $o.OperationId -and
                       $_.SubPortal -eq $o.SubPortal -and $_.Path -eq $o.Path -and $_.Method -eq $o.Method })
            $twin | Should -BeNullOrEmpty -Because "$($o.OperationId) (non-canonical) ships alongside its shipped canonical twin"
        }
    }
    It 'PILOT PIN · MultiTenant.GetTenantContext (curated alias · live-proven) KEEPS shipping — its canonical twin does not ship' {
        $alias = $script:cat.Operations | Where-Object { $_.OperationId -eq 'MultiTenant.GetTenantContext' }
        $alias.Shipped | Should -BeTrue -Because 'the pilot op is the operator-curated promotion over the mechanical canonical pick'
        $canon = $script:cat.Operations | Where-Object { $_.OperationId -eq 'Configuration.GetTenantContext' }
        $canon.Shipped | Should -BeFalse
    }
    It 'a demoted SamePath twin records WHY (ShipHeldReason provenance · never a silent unship)' {
        $demoted = @($script:cat.Operations | Where-Object { $_.DuplicateClass -eq 'SamePath' -and -not $_.Shipped -and $_.ShipHeldReason })
        # CloudApps double-poll: a still-live SamePath demotion — the canonical carries the endpoint, the demoted twin names the winner
        $cas = $script:cat.Operations | Where-Object { $_.OperationId -eq 'Configuration.GetCloudAppsSettings' }
        $cas.Shipped | Should -BeFalse -Because 'CloudApps.GetSettings (canonical) carries this endpoint'
        $cas.ShipHeldReason | Should -Match 'CloudApps\.GetSettings'
        # VM double-poll: VulnerabilityManagement is NOW SHIPPING (cat-7 finalized 2026-06-25 · the TVM capture born-typed
        # the ops + bound the {assetId} fan-out), so the SamePath ListChangeEvents group ships EXACTLY ONE twin (the
        # canonical) and DEMOTES the other — which still records WHY (no silent unship; provenance preserved). This is the
        # SAME one-poll-per-endpoint discipline as the CloudApps case above (was: both twins un-shipped while deferred).
        $vmTwin = @($script:cat.Operations | Where-Object { $_.OperationId -eq 'VulnerabilityManagement.ListChangeEvents' })
        $vmTwin | Should -Not -BeNullOrEmpty -Because 'the SamePath twins both remain in the catalogue (one ships, one demoted)'
        @($vmTwin | Where-Object { $_.Shipped }).Count | Should -Be 1 -Because 'exactly ONE ListChangeEvents twin ships (one poll per endpoint)'
        @($vmTwin | Where-Object { -not $_.Shipped -and -not $_.ShipHeldReason }) | Should -BeNullOrEmpty -Because 'the demoted VM twin records WHY (provenance · never a silent unship)'
    }
}
