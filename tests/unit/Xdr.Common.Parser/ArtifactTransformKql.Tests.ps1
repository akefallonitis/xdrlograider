#Requires -Version 7.4
# GM-2 · Get-XdrArtifactTransformKql is THE single-source carry of a per-category-schema artifact's DCR dataFlow
# transformKql into a deploy template. BOTH deploy writers (dev-tools/Build-MainTemplate.ps1 Get-StreamInfo · the SOLE
# marketplace writer · and tools/Onboard-CategorySurgical.ps1 · the surgical add) call it — neither hardcodes 'source'.
# Under approach B every category is the identity 'source'; the helper must (a) carry a non-identity transform VERBATIM
# (so a future artifact's transform is never silently dropped) and (b) fall back to 'source' iff absent/empty/blank.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    $env:PSModulePath = (Join-Path $repo 'src\Modules') + [IO.Path]::PathSeparator + $env:PSModulePath
    Import-Module Xdr.Common.Parser -Force -DisableNameChecking
    # Build a DcrResource exactly as the artifact reaches the writers: ConvertFrom-Json (PSCustomObject).
    function New-Dcr([string] $Json) { $Json | ConvertFrom-Json }
}

Describe 'GM-2 · Get-XdrArtifactTransformKql (single-source dataFlow transformKql carry)' {
    It 'carries a NON-identity transformKql VERBATIM (never collapses it to source)' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[{"transformKql":"source | extend _x = toint(Foo)","outputStream":"Custom-X"}]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source | extend _x = toint(Foo)'
    }
    It 'returns the identity transform when the artifact carries source (the B common case)' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[{"transformKql":"source","outputStream":"Custom-X"}]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source'
    }
    It 'falls back to source when properties has NO dataFlows (StrictMode-safe · guarded by PSObject.Properties)' {
        $dcr = New-Dcr '{"properties":{"streamDeclarations":{"Custom-X":{"columns":[]}}}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source'
    }
    It 'falls back to source when dataFlows is an EMPTY array' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source'
    }
    It 'falls back to source when transformKql is whitespace-only' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[{"transformKql":"   "}]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source'
    }
    It 'falls back to source when transformKql is null' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[{"transformKql":null}]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source'
    }
    It 'takes dataFlows[0] when multiple flows are present (single-stream by construction · first wins)' {
        $dcr = New-Dcr '{"properties":{"dataFlows":[{"transformKql":"source | first"},{"transformKql":"source | second"}]}}'
        Get-XdrArtifactTransformKql -DcrResource $dcr | Should -BeExactly 'source | first'
    }
}
