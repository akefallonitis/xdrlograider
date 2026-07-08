#Requires -Version 7.4
# T3d (audit 2026-06-12 · operator directive "all time filters generic/consolidated/always-working across all
# cases") · the GENERIC time-value contract. The corpus declares 6 time-filter mechanisms; the runtime handled 2
# (ClientSideHighWater · ServerFromDate-as-ISO) and emitted ISO 'o' unconditionally — an epoch op got an ISO string
# the API rejects, the OData live shape `(date ge ...000Z)` was unproducible, relative-window (daysToLookBack) and
# path-located time params were unsupported. ONE Format-XdrTimeValue formatter + TimeFilter.ValueFormat/OuterFormat/
# ServerRelative/ParamLocation='path' make every corpus mode servable by manifest DATA — zero engine edits per op.

BeforeAll {
    $script:Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $script:Repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Exceptions -Force -DisableNameChecking
    Import-Module Xdr.Common.Telemetry  -Force -DisableNameChecking
    Import-Module Xdr.Common.Runtime    -Force -DisableNameChecking
    $script:Win = @{ StartUtc = '2026-06-12T00:00:00.0000000Z'; EndUtc = '2026-06-12T06:00:00.0000000Z' }
}

Describe 'T3d · Format-XdrTimeValue · one formatter for every corpus value shape' {
    It 'default/empty format = full-fidelity ISO o (back-compat · the ServerFromDate contract)' {
        InModuleScope Xdr.Common.Runtime {
            Format-XdrTimeValue -Value '2026-06-12T00:00:00.0000000Z' -Format ''          | Should -Be '2026-06-12T00:00:00.0000000Z'
            Format-XdrTimeValue -Value '2026-06-12T00:00:00.0000000Z' -Format 'Iso8601Z'  | Should -Be '2026-06-12T00:00:00.0000000Z'
        }
    }
    It 'Iso8601ZMillis = ms-precision Z (the live OData $filter shape ...000Z)' {
        InModuleScope Xdr.Common.Runtime {
            Format-XdrTimeValue -Value '2026-03-04T00:00:00.0000000Z' -Format 'Iso8601ZMillis' | Should -Be '2026-03-04T00:00:00.000Z'
        }
    }
    It 'Iso8601DateOnly = yyyy-MM-dd' {
        InModuleScope Xdr.Common.Runtime {
            Format-XdrTimeValue -Value '2026-06-12T06:30:00.0000000Z' -Format 'Iso8601DateOnly' | Should -Be '2026-06-12'
        }
    }
    It 'EpochSeconds / EpochMillis = Unix epoch integers (the integer start/end + path-located ops)' {
        InModuleScope Xdr.Common.Runtime {
            Format-XdrTimeValue -Value '1970-01-01T00:01:00.0000000Z' -Format 'EpochSeconds' | Should -Be '60'
            Format-XdrTimeValue -Value '1970-01-01T00:01:00.0000000Z' -Format 'EpochMillis'  | Should -Be '60000'
        }
    }
    It 'an unknown format token falls back to ISO o (fail-safe · never emit garbage)' {
        InModuleScope Xdr.Common.Runtime {
            Format-XdrTimeValue -Value '2026-06-12T00:00:00.0000000Z' -Format 'NoSuchFormat' | Should -Be '2026-06-12T00:00:00.0000000Z'
        }
    }
}

Describe 'T3d · ServerFromDate · ValueFormat drives the emitted wire shape' {
    It 'default (no ValueFormat) emits ISO o — the proven GetMachineTimelineEvents contract is UNCHANGED' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/t'
                TimeFilter = @{ Mode='ServerFromDate'; FieldName='EventTime'; FromDateParam='fromDate'; ToDateParam='toDate' } }
        $u = New-XdrRequestUrl -Entry $e -Window $script:Win
        $u | Should -Match 'fromDate=2026-06-12T00%3A00%3A00\.0000000Z'
        $u | Should -Match 'toDate=2026-06-12T06%3A00%3A00\.0000000Z'
    }
    It 'ValueFormat=EpochMillis emits epoch integers (the integer startTime/endTime ops — ISO would be rejected)' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/t'
                TimeFilter = @{ Mode='ServerFromDate'; FieldName='EventTime'; FromDateParam='startTime'; ToDateParam='endTime'; ValueFormat='EpochMillis' } }
        $u = New-XdrRequestUrl -Entry $e -Window $script:Win
        $u | Should -Match 'startTime=1781222400000'
        $u | Should -Match 'endTime=1781244000000'
    }
}

