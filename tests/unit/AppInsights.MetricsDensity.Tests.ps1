#Requires -Modules Pester
<#
.SYNOPSIS
    v0.1.0-beta production-readiness polish — customMetrics density gates.

.DESCRIPTION
    Static text-grep gates that assert each hot-path file emits the
    Send-XdrAppInsightsCustomMetric calls the v0.1.0-beta observability plan
    requires. Pattern modelled on the existing static-grep gates in
    Logging.iter14.Tests.ps1 — failure of any gate here means an operator
    dashboard panel will be missing data.

    Gates by name:
      Metrics.TierPoll.PollDuration       Invoke-MDETierPoll emits
                                          xdr.poll.duration_ms with Stream + Tier.
      Metrics.Ingest.RowsBytesLatency     Send-ToLogAnalytics emits the 5
                                          per-batch ingest metrics
                                          (xdr.ingest.rows + bytes_compressed
                                          + compression_ratio + retry_count
                                          + dce_latency_ms).
      Metrics.Ingest.Rate429Count         Send-ToLogAnalytics emits
                                          xdr.ingest.rate429_count on 429
                                          retry path.
      Metrics.Dlq.PushPopDepth            Push-XdrIngestDlq emits
                                          xdr.dlq.push_count;
                                          Pop-XdrIngestDlq emits
                                          xdr.dlq.pop_count + xdr.dlq.depth.
      Metrics.KvCacheHitMiss              Get-XdrAuthFromKeyVault emits
                                          xdr.kv.cache_hit on hit and
                                          xdr.kv.cache_miss on miss.
      Metrics.Portal.Rate429              Invoke-DefenderPortalRequest emits
                                          xdr.portal.rate429_count on 429.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    $script:TierPollPath        = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Client' 'Public' 'Invoke-MDETierPoll.ps1'
    $script:SendToLogAnPath     = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Send-ToLogAnalytics.ps1'
    $script:PushDlqPath         = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Push-XdrIngestDlq.ps1'
    $script:PopDlqPath          = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Sentinel.Ingest' 'Public' 'Pop-XdrIngestDlq.ps1'
    $script:KvAuthPath          = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Common.Auth' 'Public' 'Get-XdrAuthFromKeyVault.ps1'
    $script:PortalRequestPath   = Join-Path $script:RepoRoot 'src' 'Modules' 'Xdr.Defender.Auth' 'Public' 'Invoke-DefenderPortalRequest.ps1'
}

Describe 'Metrics.TierPoll.PollDuration — xdr.stream.poll_duration_ms emitted per stream with Tier dimension' {

    # iter-14.0 Phase 2 (v0.1.0 GA): renamed from xdr.poll.duration_ms to
    # xdr.stream.poll_duration_ms to align with Section 2.3 native-routing rubric
    # (consistent xdr.stream.* prefix with xdr.stream.rows_emitted). Old metric
    # name retired — operators with existing KQL must update to the new name.
    It 'Invoke-MDETierPoll calls Send-XdrAppInsightsCustomMetric with -MetricName xdr.stream.poll_duration_ms' {
        $src = Get-Content -LiteralPath $script:TierPollPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.stream\.poll_duration_ms'"
    }

    It 'Invoke-MDETierPoll also emits xdr.stream.rows_emitted (Phase 2 addition replacing Stream.Polled customEvent)' {
        $src = Get-Content -LiteralPath $script:TierPollPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.stream\.rows_emitted'"
    }

    It 'the call site stamps Stream + Tier + Success dimensions' {
        $src = Get-Content -LiteralPath $script:TierPollPath -Raw
        # Properties hashtable must include Stream + Tier (for pivot) + Success
        # (post-Phase-2: Success replaced the old Stream.Polled customEvent's success boolean).
        ($src -match 'xdr\.stream\.poll_duration_ms[\s\S]{0,400}Stream\s*=\s*\$stream[\s\S]{0,200}Tier\s*=\s*\$Tier[\s\S]{0,200}Success\s*=') | Should -BeTrue
    }
}

