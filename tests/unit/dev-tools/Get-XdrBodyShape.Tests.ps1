#Requires -Version 7.4
# V10 (§21.1) · table test for the SHARED shape oracle (Get-XdrBodyShape) — the single classifier that drives
# runtime fan-out for EVERY catalogued op. Build-EvidenceIndex + Build-Catalogue's LiveCaptured AND (after V4) its
# Validated path all route through it; a wrapper mislabeled singleObject silently collapses a whole list to ONE row.
# This pins the load-bearing discriminations the OLD inline classifier got wrong (the 24-op flip class): a
# non-canonical single array with only metadata siblings IS a list; a record with several arrays or substantive
# siblings is NOT; the MTO one-level descent; and the empty-capture shape V5's merge waterfall keys off. Bodies are
# built via `ConvertFrom-Json -AsHashtable` (the runtime's own parse) so the test exercises the real input shape.

BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
    . (Join-Path $repo 'dev-tools/lib/Get-XdrBodyShape.ps1')
    function B([string]$json) { $json | ConvertFrom-Json -AsHashtable -Depth 25 }
}

Describe 'Get-XdrFieldUnion · F4 projection faithfulness (union keys across ALL items, not item[0])' {
    It 'unions keys that appear only in LATER items (the sparse-field drop class)' {
        $o = Get-XdrBodyShape (B '{"value":[{"a":1},{"a":2,"b":20},{"c":"z"}]}')
        @($o.FieldUnion.Keys | Sort-Object) | Should -Be @('a','b','c')   # item[0] had only 'a'; b/c recovered
    }
    It 'the representative value is the FIRST NON-NULL across items (faithful scalar-vs-<key>Json classification)' {
        $o = Get-XdrBodyShape (B '{"value":[{"obj":null},{"obj":{"nested":1}}]}')
        $o.FieldUnion['obj'] -is [System.Collections.IDictionary] | Should -BeTrue   # null in item[0] upgraded to the object in item[1]
    }
    It 'returns a Hashtable with .ContainsKey (NOT an OrderedDictionary · the Build-Catalogue consumer calls .ContainsKey)' {
        (Get-XdrBodyShape (B '{"value":[{"EventTime":"t"}]}')).FieldUnion.ContainsKey('EventTime') | Should -BeTrue
    }
    It 'a bareArray unions across all elements' {
        @((Get-XdrBodyShape (B '[{"x":1},{"y":2}]')).FieldUnion.Keys | Sort-Object) | Should -Be @('x','y')
    }
    It 'a singleObject FieldUnion is the record''s own keys' {
        $o = Get-XdrBodyShape (B '{"BuiltInTags":[1],"UserTags":[2],"name":"n"}')
        $o.Shape | Should -Be 'singleObject'
        @($o.FieldUnion.Keys | Sort-Object) | Should -Be @('BuiltInTags','name','UserTags')   # Sort-Object is case-insensitive: B, n, U
    }
    It 'an empty list or a scalar body yields a null FieldUnion (no fields)' {
        (Get-XdrBodyShape (B '{"value":[]}')).FieldUnion | Should -BeNullOrEmpty
        (Get-XdrBodyShape (B '5')).FieldUnion | Should -BeNullOrEmpty
    }
}

Describe 'Get-XdrBodyShape · shared shape oracle (V10)' {
    It 'a top-level JSON array is bareArray with the element count' {
        $o = Get-XdrBodyShape (B '[{"a":1},{"a":2}]')
        $o.Shape | Should -Be 'bareArray'; $o.RowCount | Should -Be 2; $o.ItemsContainer | Should -BeNullOrEmpty
    }
    It 'a canonical list key (Results) is a wrapper · ItemsContainer=Results · FirstItem is the first record' {
        $o = Get-XdrBodyShape (B '{"Results":[{"ActionId":"a"},{"ActionId":"b"}],"Count":2}')
        $o.Shape | Should -Be 'wrapper'; $o.ItemsContainer | Should -Be 'Results'; $o.RowCount | Should -Be 2
        $o.FirstItem.ActionId | Should -Be 'a'
    }
    It 'a NON-canonical single array with only pagination-metadata siblings is a wrapper (the inline classifier MISSED this · flip class)' {
        $o = Get-XdrBodyShape (B '{"rules":[{"id":1}],"totalCount":1,"nextLink":"x"}')
        $o.Shape | Should -Be 'wrapper'; $o.ItemsContainer | Should -Be 'rules'; $o.RowCount | Should -Be 1
    }
    It 'a record with MULTIPLE arrays is singleObject (no fan-out · arrays fold to <key>Json columns)' {
        $o = Get-XdrBodyShape (B '{"BuiltInTags":["a"],"UserDefinedTags":["b"],"DynamicRulesTags":[]}')
        $o.Shape | Should -Be 'singleObject'; $o.ItemsContainer | Should -BeNullOrEmpty; $o.RowCount | Should -Be 1
    }
    It 'a single non-canonical array WITH substantive entity siblings is singleObject (a record, not a list)' {
        $o = Get-XdrBodyShape (B '{"Sha1":"abc","FileName":"f.exe","RelatedEntities":[{"Type":"File"}]}')
        $o.Shape | Should -Be 'singleObject'; $o.ItemsContainer | Should -BeNullOrEmpty
    }
    It 'an MTO {result:{value:[...]}} envelope descends ONE level · ItemsContainer=value · ItemsPath=result,value' {
        $o = Get-XdrBodyShape (B '{"isMtoResponse":true,"metadata":{},"result":{"value":[{"id":1},{"id":2}]}}')
        $o.Shape | Should -Be 'wrapper'; $o.ItemsContainer | Should -Be 'value'; $o.RowCount | Should -Be 2
        ($o.ItemsPath -join '.') | Should -Be 'result.value'
    }
    It 'a scalar/null body is singleObject with zero rows' {
        (Get-XdrBodyShape (B '42')).Shape | Should -Be 'singleObject'
        (Get-XdrBodyShape (B '42')).RowCount | Should -Be 0
        (Get-XdrBodyShape $null).RowCount | Should -Be 0
    }
    It 'an EMPTY canonical wrapper ({value:[]}) is wrapper · FirstItem null · RowCount 0 (the V5 empty-capture case)' {
        $o = Get-XdrBodyShape (B '{"value":[]}')
        $o.Shape | Should -Be 'wrapper'; $o.ItemsContainer | Should -Be 'value'; $o.RowCount | Should -Be 0
        $o.FirstItem | Should -BeNullOrEmpty
    }
    It 'is DETERMINISTIC · the same body yields the same verdict across repeated calls (sorted key walks)' {
        $json = '{"zebra":[{"id":1}],"totalCount":1}'
        $a = Get-XdrBodyShape (B $json); $b = Get-XdrBodyShape (B $json)
        $a.Shape | Should -Be $b.Shape; $a.ItemsContainer | Should -Be $b.ItemsContainer
        $a.Shape | Should -Be 'wrapper'; $a.ItemsContainer | Should -Be 'zebra'   # single array + only-metadata sibling
    }
}
