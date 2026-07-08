#Requires -Version 7.4
# cat-1 · ENVELOPE-COLLISION rewrite in Get-XdrSafeColumnName. A projected column whose name case-collides with one of
# the 9 universal envelope columns (Category/Subcategory/Operation/Portal/RecordId/ParentRecordId/CorrelationId/
# RawJson/TimeGenerated) MUST be suffixed `_x` so it coexists with the envelope column — Log Analytics column names are
# case-INSENSITIVE, so a projected `category` would otherwise be a DUPLICATE of the envelope `Category` (the parser's
# envelope value and the projected value would fight at ingest; live-confirmed silent-null class). Surfaced by cat-1
# ExposureManagement (a recommendation's `category` field vs the table-group `Category` envelope). The rewrite is the
# SINGLE canonical Get-XdrSafeColumnName shared by the parser, Build-PerCategorySchema, Validate-Manifests and
# Build-Catalogue, so a colliding name is identical at every stage. RED-demonstrable: drop the envelope check ->
# `category` returns `category` -> the Validate-Manifests schema-parity gate FAILS (Inactive · blocks push).

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    Import-Module (Join-Path $repo 'src/Modules/Xdr.Common.Parser/Xdr.Common.Parser.psd1') -Force -DisableNameChecking
    $script:envNames = @(Get-XdrEnvelopeColumns).name
}

Describe 'cat-1 · Get-XdrSafeColumnName envelope-collision rewrite (projected col vs the 9 envelope cols)' {
    It 'discovers the 9 envelope columns (gate not vacuous)' {
        @($script:envNames).Count | Should -Be 9
    }
    It 'a projected column matching an envelope name (any case) is suffixed _x' {
        foreach ($e in $script:envNames) {
            Get-XdrSafeColumnName -Name $e | Should -Be "${e}_x" -Because "projected '$e' duplicates the envelope column"
            $lower = $e.ToLower()
            if ($lower -ne $e) {
                Get-XdrSafeColumnName -Name $lower | Should -Be "${lower}_x" -Because "LA is case-insensitive: '$lower' collides with envelope '$e'"
            }
        }
    }
    It 'the concrete cat-1 case: category -> category_x' {
        Get-XdrSafeColumnName -Name 'category' | Should -Be 'category_x'
    }
    It 'a NON-colliding projected column is UNCHANGED (no false rewrite)' {
        foreach ($n in @('score','lastStateChange','id','maxScore','isDisabled','recommendationName','severity')) {
            Get-XdrSafeColumnName -Name $n | Should -Be $n
        }
    }
    It 'an LA-reserved name rewrites — incl. the cat-1-added documented set (live-proved by the Exposure table deploy)' {
        Get-XdrSafeColumnName -Name 'TimeGenerated'        | Should -Be 'TimeGenerated_x'
        Get-XdrSafeColumnName -Name 'Type'                 | Should -Be 'Type_x'
        Get-XdrSafeColumnName -Name '_etag'                | Should -Be 'etag_x'
        # cat-1 deploy blocker: the live table PUT returned "Columns 'title' are invalid or reserved" -> Title/title MUST rewrite
        Get-XdrSafeColumnName -Name 'title'                | Should -Be 'title_x'
        Get-XdrSafeColumnName -Name 'Title'                | Should -Be 'Title_x'
        Get-XdrSafeColumnName -Name 'UniqueId'             | Should -Be 'UniqueId_x'
        Get-XdrSafeColumnName -Name 'BilledSize'           | Should -Be 'BilledSize_x'
        Get-XdrSafeColumnName -Name 'IsBillable'           | Should -Be 'IsBillable_x'
        Get-XdrSafeColumnName -Name 'InvalidTimeGenerated' | Should -Be 'InvalidTimeGenerated_x'
    }
    It 'id is NOT reserved on the live estate — stays id (the pilot + Exposure both ship it; adding it would regress)' {
        Get-XdrSafeColumnName -Name 'id' | Should -Be 'id'
    }
}