Describe 'Metrics.Ingest.RowsBytesLatency — Send-ToLogAnalytics emits the 5 per-batch ingest metrics' {

    It 'emits xdr.ingest.rows' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.rows'"
    }

    It 'emits xdr.ingest.bytes_compressed' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.bytes_compressed'"
    }

    It 'emits xdr.ingest.compression_ratio' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.compression_ratio'"
    }

    It 'emits xdr.ingest.retry_count' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.retry_count'"
    }

    It 'emits xdr.ingest.dce_latency_ms' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.dce_latency_ms'"
    }
}

Describe 'Metrics.Ingest.Rate429Count — DCE 429s tracked per stream' {

    It 'Send-ToLogAnalytics emits xdr.ingest.rate429_count on the 429 retry path' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.ingest\.rate429_count'"
    }
}

Describe 'Metrics.Dlq.PushPopDepth — DLQ push/pop counters + depth gauge' {

    It 'Push-XdrIngestDlq emits xdr.dlq.push_count' {
        $src = Get-Content -LiteralPath $script:PushDlqPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.dlq\.push_count'"
    }

    It 'Pop-XdrIngestDlq emits xdr.dlq.pop_count' {
        $src = Get-Content -LiteralPath $script:PopDlqPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.dlq\.pop_count'"
    }

    It 'Pop-XdrIngestDlq emits xdr.dlq.depth gauge' {
        $src = Get-Content -LiteralPath $script:PopDlqPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.dlq\.depth'"
    }
}

Describe 'Metrics.KvCacheHitMiss — KV cache hit/miss counters' {

    It 'Get-XdrAuthFromKeyVault emits xdr.kv.cache_hit on cache hit' {
        $src = Get-Content -LiteralPath $script:KvAuthPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.kv\.cache_hit'"
    }

    It 'Get-XdrAuthFromKeyVault emits xdr.kv.cache_miss on cache miss / first-fetch / TTL-evict / Force' {
        $src = Get-Content -LiteralPath $script:KvAuthPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.kv\.cache_miss'"
    }
}

Describe 'Metrics.Portal.Rate429 — portal-side 429 counter' {

    It 'Invoke-DefenderPortalRequest emits xdr.portal.rate429_count on 429 path' {
        $src = Get-Content -LiteralPath $script:PortalRequestPath -Raw
        $src | Should -Match "Send-XdrAppInsightsCustomMetric\s+-MetricName\s+'xdr\.portal\.rate429_count'"
    }
}

Describe 'Metrics.ExceptionTracking — exception coverage on hot-path catches' {

    It 'Invoke-MDETierPoll emits Send-XdrAppInsightsException in stream catch + DLQ-drain catch' {
        $src = Get-Content -LiteralPath $script:TierPollPath -Raw
        # At least 2 emissions: stream-level catch + DLQ-drain catch.
        ($src | Select-String -Pattern 'Send-XdrAppInsightsException' -AllMatches).Matches.Count |
            Should -BeGreaterOrEqual 2
    }

    It 'Send-ToLogAnalytics emits Send-XdrAppInsightsException on terminal failure (before throw)' {
        $src = Get-Content -LiteralPath $script:SendToLogAnPath -Raw
        $src | Should -Match 'Send-XdrAppInsightsException'
    }

    It 'Push-XdrIngestDlq emits Send-XdrAppInsightsException on Storage Tables write failure' {
        $src = Get-Content -LiteralPath $script:PushDlqPath -Raw
        $src | Should -Match 'Send-XdrAppInsightsException'
    }

    It 'Pop-XdrIngestDlq emits Send-XdrAppInsightsException on query / decode failures' {
        $src = Get-Content -LiteralPath $script:PopDlqPath -Raw
        $src | Should -Match 'Send-XdrAppInsightsException'
    }

    It 'Invoke-DefenderPortalRequest emits Send-XdrAppInsightsException on portal failure' {
        $src = Get-Content -LiteralPath $script:PortalRequestPath -Raw
        $src | Should -Match 'Send-XdrAppInsightsException'
    }

    It 'Get-XdrAuthFromKeyVault emits Send-XdrAppInsightsException on KV read failure' {
        $src = Get-Content -LiteralPath $script:KvAuthPath -Raw
        $src | Should -Match 'Send-XdrAppInsightsException'
    }
}