Describe 'T3d · ServerOData · OuterFormat=ParenOData + ms-Z produces the LIVE filter shape' {
    It 'emits $filter=(date ge 2026-03-04T00:00:00.000Z) — parenthesized + ms (the corpus live shape)' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/v'
                TimeFilter = @{ Mode='ServerOData'; FieldName='date'; Operator='ge'; OuterFormat='ParenOData'; ValueFormat='Iso8601ZMillis' } }
        $u = New-XdrRequestUrl -Entry $e -Window @{ StartUtc='2026-03-04T00:00:00.0000000Z'; EndUtc='2026-03-05T00:00:00.0000000Z' }
        $decoded = [uri]::UnescapeDataString($u)
        $decoded | Should -Match '\$filter=\(date ge 2026-03-04T00:00:00\.000Z\)'
    }
    It 'Bare (default) keeps the existing unparenthesized shape (back-compat)' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/v'
                TimeFilter = @{ Mode='ServerOData'; FieldName='EventTime'; Operator='ge' } }
        $u = New-XdrRequestUrl -Entry $e -Window $script:Win
        $decoded = [uri]::UnescapeDataString($u)
        $decoded | Should -Match '\$filter=EventTime ge 2026-06-12T00:00:00\.0000000Z'
        $decoded | Should -Not -Match '\$filter=\('
    }
}

Describe 'T3d · ServerRelative · the rolling-window param (daysToLookBack family) derives from LookbackHours' {
    It 'RelativeDays emits ceil(LookbackHours/24) days' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/r'; LookbackHours = 168
                TimeFilter = @{ Mode='ServerRelative'; RelativeParam='daysToLookBack'; ValueFormat='RelativeDays' } }
        (New-XdrRequestUrl -Entry $e -Window $script:Win) | Should -Match 'daysToLookBack=7'
    }
    It 'RelativeHours emits LookbackHours verbatim' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/r'; LookbackHours = 24
                TimeFilter = @{ Mode='ServerRelative'; RelativeParam='lookbackHours'; ValueFormat='RelativeHours' } }
        (New-XdrRequestUrl -Entry $e -Window $script:Win) | Should -Match 'lookbackHours=24'
    }
    It 'absent LookbackHours degrades to 24h-equivalent (1 day) — never an empty param' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/r'
                TimeFilter = @{ Mode='ServerRelative'; RelativeParam='daysToLookBack'; ValueFormat='RelativeDays' } }
        (New-XdrRequestUrl -Entry $e -Window $script:Win) | Should -Match 'daysToLookBack=1'
    }
}

Describe 'T3d · ParamLocation=path · time params substitute into the URL path (the epoch-in-path ops)' {
    It 'substitutes {startDate}/{endDate} path tokens with epoch-ms values' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/mail/{startDate}/{endDate}/report'
                TimeFilter = @{ Mode='ServerFromDate'; FieldName='date'; FromDateParam='startDate'; ToDateParam='endDate'; ParamLocation='path'; ValueFormat='EpochMillis' } }
        $u = New-XdrRequestUrl -Entry $e -Window $script:Win
        $u | Should -Match '/mail/1781222400000/1781244000000/report'
        $u | Should -Not -Match '\{startDate\}'
        $u | Should -Not -Match '\{endDate\}'
    }
}

Describe 'T3d · client modes stay param-free (regression pins)' {
    It 'ClientSideHighWater emits NO server time param (the GetHistory contract)' {
        $e = @{ Portal='Defender'; SubPortal='mtp'; Path='/h'
                TimeFilter = @{ Mode='ClientSideHighWater'; FieldName='EventTime' } }
        (New-XdrRequestUrl -Entry $e -Window $script:Win) | Should -Not -Match '[?&](fromDate|toDate|startTime|endTime|\$filter)='
    }
}
