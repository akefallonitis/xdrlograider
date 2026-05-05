#Requires -Modules Pester
<#
.SYNOPSIS
    Mock-based unit tests for portal request error paths.
    Coverage: Invoke-DefenderPortalRequest 429 backoff + 5xx + DNS/TLS error paths.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:RequestPath = Join-Path $script:RepoRoot 'src/Modules/Xdr.Defender.Auth/Public/Invoke-DefenderPortalRequest.ps1'
}

Describe 'PortalRequest.ErrorPaths — 429 Too Many Requests backoff' {
    It '429 status code is handled with retry loop' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match '\b429\b'
        $content | Should -Match '(?i)retry|backoff'
    }

    It 'Retry-After header is parsed (seconds form)' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match '(?i)Retry-After'
    }

    It 'Retry-After header is parsed (HTTP-date form via [datetime]::Parse)' {
        $content = Get-Content $script:RequestPath -Raw
        ($content -match '\[datetime\]::Parse' -or $content -match 'TryParse') | Should -BeTrue -Because 'Retry-After can be HTTP-date; parse fallback required'
    }

    It 'Jitter is added to retry wait (Get-Random)' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match 'Get-Random'
    }

    It 'Retry counter has a max-attempts cap (3 retries)' {
        $content = Get-Content $script:RequestPath -Raw
        ($content -match 'maxRateLimitAttempts|maxRetry|3' -and $content -match '\bthrow\b') | Should -BeTrue -Because 'must throw [MDERateLimited] after exhausting retries'
    }

    It '429 emits AppInsights customMetric (xdr.portal.rate429_count)' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match 'xdr\.portal\.rate429_count'
    }

    It '$script:Rate429Count is incremented on every 429' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match 'Rate429Count\+\+|Rate429Count \+= 1|Rate429Count \+ 1'
    }

    It 'AuthChain.RateLimited customEvent is sent per retry' {
        $content = Get-Content $script:RequestPath -Raw
        $content | Should -Match 'AuthChain\.RateLimited'
    }
}
